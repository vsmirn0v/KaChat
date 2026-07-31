import SwiftUI

struct ImportWalletView: View {
    @EnvironmentObject var walletManager: WalletManager

    @State private var alias = "Imported Account"
    @State private var seedWordCount = 24
    // Fixed-capacity backing store; only the first `seedWordCount` entries are used.
    @State private var words: [String] = Array(repeating: "", count: 24)
    @State private var showPassphraseStep = false
    @State private var error: String?
    @FocusState private var aliasFocused: Bool

    private var slots: [String] { Array(words.prefix(seedWordCount)) }
    private var seedPhraseText: String { slots.joined(separator: " ") }
    private var filledCount: Int { slots.filter { BIP39.shared.isValidWord($0) }.count }

    private var allWordsValid: Bool {
        slots.count == seedWordCount && slots.allSatisfy { BIP39.shared.isValidWord($0) }
    }

    private var canImport: Bool { allWordsValid && !alias.isEmpty }

    var body: some View {
        VStack(spacing: 12) {
            // Account name (uses the normal keyboard - it isn't sensitive)
            VStack(alignment: .leading, spacing: 6) {
                Text("Account Name")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                TextField("Enter account name", text: $alias)
                    .textFieldStyle(.roundedBorder)
                    .focused($aliasFocused)
                    .submitLabel(.done)
                    .onSubmit { aliasFocused = false }
            }

            // Word-count selector
            Picker("", selection: $seedWordCount) {
                Text("24 words").tag(24)
                Text("12 words").tag(12)
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Enter your recovery phrase")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(filledCount)/\(seedWordCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(allWordsValid ? .green : .secondary)
            }

            // Custom in-app keyboard + numbered slot grid + autocomplete (no OS keyboard for the seed)
            SeedPhraseKeyboardView(words: $words, wordCount: seedWordCount)

            Button {
                advanceToPassphrase()
            } label: {
                HStack {
                    Image(systemName: "arrow.right.circle.fill")
                    Text("Continue")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(canImport ? Color.accentColor : Color.gray)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!canImport)
        }
        .padding()
        .navigationTitle("Import Account")
        .navigationBarTitleDisplayMode(.inline)
        // The seed uses the in-app keyboard; the only native keyboard here is the account-name
        // field. Its return key (the checkmark) dismisses it; also allow a downward swipe since
        // there's no ScrollView to interactively dismiss from.
        .simultaneousGesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                if aliasFocused && value.translation.height > 20 {
                    aliasFocused = false
                }
            }
        )
        .navigationDestination(isPresented: $showPassphraseStep) {
            PassphraseOptionView(mode: .importExisting) { passphrase in
                try await commitImport(passphrase: passphrase)
            }
        }
        .alert("Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            if let error = error {
                Text(error)
            }
        }
    }

    /// Validates the phrase (incl. BIP39 checksum) up front so a mistake surfaces here rather than
    /// after the passphrase step, then advances to the optional passphrase screen.
    private func advanceToPassphrase() {
        guard canImport else { return }
        guard BIP39.shared.validateMnemonic(seedPhraseText) else {
            error = "This recovery phrase is invalid. Double-check the words - the last word encodes a checksum, so one wrong word fails validation."
            return
        }
        showPassphraseStep = true
    }

    /// Performs the import with the chosen passphrase ("" = none). Called from the passphrase step.
    /// Throwing surfaces the error on that screen and lets the user retry.
    private func commitImport(passphrase: String) async throws {
        // Arm the Welcome Guide before importing (see ImportWalletView history): importWallet sets
        // `currentWallet` and suspends at an await, which can mount MainTabView - whose onAppear
        // consumes this one-shot flag - before control returns here.
        walletManager.justCreatedNewWallet = true
        do {
            _ = try await walletManager.importWallet(from: seedPhraseText, alias: alias, passphrase: passphrase)
        } catch {
            walletManager.justCreatedNewWallet = false
            throw error
        }
    }
}

#Preview {
    NavigationStack {
        ImportWalletView()
            .environmentObject(WalletManager.shared)
    }
}
