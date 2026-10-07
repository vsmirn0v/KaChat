import SwiftUI

/// Import Account, after the source wallet (`ImportSourceWalletView`): the account's name, local
/// to this device - the same screen as Create Account's first step. Then the seed length
/// (`ImportLengthStep`), the words (`ImportWalletView`), and the optional passphrase.
struct ImportNameStep: View {
    var sourceFamily: WalletSourceFamily = .kaspaStandard
    /// Starts empty on purpose: the name is the user's choice.
    @State private var alias = ""
    @State private var showLengthStep = false

    var body: some View {
        AccountNameForm(alias: $alias) { showLengthStep = true }
            .navigationTitle("Import Account")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(isPresented: $showLengthStep) {
                ImportLengthStep(sourceFamily: sourceFamily, alias: alias.trimmingCharacters(in: .whitespacesAndNewlines))
            }
    }
}

/// Import Account: how many words the seed phrase being imported has.
struct ImportLengthStep: View {
    let sourceFamily: WalletSourceFamily
    let alias: String
    /// No length is selected until the user picks one.
    @State private var wordCount: Int?
    @State private var showWords = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose seed phrase length")
                        .font(.title2.weight(.bold))
                    Text("How many words is the seed phrase you're importing?")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    SeedLengthButton(count: 12, title: "12 words", selection: $wordCount)
                    SeedLengthButton(count: 24, title: "24 words", selection: $wordCount)
                }

                CreateWalletNextButton(title: "Next", enabled: wordCount != nil) { showWords = true }
            }
            .padding()
        }
        .navigationTitle("Import Account")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(isPresented: $showWords) {
            if let wordCount {
                ImportWalletView(sourceFamily: sourceFamily, alias: alias, wordCount: wordCount)
            }
        }
    }
}

/// Import Account: the seed phrase's words (in-app keyboard, or Paste), then the passphrase step.
struct ImportWalletView: View {
    @EnvironmentObject var walletManager: WalletManager

    /// Identity derivation-path family of the wallet this seed comes from, chosen on the
    /// source-wallet screen (`ImportSourceWalletView`) BEFORE this seed-entry screen. Standard
    /// (KaChat's own path) unless the user picked a wallet on another branch.
    var sourceFamily: WalletSourceFamily = .kaspaStandard
    /// The account's name, from `ImportNameStep`.
    var alias: String = "Imported Account"

    /// From `ImportLengthStep`; a pasted phrase of the other length switches it.
    @State private var seedWordCount: Int
    // Fixed-capacity backing store; only the first `seedWordCount` entries are used.
    @State private var words: [String] = Array(repeating: "", count: 24)
    @State private var showPassphraseStep = false
    @State private var error: String?

    init(sourceFamily: WalletSourceFamily = .kaspaStandard, alias: String = "Imported Account", wordCount: Int = 24) {
        self.sourceFamily = sourceFamily
        self.alias = alias
        _seedWordCount = State(initialValue: wordCount == 12 ? 12 : 24)
    }

    private var slots: [String] { Array(words.prefix(seedWordCount)) }
    private var seedPhraseText: String { slots.joined(separator: " ") }
    private var filledCount: Int { slots.filter { BIP39.shared.isValidWord($0) }.count }

    private var allWordsValid: Bool {
        slots.count == seedWordCount && slots.allSatisfy { BIP39.shared.isValidWord($0) }
    }

    private var canImport: Bool { allWordsValid && !alias.isEmpty }

    /// Fills the slots from a phrase on the clipboard: 12 or 24 words, any spacing or line
    /// breaks, numbering like "1." tolerated. Anything else is refused with a message, and the
    /// clipboard is cleared once the words are in - a seed does not belong there.
    private func pasteSeedPhrase() {
        guard let raw = UIPasteboard.general.string else {
            error = "Nothing to paste."
            return
        }
        let pasted = raw
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".)")) }
            .filter { !$0.isEmpty && !$0.allSatisfy(\.isNumber) }
        guard pasted.count == 12 || pasted.count == 24 else {
            error = "A recovery phrase is 12 or 24 words - the clipboard holds \(pasted.count)."
            return
        }
        let unknown = pasted.filter { !BIP39.shared.isValidWord($0) }
        guard unknown.isEmpty else {
            error = "Not a recovery phrase word: \(unknown.prefix(3).joined(separator: ", "))."
            return
        }
        seedWordCount = pasted.count
        var filled = Array(repeating: "", count: 24)
        for (index, word) in pasted.enumerated() { filled[index] = word }
        words = filled
        error = nil
        UIPasteboard.general.string = ""
        Haptics.success()
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Enter your recovery phrase")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                // A phrase on the clipboard fills the slots in one tap; the word count follows
                // whichever length was pasted.
                Button {
                    pasteSeedPhrase()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
        .navigationDestination(isPresented: $showPassphraseStep) {
            PassphraseOptionView(
                mode: .importExisting,
                // The live address preview needs the words and the derivation family, so what it
                // shows is the address this import would actually produce.
                seedWords: slots.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty },
                family: sourceFamily
            ) { passphrase in
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
        // Nothing syncs while the wizard is on screen: an import's from-genesis sync of every
        // contact ingests on the main actor, which is what made typing through setup crawl.
        // Released by the guide's Finish (or by MainTabView, if no guide ends up shown).
        ChatService.shared.holdSyncForOnboarding()
        // Import-only marker (create never sets it): lets the Welcome Guide's funding step offer
        // "Change Chatting Address" - only an imported seed can have its identity at a nonzero
        // derivation index. Cleared by the guide on Finish, or here on failure.
        walletManager.justImportedWallet = true
        do {
            _ = try await walletManager.importWallet(from: seedPhraseText, alias: alias, passphrase: passphrase, family: sourceFamily)
        } catch {
            walletManager.justCreatedNewWallet = false
            walletManager.justImportedWallet = false
            ChatService.shared.releaseSyncForOnboarding()
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
