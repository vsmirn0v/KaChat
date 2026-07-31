import SwiftUI

struct ImportWalletView: View {
    @EnvironmentObject var walletManager: WalletManager

    @State private var seedPhraseText = ""
    @State private var alias = "Imported Account"
    @State private var showPassphraseStep = false
    @State private var error: String?
    @State private var wordCount = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Info Card
                VStack(alignment: .leading, spacing: 12) {
                    Label("Import Your Account", systemImage: "square.and.arrow.down")
                        .font(.headline)

                    Text("Enter your 12 or 24 word seed phrase to restore your account. Separate each word with a space.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Seed Phrase Input
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Seed Phrase")
                            .font(.headline)
                        Spacer()
                        Text("\(wordCount) words")
                            .font(.caption)
                            .foregroundColor(isValidWordCount ? .green : .secondary)
                    }

                    TextEditor(text: $seedPhraseText)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .frame(minHeight: 120)
                        .padding(8)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(.systemGray4), lineWidth: 1)
                        )
                        .onChange(of: seedPhraseText) { newValue in
                            updateWordCount(newValue)
                        }

                    if !seedPhraseText.isEmpty && !isValidWordCount {
                        Text("Please enter exactly 12 or 24 words")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                // Alias Input
                VStack(alignment: .leading, spacing: 8) {
                    Text("Account Name")
                        .font(.headline)

                    TextField("Enter account name", text: $alias)
                        .textFieldStyle(.roundedBorder)
                }

                // Paste Button
                Button {
                    if let pastedText = UIPasteboard.general.string {
                        seedPhraseText = pastedText
                        updateWordCount(pastedText)
                    }
                } label: {
                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                        .font(.subheadline)
                }
                .foregroundColor(.accentColor)

                Spacer().frame(height: 20)

                // Continue Button - advances to the optional passphrase step; the actual import
                // happens there (with or without a passphrase).
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
        }
        .navigationTitle("Import Account")
        .navigationBarTitleDisplayMode(.large)
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

    private var isValidWordCount: Bool {
        wordCount == 12 || wordCount == 24
    }

    private var canImport: Bool {
        isValidWordCount && !alias.isEmpty
    }

    private func updateWordCount(_ text: String) {
        let words = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        wordCount = words.count
    }

    /// Validates the seed phrase up front (so typos surface here, not after the passphrase step)
    /// then advances to the optional passphrase screen where the import is actually performed.
    private func advanceToPassphrase() {
        guard canImport else { return }
        guard BIP39.shared.validateMnemonic(seedPhraseText) else {
            error = "This seed phrase is invalid. Please double-check the words and try again."
            return
        }
        showPassphraseStep = true
    }

    /// Performs the import with the chosen passphrase ("" = none). Called from the passphrase step.
    /// Throwing surfaces the error on that screen and lets the user retry.
    private func commitImport(passphrase: String) async throws {
        // Arm the Welcome Guide *before* importing, matching the new-wallet flow.
        // `importWallet` sets `currentWallet` internally and then suspends at an `await`, which
        // lets the router mount `MainTabView` - whose `onAppear` consumes this one-shot flag -
        // before control returns here. Setting it first guarantees it's true when MainTabView
        // appears. On success the router replaces onboarding with the main app automatically.
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
