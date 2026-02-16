import SwiftUI

struct CreateWalletView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss

    @State private var alias = "My Account"
    @State private var generatedSeedPhrase: SeedPhrase?
    @State private var isCreating = false
    @State private var showSeedPhrase = false
    @State private var hasConfirmedBackup = false
    @State private var error: String?
    @State private var wordCount: Int = 24
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success

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
        .toast(message: toastMessage, style: toastStyle)
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

            // Copy Button
            if showSeedPhrase {
                Button {
                    UIPasteboard.general.string = seedPhrase.phrase
                    let copiedPhrase = seedPhrase.phrase
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                        if UIPasteboard.general.string == copiedPhrase {
                            UIPasteboard.general.string = ""
                        }
                    }
                    Haptics.success()
                    showToast("Seed phrase copied. Clipboard will clear in 30s.")
                } label: {
                    Label("Copy to Clipboard", systemImage: "doc.on.doc")
                        .font(.subheadline)
                }
                .foregroundColor(.accentColor)
            }

            // Confirmation Toggle
            Toggle(isOn: $hasConfirmedBackup) {
                Text("I have written down my seed phrase and stored it securely")
                    .font(.subheadline)
            }
            .toggleStyle(CheckboxToggleStyle())
            .padding(.top)

            // Continue Button
            Button {
                dismiss()
            } label: {
                Text("Continue to App")
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
                let result = try await walletManager.createWallet(alias: alias, wordCount: wordCount)
                generatedSeedPhrase = result.seedPhrase
            } catch {
                self.error = error.localizedDescription
            }
            isCreating = false
        }
    }

    private func showToast(_ message: String, style: ToastStyle = .success) {
        let token = UUID()
        toastToken = token
        toastStyle = style
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
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
