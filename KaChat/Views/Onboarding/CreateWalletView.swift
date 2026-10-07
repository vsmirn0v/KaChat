import SwiftUI

/// Create Account, step 1 of 3: the account's name - local to this device. Then the seed
/// length (`CreateWalletLengthStep`), then the seed phrase itself (`CreateWalletSeedStep`),
/// then the optional passphrase (`PassphraseOptionView`), which commits the account.
struct CreateWalletView: View {
    /// Starts empty on purpose: the name is the user's choice.
    @State private var alias = ""
    @State private var showLengthStep = false

    private var trimmedAlias: String {
        alias.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        AccountNameForm(alias: $alias) { showLengthStep = true }
            .navigationTitle("Create Account")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(isPresented: $showLengthStep) {
                CreateWalletLengthStep(alias: trimmedAlias)
            }
    }
}

/// The account name step of Create Account and Import Account: a name local to this device.
/// Next stays off until there is a name.
struct AccountNameForm: View {
    @Binding var alias: String
    let onNext: () -> Void
    @FocusState private var nameFocused: Bool

    private var hasName: Bool { !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Create a name for your wallet")
                        .font(.title2.weight(.bold))
                    Text("This name is only stored on this device, to tell your wallets apart. No one else will ever see it.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                TextField("Enter account name", text: $alias)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .submitLabel(.next)
                    .onSubmit { next() }

                CreateWalletNextButton(title: "Next", enabled: hasName) { next() }
            }
            .padding()
        }
        .onAppear { nameFocused = true }
    }

    private func next() {
        guard hasName else { return }
        nameFocused = false
        onNext()
    }
}

/// One of the two seed length choices (12 or 24 words): a full-width button in the Generate
/// Account style, filled when chosen and outlined otherwise.
struct SeedLengthButton: View {
    let count: Int
    let title: LocalizedStringKey
    @Binding var selection: Int?
    var disabled = false

    var body: some View {
        let chosen = selection == count
        Button {
            selection = count
        } label: {
            HStack {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                Text(title)
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding()
            .background(chosen ? Color.accentColor : Color.clear)
            .foregroundColor(chosen ? .white : .accentColor)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 1.5))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// What a seed phrase is, in plain words: the half sheet behind "What is this?" on the seed
/// length step.
struct SeedPhraseExplainerSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("A seed phrase is a list of 12 or 24 ordinary words that works as the master key to your account. Your wallet, your chatting address and your messages all come from it.")
                    Text("Anyone who has these words can take everything in your account. If you lose them and lose this device, nobody can get your account back, not even KaChat.")
                    Text("Write the words on paper, in order, and keep them somewhere safe and private. Never type them into a website, send them in a chat, or keep them in a screenshot or cloud notes.")
                    Text("12 words are already very secure. 24 words add even more protection.")
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding()
            }
            .navigationTitle("What is a seed phrase?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// Create Account, step 2 of 3: 12 or 24 words, and the warning that the seed phrase comes next.
private struct CreateWalletLengthStep: View {
    let alias: String
    @EnvironmentObject var walletManager: WalletManager

    /// No length is selected until the user picks one.
    @State private var wordCount: Int?
    @State private var isCreating = false
    @State private var generatedSeedPhrase: SeedPhrase?
    @State private var showSeedStep = false
    @State private var showExplainer = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose seed phrase length")
                        .font(.title2.weight(.bold))
                    // Two full-width buttons in the Generate Account style; the chosen one is
                    // filled, the other outlined. Nothing is chosen until the user taps one.
                    SeedLengthButton(count: 12, title: "12 words", selection: $wordCount, disabled: isCreating)
                    SeedLengthButton(count: 24, title: "24 words", selection: $wordCount, disabled: isCreating)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Label("Important", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundColor(.orange)
                    Text("The next screen shows your seed phrase. It is the only way to recover your account: write it down and store it securely, and make sure no one can see your screen.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                CreateWalletNextButton(title: "Generate Account", enabled: wordCount != nil && !isCreating, busy: isCreating) {
                    generate()
                }

                Button {
                    showExplainer = true
                } label: {
                    Label("What is this?", systemImage: "questionmark.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
            .padding()
        }
        .sheet(isPresented: $showExplainer) { SeedPhraseExplainerSheet() }
        .navigationTitle("Create Account")
        .navigationBarTitleDisplayMode(.large)
        .alert("Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            if let error { Text(error) }
        }
        .navigationDestination(isPresented: $showSeedStep) {
            if let generatedSeedPhrase {
                CreateWalletSeedStep(alias: alias, seedPhrase: generatedSeedPhrase)
            }
        }
    }

    private func generate() {
        guard let wordCount else { return }
        isCreating = true
        Task {
            do {
                // Generate the mnemonic for display only. Key derivation + persistence are
                // deferred to the passphrase step, after the user backs it up.
                generatedSeedPhrase = try await walletManager.generateNewWalletSeedPhrase(wordCount: wordCount)
                showSeedStep = true
            } catch {
                self.error = error.localizedDescription
            }
            isCreating = false
        }
    }
}

/// Create Account, step 3 of 3: the seed phrase, backed up by hand, then the passphrase step.
private struct CreateWalletSeedStep: View {
    let alias: String
    let seedPhrase: SeedPhrase
    @EnvironmentObject var walletManager: WalletManager

    @State private var showSeedPhrase = false
    @State private var hasConfirmedBackup = false
    @State private var showPassphraseStep = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Warning
                VStack(alignment: .leading, spacing: 12) {
                    Label("Write Down Your Seed Phrase", systemImage: "pencil.and.outline")
                        .font(.headline)
                        .foregroundColor(.orange)

                    Text("Store this in a safe place. Anyone with these words can access your account.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Seed Phrase Grid
                VStack(spacing: 8) {
                    if showSeedPhrase {
                        SecureView {
                            LazyVGrid(columns: [
                                GridItem(.flexible()),
                                GridItem(.flexible()),
                                GridItem(.flexible())
                            ], spacing: 8) {
                                ForEach(Array(seedPhrase.words.enumerated()), id: \.offset) { index, word in
                                    HStack(spacing: 4) {
                                        Text("\(index + 1).")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .frame(width: 18, alignment: .trailing)
                                        Text(word)
                                            .font(.system(.subheadline, design: .monospaced))
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.6)
                                            .allowsTightening(true)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 6)
                                    .background(Color(.systemGray6))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                    } else {
                        Button {
                            showSeedPhrase = true
                        } label: {
                            VStack(spacing: 12) {
                                Image(systemName: "eye.slash.fill")
                                    .font(.largeTitle)
                                Text("Tap to reveal seed phrase")
                                    .font(.subheadline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(40)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .foregroundColor(.secondary)
                    }
                }

                // Copying the seed phrase is intentionally not offered - recovery material must be
                // transcribed by hand, never placed on the clipboard (other apps and clipboard
                // history can read it).

                // Confirmation Toggle
                Toggle(isOn: $hasConfirmedBackup) {
                    Text("I have written down my seed phrase and stored it securely")
                        .font(.subheadline)
                }
                .toggleStyle(CheckboxToggleStyle())
                .padding(.top)

                // Continue Button - advances to the optional passphrase step (the wallet is not
                // committed/derived until after that, so the passphrase can shape the account).
                Button {
                    showPassphraseStep = true
                } label: {
                    Text("Next")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(hasConfirmedBackup ? Color.accentColor : Color.gray)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!hasConfirmedBackup)
            }
            .padding()
        }
        .navigationTitle("Create Account")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(isPresented: $showPassphraseStep) {
            PassphraseOptionView(
                mode: .create,
                // The live address preview needs the words this account will be built from.
                seedWords: seedPhrase.words
            ) { passphrase in
                try await commit(passphrase: passphrase)
            }
        }
        .onDisappear {
            // Harmless safety net: this flow no longer sets `isAwaitingSeedPhraseConfirmation`
            // (the wallet isn't committed until after the passphrase step, so `currentWallet`
            // stays nil during seed display and routing stays on onboarding on its own). Clearing
            // it on the way out guards against any other path leaving it stuck true, which would
            // otherwise trap a user on onboarding despite a valid persisted wallet.
            walletManager.isAwaitingSeedPhraseConfirmation = false
        }
    }

    /// Commits the new wallet with the chosen passphrase ("" = none). Called from the passphrase
    /// step. Throwing surfaces the error on that screen and lets the user retry.
    private func commit(passphrase: String) async throws {
        // Arm the Welcome Guide before committing: `importWallet` (inside commitCreatedWallet) sets
        // `currentWallet` and suspends at an await, which can mount MainTabView - whose onAppear
        // consumes this one-shot flag - before control returns here. Setting it first guarantees
        // the guide appears. Mirrors ImportWalletView.
        walletManager.justCreatedNewWallet = true
        // Nothing syncs while the wizard is on screen - see ImportWalletView. A brand-new account
        // has nothing to sync, but the hold keeps both paths identical and the release honest.
        ChatService.shared.holdSyncForOnboarding()
        do {
            _ = try await walletManager.commitCreatedWallet(seedPhrase: seedPhrase, passphrase: passphrase, alias: alias)
        } catch {
            walletManager.justCreatedNewWallet = false
            ChatService.shared.releaseSyncForOnboarding()
            throw error
        }
    }
}

/// The accent-filled continue button of the Create Account and Import Account steps (dims while
/// disabled).
struct CreateWalletNextButton: View {
    let title: LocalizedStringKey
    let enabled: Bool
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                if busy {
                    ProgressView().tint(.white)
                }
                Text(title)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.accentColor)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            // A custom background doesn't dim on its own when the button is disabled.
            .opacity(enabled || busy ? 1 : 0.4)
        }
        .disabled(!enabled)
    }
}

struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundColor(configuration.isOn ? .accentColor : .secondary)
                    .font(.title3)

                configuration.label
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        CreateWalletView()
            .environmentObject(WalletManager.shared)
    }
}
