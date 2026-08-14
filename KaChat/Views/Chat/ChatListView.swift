import SwiftUI
import UserNotifications
import UIKit

struct ChatListView: View {
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
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
    @State private var selectedListTab: ChatsListTab = .chats
    /// The page Select mode started on - page swipes snap back to it while editing.
    @State private var editModeLockedTab: ChatsListTab?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success
    @State private var loadedConversationCount = 80
    @State private var isPaginatingConversations = false
    @State private var filteredConversationsCache: [Conversation] = []
    @State private var searchFilterTask: Task<Void, Never>?
    /// True for the duration of a pull-to-refresh. While set, conversation/contact changes DON'T
    /// rebuild the visible list — reloading the underlying List mid-spin resets the native refresh
    /// control's animation, which is what made the wheel blink/stutter. The coalesced changes are
    /// applied in one pass when the pull finishes (the spinner is dismissing then anyway).
    @State private var isPullRefreshing = false
    @State private var avatarPrefetchTask: Task<Void, Never>?
    @State private var splitColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var showBulkDeleteConfirmation = false
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
        // Split into staged intermediate variables (rather than one long chained-modifier
        // expression) so the type checker isn't solving toolbar + searchable/refreshable/toast/
        // sheet + three `.alert`s + two custom modifiers + `.environment` all as a single
        // expression - that combination is what triggered "unable to type-check in reasonable
        // time" once the third `.alert` (bulk delete) was added.
        let withToolbar = chatListContent
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.large)
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

        let withPresentation = withToolbar
            // placement .always is load-bearing: the chats/groups lists live inside a paging
            // TabView (chatListContent), so their scrolling no longer drives the navigation
            // bar — with the default .automatic placement under a .large title, the search
            // drawer waits for a nav-bar-linked scroll to reveal it and therefore NEVER
            // appears. Pinning it keeps: bold "Chats" large title, search bar underneath.
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search chats"
            )
            .refreshable {
                isPullRefreshing = true
                await chatService.fetchNewMessages()
                isPullRefreshing = false
                // Apply everything that changed during the pull in a single rebuild, now that the
                // refresh control is no longer animating — so the wheel spins smoothly throughout.
                refreshFilteredConversations()
                scheduleAvatarPrefetch()
            }
            .toast(message: toastMessage, style: toastStyle)
            .sheet(isPresented: $showAddContact) {
                AddContactView { contact in
                    _ = chatService.getOrCreateConversation(for: contact)
                    selectedContactStartInPaymentMode = false
                    selectedGroup = nil
                    selectedContact = contact
                    selectedListTab = .chats
                    showAddContact = false
                } onCreateGroup: { group in
                    selectedContactStartInPaymentMode = false
                    selectedContact = nil
                    selectedGroup = group
                    selectedListTab = .groups
                    showAddContact = false
                }
                .presentationDetents([.large])
            }

        let withAlerts = withPresentation
            .alert(
                bulkDeleteAlertTitle,
                isPresented: $showBulkDeleteConfirmation
            ) {
                Button("Delete", role: .destructive) {
                    if selectedListTab == .chats {
                        let targets = filteredConversationsCache
                            .filter { selectedContactIDs.contains($0.contact.id) }
                            .map { $0.contact }
                        deleteConversations(targets)
                    } else {
                        let targets = groupChatService.groups.filter { selectedGroupIDs.contains($0.id) }
                        deleteGroups(targets)
                    }
                    editMode = .inactive
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(bulkDeleteAlertMessage)
            }

        return withAlerts
            .environment(\EnvironmentValues.editMode, $editMode)
    }

    @ViewBuilder
    private var splitDetailPane: some View {
        if let group = selectedGroup {
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
                // The whole tab-bar strip is swipeable left/right - no row gestures up here to
                // fight with.
                .contentShape(Rectangle())
                .gesture(listTabSwipe())
            // A REAL page-style TabView (same as the KaPosts feeds): interactive, finger-
            // tracked paging in both directions - far smoother than the transition-based slide
            // this replaced. Safe now that rows have no swipe actions to fight with (delete/
            // read live in Select mode). Edit mode pins the page via editModeLockedTab.
            TabView(selection: $selectedListTab) {
                chatsTabContent
                    .tag(ChatsListTab.chats)
                groupsTabContent
                    .tag(ChatsListTab.groups)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
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
                editModeLockedTab = nil
            } else if newValue == .active {
                editModeLockedTab = selectedListTab
            }
        }
        .onChange(of: selectedListTab) { newValue in
            // Selection mode is scoped to the list it started on (see chatsTabButton) - a page
            // swipe mid-select snaps back to the locked page.
            if let locked = editModeLockedTab, newValue != locked {
                selectedListTab = locked
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChat)) { notification in
            handleOpenChatNotification(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openGroup)) { notification in
            handleOpenGroupNotification(notification)
        }
        .onAppear {
            checkPendingNavigation()
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
            // Suppressed during a pull-to-refresh; the pull's completion handler rebuilds once.
            guard !isPullRefreshing else { return }
            scheduleFilteredConversationsRefresh(debounce: false)
            scheduleAvatarPrefetch()
        }
        .onChange(of: contactsManager.contacts) { _ in
            guard !isPullRefreshing else { return }
            scheduleFilteredConversationsRefresh(debounce: false)
        }
        .onDisappear {
            searchFilterTask?.cancel()
            avatarPrefetchTask?.cancel()
        }
        .task {
            await contactsManager.fetchKNSDomainsForAllContacts()
            await preloadAvatarsForAllChats(forceProfileRefresh: false)
            await chatService.refreshLatestReactionPreviews()
        }
        .onChange(of: chatService.pendingChatNavigation) { newValue in
            if newValue != nil {
                checkPendingNavigation()
            }
        }
        .onChange(of: groupChatService.pendingGroupNavigation) { newValue in
            if newValue != nil {
                checkPendingGroupNavigation()
            }
        }
        .onChange(of: groupChatService.groups) { _ in
            // A pending group tap that arrived before its group was created (catch-up in flight)
            // resolves the instant the group is inserted into the list.
            checkPendingGroupNavigation()
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

    private func handleOpenGroupNotification(_ notification: Notification) {
        guard let groupId = notification.userInfo?["groupId"] as? String else { return }
        navigateToGroup(groupId: groupId)
    }

    private func checkPendingGroupNavigation() {
        guard let groupId = groupChatService.pendingGroupNavigation else { return }
        // Don't consume the pending navigation until the group actually exists locally: a tap that
        // arrives before catch-up has created the group (e.g. "you were added to a group") would
        // otherwise be dropped silently. The .onChange(of: groupChatService.groups) below re-runs
        // this the moment the group is inserted, so the tap resolves as soon as it lands.
        guard groupChatService.groups.contains(where: { $0.id == groupId }) else { return }
        groupChatService.pendingGroupNavigation = nil
        navigateToGroup(groupId: groupId)
    }

    private func navigateToGroup(groupId: String) {
        guard let target = groupChatService.groups.first(where: { $0.id == groupId }) else { return }
        selectedListTab = .groups
        selectedContact = nil
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
            selectedContact = target
            return
        }

        // When a chat is already open, ChatDetailView handles the switch
        // in-place via its own .onReceive(.openChat) handler.
        if selectedContact == nil {
            selectedContactStartInPaymentMode = startInPaymentMode
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
    /// visual language as the app's other underline tab bars. Tap-only (see `chatListContent`).
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

    /// Horizontal swipe that switches the Chats/Groups tab - attached to the tab bar and the
    /// full list surface alike.
    private func listTabSwipe() -> some Gesture {
        DragGesture(minimumDistance: 25, coordinateSpace: .global)
            .onEnded { value in
                guard editMode != .active else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                // Decisively horizontal only, so vertical list scrolling never trips it.
                guard abs(dx) > 50, abs(dx) > abs(dy) * 1.5 else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    if dx < 0, selectedListTab == .chats {
                        selectedListTab = .groups
                    } else if dx > 0, selectedListTab == .groups {
                        selectedListTab = .chats
                    }
                }
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
            // Rendered as an overlay rather than a List row so it can center properly over the
            // whole list area instead of being subject to List's row/separator layout.
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
                        Image(systemName: "envelope.open")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(selectedContactIDs.isEmpty)

                    Button {
                        let targets = filteredConversationsCache.filter { selectedContactIDs.contains($0.contact.id) }
                        chatService.markConversationsAsUnread(targets)
                        editMode = .inactive
                    } label: {
                        Image(systemName: "envelope.badge")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(selectedContactIDs.isEmpty)

                    Button(role: .destructive) {
                        showBulkDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(selectedContactIDs.isEmpty)
                } else {
                    Button {
                        let targets = groupChatService.groups.filter { selectedGroupIDs.contains($0.id) }
                        groupChatService.markGroupsAsRead(targets)
                        editMode = .inactive
                    } label: {
                        Image(systemName: "envelope.open")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(selectedGroupIDs.isEmpty)

                    Button {
                        let targets = groupChatService.groups.filter { selectedGroupIDs.contains($0.id) }
                        groupChatService.markGroupsAsUnread(targets)
                        editMode = .inactive
                    } label: {
                        Image(systemName: "envelope.badge")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(selectedGroupIDs.isEmpty)

                    Button(role: .destructive) {
                        showBulkDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(selectedGroupIDs.isEmpty)
                }
            }
            .font(.system(size: 18))
            .buttonStyle(.bordered)
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private var balanceToolbarView: some View {
        let sompi = walletManager.currentWallet?.balanceSompi
        let exact = sompi.map(formatKaspaExact) ?? "--"
        // Kaspa logo + bold, matching KaPosts' balance header style.
        return HStack(spacing: 6) {
            Image("KaspaLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 15, height: 15)
            Text("\(exact) KAS")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
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
        // Concurrent batch refresh (KNSService's own bounded-concurrency path) instead of awaiting
        // each contact serially - the serial loop meant N sequential network round-trips, each one
        // triggering a KNSService @Published write that re-rendered every visible chat row.
        await KNSService.shared.refreshProfilesIfNeeded(for: addresses, network: AppSettings.load().networkType)
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

    /// Pulled out of the `.alert(...)` call site as a plain computed property - an inline ternary
    /// nested inside string interpolation there was making the compiler unable to type-check the
    /// `.alert` expression in reasonable time.
    private var bulkDeleteAlertTitle: String {
        if selectedListTab == .chats {
            return "Delete \(selectedContactIDs.count) Chat\(selectedContactIDs.count == 1 ? "" : "s")?"
        } else {
            return "Delete \(selectedGroupIDs.count) Group\(selectedGroupIDs.count == 1 ? "" : "s")?"
        }
    }

    private var bulkDeleteAlertMessage: String {
        selectedListTab == .chats
            ? "This permanently deletes every message in each selected chat, including from iCloud, so they're removed from your other devices too. This cannot be undone."
            : "This removes each selected group and its messages from this device. This cannot be undone, and other members won't be notified."
    }

    /// Bulk multi-select delete (Select mode is the only delete path now that row swipes are
    /// gone) - per-contact cleanup with one resubscribe and toast at the end.
    private func deleteConversations(_ contacts: [Contact]) {
        guard !contacts.isEmpty else { return }
        for contact in contacts {
            chatService.removeConversation(for: contact.address)
            contactsManager.deleteContact(contact)
        }
        chatService.checkAndResubscribeIfNeeded()
        selectedContactIDs = []
        showToast(contacts.count == 1 ? "Chat deleted." : "\(contacts.count) chats deleted.")
    }

    /// Bulk multi-select delete for groups - mirrors `deleteConversations`.
    private func deleteGroups(_ groups: [GroupChat]) {
        guard !groups.isEmpty else { return }
        for group in groups {
            if selectedGroup?.id == group.id { selectedGroup = nil }
            groupChatService.deleteGroup(group.id)
        }
        selectedGroupIDs = []
        showToast(groups.count == 1 ? "Group deleted." : "\(groups.count) groups deleted.")
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

struct ConversationRow: View {
    @ObservedObject private var contactAvatars = SystemContactAvatarStore.shared
    let conversation: Conversation
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var walletManager: WalletManager
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
                size: 50,
                overrideImage: contactAvatars.displayImage(for: conversation.contact)
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

                        Text(reactionPreviewText ?? formatPreview(lastMessage.content))
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

    /// A reaction more recent than `lastMessage` gets shown instead of the message preview -
    /// reactions never become messages (they're applied as a corner pill), so without this the
    /// chat list would just silently show whatever the last real message was, even if the truly
    /// most recent activity was someone reacting to something older. `nil` when there's no
    /// reaction newer than the last message.
    private var reactionPreviewText: String? {
        guard let preview = chatService.latestReactionByContact[conversation.contact.address] else { return nil }
        let reactionDate = Date(timeIntervalSince1970: TimeInterval(preview.blockTime) / 1000.0)
        if let lastMessage = conversation.lastMessage, lastMessage.timestamp >= reactionDate {
            return nil
        }
        let myAddress = walletManager.currentWallet?.publicAddress
        let reactedByMe = preview.reactorAddress == myAddress
        let targetIsMine = preview.targetMessageIsOutgoing ?? false
        switch (reactedByMe, targetIsMine) {
        case (true, true): return "You reacted to your message"
        case (true, false): return "You reacted to their message"
        case (false, true): return "Reacted to your message"
        case (false, false): return "Reacted to their message"
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

#Preview {
    ChatListView()
        .environmentObject(ChatService.shared)
        .environmentObject(ContactsManager.shared)
        .environmentObject(WalletManager.shared)
}