import SwiftUI
import UserNotifications
import UIKit

struct ChatListView: View {
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var broadcastService: BroadcastService
    @EnvironmentObject var groupChatService: GroupChatService
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    enum ChatsListTab: Int {
        case chats, groups
    }

    @State private var searchText = ""
    @State private var selectedContact: Contact?
    @State private var selectedGroup: GroupChat?
    @State private var selectedContactStartInPaymentMode = false
    @State private var showAddContact = false
    @State private var showBroadcastList = false
    @State private var pendingBroadcastChannel: String?
    @State private var selectedListTab: ChatsListTab = .chats
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success
    @State private var loadedConversationCount = 80
    @State private var isPaginatingConversations = false
    @State private var filteredConversationsCache: [Conversation] = []
    @State private var searchFilterTask: Task<Void, Never>?
    @State private var avatarPrefetchTask: Task<Void, Never>?
    @State private var splitColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var contactPendingDelete: Contact?
    @State private var groupPendingDelete: GroupChat?
    @State private var editMode: EditMode = .inactive
    @State private var selectedContactIDs: Set<UUID> = []
    @State private var selectedGroupIDs: Set<String> = []

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
                        .modifier(ChatDetailNavigationDestination(
                            selectedContact: $selectedContact,
                            startInPaymentMode: selectedContactStartInPaymentMode
                        ))
                        .modifier(GroupChatDetailNavigationDestination(selectedGroup: $selectedGroup))
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
                    if editMode == .active {
                        if selectedListTab == .chats {
                            Button(selectedContactIDs.count == filteredConversationsCache.count ? "Deselect All" : "Select All") {
                                if selectedContactIDs.count == filteredConversationsCache.count {
                                    selectedContactIDs = []
                                } else {
                                    selectedContactIDs = Set(filteredConversationsCache.map { $0.contact.id })
                                }
                            }
                        } else {
                            Button(selectedGroupIDs.count == displayedGroups.count ? "Deselect All" : "Select All") {
                                if selectedGroupIDs.count == displayedGroups.count {
                                    selectedGroupIDs = []
                                } else {
                                    selectedGroupIDs = Set(displayedGroups.map { $0.id })
                                }
                            }
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(editMode == .active ? "Cancel" : "Select") {
                        withAnimation {
                            editMode = editMode == .active ? .inactive : .active
                        }
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
                    selectedContactStartInPaymentMode = false
                    pendingBroadcastChannel = nil
                    showBroadcastList = false
                    selectedGroup = nil
                    selectedContact = contact
                    selectedListTab = .chats
                    showAddContact = false
                } onCreateGroup: { group in
                    selectedContactStartInPaymentMode = false
                    pendingBroadcastChannel = nil
                    showBroadcastList = false
                    selectedContact = nil
                    selectedGroup = group
                    selectedListTab = .groups
                    showAddContact = false
                }
                .presentationDetents([.large])
            }
            .alert(
                "Delete Chat with \(contactPendingDelete?.alias ?? "")",
                isPresented: Binding(
                    get: { contactPendingDelete != nil },
                    set: { if !$0 { contactPendingDelete = nil } }
                )
            ) {
                Button("Delete", role: .destructive) {
                    if let contact = contactPendingDelete {
                        deleteConversation(contact)
                    }
                    contactPendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    contactPendingDelete = nil
                }
            } message: {
                Text("This permanently deletes every message with them, including from iCloud, so it's removed from your other devices too. This cannot be undone.")
            }
            .alert(
                "Delete \"\(groupPendingDelete?.name ?? "")\"",
                isPresented: Binding(
                    get: { groupPendingDelete != nil },
                    set: { if !$0 { groupPendingDelete = nil } }
                )
            ) {
                Button("Delete", role: .destructive) {
                    if let group = groupPendingDelete {
                        if selectedGroup?.id == group.id { selectedGroup = nil }
                        groupChatService.deleteGroup(group.id)
                    }
                    groupPendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    groupPendingDelete = nil
                }
            } message: {
                Text("This removes the group and its messages from this device. This cannot be undone, and other members won't be notified.")
            }
            .modifier(BroadcastListNavigationDestination(
                mode: BroadcastNavigationPolicy.listPresentationMode(usesSplitLayout: shouldUseSplitLayout),
                showBroadcastList: $showBroadcastList,
                pendingBroadcastChannel: $pendingBroadcastChannel
            ))
            .environment(\.editMode, $editMode)
    }

    @ViewBuilder
    private var splitDetailPane: some View {
        if showBroadcastList {
            BroadcastListView(initialChannel: pendingBroadcastChannel)
                .id(pendingBroadcastChannel ?? "__broadcasts")
        } else if let group = selectedGroup {
            GroupChatDetailView(group: group, onDeleted: { selectedGroup = nil })
                .id(group.id)
        } else if let contact = selectedContact {
            ChatDetailView(contact: contact, startInPaymentMode: selectedContactStartInPaymentMode)
                .id(contact.id)
        } else {
            splitEmptyDetailView
        }
    }

    @ViewBuilder
    private var chatListContent: some View {
        VStack(spacing: 0) {
            chatsTopTabBar
            // Tap-only, not swipeable - a paging TabView here would fight the row-level
            // swipe-to-delete/mark-read gestures on both the Chats and Group Chats lists.
            Group {
                switch selectedListTab {
                case .chats:
                    chatsTabContent
                case .groups:
                    groupsTabContent
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if editMode == .active {
                selectionActionBar
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if editMode != .active {
                createChatButton
            }
        }
        .onChange(of: editMode) { newValue in
            if newValue == .inactive {
                selectedContactIDs = []
                selectedGroupIDs = []
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChat)) { notification in
            handleOpenChatNotification(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openBroadcast)) { notification in
            handleOpenBroadcastNotification(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openGroup)) { notification in
            handleOpenGroupNotification(notification)
        }
        .onAppear {
            checkPendingNavigation()
            checkPendingBroadcastNavigation()
            checkPendingGroupNavigation()
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
            scheduleAvatarPrefetch()
        }
        .onChange(of: contactsManager.contacts) { _ in
            scheduleFilteredConversationsRefresh(debounce: false)
        }
        .onDisappear {
            searchFilterTask?.cancel()
            avatarPrefetchTask?.cancel()
        }
        .task {
            await contactsManager.fetchKNSDomainsForAllContacts()
            await preloadAvatarsForAllChats(forceProfileRefresh: false)
        }
        .onChange(of: chatService.pendingChatNavigation) { newValue in
            if newValue != nil {
                checkPendingNavigation()
            }
        }
        .onChange(of: broadcastService.pendingBroadcastNavigation) { newValue in
            if newValue != nil {
                checkPendingBroadcastNavigation()
            }
        }
        .onChange(of: groupChatService.pendingGroupNavigation) { newValue in
            if newValue != nil {
                checkPendingGroupNavigation()
            }
        }
    }

    private func handleOpenChatNotification(_ notification: Notification) {
        guard let contactAddress = notification.userInfo?["contactAddress"] as? String else { return }
        let startInPaymentMode = notification.userInfo?["paymentMode"] as? Bool ?? false
        navigateToChat(address: contactAddress, startInPaymentMode: startInPaymentMode)
    }

    private func checkPendingNavigation() {
        guard let contactAddress = chatService.pendingChatNavigation else { return }
        chatService.pendingChatNavigation = nil
        navigateToChat(address: contactAddress)
    }

    private func handleOpenBroadcastNotification(_ notification: Notification) {
        guard let channel = notification.userInfo?["channel"] as? String else { return }
        navigateToBroadcast(channel: channel)
    }

    private func checkPendingBroadcastNavigation() {
        guard let channel = broadcastService.pendingBroadcastNavigation else { return }
        broadcastService.pendingBroadcastNavigation = nil
        navigateToBroadcast(channel: channel)
    }

    private func handleOpenGroupNotification(_ notification: Notification) {
        guard let groupId = notification.userInfo?["groupId"] as? String else { return }
        navigateToGroup(groupId: groupId)
    }

    private func checkPendingGroupNavigation() {
        guard let groupId = groupChatService.pendingGroupNavigation else { return }
        groupChatService.pendingGroupNavigation = nil
        navigateToGroup(groupId: groupId)
    }

    /// Opens the broadcast list already pushed one level deeper into the tapped room, matching
    /// `navigateToChat`'s cold-start/already-running handling for 1:1 chats.
    private func navigateToBroadcast(channel: String) {
        pendingBroadcastChannel = channel
        selectedContact = nil
        showBroadcastList = true
    }

    private func navigateToGroup(groupId: String) {
        guard let target = groupChatService.groups.first(where: { $0.id == groupId }) else { return }
        selectedListTab = .groups
        selectedContact = nil
        pendingBroadcastChannel = nil
        showBroadcastList = false
        selectedGroup = target
    }

    private func navigateToChat(address: String, startInPaymentMode: Bool = false) {
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

        selectedListTab = .chats

        if shouldUseSplitLayout {
            selectedContactStartInPaymentMode = startInPaymentMode
            pendingBroadcastChannel = nil
            showBroadcastList = false
            selectedContact = target
            return
        }

        // When a chat is already open, ChatDetailView handles the switch
        // in-place via its own .onReceive(.openChat) handler.
        if selectedContact == nil {
            selectedContactStartInPaymentMode = startInPaymentMode
            pendingBroadcastChannel = nil
            showBroadcastList = false
            selectedContact = target
        }
    }

    private var createChatButton: some View {
        Button {
            Haptics.impact(.light)
            showAddContact = true
        } label: {
            Image(systemName: "person.badge.plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 56, height: 56)
                .background(
                    Circle()
                        .fill(.regularMaterial)
                        .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.8))
                        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
                )
        }
        .padding(.trailing, 20)
        .padding(.bottom, 16)
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

            Text("Choose a conversation on the left")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Color(UIColor.systemBackground))
    }

    /// Underline-style tab bar (bold labels, teal indicator bar under the selected tab) - same
    /// visual language as `BroadcastListView.broadcastTabBar`'s own Channels/Popular sub-tabs.
    /// Tap-only (see `chatListContent`) - Broadcasts isn't one of these tabs, it's the first row
    /// inside the Chats tab's own list (see `chatsTabContent`), matching its original
    /// placement/behavior (a pushed screen reached from a chat-like row, not a tab).
    private var chatsTopTabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                chatsTabButton("Chats", tab: .chats)
                chatsTabButton("Group Chats", tab: .groups)
            }
            Divider()
        }
    }

    private func chatsTabButton(_ title: String, tab: ChatsListTab) -> some View {
        let isSelected = selectedListTab == tab
        // Selection mode is scoped to whichever list it was started on - switching tabs mid-select
        // would either strand a selection the visible list can't act on, or silently blend Chats
        // and Group Chats selections together, so the other tab is inert while editing.
        let isSwitchBlocked = editMode == .active && !isSelected
        let unreadCount = tab == .chats
            ? chatService.conversations.reduce(0) { $0 + $1.unreadCount }
            : groupChatService.totalGroupUnreadCount
        return Button {
            guard !isSwitchBlocked else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedListTab = tab
            }
        } label: {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(isSelected ? .accentColor : .accentColor.opacity(isSwitchBlocked ? 0.25 : 0.5))

                    if unreadCount > 0 {
                        Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.red))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 12)

                Rectangle()
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .frame(height: 2.5)
            }
        }
        .buttonStyle(.plain)
    }

    /// Most recent activity first, matching chatsTabContent's identical sort for 1:1
    /// (refreshFilteredConversations) - falls back to createdAt for a group with no messages
    /// yet, so a brand-new empty group still sorts by when it was added/joined - then filtered
    /// by search, matching refreshFilteredConversations' match fields (alias/address/message
    /// content): group name, each member's alias-or-address, and message content. Shared by
    /// groupsTabContent and the toolbar's Select All so both agree on what's "visible."
    private var displayedGroups: [GroupChat] {
        let sorted = groupChatService.groups.sorted { g1, g2 in
            let t1 = groupChatService.groupMessages[g1.id]?.map { $0.timestamp }.max() ?? g1.createdAt
            let t2 = groupChatService.groupMessages[g2.id]?.map { $0.timestamp }.max() ?? g2.createdAt
            return t1 > t2
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sorted }
        return sorted.filter { group in
            if group.name.range(of: query, options: .caseInsensitive) != nil {
                return true
            }
            if group.members.contains(where: { member in
                if let alias = contactsManager.getContact(byAddress: member.address)?.alias,
                   alias.range(of: query, options: .caseInsensitive) != nil {
                    return true
                }
                return member.address.range(of: query, options: .caseInsensitive) != nil
            }) {
                return true
            }
            return (groupChatService.groupMessages[group.id] ?? []).contains { message in
                message.content.range(of: query, options: .caseInsensitive) != nil
            }
        }
    }

    private var groupsTabContent: some View {
        let groups = displayedGroups
        return List(selection: $selectedGroupIDs) {
            if !groups.isEmpty {
                ForEach(groups) { group in
                    Button {
                        // Same reasoning as chatsTabContent's row Button: our own Button label
                        // consumes the tap before List(selection:)'s native edit-mode row-selection
                        // UI ever sees it, so selection is toggled explicitly here instead.
                        if editMode == .active {
                            if selectedGroupIDs.contains(group.id) {
                                selectedGroupIDs.remove(group.id)
                            } else {
                                selectedGroupIDs.insert(group.id)
                            }
                        } else {
                            pendingBroadcastChannel = nil
                            showBroadcastList = false
                            selectedContact = nil
                            selectedGroup = group
                        }
                    } label: {
                        GroupChatRow(group: group)
                    }
                    .buttonStyle(ChatRowPressStyle())
                    .tag(group.id)
                    .listRowBackground(
                        shouldUseSplitLayout && selectedGroup?.id == group.id
                            ? Color.accentColor.opacity(0.14)
                            : Color.clear
                    )
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            if groupChatService.unreadCount(for: group) > 0 {
                                groupChatService.markGroupAsRead(group.id)
                            } else {
                                groupChatService.markGroupAsUnread(group.id)
                            }
                        } label: {
                            if groupChatService.unreadCount(for: group) > 0 {
                                Label("Read", systemImage: "envelope.open")
                            } else {
                                Label("Unread", systemImage: "envelope.badge")
                            }
                        }
                        .tint(.accentColor)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            groupPendingDelete = group
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }

                Text("\(groups.count) group\(groups.count == 1 ? "" : "s")")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay {
            if groups.isEmpty && searchText.isEmpty {
                groupsEmptyStateView
            }
        }
    }

    private var groupsEmptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.3")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Group Chats Yet")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Start a new group from the add-chat button")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }

    private var chatsTabContent: some View {
        let filtered = filteredConversationsCache
        let totalCount = filtered.count
        let displayed: [Conversation]
        if searchText.isEmpty {
            let count = min(totalCount, max(loadedConversationCount, conversationPageSize))
            displayed = Array(filtered.prefix(count))
        } else {
            displayed = filtered
        }

        return List(selection: $selectedContactIDs) {
            // Restored to its original placement: a row inside the Chats list itself (so it
            // reads as "just another chat"), not a standalone element above the tabs - only
            // shown while not searching, matching every other non-conversation row here.
            if searchText.isEmpty {
                Button {
                    pendingBroadcastChannel = nil
                    selectedContact = nil
                    selectedGroup = nil
                    showBroadcastList = true
                } label: {
                    BroadcastEntryRow()
                }
                .listRowBackground(
                    shouldUseSplitLayout && showBroadcastList
                        ? Color.accentColor.opacity(0.14)
                        : Color.clear
                )
            }

            if !displayed.isEmpty {
                ForEach(Array(displayed.enumerated()), id: \.element.id) { index, conversation in
                    Button {
                        // List(selection:)'s native edit-mode row-selection UI never gets a
                        // chance to see this tap - our own Button label already consumes it - so
                        // toggle selection here explicitly instead of relying on that.
                        if editMode == .active {
                            if selectedContactIDs.contains(conversation.contact.id) {
                                selectedContactIDs.remove(conversation.contact.id)
                            } else {
                                selectedContactIDs.insert(conversation.contact.id)
                            }
                        } else {
                            selectedContactStartInPaymentMode = false
                            pendingBroadcastChannel = nil
                            showBroadcastList = false
                            selectedGroup = nil
                            selectedContact = conversation.contact
                        }
                    } label: {
                        ConversationRow(conversation: conversation)
                    }
                    .buttonStyle(ChatRowPressStyle())
                    .tag(conversation.contact.id)
                    .listRowBackground(
                        shouldUseSplitLayout && selectedContact?.address == conversation.contact.address
                            ? Color.accentColor.opacity(0.14)
                            : Color.clear
                    )
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            if conversation.unreadCount > 0 {
                                Task {
                                    await chatService.markConversationAsRead(conversation)
                                }
                            } else {
                                chatService.markConversationAsUnread(conversation)
                            }
                        } label: {
                            if conversation.unreadCount > 0 {
                                Label("Read", systemImage: "envelope.open")
                            } else {
                                Label("Unread", systemImage: "envelope.badge")
                            }
                        }
                        .tint(.accentColor)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            contactPendingDelete = conversation.contact
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                    .onAppear {
                        maybeLoadMoreConversations(
                            currentIndex: index,
                            displayedCount: displayed.count,
                            totalCount: totalCount
                        )
                    }
                }

                Text("\(totalCount) chat\(totalCount == 1 ? "" : "s")")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay {
            // Rendered as an overlay rather than a List row: as a row, it sat right after the
            // Broadcasts row with no content to expand into the remaining space, which left a
            // stray-looking separator line floating above Broadcasts with a large dead gap below
            // it instead of a normal centered empty state. An overlay isn't subject to List's
            // row/separator layout at all, so it can just center properly over the whole list area.
            if displayed.isEmpty && searchText.isEmpty {
                emptyStateView
            }
        }
    }

    private var selectionActionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                if selectedListTab == .chats {
                    Button {
                        let targets = filteredConversationsCache.filter { selectedContactIDs.contains($0.contact.id) }
                        Task {
                            await chatService.markConversationsAsRead(targets)
                        }
                        editMode = .inactive
                    } label: {
                        Label("Mark as Read", systemImage: "envelope.open")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(selectedContactIDs.isEmpty)

                    Button {
                        let targets = filteredConversationsCache.filter { selectedContactIDs.contains($0.contact.id) }
                        chatService.markConversationsAsUnread(targets)
                        editMode = .inactive
                    } label: {
                        Label("Mark as Unread", systemImage: "envelope.badge")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(selectedContactIDs.isEmpty)
                } else {
                    Button {
                        let targets = groupChatService.groups.filter { selectedGroupIDs.contains($0.id) }
                        groupChatService.markGroupsAsRead(targets)
                        editMode = .inactive
                    } label: {
                        Label("Mark as Read", systemImage: "envelope.open")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(selectedGroupIDs.isEmpty)

                    Button {
                        let targets = groupChatService.groups.filter { selectedGroupIDs.contains($0.id) }
                        groupChatService.markGroupsAsUnread(targets)
                        editMode = .inactive
                    } label: {
                        Label("Mark as Unread", systemImage: "envelope.badge")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(selectedGroupIDs.isEmpty)
                }
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(.bar)
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

    private func scheduleAvatarPrefetch() {
        avatarPrefetchTask?.cancel()
        avatarPrefetchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            await preloadAvatarsForAllChats(forceProfileRefresh: false)
        }
    }

    @MainActor
    private func preloadAvatarsForAllChats(forceProfileRefresh: Bool) async {
        let addresses = Array(Set(chatService.conversations.map { $0.contact.address }))
        guard !addresses.isEmpty else { return }

        let kns = KNSService.shared
        let addressesToFetch: [String]
        if forceProfileRefresh {
            addressesToFetch = addresses
        } else {
            addressesToFetch = addresses.filter { kns.profileCache[$0] == nil }
        }

        if !addressesToFetch.isEmpty {
            await fetchProfilesInBatches(for: addressesToFetch)
        }

        let avatarURLs = addresses.compactMap { address in
            kns.profileCache[address]?.avatarURL
        }
        await KNSProfileImagePrefetcher.preload(rawURLStrings: avatarURLs, maxConcurrent: 6)
    }

    @MainActor
    private func fetchProfilesInBatches(for addresses: [String]) async {
        guard !addresses.isEmpty else { return }
        for address in addresses {
            _ = await KNSService.shared.fetchProfile(for: address)
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

    private func deleteConversation(_ contact: Contact) {
        chatService.removeConversation(for: contact.address)
        contactsManager.deleteContact(contact)
        chatService.checkAndResubscribeIfNeeded()
        showToast("Chat deleted.")
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
                    AppLog.log("[ChatListView] Notification permission denied by user")
                } else {
                    AppLog.log("[ChatListView] Notification permission granted")
                }
            }
        }
    }
}

/// `.navigationDestination(item:)` (iOS 17+) rather than `isPresented:` + a synthetic get/set
/// boolean - see `BroadcastChannelDestination` below for why: popping back via the native swipe
/// gesture toggles the synthetic boolean through a quick true→false transition that can race
/// UIKit's own pop animation, which is what produced the black screen flashing in from the right
/// when swiping back out of a chat quickly. Binding directly to the optional `Contact` item is
/// the race-free API SwiftUI provides for this; iOS 16 falls back to the older pattern since
/// `item:` isn't available there.
private struct ChatDetailNavigationDestination: ViewModifier {
    @Binding var selectedContact: Contact?
    let startInPaymentMode: Bool

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.navigationDestination(item: $selectedContact) { contact in
                ChatDetailView(contact: contact, startInPaymentMode: startInPaymentMode)
            }
        } else {
            content.navigationDestination(isPresented: Binding(
                get: { selectedContact != nil },
                set: { isPresented in
                    if !isPresented {
                        selectedContact = nil
                    }
                }
            )) {
                if let contact = selectedContact {
                    ChatDetailView(contact: contact, startInPaymentMode: startInPaymentMode)
                } else {
                    EmptyView()
                }
            }
        }
    }
}

private struct GroupChatDetailNavigationDestination: ViewModifier {
    @Binding var selectedGroup: GroupChat?

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.navigationDestination(item: $selectedGroup) { group in
                GroupChatDetailView(group: group, onDeleted: { selectedGroup = nil })
            }
        } else {
            content.navigationDestination(isPresented: Binding(
                get: { selectedGroup != nil },
                set: { isPresented in
                    if !isPresented {
                        selectedGroup = nil
                    }
                }
            )) {
                if let group = selectedGroup {
                    GroupChatDetailView(group: group, onDeleted: { selectedGroup = nil })
                } else {
                    EmptyView()
                }
            }
        }
    }
}

private struct BroadcastListNavigationDestination: ViewModifier {
    let mode: BroadcastListPresentationMode
    @Binding var showBroadcastList: Bool
    @Binding var pendingBroadcastChannel: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        switch mode {
        case .splitDetail:
            content
        case .navigationDestination:
            content.navigationDestination(isPresented: Binding(
                get: { showBroadcastList },
                set: { isPresented in
                    showBroadcastList = isPresented
                    if !isPresented {
                        pendingBroadcastChannel = nil
                    }
                }
            )) {
                BroadcastListView(initialChannel: pendingBroadcastChannel)
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
        .task(id: conversation.contact.address) {
            let address = conversation.contact.address
            if knsService.profileCache[address] == nil {
                _ = await knsService.fetchProfile(for: address)
            }
        }
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
        // `content.utf8.count` (not `.count`, which does a full Unicode grapheme-cluster scan)
        // - a chat's last message can be a multi-MB base64 photo/audio payload, and this cache
        // key has to be computed before the cache can even be checked. With `.count` (and the
        // `.hashValue` this used to also include, an equally expensive full-string hash), every
        // row in the chat list paid two full scans of its entire last-message content on every
        // single render - including the render triggered by returning from a chat, which made
        // that transition visibly freeze for chats with large last messages.
        let key = "\(content.utf8.count)|\(content.prefix(24))" as NSString
        if let cached = Self.previewCache.object(forKey: key) {
            return cached as String
        }

        let result: String
        // Unwrap a reply envelope first, so a reply's own text (or its attachment, below) is
        // what's previewed rather than the raw `{"type":"reply",...}` JSON.
        let unwrapped = MessageReplyCodec.unwrappedText(content)

        // Check if content is a file JSON payload
        let trimmed = unwrapped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else {
            result = unwrapped
            Self.previewCache.setObject(result as NSString, forKey: key)
            return result
        }

        if ChessCodec.parseAny(unwrapped) != nil {
            result = "♟️ Chess game"
            Self.previewCache.setObject(result as NSString, forKey: key)
            return result
        }

        guard let data = unwrapped.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "file",
              let mimeType = json["mimeType"] as? String else {
            result = unwrapped
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

struct BroadcastEntryRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.accentColor.opacity(0.2))
                .frame(width: 50, height: 50)
                .overlay(
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 20))
                        .foregroundColor(.accentColor)
                )

            Text("Broadcasts")
                .font(.headline)

            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct GroupChatRow: View {
    let group: GroupChat
    @EnvironmentObject var groupChatService: GroupChatService
    @EnvironmentObject var contactsManager: ContactsManager
    @ObservedObject private var knsService = KNSService.shared

    private var lastMessage: GroupMessage? {
        groupChatService.groupMessages[group.id]?.max { $0.timestamp < $1.timestamp }
    }

    /// Same resolution as `GroupChatDetailView.displayName(for:)`.
    private func resolveDisplayName(for address: String) -> String {
        if let contact = contactsManager.getContact(byAddress: address), !contact.alias.isEmpty {
            return contact.alias
        }
        if let knsName = knsService.profileCache[address]?.domainName, !knsName.isEmpty {
            return knsName
        }
        return Contact.generateDefaultAlias(from: address)
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.accentColor.opacity(0.2))
                .frame(width: 50, height: 50)
                .overlay(
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.accentColor)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(group.name)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer()

                    if let lastMessage {
                        Text(formatDate(lastMessage.timestamp))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    if let lastMessage {
                        Text(GroupMentionCodec.decodeForDisplay(MessageReplyCodec.previewText(for: lastMessage.content), members: group.members, resolveDisplayName: resolveDisplayName(for:)))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("\(group.members.count) member\(group.members.count == 1 ? "" : "s")")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .italic()
                    }

                    Spacer()

                    let unreadCount = groupChatService.unreadCount(for: group)
                    if unreadCount > 0 {
                        Text("\(unreadCount)")
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
        .contentShape(Rectangle())
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
        .environmentObject(BroadcastService.shared)
}
