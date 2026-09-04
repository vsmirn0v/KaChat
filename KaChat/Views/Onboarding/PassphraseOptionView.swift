import SwiftUI

/// The optional BIP39 passphrase ("25th word") step, shown after the seed-phrase backup (create)
/// or seed-phrase entry (import) and before the Welcome Guide.
///
/// Three screens rather than one. The old version was a single page of explainer cards with the
/// fields already on it and two buttons at the bottom, which asked someone to decide before it had
/// told them what they were deciding - and most people meeting this screen have never heard of a
/// passphrase. So it opens with the question, on its own, with a way to go and read about it
/// first:
///
///   1. `question` - "Did you create this seed with a passphrase?" (import) or "Do you want to add
///      a passphrase to your account?" (create). Yes / No / What is a passphrase?
///   2. `entry` - the field, with the chatting address it produces updating underneath as you
///      type. That live address is the point: it is the only direct evidence that a passphrase
///      opens a DIFFERENT account rather than protecting the same one.
///   3. `explainer` - plain-language, back only, so reading about it always returns to the choice.
///
/// The caller (`CreateWalletView` / `ImportWalletView`) performs the actual wallet commit via
/// `onProceed`, which receives the chosen passphrase ("" when there is none).
struct PassphraseOptionView: View {
    enum Mode {
        case create
        case importExisting
    }

    private enum Step {
        case question
        case entry
        case explainer
    }

    let mode: Mode
    /// The words behind this flow, for the live address preview on the entry screen. Empty is
    /// tolerated - the preview simply does not appear.
    var seedWords: [String] = []
    /// Identity derivation family, so the previewed address matches what the import will actually
    /// produce for a seed coming from another wallet.
    var family: WalletSourceFamily = .kaspaStandard
    /// Performs the create/import commit with the chosen passphrase ("" = none). Throwing surfaces
    /// an inline error here and re-enables the buttons; on success the app router swaps onboarding
    /// for the main app, so this view is torn down automatically.
    let onProceed: (String) async throws -> Void

    @EnvironmentObject private var walletManager: WalletManager

    @State private var step: Step = .question
    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var reveal = false
    @State private var isBusy = false
    @State private var error: String?
    /// Address #0 for the passphrase as currently typed. Recomputed on a short debounce rather
    /// than per keystroke: the derivation is PBKDF2 over 2048 rounds, which is quick but not free.
    @State private var previewAddress: String?
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        Group {
            switch step {
            case .question: questionScreen
            case .entry: entryScreen
            case .explainer: explainerScreen
            }
        }
        .interactiveDismissDisabled(isBusy)
        .alert("Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            if let error { Text(error) }
        }
    }

    // MARK: - 1. The question

    private var questionTitle: String {
        mode == .create
            ? "Do you want to add a passphrase to your account?"
            : "Did you create this seed with a passphrase?"
    }

    private var questionScreen: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)

            Text(questionTitle)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // Import keeps a line of steer, because someone who has never heard of a passphrase
            // still has to answer a question about their own past. Create needs none: the choice
            // is theirs to make, and "What is a passphrase?" is right there if they want it.
            if mode == .importExisting {
                Text("If you are not sure, the answer is almost certainly no. A passphrase is something you would have typed in on purpose.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                Button {
                    step = .entry
                } label: {
                    Text("Yes")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(isBusy)

                Button {
                    submit(passphrase: "")
                } label: {
                    Group {
                        if isBusy {
                            ProgressView()
                        } else {
                            Text("No")
                                .font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundColor(.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(isBusy)

                Button {
                    step = .explainer
                } label: {
                    Text("What is a passphrase?")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
            }
        }
        .padding(24)
        .navigationTitle("Passphrase")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isBusy)
    }

    // MARK: - 2. Entry, with the address it produces

    private var entryScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(mode == .create ? "Choose your passphrase" : "Enter your passphrase")
                    .font(.title3.weight(.bold))

                Text(mode == .create
                     ? "Write it down somewhere safe. Without it this account cannot be recovered, even with your seed phrase."
                     : "It has to be exactly what you used before, including capital letters and spaces.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                passphraseFields

                addressPreview

                Button {
                    submitFromEntry()
                } label: {
                    Group {
                        if isBusy {
                            ProgressView().tint(.white)
                        } else {
                            Text(mode == .create ? "Continue" : "Import")
                                .font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(canSubmitPassphrase ? Color.accentColor : Color.gray)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmitPassphrase || isBusy)
            }
            .padding(24)
        }
        .navigationTitle("Passphrase")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Back") {
                    passphrase = ""
                    confirmPassphrase = ""
                    step = .question
                }
                .disabled(isBusy)
            }
        }
        .onChange(of: passphrase) { _ in schedulePreview() }
        .onAppear { schedulePreview() }
    }

    private var passphraseFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Group {
                    if reveal {
                        TextField("Passphrase", text: $passphrase)
                    } else {
                        SecureField("Passphrase", text: $passphrase)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Button {
                    reveal.toggle()
                } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if mode == .create {
                Group {
                    if reveal {
                        TextField("Re-enter passphrase", text: $confirmPassphrase)
                    } else {
                        SecureField("Re-enter passphrase", text: $confirmPassphrase)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    /// The whole reason this screen shows an address: a passphrase does not protect one account,
    /// it opens a different one. Watching #0 change with every character is what makes that
    /// concrete, and on import it is how someone confirms they typed the right thing before
    /// committing to an account that would otherwise look simply empty.
    private var addressPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your chatting address")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(previewAddress ?? "Checking...")
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(previewAddress == nil ? .secondary : .primary)
                .lineLimit(2)
                .animation(.none, value: previewAddress)
            Text(passphrase.isEmpty
                 ? "This is the account your seed phrase opens on its own."
                 : "A different passphrase gives a different address, and a different account.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .opacity(seedWords.isEmpty ? 0 : 1)
    }

    private func schedulePreview() {
        previewTask?.cancel()
        guard !seedWords.isEmpty else { return }
        let typed = passphrase
        previewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            previewAddress = walletManager.previewChattingAddress(
                words: seedWords,
                passphrase: typed,
                family: family
            )
        }
    }

    // MARK: - 3. What is a passphrase?

    private var explainerScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                explainerSection(
                    "The short version",
                    "A passphrase is an extra word or sentence you add on top of your seed phrase. It is optional, and most people do not use one."
                )
                explainerSection(
                    "It does not lock your account",
                    "This is the part people get wrong. A passphrase does not put a password on your account. It opens a completely different account. Your seed phrase with no passphrase opens one account. The same seed phrase with the word \"apple\" opens another one. With \"banana\", another one again. Every passphrase is its own separate account, with its own address and its own balance."
                )
                explainerSection(
                    "Why anyone bothers",
                    "If someone finds your written seed phrase, they get the account it opens on its own. They do not get the one behind your passphrase, because they do not know there is one, and they could not guess it anyway."
                )
                explainerSection(
                    "The catch",
                    "There is no reset and no recovery. If you forget your passphrase, the account it opened is gone for good. Your seed phrase alone will not bring it back, and nobody can help you. Treat it exactly like the seed phrase itself: written down, somewhere safe, before you rely on it."
                )
                explainerSection(
                    "One more thing to know",
                    "If you type the wrong passphrase, nothing will tell you. You will simply land in a different account, and it will look empty. That is not a bug and your money is not lost - it just means you are in the wrong account."
                )
                explainerSection(
                    "So do you need one?",
                    mode == .create
                        ? "If you are not sure, choose No. Your account is still protected by your seed phrase, and you can always create another account with a passphrase later."
                        : "If you never set one up, choose No. A passphrase is something you would have typed in on purpose, so if this is the first you are hearing of it, you do not have one."
                )
            }
            .padding(24)
        }
        .navigationTitle("What is a passphrase?")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Back") { step = .question }
            }
        }
    }

    private func explainerSection(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(body)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private var canSubmitPassphrase: Bool {
        !passphrase.isEmpty
    }

    private func submitFromEntry() {
        guard !passphrase.isEmpty else {
            error = "Enter a passphrase, or go back and choose No."
            return
        }
        if mode == .create, passphrase != confirmPassphrase {
            error = "The passphrases do not match. Please re-enter them."
            return
        }
        submit(passphrase: passphrase)
    }

    private func submit(passphrase chosen: String) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            do {
                try await onProceed(chosen)
                // Success: the router replaces onboarding with the main app; nothing more to do.
            } catch {
                self.error = error.localizedDescription
                isBusy = false
            }
        }
    }
}

#Preview {
    NavigationStack {
        PassphraseOptionView(mode: .create) { _ in }
            .environmentObject(WalletManager.shared)
    }
}
