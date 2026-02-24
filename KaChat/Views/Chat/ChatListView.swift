import SwiftUI
import UserNotifications
import UIKit

struct ChatListView: View {
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var searchText = ""
    @State private var selectedContact: Contact?
    @State private var showAddContact = false
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success
    @State private var loadedConversationCount = 80
    @State private var isPaginatingConversations = false
    @State private var filteredConversationsCache: [Conversation] = []
    @State private var searchFilterTask: Task<Void, Never>?
    @State private var splitColumnVisibility: NavigationSplitViewVisibility = .all

    private let conversationPageSize = 80
    private let conversationPrefetchThreshold = 12

    private var shouldUseSplitLayout: Bool {
#if targetEnvironment(macCatalyst)
        true
#else
        horizontalSizeClass == .regular
#endif
    }

    var body: some View {
        Group {
            if shouldUseSplitLayout {
                NavigationSplitView(columnVisibility: $splitColumnVisibility) {
                    chatListPane
                } detail: {
                    splitDetailPane
                }
                .navigationSplitViewStyle(.balanced)
                .onAppear {
                    splitColumnVisibility = .all
                }
            } else {
                NavigationStack {
                    chatListPane
                        .navigationDestination(isPresented: Binding(
                            get: { selectedContact != nil },
                            set: { isPresented in
                                if !isPresented {
                                    selectedContact = nil
                                }
                            }
                        )) {
                            if let contact = selectedContact {
                                ChatDetailView(contact: contact)
                            } else {
                                EmptyView()
                            }
                        }
                }
            }
        }
    }

    private var chatListPane: some View {
        chatListContent
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ConnectionStatusIndicator()
                }
                ToolbarItem(placement: .principal) {
                    balanceToolbarView
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showAddContact = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search chats")
            .refreshable {
                await chatService.fetchNewMessages()
            }
            .toast(message: toastMessage, style: toastStyle)
            .sheet(isPresented: $showAddContact) {
                AddContactView { contact in
                    _ = chatService.getOrCreateConversation(for: contact)
                    selectedContact = contact
                    showAddContact = false
                }
            }
    }

    @ViewBuilder
    private var splitDetailPane: some View {
        if let contact = selectedContact {
            ChatDetailView(contact: contact)
                .id(contact.id)
        } else {
            splitEmptyDetailView
        }
    }

    @ViewBuilder
    private var chatListContent: some View {
        Group {
            if chatService.conversations.isEmpty {
                emptyStateView
            } else {
                conversationsList
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChat)) { notification in
            handleOpenChatNotification(notification)
        }
        .onAppear {
            checkPendingNavigation()
            requestNotificationPermissionIfNeeded()
            loadedConversationCount = conversationPageSize
            refreshFilteredConversations()
            Task { _ = try? await walletManager.refreshBalance() }
        }
        .onChange(of: searchText) { newValue in
            if newValue.isEmpty {
                loadedConversationCount = conversationPageSize
                scheduleFilteredConversationsRefresh(debounce: false)
            } else {
                scheduleFilteredConversationsRefresh(debounce: true)
            }
        }
        .onChange(of: chatService.conversations) { _ in
            scheduleFilteredConversationsRefresh(debounce: false)
        }
        .onChange(of: contactsManager.contacts) { _ in
            scheduleFilteredConversationsRefresh(debounce: false)
        }
        .onChange(of: settingsViewModel.settings.hideAutoCreatedPaymentChats) { _ in
            scheduleFilteredConversationsRefresh(debounce: false)
        }
        .onDisappear {
            searchFilterTask?.cancel()
        }
        .task {
            await contactsManager.fetchKNSDomainsForAllContacts()
        }
        .onChange(of: chatService.pendingChatNavigation) { newValue in
            if newValue != nil {
                checkPendingNavigation()
            }
        }
    }

    private func handleOpenChatNotification(_ notification: Notification) {
        guard let contactAddress = notification.userInfo?["contactAddress"] as? String else { return }
        navigateToChat(address: contactAddress)
    }

    private func checkPendingNavigation() {
        guard let contactAddress = chatService.pendingChatNavigation else { return }
        chatService.pendingChatNavigation = nil
        navigateToChat(address: contactAddress)
    }

    private func navigateToChat(address: String) {
        // Find contact by address
        let contact: Contact?
        if let c = contactsManager.contacts.first(where: { $0.address == address }) {
            contact = c
        } else if let conversation = chatService.conversations.first(where: { $0.contact.address == address }) {
            contact = conversation.contact
        } else {
            contact = nil
        }
        guard let target = contact else { return }

        if shouldUseSplitLayout {
            selectedContact = target
            return
        }

        // When a chat is already open, ChatDetailView handles the switch
        // in-place via its own .onReceive(.openChat) handler.
        if selectedContact == nil {
            selectedContact = target
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Conversations Yet")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Start a new chat by adding a contact")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button {
                showAddContact = true
            } label: {
                Label("Add Contact", systemImage: "person.badge.plus")
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.top)
        }
        .padding()
    }

    private var splitEmptyDetailView: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44))
                .foregroundColor(.secondary)

            Text("Select a chat")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Choose a conversation on the left to view messages.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Color(UIColor.systemBackground))
    }

    private var conversationsList: some View {
        let filtered = filteredConversationsCache
        let totalCount = filtered.count
        let displayed: [Conversation]
        if searchText.isEmpty {
            let count = min(totalCount, max(loadedConversationCount, conversationPageSize))
            displayed = Array(filtered.prefix(count))
        } else {
            displayed = filtered
        }

        return List {
            ForEach(Array(displayed.enumerated()), id: \.element.id) { index, conversation in
                Button {
                    selectedContact = conversation.contact
                } label: {
                    ConversationRow(conversation: conversation)
                }
                .buttonStyle(ChatRowPressStyle())
                .listRowBackground(
                    shouldUseSplitLayout && selectedContact?.address == conversation.contact.address
                        ? Color.accentColor.opacity(0.14)
                        : Color.clear
                )
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        archiveConversation(conversation.contact.address)
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .tint(.gray)
                }
                .onAppear {
                    maybeLoadMoreConversations(
                        currentIndex: index,
                        displayedCount: displayed.count,
                        totalCount: totalCount
                    )
                }
            }
        }
        .listStyle(.plain)
    }

    private var balanceToolbarView: some View {
        let sompi = walletManager.currentWallet?.balanceSompi
        let exact = sompi.map(formatKaspaExact) ?? "--"
        return Text("\(exact) KAS")
            .font(.caption)
            .monospacedDigit()
            .foregroundColor(.secondary)
        .onTapGesture {
            guard sompi != nil else { return }
            UIPasteboard.general.string = exact
            Haptics.success()
            showToast("Balance copied to clipboard.")
        }
    }

    private func formatKaspaExact(_ sompi: UInt64) -> String {
        let kas = Double(sompi) / 100_000_000.0
        return String(format: "%.8f", kas)
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

    private func scheduleFilteredConversationsRefresh(debounce: Bool) {
        searchFilterTask?.cancel()
        if debounce {
            searchFilterTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled else { return }
                refreshFilteredConversations()
            }
        } else {
            refreshFilteredConversations()
        }
    }

    private func refreshFilteredConversations() {
        let settings = settingsViewModel.settings
        let sourceConversations = chatService.conversations

        if searchText.isEmpty {
            filteredConversationsCache = sourceConversations
                .filter { conversation in
                    chatService.isConversationVisibleInChatList(conversation, settings: settings)
                }
                .sorted { conv1, conv2 in
                    let time1 = conv1.lastMessage?.timestamp ?? Date.distantPast
                    let time2 = conv2.lastMessage?.timestamp ?? Date.distantPast
                    return time1 > time2
                }
            return
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            filteredConversationsCache = sourceConversations
                .filter { conversation in
                    chatService.isConversationVisibleInChatList(conversation, settings: settings)
                }
                .sorted { conv1, conv2 in
                    let time1 = conv1.lastMessage?.timestamp ?? Date.distantPast
                    let time2 = conv2.lastMessage?.timestamp ?? Date.distantPast
                    return time1 > time2
                }
            return
        }

        filteredConversationsCache = sourceConversations.filter { conv in
            guard chatService.isConversationVisibleInChatList(conv, settings: settings) else { return false }
            if conv.contact.alias.range(of: query, options: .caseInsensitive) != nil {
                return true
            }
            if conv.contact.address.range(of: query, options: .caseInsensitive) != nil {
                return true
            }
            return conv.messages.contains { message in
                message.content.range(of: query, options: .caseInsensitive) != nil
            }
        }
    }

    private func archiveConversation(_ address: String) {
        contactsManager.setContactArchived(address: address, isArchived: true)
        chatService.checkAndResubscribeIfNeeded()
        showToast("Chat archived.")
    }

    private func maybeLoadMoreConversations(currentIndex: Int, displayedCount: Int, totalCount: Int) {
        guard searchText.isEmpty else { return }
        guard !isPaginatingConversations else { return }
        guard loadedConversationCount < totalCount else { return }

        let triggerIndex = max(0, displayedCount - conversationPrefetchThreshold)
        guard currentIndex >= triggerIndex else { return }

        isPaginatingConversations = true
        DispatchQueue.main.async {
            loadedConversationCount = min(totalCount, loadedConversationCount + conversationPageSize)
            isPaginatingConversations = false
        }
    }

    /// Request notification permission if not yet requested
    private func requestNotificationPermissionIfNeeded() {
        // Skip if already requested
        guard !settingsViewModel.settings.notificationPermissionRequested else { return }

        // Mark as requested (will save even if user doesn't respond)
        settingsViewModel.settings.notificationPermissionRequested = true
        settingsViewModel.saveSettings()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DispatchQueue.main.async {
                if !granted {
                    // User denied - disable notifications in settings
                    settingsViewModel.settings.notificationsEnabled = false
                    settingsViewModel.saveSettings()
                    NSLog("[ChatListView] Notification permission denied by user")
                } else {
                    NSLog("[ChatListView] Notification permission granted")
                }
            }
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    @EnvironmentObject var chatService: ChatService
    @ObservedObject private var knsService = KNSService.shared
    private static let previewCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 2048
        return cache
    }()

    private var avatarURLString: String? {
        knsService.profileCache[conversation.contact.address]?.avatarURL
    }

    var body: some View {
        let lastMessage = conversation.lastMessage

        HStack(spacing: 12) {
            // Avatar
            KNSAvatarView(
                avatarURLString: avatarURLString,
                fallbackText: conversation.contact.alias,
                size: 50
            )

            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(conversation.contact.alias)
                            .font(.headline)
                            .lineLimit(1)
                    }

                    Spacer()

                    if let state = chatService.chatFetchStates[conversation.contact.address] {
                        switch state {
                        case .loading:
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.secondary)
                        case .failed:
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }

                    if let lastMessage {
                        Text(formatDate(lastMessage.timestamp))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    if let lastMessage {
                        if lastMessage.isOutgoing || lastMessage.deliveryStatus == .warning {
                            switch lastMessage.deliveryStatus {
                            case .sent:
                                Image(systemName: "checkmark")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            case .pending:
                                Image(systemName: "clock")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            case .failed:
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundColor(.red)
                            case .warning:
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            }
                        }

                        Text(formatPreview(lastMessage.content))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("No messages yet")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .italic()
                    }

                    Spacer()

                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle()) // Make entire row tappable
    }

    private func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            return SharedFormatting.chatTime.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            return SharedFormatting.chatDay.string(from: date)
        }
    }

    private func formatPreview(_ content: String) -> String {
        let key = "\(content.count)|\(content.hashValue)|\(content.prefix(24))" as NSString
        if let cached = Self.previewCache.object(forKey: key) {
            return cached as String
        }

        let result: String
        // Check if content is a file JSON payload
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else {
            result = content
            Self.previewCache.setObject(result as NSString, forKey: key)
            return result
        }

        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "file",
              let mimeType = json["mimeType"] as? String else {
            result = content
            Self.previewCache.setObject(result as NSString, forKey: key)
            return result
        }

        let mime = mimeType.lowercased()
        if mime.hasPrefix("image/") {
            result = "Photo"
        } else if mime.hasPrefix("audio/") {
            result = "Voice message"
        } else if mime.hasPrefix("video/") {
            result = "Video"
        } else {
            result = "File"
        }
        Self.previewCache.setObject(result as NSString, forKey: key)
        return result
    }
}

private struct ChatRowPressStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let overlayColor = colorScheme == .dark
            ? Color.white.opacity(0.22)
            : Color.black.opacity(0.10)

        return configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                Rectangle()
                    .fill(configuration.isPressed ? overlayColor : .clear)
            )
            .opacity(configuration.isPressed ? 0.96 : 1.0)
            .animation(.linear(duration: 0.06), value: configuration.isPressed)
    }
}

struct ShimmeringText: View {
    let text: String
    let font: Font
    let color: Color
    let isShimmering: Bool

    @State private var phase: CGFloat = -1

    private var baseText: Text {
        Text(text)
            .font(font)
            .monospacedDigit()
    }

    var body: some View {
        baseText
            .foregroundColor(color)
            .overlay {
                if isShimmering {
                    ShimmerOverlay(phase: phase)
                        .mask(baseText)
                }
            }
            .onAppear {
                updateShimmer()
            }
            .onChange(of: isShimmering) { _ in
                updateShimmer()
            }
    }

    private func updateShimmer() {
        if isShimmering {
            phase = -1
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1
            }
        } else {
            phase = -1
        }
    }
}

private struct ShimmerOverlay: View {
    let phase: CGFloat

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.0),
                            Color.white.opacity(0.24),
                            Color.white.opacity(0.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .rotationEffect(.degrees(20))
                .offset(x: phase * width * 1.4)
        }
    }
}

struct ContactRow: View {
    let contact: Contact
    @EnvironmentObject var contactsManager: ContactsManager

    private var knsDomains: [KNSDomain] {
        contactsManager.getKNSDomains(for: contact)
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.accentColor.opacity(0.2))
                .frame(width: 44, height: 44)
                .overlay(
                    Text(contact.alias.prefix(2).uppercased())
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.accentColor)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(contact.alias)
                    .font(.body)

                if !knsDomains.isEmpty {
                    Text(knsDomains.map { $0.fullName }.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                        .lineLimit(1)
                }

                Text(contact.address)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle()) // Make entire row tappable
    }
}

#Preview {
    ChatListView()
        .environmentObject(ChatService.shared)
        .environmentObject(ContactsManager.shared)
        .environmentObject(WalletManager.shared)
}
