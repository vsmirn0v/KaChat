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

/// Who reacted to one message, and with what.
///
/// The pill on a bubble shows which emoji are on it and nothing else - not how many of each, and
/// not from whom. Shared by 1:1, group and broadcast messages, which each carry their own
/// reaction snapshot type; callers map theirs into `Entry`.
struct ReactionsSheet: View {
    struct Entry: Identifiable {
        let emoji: String
        let reactorAddress: String
        var id: String { "\(emoji)-\(reactorAddress)" }
    }

    let entries: [Entry]
    let myAddress: String
    let displayName: (String) -> String
    /// KNS avatar for a reactor, when one is cached. A face is how you recognise someone in a
    /// list of names you may not have saved.
    var avatarURL: (String) -> String? = { _ in nil }

    /// One emoji and everyone who used it. A named type, not a tuple: an array of labelled
    /// tuples built by a chained map/sorted is expensive for the type checker to infer.
    private struct EmojiGroup: Identifiable {
        let emoji: String
        let reactors: [Entry]
        var id: String { emoji }
    }

    private var grouped: [EmojiGroup] {
        let byEmoji: [String: [Entry]] = Dictionary(grouping: entries, by: { $0.emoji })
        let groups: [EmojiGroup] = byEmoji.map { EmojiGroup(emoji: $0.key, reactors: $0.value) }
        return groups.sorted { $0.reactors.count > $1.reactors.count }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(grouped) { group in
                    Section {
                        ForEach(group.reactors) { entry in
                            let name = entry.reactorAddress == myAddress
                                ? "You"
                                : displayName(entry.reactorAddress)
                            HStack(spacing: 10) {
                                KNSAvatarView(
                                    avatarURLString: avatarURL(entry.reactorAddress),
                                    fallbackText: name,
                                    size: 28,
                                    contactAddress: entry.reactorAddress
                                )
                                Text(name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    } header: {
                        HStack(spacing: 8) {
                            Text(group.emoji).font(.title3)
                            Text(group.reactors.count == 1 ? "1 person" : "\(group.reactors.count) people")
                        }
                    }
                }
            }
            .navigationTitle(entries.count == 1 ? "1 Reaction" : "\(entries.count) Reactions")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// Identifiable wrapper so a plain txId can drive `.sheet(item:)`.
struct ReactionsSheetTarget: Identifiable {
    let txId: String
    var id: String { txId }
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


/// A URL made Identifiable so `.sheet(item:)` can present on it - `URL` itself is not.
struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
    init(_ url: URL) { self.url = url }
}

/// What to do with a link someone sent: the half-sheet form of the old confirmation dialog.
///
/// A dialog of bare labels could show the verb and nothing else, and put the URL in small print
/// above the buttons. As a sheet the link itself gets room to be read - which matters, because
/// deciding whether to open a link IS reading it.
struct LinkActionsSheet: View {
    let url: URL
    let onOpen: () -> Void
    let onCopy: () -> Void
    /// Nil where replying makes no sense (a KaPost, a broadcast you cannot reply into).
    var onReply: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text(url.absoluteString)
                .font(.footnote.weight(.medium))
                .foregroundColor(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 20)
                .padding(.horizontal, 20)
                .padding(.bottom, 4)

            ActionSheetRow(
                title: "Open Link",
                subtitle: "Opens in your browser.",
                systemImage: "safari"
            ) { dismiss(); onOpen() }

            ActionSheetRow(
                title: "Copy Link",
                subtitle: "Copies the address to your clipboard.",
                systemImage: "doc.on.doc"
            ) { dismiss(); onCopy() }

            if let onReply {
                ActionSheetRow(
                    title: "Reply",
                    subtitle: "Reply to this message instead.",
                    systemImage: "arrowshape.turn.up.left"
                ) { dismiss(); onReply() }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .presentationDetents([.height(onReply == nil ? 260 : 330)])
    }
}

/// Repost as-is, or quote it with your own words - the half-sheet form of the old dialog.
struct RepostActionsSheet: View {
    let onRepost: () -> Void
    let onQuote: () -> Void
    /// Set when the post is already reposted, so the first row offers to take it back.
    var isReposted: Bool = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text(isReposted ? "Reposted" : "Repost")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 4)

            ActionSheetRow(
                title: isReposted ? "Undo Repost" : "Repost",
                subtitle: isReposted
                    ? "Removes it from your profile."
                    : "Shares it to your followers as-is.",
                systemImage: isReposted ? "arrow.uturn.backward" : "arrow.2.squarepath",
                tint: isReposted ? .red : .accentColor
            ) { dismiss(); onRepost() }

            ActionSheetRow(
                title: "Quote",
                subtitle: "Adds your own words above it.",
                systemImage: "quote.bubble"
            ) { dismiss(); onQuote() }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .presentationDetents([.height(280)])
    }
}


/// Closing the composer with something written: keep it, or throw it away.
///
/// A sheet rather than a confirmation dialog so each choice can say what happens to the post -
/// "Save Draft" and "Discard" as bare verbs leave you to work out where a saved one goes.
struct ComposerCloseOptionsSheet: View {
    let onSaveDraft: () -> Void
    let onDiscard: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("Save this post?")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 4)

            ActionSheetRow(
                title: "Save Draft",
                subtitle: "Keep it in Drafts to finish later.",
                systemImage: "square.and.arrow.down"
            ) { dismiss(); onSaveDraft() }

            ActionSheetRow(
                title: "Discard",
                subtitle: "Throw this away.",
                systemImage: "trash",
                tint: .red
            ) { dismiss(); onDiscard() }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .presentationDetents([.height(280)])
    }
}

/// A yes/no confirmation, in a half sheet.
///
/// The app's confirmations were `.confirmationDialog`s - a stack of bare verbs with the reason
/// squeezed into a small grey line above them. As a sheet the consequence gets a full row of its
/// own next to the action it belongs to, which is what someone about to log out or delete
/// something is actually reading for.
struct ConfirmActionSheet: View {
    let title: String
    let confirmTitle: String
    /// What actually happens if they go ahead - the row's second line.
    let confirmSubtitle: String
    var confirmSystemImage: String = "checkmark.circle"
    var isDestructive: Bool = true
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.top, 20)
                .padding(.bottom, 4)

            ActionSheetRow(
                title: confirmTitle,
                subtitle: confirmSubtitle,
                systemImage: confirmSystemImage,
                tint: isDestructive ? .red : .accentColor
            ) { dismiss(); onConfirm() }

            ActionSheetRow(
                title: "Cancel",
                subtitle: "Leave everything as it is.",
                systemImage: "xmark"
            ) { dismiss() }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
    }
}
