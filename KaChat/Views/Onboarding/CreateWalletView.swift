import SwiftUI

struct CreateWalletView: View {
    @EnvironmentObject var walletManager: WalletManager

    @State private var alias = "My Account"
    @State private var generatedSeedPhrase: SeedPhrase?
    @State private var isCreating = false
    @State private var showSeedPhrase = false
    @State private var hasConfirmedBackup = false
    @State private var showPassphraseStep = false
    @State private var error: String?
    @State private var wordCount: Int = 24

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let seedPhrase = generatedSeedPhrase {
                    seedPhraseView(seedPhrase)
                } else {
                    setupView
                }
            }
            .padding()
        }
        .navigationTitle("Create Account")
        .navigationBarTitleDisplayMode(.large)
        .alert("Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            if let error = error {
                Text(error)
            }
        }
        .navigationDestination(isPresented: $showPassphraseStep) {
            PassphraseOptionView(mode: .create) { passphrase in
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

    private var setupView: some View {
        VStack(spacing: 24) {
            // Info Card
            VStack(alignment: .leading, spacing: 12) {
                Label("Important", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundColor(.orange)

                Text("You will be shown a seed phrase. This is the only way to recover your account. Write it down and store it securely.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Word count picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Seed Phrase Length")
                    .font(.headline)

                Picker("Seed Phrase Length", selection: $wordCount) {
                    Text("24 words (recommended)").tag(24)
                    Text("12 words").tag(12)
                }
                .pickerStyle(.segmented)
            }

            // Alias Input
            VStack(alignment: .leading, spacing: 8) {
                Text("Account Name")
                    .font(.headline)

                TextField("Enter account name", text: $alias)
                    .textFieldStyle(.roundedBorder)
            }

            Spacer().frame(height: 20)

            // Create Button
            Button {
                createWallet()
            } label: {
                HStack {
                    if isCreating {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "plus.circle.fill")
                    }
                    Text("Generate Account")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.accentColor)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(isCreating || alias.isEmpty)
        }
    }

    private func seedPhraseView(_ seedPhrase: SeedPhrase) -> some View {
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
                                HStack {
                                    Text("\(index + 1).")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .frame(width: 24, alignment: .trailing)
                                    Text(word)
                                        .font(.system(.body, design: .monospaced))
                                    Spacer()
                                }
                                .padding(8)
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
            // transcribed by hand, never placed on the clipboard (other apps and clipboard history
            // can read it).

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
    }

    private func createWallet() {
        isCreating = true

        Task {
            do {
                // Generate the mnemonic for display only. Key derivation + persistence are deferred
                // to `commit(passphrase:)`, after the user backs it up and picks a passphrase.
                generatedSeedPhrase = try await walletManager.generateNewWalletSeedPhrase(wordCount: wordCount)
            } catch {
                self.error = error.localizedDescription
            }
            isCreating = false
        }
    }

    /// Commits the new wallet with the chosen passphrase ("" = none). Called from the passphrase
    /// step. Throwing surfaces the error on that screen and lets the user retry.
    private func commit(passphrase: String) async throws {
        guard let seedPhrase = generatedSeedPhrase else { return }
        // Arm the Welcome Guide before committing: `importWallet` (inside commitCreatedWallet) sets
        // `currentWallet` and suspends at an await, which can mount MainTabView - whose onAppear
        // consumes this one-shot flag - before control returns here. Setting it first guarantees
        // the guide appears. Mirrors ImportWalletView.
        walletManager.justCreatedNewWallet = true
        do {
            _ = try await walletManager.commitCreatedWallet(seedPhrase: seedPhrase, passphrase: passphrase, alias: alias)
        } catch {
            walletManager.justCreatedNewWallet = false
            throw error
        }
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
