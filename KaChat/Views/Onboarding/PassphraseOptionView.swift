import SwiftUI

/// Optional BIP39 passphrase ("25th word") step, shown after the seed-phrase backup (create) or
/// seed-phrase entry (import) and before the Welcome Guide. It explains what a passphrase does,
/// how it increases security, and the risk of forgetting it, then lets the user proceed with a
/// passphrase or skip. The caller (`CreateWalletView` / `ImportWalletView`) performs the actual
/// wallet commit via `onProceed`, which receives the chosen passphrase ("" when skipped).
struct PassphraseOptionView: View {
    enum Mode {
        case create
        case importExisting
    }

    let mode: Mode
    /// Performs the create/import commit with the chosen passphrase ("" = none). Throwing surfaces
    /// an inline error here and re-enables the buttons; on success the app router swaps onboarding
    /// for the main app, so this view is torn down automatically.
    let onProceed: (String) async throws -> Void

    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var reveal = false
    @State private var isBusy = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                explainerCard
                benefitsCard
                passphraseFields
                riskCard
                buttons
            }
            .padding()
        }
        .navigationTitle("Add a Passphrase")
        .navigationBarTitleDisplayMode(.large)
        .interactiveDismissDisabled(isBusy)
        .alert("Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            if let error = error { Text(error) }
        }
    }

    // MARK: - Sections

    private var explainerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Optional Passphrase", systemImage: "lock.shield.fill")
                .font(.headline)

            Text("A passphrase is an optional extra secret only you know. It's combined with your seed phrase to unlock a completely separate, hidden account.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var benefitsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Why add one?", systemImage: "checkmark.shield.fill")
                .font(.headline)
                .foregroundColor(.green)

            bulletRow("Even if someone finds your written seed phrase, they can't reach this account without the passphrase.")
            bulletRow("It creates a hidden account, separate from the standard one your seed phrase alone unlocks.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.green.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var passphraseFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Passphrase")
                .font(.headline)

            HStack {
                Group {
                    if reveal {
                        TextField("Enter passphrase", text: $passphrase)
                    } else {
                        SecureField("Enter passphrase", text: $passphrase)
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
            }
            .padding()
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if mode == .create {
                Text("Confirm Passphrase")
                    .font(.headline)
                    .padding(.top, 4)

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
            } else {
                Text("Enter the exact passphrase you used when this account was created.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var riskCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Important — read this", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundColor(.orange)

            bulletRow("If you forget your passphrase, this account is permanently lost. Your seed phrase alone will NOT recover it.", tint: .orange)
            bulletRow("There is no way to reset or recover a passphrase. Store it as carefully as your seed phrase.", tint: .orange)
            if mode == .importExisting {
                bulletRow("A different passphrase silently opens a different, empty account — it won't show an error.", tint: .orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var buttons: some View {
        VStack(spacing: 12) {
            Button {
                submit(usePassphrase: true)
            } label: {
                HStack {
                    if isBusy {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "lock.fill")
                    }
                    Text(mode == .create ? "Continue with Passphrase" : "Import with Passphrase")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(canSubmitPassphrase ? Color.accentColor : Color.gray)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!canSubmitPassphrase || isBusy)

            Button {
                submit(usePassphrase: false)
            } label: {
                Text("Skip — no passphrase")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemGray5))
                    .foregroundColor(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(isBusy)
        }
    }

    private func bulletRow(_ text: String, tint: Color = .secondary) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundColor(tint)
                .padding(.top, 6)
            Text(text)
                .font(.subheadline)
                .foregroundColor(tint == .secondary ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Actions

    private var canSubmitPassphrase: Bool {
        !passphrase.isEmpty
    }

    private func submit(usePassphrase: Bool) {
        guard !isBusy else { return }
        let chosen: String
        if usePassphrase {
            let trimmed = passphrase
            guard !trimmed.isEmpty else {
                error = "Enter a passphrase, or tap Skip to continue without one."
                return
            }
            if mode == .create, trimmed != confirmPassphrase {
                error = "The passphrases don't match. Please re-enter them."
                return
            }
            chosen = trimmed
        } else {
            chosen = ""
        }

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
