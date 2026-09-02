import SwiftUI

/// The app's frosted card. Every other place that draws one has its own file-private copy of
/// this; this file needs one too because it is not in any of them.
private func glassBackground(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
}

/// One option in a half-sheet menu: an icon, a title, and a line saying what the option does.
///
/// The app's menus used to be popovers and confirmation dialogs of bare labels, which have room
/// for a verb and nothing else. Every menu that has since become a sheet - the cold storage
/// account and address menus, Address Actions, the transaction menu below - is built from this,
/// so they read as the same kind of object wherever they appear.
struct ActionSheetRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var tint: Color = .accentColor
    var isBusy: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(tint == .accentColor ? .primary : tint)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if isBusy { ProgressView().controlSize(.small) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(glassBackground(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isBusy || isDisabled)
    }
}

/// Renaming something, in a half sheet.
///
/// A system alert with a text field is the platform's default for this, and it is the wrong
/// shape: it steals the whole screen for one word, and its field is a cramped afterthought. This
/// is the same sheet every other cold-storage action already uses.
struct RenameSheet: View {
    let title: String
    var subtitle: String?
    var fieldLabel: String = "Name"
    @Binding var text: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 4)

            TextField(fieldLabel, text: $text)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focused)
                .onSubmit(save)
                .padding(14)
                .background(glassBackground(cornerRadius: 16))

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundColor(.primary)
                    .background(glassBackground(cornerRadius: 16))

                Button("Save", action: save)
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundColor(.black)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.accentColor.opacity(trimmed.isEmpty ? 0.4 : 1))
                    )
                    .disabled(trimmed.isEmpty)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(260)])
        .presentationDragIndicator(.visible)
        // A turn later: the field does not exist yet on the tap that presented this.
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        Haptics.success()
        dismiss()
    }
}

/// So the transaction menu can be presented with `.sheet(item:)`. A txid is already the identity
/// of a transaction, and the property is computed, so it stays out of the Codable synthesis.
extension KaspaFullTransactionResponse: Identifiable {
    var id: String { transactionId }
}

/// What to do with a transaction you tapped in an address history: look at it, or record it.
///
/// Shared by cold storage history, the spending-address histories and the chatting address, all
/// three of which used to raise their own identical confirmation dialog.
struct TransactionActionsSheet: View {
    let transaction: KaspaFullTransactionResponse
    /// The address the history was viewed under, which is what decides whether this reads as
    /// money in or money out.
    let address: String
    let onOpenExplorer: () -> Void
    /// Nil candidate means the transaction has no side involving `address` we can price, so
    /// there is nothing to record and the option is not offered.
    let onAddToPortfolio: (PortfolioCandidateTransaction) -> Void

    @Environment(\.dismiss) private var dismiss

    private var candidate: PortfolioCandidateTransaction? {
        PortfolioCandidateTransaction(transaction: transaction, address: address)
    }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("Transaction")
                    .font(.headline)
                if let candidate {
                    Text(summary(candidate))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(transaction.transactionId)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .multilineTextAlignment(.center)
            .padding(.top, 8)

            ActionSheetRow(
                title: "Open in Explorer",
                subtitle: "Opens this transaction on the block explorer.",
                systemImage: "safari"
            ) {
                dismiss()
                onOpenExplorer()
            }

            if let candidate {
                ActionSheetRow(
                    title: "Add to Portfolio",
                    subtitle: "Records it as a buy or a sell in a portfolio of your choosing.",
                    systemImage: "chart.pie.fill"
                ) {
                    dismiss()
                    onAddToPortfolio(candidate)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .presentationDetents([.height(candidate == nil ? 250 : 320)])
        .presentationDragIndicator(.visible)
    }

    private func summary(_ candidate: PortfolioCandidateTransaction) -> String {
        let direction = candidate.isOutgoing ? "Sent" : "Received"
        return "\(direction) \(PortfolioFormat.kas(candidate.amountKas)) on "
            + candidate.timestamp.formatted(date: .abbreviated, time: .shortened)
    }
}
