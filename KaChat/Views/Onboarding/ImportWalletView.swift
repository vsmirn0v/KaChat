import SwiftUI

struct ImportWalletView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss

    @State private var seedPhraseText = ""
    @State private var alias = "Imported Account"
    @State private var isImporting = false
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
                        .onChange(of: seedPhraseText) { _, newValue in
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

                // Import Button
                Button {
                    importWallet()
                } label: {
                    HStack {
                        if isImporting {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        Text("Import Account")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(canImport ? Color.accentColor : Color.gray)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!canImport || isImporting)
            }
            .padding()
        }
        .navigationTitle("Import Account")
        .navigationBarTitleDisplayMode(.large)
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

    private func importWallet() {
        isImporting = true

        Task {
            do {
                _ = try await walletManager.importWallet(from: seedPhraseText, alias: alias)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isImporting = false
        }
    }
}

#Preview {
    NavigationStack {
        ImportWalletView()
            .environmentObject(WalletManager.shared)
    }
}
