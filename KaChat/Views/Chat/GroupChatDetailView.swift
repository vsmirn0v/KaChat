import SwiftUI

/// Group chat thread view. Deliberately simpler than `ChatDetailView`/`MessageBubbleView`
/// (text-only for now, no payments/audio/reply) - scoped to what's needed to make group
/// messaging usable, matching the "add features without redesigning the UI" brief this was
/// built under.
struct GroupChatDetailView: View {
    let group: GroupChat
    @EnvironmentObject var groupChatService: GroupChatService
    @State private var draft = ""
    @State private var showInfo = false
    @State private var errorMessage: String?
    @FocusState private var isComposerFocused: Bool

    private var messages: [GroupMessage] {
        (groupChatService.groupMessages[group.id] ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(messages) { message in
                            GroupMessageBubbleRow(message: message, group: group)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) { _ in
                    if let last = messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
            }

            composeBar
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
            }
        }
        .sheet(isPresented: $showInfo) {
            GroupChatInfoView(group: group)
        }
        .task {
            groupChatService.loadMessages(for: group.id)
        }
    }

    private var composeBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($isComposerFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(glassBackground(cornerRadius: 20))

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(canSend ? .accentColor : .secondary)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        errorMessage = nil
        Task {
            do {
                try await groupChatService.sendGroupMessage(text, to: group.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func glassBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
    }
}

private struct GroupMessageBubbleRow: View {
    let message: GroupMessage
    let group: GroupChat

    private static let bubbleColor = Color(red: 112.0 / 255.0, green: 199.0 / 255.0, blue: 186.0 / 255.0)

    private var senderName: String {
        guard let address = message.senderAddress else { return "Unknown" }
        if let member = group.members.first(where: { $0.address == address }), let displayName = member.displayName, !displayName.isEmpty {
            return displayName
        }
        return String(address.suffix(10))
    }

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 40) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                if !message.isOutgoing {
                    Text(senderName)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 4)
                }

                HStack(spacing: 4) {
                    if message.isOutgoing {
                        statusIcon
                    }
                    Text(message.content)
                        .font(.body)
                        .foregroundColor(message.isOutgoing ? .white : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(message.isOutgoing ? Self.bubbleColor : Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }

            if !message.isOutgoing { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch message.deliveryStatus {
        case .pending:
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundColor(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.red)
        case .sent, .warning:
            EmptyView()
        }
    }
}

/// Group membership + invite sharing. Kept intentionally minimal - member add/remove and
/// "join via invite link" entry points are natural next steps once this is in front of you.
struct GroupChatInfoView: View {
    let group: GroupChat
    @EnvironmentObject var groupChatService: GroupChatService
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var isPublishingInvite = false
    @State private var shareLink: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Members (\(group.members.count))") {
                    ForEach(group.members) { member in
                        let hasDisplayName = !(member.displayName ?? "").isEmpty
                        let memberLabel = hasDisplayName ? (member.displayName ?? "") : String(member.address.suffix(10))
                        HStack {
                            Text(memberLabel)
                                .font(.system(.body, design: hasDisplayName ? .default : .monospaced))
                            Spacer()
                            if member.isAdmin {
                                Text("Admin")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                if group.isAdmin {
                    Section {
                        Button {
                            shareInvite()
                        } label: {
                            if isPublishingInvite {
                                HStack {
                                    ProgressView()
                                    Text("Publishing invite...")
                                }
                            } else {
                                Label("Create Invite Link", systemImage: "link.badge.plus")
                            }
                        }
                        .disabled(isPublishingInvite)
                    } footer: {
                        Text("Anyone with this link can join the group without needing to already be a contact.")
                    }
                }

                if let shareLink {
                    Section {
                        Text(shareLink)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                        ShareLink(item: shareLink) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Group Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func shareInvite() {
        isPublishingInvite = true
        errorMessage = nil
        Task {
            do {
                let invite = try groupChatService.createInvite(for: group.id)
                try await groupChatService.publishInvite(invite)
                await MainActor.run {
                    shareLink = GroupChatService.inviteLink(invite)
                    isPublishingInvite = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isPublishingInvite = false
                }
            }
        }
    }
}
