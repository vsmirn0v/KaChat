import SwiftUI
import UserNotifications
import UIKit

struct ChatListView: View {
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var groupChatService: GroupChatService
    /// Not observed here: every room message, read marker, reaction and poll would re-render the
    /// whole chat list. The circles row above the list (`ChatCirclesStrip`) observes it on its own.
    private var publicChats: PublicChatService { PublicChatService.shared }
    @State private var showPublicChatsSettings = false
    /// The public room open on top of this list (opened from its circle, a notification or a link).
    @State private var selectedPublicRoom: String?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var searchText = ""
    @State private var selectedContact: Contact?
    @State private var showMessageRequests = false
    @State private var selectedGroup: GroupChat?
    @State private var selectedContactStartInPaymentMode = false
    /// The bottom-right + : one sheet for every page (new chat, group, public room, the two QR
    /// screens). Everything happens inside that one sheet - choosing an option changes what it
    /// shows rather than closing it and opening another, so there's no dismiss-then-present wait.
    @State private var showCreateSheet = false
    /// Non-nil while the sheet shows the create screen: false = new chat, true = new group.
    @State private var createAddContactGroupMode: Bool?
    @State private var createPath: [CreateRoute] = []
    @State private var createDetent: PresentationDetent = Self.createSheetHeight
    @State private var createRoomName = ""
    @State private var createRoomError: String?
    @FocusState private var createRoomFieldFocused: Bool
    private enum CreateRoute: Hashable {
        case joinRoom
    }
    /// The QR options leave the New sheet: it goes down and the full white QR page comes up in
    /// its own sheet, like Profile's.
    @State private var afterCreateSheet: (() -> Void)?
    @State private var qrScreen: ChatsQRScreen?
    /// "Send Kaspa" in the New sheet: Profile's send from the current spending address.
    @State private var showSpendingSend = false
    private enum ChatsQRScreen: String, Identifiable {
        case fundChatting, receive
        var id: String { rawValue }
    }
    /// From a profile link: the person whose User Info is up.
    @State private var linkedProfileContact: Contact?
    /// Group chats and public rooms pinned to the front of the circles row, in order - ids
    /// "g:<groupId>" / "r:<room>", saved per wallet.
    @State private var circlePins: [String] = []
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
    /// Row-level delete targets from the long-press context menu - separate from the Select-mode
    /// bulk selection state so a context-menu delete never touches (or is blocked by) edit mode.
    /// Confirmed via their own alerts below, which reuse `deleteConversations`/`deleteGroups`.
    @State private var rowDeleteContact: Contact?
    /// The row whose long-press action sheet is up.
    @State private var conversationActionTarget: Conversation?
    @State private var editMode: EditMode = .inactive
    @State private var selectedContactIDs: Set<UUID> = []
    @State private var selectedGroupIDs: Set<String> = []
    /// Public rooms picked in Select mode (by channel name).
    @State private var selectedPublicRooms: Set<String> = []

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
                        .modifier(PublicChatChannelDestination(selectedChannel: $selectedPublicRoom))
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
                        // One selection across the chats and the circles above them.
                        Button(isEverythingSelected ? "Deselect All" : "Select All") {
                            if isEverythingSelected {
                                selectedContactIDs = []
                                selectedGroupIDs = []
                                selectedPublicRooms = []
                            } else {
                                selectedContactIDs = Set(filteredConversationsCache.map { $0.contact.id })
                                selectedGroupIDs = Set(displayedGroups.map { $0.id })
                                selectedPublicRooms = Set(displayedRooms.map(\.channelName))
                            }
                        }
                    }
                }
                // Public room settings (which default rooms show), next to Select.
                ToolbarItem(placement: .navigationBarTrailing) {
                    if editMode != .active {
                        Button {
                            showPublicChatsSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Public Chats settings")
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
                // One list now: chats and the group circles above them both refresh.
                async let chats: Void = chatService.fetchNewMessages()
                async let groups: Void = groupChatService.performCatchUpSync()
                _ = await (chats, groups)
                PublicChatService.shared.refreshChannels()
                isPullRefreshing = false
                // Apply everything that changed during the pull in a single rebuild, now that the
                // refresh control is no longer animating — so the wheel spins smoothly throughout.
                refreshFilteredConversations()
                scheduleAvatarPrefetch()
            }
            .toast(message: toastMessage, style: toastStyle)

        let withAlerts = withPresentation
            .sheet(item: $conversationActionTarget) { conversation in
            conversationRowSheet(for: conversation)
        }
        .alert(
                bulkDeleteAlertTitle,
                isPresented: $showBulkDeleteConfirmation
            ) {
                Button("Delete", role: .destructive) {
                    let contacts = filteredConversationsCache
                        .filter { selectedContactIDs.contains($0.contact.id) }
                        .map { $0.contact }
                    if !contacts.isEmpty { deleteConversations(contacts) }
                    let groups = groupChatService.groups.filter { selectedGroupIDs.contains($0.id) }
                    if !groups.isEmpty { deleteGroups(groups) }
                    for room in selectedPublicRooms {
                        PublicChatService.shared.removeFromList(room)
                    }
                    editMode = .inactive
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(bulkDeleteAlertMessage)
            }

        // Row context-menu deletes confirm through their own alerts (same destructive-confirm
        // pattern and wording as the bulk alert above, singular) - staged as separate variables
        // for the same type-checker reason as the rest of this chain.
        let withRowDeleteAlert = withAlerts
            .alert(
                "Delete Chat?",
                isPresented: Binding(
                    get: { rowDeleteContact != nil },
                    set: { if !$0 { rowDeleteContact = nil } }
                ),
                presenting: rowDeleteContact
            ) { contact in
                Button("Delete", role: .destructive) {
                    deleteConversations([contact])
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This permanently deletes every message in this chat from this device. This cannot be undone.")
            }

        return withRowDeleteAlert
            .environment(\EnvironmentValues.editMode, $editMode)
    }

    @ViewBuilder
    private var splitDetailPane: some View {
        if let group = selectedGroup {
            GroupChatDetailView(group: group, onDeleted: { selectedGroup = nil })
                .id(group.id)
        } else if let room = selectedPublicRoom {
            PublicChatChannelView(channelName: room)
                .id(room)
        } else if let contact = selectedContact {
            ChatDetailView(contact: contact, startInPaymentMode: selectedContactStartInPaymentMode)
                .id(contact.id)
        } else {
            splitEmptyDetailView
        }
    }

    @ViewBuilder
    private var chatListContent: some View {
        // One list: the chats, with the group chats and public rooms as circles above them
        // (`ChatCirclesStrip`). The three-tab paging layout is gone.
        chatsTabContent
        .onReceive(NotificationCenter.default.publisher(for: .openPublicChat)) { notification in
            guard let channel = notification.userInfo?["channel"] as? String else { return }
            openRoomFromHandoff(channel)
        }
        .onReceive(PublicChatService.shared.$pendingPublicChatNavigation) { pending in
            guard let pending else { return }
            PublicChatService.shared.pendingPublicChatNavigation = nil
            openRoomFromHandoff(pending)
        }
        .onAppear {
            // The curated rooms always have store rows, so their circles and bell state exist.
            PublicChatService.shared.ensureFeaturedChannelsJoined()
            PublicChatService.shared.refreshChannels()
            // Cold start from a profile link.
            if chatService.pendingProfileAddress != nil { openPendingProfile() }
        }
        .onChange(of: walletManager.currentWallet?.publicAddress) { _ in loadCirclePins() }
        .onAppear { loadCirclePins() }
        .safeAreaInset(edge: .bottom) {
            if editMode == .active {
                selectionActionBar
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // One + on every page; the rooms page no longer draws its own when embedded here.
            if editMode != .active {
                newButton
            }
        }
        .sheet(isPresented: $showPublicChatsSettings) {
            PublicChatsSettingsView()
                .environmentObject(publicChats)
        }
        .sheet(isPresented: $showCreateSheet, onDismiss: {
            resetCreateSheet()
            let next = afterCreateSheet
            afterCreateSheet = nil
            next?()
        }) {
            createSheet
                .environmentObject(walletManager)
        }
        .sheet(isPresented: $showSpendingSend) {
            SpendingSendLauncher()
                .environmentObject(chatService)
                .environmentObject(contactsManager)
                .environmentObject(settingsViewModel)
                .environmentObject(walletManager)
        }
        .sheet(item: $qrScreen) { screen in
            NavigationStack {
                Group {
                    switch screen {
                    case .fundChatting:
                        if let wallet = walletManager.currentWallet {
                            ChattingAddressQRView(address: wallet.publicAddress, balanceSompi: wallet.balanceSompi)
                        }
                    case .receive:
                        ProfileView.ReceiveKaspaQRView()
                    }
                }
                .navigationTitle(screen == .fundChatting ? "Chatting Address" : "Receive Kaspa")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { qrScreen = nil }
                    }
                }
            }
            .environmentObject(walletManager)
        }
        .onChange(of: editMode) { newValue in
            if newValue == .inactive {
                selectedContactIDs = []
                selectedGroupIDs = []
                selectedPublicRooms = []
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
            checkPendingGroupListNavigation()
            requestNotificationPermissionIfNeeded()
            loadedConversationCount = conversationPageSize
            // Back from a chat: its fully loaded history can go now.
            chatService.trimLeftConversationIfNeeded()
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
            // A pending chat tap whose contact didn't exist yet resolves the moment the
            // conversation (or the contact, below) is created by the catch-up sync.
            checkPendingNavigation()
            // Suppressed during a pull-to-refresh; the pull's completion handler rebuilds once.
            guard !isPullRefreshing else { return }
            scheduleFilteredConversationsRefresh(debounce: false)
            scheduleAvatarPrefetch()
        }
        .onChange(of: contactsManager.contacts) { _ in
            checkPendingNavigation()
            guard !isPullRefreshing else { return }
            scheduleFilteredConversationsRefresh(debounce: false)
        }
        // Accept / Reject / Private move chats between the list and Message Requests.
        .onChange(of: chatService.chatRequestsRevision) { _ in
            scheduleFilteredConversationsRefresh(debounce: false)
        }
        .sheet(isPresented: $showMessageRequests) {
            MessageRequestsView()
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
        .onChange(of: chatService.pendingProfileAddress) { newValue in
            if newValue != nil { openPendingProfile() }
        }
        .sheet(isPresented: Binding(
            get: { linkedProfileContact != nil },
            set: { if !$0 { linkedProfileContact = nil } }
        )) {
            if let contact = linkedProfileContact {
                NavigationStack {
                    ChatInfoView(
                        contact: Binding(
                            get: { linkedProfileContact ?? contact },
                            set: { linkedProfileContact = $0 }
                        )
                    )
                }
            }
        }
        .onChange(of: groupChatService.pendingGroupNavigation) { newValue in
            if newValue != nil {
                checkPendingGroupNavigation()
            }
        }
        .onChange(of: groupChatService.pendingGroupListNavigation) { newValue in
            if newValue { checkPendingGroupListNavigation() }
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

    /// A profile link: that person's User Info. Someone new gets the same auto-added contact a
    /// tapped public chat sender does, so the name and settings saved there stick. Your own link
    /// shows your own User Info from a throwaway value - you are never added as your own contact.
    private func openPendingProfile() {
        guard let address = chatService.pendingProfileAddress else { return }
        chatService.pendingProfileAddress = nil
        let contact = walletManager.currentWallet?.publicAddress.lowercased() == address.lowercased()
            ? Contact(address: address)
            : (contactsManager.getContact(byAddress: address) ?? contactsManager.getOrCreateContact(address: address))
        // A profile sheet already up (or one SwiftUI declined to present) would leave the binding
        // stuck true, and no later link could open. Close it first, then present the new one.
        if linkedProfileContact != nil {
            linkedProfileContact = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { linkedProfileContact = contact }
        } else {
            linkedProfileContact = contact
        }
    }

    private func checkPendingNavigation() {
        guard let contactAddress = chatService.pendingChatNavigation else { return }
        // Same rule as checkPendingGroupNavigation: don't consume the tap until its contact
        // actually exists locally. A notification from someone not in the address book yet (a
        // handshake, or a first message/payment whose contact the catch-up sync creates moments
        // later) is tapped on a cold start BEFORE that sync lands - consuming it here would
        // clear the target and navigate nowhere. The contacts/conversations onChange handlers
        // below re-run this the instant the contact appears.
        guard contactsManager.contacts.contains(where: { $0.address == contactAddress }) ||
                chatService.conversations.contains(where: { $0.contact.address == contactAddress }) else { return }
        chatService.pendingChatNavigation = nil
        if let open = selectedContact, open.address != contactAddress {
            // A chat is already open on top of this list, so the swap belongs to ChatDetailView's
            // own in-place handler (navigateToChat deliberately no-ops in that case). It only
            // listens for the notification, and the one this tap posted arrived before the
            // contact existed - re-post it now that it resolves.
            NotificationCenter.default.post(
                name: .openChat,
                object: nil,
                userInfo: ["contactAddress": contactAddress]
            )
            return
        }
        navigateToChat(address: contactAddress)
    }

    private func handleOpenGroupNotification(_ notification: Notification) {
        guard let groupId = notification.userInfo?["groupId"] as? String, !groupId.isEmpty else {
            // Group notification with no group to open (the undecryptable-push fallback, thread
            // id "group") - show the Groups list, which is as specific as that tap can get.
            // Group notification with nothing to open: the circles row on the chat list is as
            // specific as that tap can get.
            groupChatService.pendingGroupListNavigation = false
            return
        }
        navigateToGroup(groupId: groupId)
    }

    private func checkPendingGroupListNavigation() {
        guard groupChatService.pendingGroupListNavigation else { return }
        groupChatService.pendingGroupListNavigation = false
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
        selectedContact = nil
        selectedPublicRoom = nil
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

    /// The floating glass "+" in the bottom-right corner on every page, opening the New sheet.
    private var newButton: some View {
        Button {
            Haptics.impact(.light)
            showCreateSheet = true
        } label: {
            Image(systemName: "plus")
                .font(.scaled(size: 22, weight: .semibold))
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
        .accessibilityLabel(Text("New"))
    }

    /// What the + offers, wherever you are in Chats - all inside this one sheet. New Chat / New
    /// Group swap the sheet to the create screen (Cancel comes back here); the room name and the
    /// two QR screens push inside it. It grows to full height for anything bigger than the menu.
    @ViewBuilder
    private var createSheet: some View {
        Group {
            if let groupMode = createAddContactGroupMode {
                AddContactView(
                    startInGroupMode: groupMode,
                    onAdd: { contact in
                        _ = chatService.getOrCreateConversation(for: contact)
                        selectedContactStartInPaymentMode = false
                        selectedGroup = nil
                        selectedContact = contact
                        showCreateSheet = false
                    },
                    onCreateGroup: { group in
                        selectedContactStartInPaymentMode = false
                        selectedContact = nil
                        selectedGroup = group
                        showCreateSheet = false
                    },
                    onCancel: {
                        createAddContactGroupMode = nil
                        createDetent = Self.createSheetHeight
                    }
                )
            } else {
                NavigationStack(path: $createPath) {
                    createMenu
                        .toolbar(.hidden, for: .navigationBar)
                        .navigationDestination(for: CreateRoute.self) { route in
                            createDestination(route)
                        }
                }

            }
        }
        .presentationDetents([Self.createSheetHeight, .large], selection: $createDetent)
        .presentationDragIndicator(.visible)
    }

    /// The New options as square tiles, three to a row.
    private var createMenu: some View {
        let columns = Array(repeating: GridItem(.fixed(Self.createTileSize), spacing: 14), count: 3)
        return VStack(spacing: 16) {
            Text("New")
                .font(.headline)
                .padding(.top, 20)

            LazyVGrid(columns: columns, spacing: 14) {
                CreateTile(title: "New Chat", hint: "Message someone by their address or name.", systemImage: "bubble.left") {
                    createDetent = .large
                    createAddContactGroupMode = false
                }
                CreateTile(title: "New Group Chat", hint: "Start an encrypted group with several people.", systemImage: "person.3") {
                    createDetent = .large
                    createAddContactGroupMode = true
                }
                CreateTile(title: "New Public Chat", hint: "Join a public room, or create one.", systemImage: "number") {
                    createRoomName = ""
                    createRoomError = nil
                    pushCreate(.joinRoom)
                }
                CreateTile(title: "Send Kaspa", hint: "Send Kaspa from your spending address.", systemImage: "arrow.up.circle") {
                    closeCreateSheet { showSpendingSend = true }
                }
                CreateTile(title: "Receive Kaspa", hint: "Show a fresh address to get paid.", systemImage: "arrow.down.circle") {
                    closeCreateSheet { qrScreen = .receive }
                }
                CreateTile(title: "Fund Chatting Address", hint: "Show the QR code to add Kaspa for sending messages.", systemImage: "qrcode") {
                    closeCreateSheet { qrScreen = .fundChatting }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    static let createTileSize: CGFloat = 104

    @ViewBuilder
    private func createDestination(_ route: CreateRoute) -> some View {
        switch route {
        case .joinRoom:
            createJoinRoom
                .navigationTitle("New Public Chat")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Join or create a public room, right in the New sheet. Joining opens the room.
    private var createJoinRoom: some View {
        VStack(spacing: 12) {
            Text("Anyone who joins the same channel name can see and post messages there - there is no owner and no invite.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
                .padding(.bottom, 4)

            HStack(spacing: 4) {
                Text("#")
                    .font(.headline)
                    .foregroundColor(.secondary)
                TextField("channel-name", text: $createRoomName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.join)
                    .focused($createRoomFieldFocused)
                    .onSubmit { joinRoomFromCreateSheet() }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial)
            )

            if let createRoomError {
                Text(createRoomError)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            Button(action: joinRoomFromCreateSheet) {
                Text("Join")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundColor(.black)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.accentColor.opacity(createRoomNameIsEmpty ? 0.4 : 1))
                    )
            }
            .buttonStyle(.plain)
            .disabled(createRoomNameIsEmpty)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // A turn later: the field doesn't exist yet on the push that showed it.
        .onAppear { DispatchQueue.main.async { createRoomFieldFocused = true } }
    }

    private var createRoomNameIsEmpty: Bool {
        createRoomName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The same rules as the rooms page's own join sheet; errors show in place, and a joined room
    /// opens on the Public Chats page.
    private func joinRoomFromCreateSheet() {
        guard !createRoomNameIsEmpty else { return }
        let normalized = PublicChatChannelName.normalize(createRoomName)
        guard PublicChatChannelName.isValid(normalized) else {
            createRoomError = "Channel names must be 1-\(PublicChatChannelName.maxLength) characters with no spaces or colons."
            return
        }
        guard publicChats.joinChannel(normalized) else {
            createRoomError = "Something went wrong joining that channel."
            return
        }
        Haptics.success()
        showCreateSheet = false
        openRoom(normalized)
    }

    /// The menu and the room name share this one height, so moving between them is a plain push.
    /// The create forms open at full height; the QR options leave for their own white sheet.
    static let createSheetHeight: PresentationDetent = .height(380)

    private func pushCreate(_ route: CreateRoute) {
        createPath.append(route)
    }

    /// Closes the New sheet and runs `action` once it's gone (a sheet can't present while
    /// another is still going down).
    private func closeCreateSheet(then action: @escaping () -> Void) {
        afterCreateSheet = action
        showCreateSheet = false
    }

    private func resetCreateSheet() {
        createAddContactGroupMode = nil
        createPath = []
        createDetent = Self.createSheetHeight
        createRoomName = ""
        createRoomError = nil
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.scaled(size: 60))
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
                .font(.scaled(size: 44))
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

    /// Most recent activity first, matching chatsTabContent's identical sort for 1:1
    /// (refreshFilteredConversations) - falls back to createdAt for a group with no messages
    /// yet, so a brand-new empty group still sorts by when it was added/joined - then filtered
    /// by search, matching refreshFilteredConversations' match fields (alias/address/message
    /// content): group name, each member's alias-or-address, and message content. Shared by
    /// the toolbar's Select All and the delete/read actions so they agree on what's "visible."
    private var displayedGroups: [GroupChat] {
        // Decorate-sort-undecorate, like refreshFilteredConversations: the key is computed once
        // per group rather than once per comparison (the old comparator mapped+maxed the whole
        // message array for both operands on every compare). Group message arrays are kept in
        // chronological order, so the last message carries the newest timestamp.
        let groupMessages = groupChatService.groupMessages
        let sorted = groupChatService.groups
            .map { (key: groupMessages[$0.id]?.last?.timestamp ?? $0.createdAt, value: $0) }
            .sorted { $0.key > $1.key }
            .map(\.value)
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
                // Skip media envelopes: a photo/voice message's content is a multi-KB base64
                // blob, and substring-scanning those froze the search field on media-heavy
                // histories (nobody is searching for base64 fragments).
                message.content.utf8.count <= 4096 &&
                    message.content.range(of: query, options: .caseInsensitive) != nil
            }
        }
    }

    /// The public rooms the circles show, filtered by the search like `displayedGroups`. Read
    /// without observing (see `publicChats`) - for Select All and the action bar.
    private var displayedRooms: [PublicChatChannel] {
        let rooms = PublicChatService.shared.listedChannels
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rooms }
        return rooms.filter { $0.channelName.range(of: query, options: .caseInsensitive) != nil }
    }

    private var isEverythingSelected: Bool {
        let total = filteredConversationsCache.count + displayedGroups.count + displayedRooms.count
        let selected = selectedContactIDs.count + selectedGroupIDs.count + selectedPublicRooms.count
        return total > 0 && selected >= total
    }

    private var selectionCount: Int {
        selectedContactIDs.count + selectedGroupIDs.count + selectedPublicRooms.count
    }

    // MARK: - Circles (group chats and public rooms)

    private func openGroupFromCircle(_ group: GroupChat) {
        selectedContact = nil
        selectedPublicRoom = nil
        selectedGroup = group
    }

    private func openRoom(_ name: String) {
        selectedContact = nil
        selectedGroup = nil
        selectedPublicRoom = name
    }

    /// A room handed over from outside: a tapped notification or a shared room link. The name is
    /// re-validated (a link's is attacker-controlled), and a room with no store row gets one
    /// first, so it opens with its circle already in the row behind it.
    private func openRoomFromHandoff(_ rawName: String) {
        guard let normalized = KaChatInternalLink.normalizeAndValidateChannel(rawName) else { return }
        if !PublicChatService.shared.channels.contains(where: { $0.channelName == normalized }) {
            PublicChatService.shared.joinChannel(normalized)
        }
        openRoom(normalized)
    }

    private var circlePinsKey: String? {
        guard let address = walletManager.currentWallet?.publicAddress.lowercased() else { return nil }
        return "kachat_chat_circle_pins_\(address)"
    }

    private func loadCirclePins() {
        guard let key = circlePinsKey else { circlePins = []; return }
        circlePins = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// Hold a circle: pin it to the front (newest pin first), or unpin it.
    private func toggleCirclePin(_ id: String) {
        Haptics.impact(.medium)
        if let index = circlePins.firstIndex(of: id) {
            circlePins.remove(at: index)
            showToast(AppLocalization.string("Unpinned"))
        } else {
            circlePins.insert(id, at: 0)
            showToast(AppLocalization.string("Pinned to the front"))
        }
        if let key = circlePinsKey { UserDefaults.standard.set(circlePins, forKey: key) }
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

        let showsRequestsRow = searchText.isEmpty && editMode != .active
        let requestCount = showsRequestsRow ? chatService.messageRequests.count : 0
        return List(selection: $selectedContactIDs) {
            // Group chats and public rooms, as circles under the search bar - swipe sideways for
            // all of them. Tap opens, hold pins to the front, Select mode selects them too.
            ChatCirclesStrip(
                searchText: searchText,
                pins: circlePins,
                selectedGroupIDs: $selectedGroupIDs,
                selectedRooms: $selectedPublicRooms,
                onOpenGroup: openGroupFromCircle,
                onOpenRoom: openRoom,
                onTogglePin: toggleCirclePin
            )
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            // People who wrote first and haven't been accepted - one row, always there, right
            // above your own chat (NO_HANDSHAKE_MESSAGING.md).
            if showsRequestsRow {
                Button {
                    Haptics.impact(.light)
                    showMessageRequests = true
                } label: {
                    MessageRequestsRow(count: requestCount)
                }
                .buttonStyle(ChatRowPressStyle())
                .listRowBackground(Color.clear)
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
                            selectedGroup = nil
                            selectedContact = conversation.contact
                        }
                    } label: {
                        ConversationRow(conversation: conversation)
                    }
                    .buttonStyle(ChatRowPressStyle())
                    // A sheet, not a context menu: the options each carry a line saying what
                    // they do, and "Silence" needs one - it is not obvious that it survives the
                    // app-wide notification setting.
                    //
                    // `.simultaneousGesture`, not `.onLongPressGesture`: the row's label IS a
                    // Button, and a discrete gesture attached outside it loses the race to the
                    // Button every time - the press did nothing at all. Same reason the message
                    // bubbles use simultaneousGesture for their double-tap.
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                            guard editMode != .active else { return }
                            Haptics.impact(.medium)
                            conversationActionTarget = conversation
                        }
                    )
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
        .overlay(alignment: .center) {
            // Below the circles row rather than over it: only when there are no chats at all.
            if displayed.isEmpty && searchText.isEmpty {
                emptyStateView
                    .padding(.top, 120)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Mark read, mark unread and delete, for everything selected: chats, group circles and room
    /// circles alike.
    private var selectionActionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button {
                    let chats = filteredConversationsCache.filter { selectedContactIDs.contains($0.contact.id) }
                    let groups = groupChatService.groups.filter { selectedGroupIDs.contains($0.id) }
                    if !groups.isEmpty { groupChatService.markGroupsAsRead(groups) }
                    for room in selectedPublicRooms { PublicChatService.shared.markChannelRead(room) }
                    if !chats.isEmpty { Task { await chatService.markConversationsAsRead(chats) } }
                    editMode = .inactive
                } label: {
                    Image(systemName: "envelope.open")
                        .frame(maxWidth: .infinity)
                }
                .disabled(selectionCount == 0)

                Button {
                    let chats = filteredConversationsCache.filter { selectedContactIDs.contains($0.contact.id) }
                    let groups = groupChatService.groups.filter { selectedGroupIDs.contains($0.id) }
                    if !chats.isEmpty { chatService.markConversationsAsUnread(chats) }
                    if !groups.isEmpty { groupChatService.markGroupsAsUnread(groups) }
                    for room in selectedPublicRooms { PublicChatService.shared.markChannelUnread(room) }
                    editMode = .inactive
                } label: {
                    Image(systemName: "envelope.badge")
                        .frame(maxWidth: .infinity)
                }
                .disabled(selectionCount == 0)

                Button(role: .destructive) {
                    showBulkDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                }
                .disabled(selectionCount == 0)
            }
            .font(.scaled(size: 18))
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
            Text(verbatim: "\(exact) \(KaspaUnit.symbol)")
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
                .map { (key: $0.lastMessage?.timestamp ?? Date.distantPast, value: $0) }
                .sorted { $0.key > $1.key }
                .map(\.value)
            filteredConversationsCache = pinningSelfChat(filteredConversationsCache)
            return
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            filteredConversationsCache = sourceConversations
                .filter { conversation in
                    chatService.isConversationVisibleInChatList(conversation, settings: settings)
                }
                .map { (key: $0.lastMessage?.timestamp ?? Date.distantPast, value: $0) }
                .sorted { $0.key > $1.key }
                .map(\.value)
            filteredConversationsCache = pinningSelfChat(filteredConversationsCache)
            return
        }

        filteredConversationsCache = pinningSelfChat(sourceConversations.filter { conv in
            guard chatService.isConversationVisibleInChatList(conv, settings: settings) else { return false }
            if contactsManager.displayName(for: conv.contact).range(of: query, options: .caseInsensitive) != nil {
                return true
            }
            if conv.contact.address.range(of: query, options: .caseInsensitive) != nil {
                return true
            }
            return conv.messages.contains { message in
                // Same media-envelope guard as the group search above. Cross-device placeholders
                // are hidden from every surface, so a query matching their fixed text must not
                // surface the conversation either.
                !message.isSentPlaceholder &&
                    message.content.utf8.count <= 4096 &&
                    message.content.range(of: query, options: .caseInsensitive) != nil
            }
        })
    }

    /// Your chat with yourself always sits first, whatever else was active more recently - it is
    /// the notes-to-self and landing spot for unknown senders, and should never have to be
    /// scrolled for. Everything else keeps its order.
    private func isOwnChat(_ contact: Contact) -> Bool {
        guard let mine = walletManager.currentWallet?.publicAddress.lowercased() else { return false }
        return contact.address.lowercased() == mine
    }

    private func pinningSelfChat(_ conversations: [Conversation]) -> [Conversation] {
        guard let mine = walletManager.currentWallet?.publicAddress.lowercased(),
              let index = conversations.firstIndex(where: { $0.contact.address.lowercased() == mine }),
              index > 0 else { return conversations }
        var pinned = conversations
        pinned.insert(pinned.remove(at: index), at: 0)
        return pinned
    }

    /// Pulled out of the `.alert(...)` call site as a plain computed property - an inline ternary
    /// nested inside string interpolation there was making the compiler unable to type-check the
    /// `.alert` expression in reasonable time.
    private var bulkDeleteAlertTitle: String {
        let chats = selectedContactIDs.count, groups = selectedGroupIDs.count, rooms = selectedPublicRooms.count
        if groups == 0 && rooms == 0 {
            return "Delete \(chats) Chat\(chats == 1 ? "" : "s")?"
        } else if chats == 0 && rooms == 0 {
            return "Delete \(groups) Group\(groups == 1 ? "" : "s")?"
        } else if chats == 0 && groups == 0 {
            return "Delete \(rooms) Public Chat\(rooms == 1 ? "" : "s")?"
        }
        return "Delete \(chats + groups + rooms) Selected?"
    }

    private var bulkDeleteAlertMessage: String {
        var parts: [String] = []
        if !selectedContactIDs.isEmpty {
            parts.append(AppLocalization.string("This permanently deletes every message in each selected chat from this device. This cannot be undone."))
        }
        if !selectedGroupIDs.isEmpty {
            parts.append(AppLocalization.string("This removes each selected group and its messages from this device. This cannot be undone, and other members won't be notified."))
        }
        if !selectedPublicRooms.isEmpty {
            parts.append(AppLocalization.string("Rooms you added are removed with their messages. Default rooms are only switched off - turn them back on any time in Public Chats settings (the gear)."))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Long-press context menu for a 1:1 conversation row. Read/Unread show contextually (the
    /// relevant one only, matching Mail) and reuse the exact same service calls as the Select-mode
    /// bulk bar; Delete routes through its own confirmation alert, which then reuses
    /// `deleteConversations`. Empty while Select mode is active - the bulk bar owns actions there.
    private func conversationRowSheet(for conversation: Conversation) -> some View {
        let isSilent = conversation.contact.notificationModeOverride == .off
        return VStack(spacing: 12) {
            Text(contactsManager.displayName(for: conversation.contact))
                .font(.headline)
                .lineLimit(1)
                .padding(.top, 20)
                .padding(.bottom, 4)

            if conversation.unreadCount > 0 {
                ActionSheetRow(
                    title: "Mark as Read",
                    subtitle: "Clears the unread badge on this chat.",
                    systemImage: "envelope.open"
                ) {
                    conversationActionTarget = nil
                    Task { await chatService.markConversationAsRead(conversation) }
                }
            } else {
                ActionSheetRow(
                    title: "Mark as Unread",
                    subtitle: "Puts the unread badge back so you come across it again.",
                    systemImage: "envelope.badge"
                ) {
                    conversationActionTarget = nil
                    chatService.markConversationAsUnread(conversation)
                }
            }

            ActionSheetRow(
                title: isSilent ? "Unsilence" : "Silence",
                subtitle: isSilent
                    ? "Notifications from this chat resume."
                    : "No notification from this chat, whatever your app-wide setting says.",
                systemImage: isSilent ? "bell" : "bell.slash"
            ) {
                conversationActionTarget = nil
                setSilent(!isSilent, for: conversation.contact)
            }

            // Your chat with yourself cannot be deleted - it is always there, first in the list.
            if !isOwnChat(conversation.contact) {
                ActionSheetRow(
                    title: "Delete",
                    subtitle: "Removes this chat and its messages from this device.",
                    systemImage: "trash",
                    tint: .red
                ) {
                    conversationActionTarget = nil
                    // One turn later: the confirmation alert cannot present while the sheet is
                    // still on its way out.
                    DispatchQueue.main.async { rowDeleteContact = conversation.contact }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(400)])
        .presentationDragIndicator(.visible)
    }

    /// Silencing a 1:1 chat is the existing per-contact notification override set to `.off` -
    /// the one the notification path and the push registration already consult - not a second,
    /// parallel mute flag that only some of them would honour.
    private func setSilent(_ silent: Bool, for contact: Contact) {
        var updated = contact
        updated.notificationModeOverride = silent ? .off : nil
        contactsManager.updateContact(updated)
    }

    /// Shared delete path for both Select-mode bulk deletes and single-row context-menu deletes
    /// (row swipes are gone) - per-contact cleanup with one resubscribe and toast at the end.
    private func deleteConversations(_ contacts: [Contact]) {
        // Your own chat is never deleted, even when it was part of a Select All.
        let contacts = contacts.filter { !isOwnChat($0) }
        guard !contacts.isEmpty else {
            selectedContactIDs = []
            return
        }
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
/// boolean - see `PublicChatChannelDestination` below for why: popping back via the native swipe
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
    let conversation: Conversation
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var walletManager: WalletManager
    @ObservedObject private var knsService = KNSService.shared
    @ObservedObject private var kachatRegistry = KachatNamesRegistry.shared
    private static let previewCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 2048
        return cache
    }()

    private var avatarURLString: String? {
        knsService.profileCache[conversation.contact.address]?.avatarURL
    }

    /// `ContactsManager.displayName` - assigned name, else KNS domain, else short address - read
    /// through the observed KNS service so the row redraws when a profile lands.
    private var rowDisplayName: String {
        if let assigned = conversation.contact.assignedName { return assigned }
        // On testnet: the .kachat name (read through the observed registry, so the row redraws
        // when it lands); KNS isn't consulted there.
        if KachatNamesService.isEnabled {
            if let label = kachatRegistry.cachedIdentity(for: conversation.contact.address)?.label { return "\(label).kachat" }
            return Contact.generateDefaultAlias(from: conversation.contact.address)
        }
        if let domain = knsService.profileCache[conversation.contact.address]?.domainName, !domain.isEmpty {
            return domain
        }
        return Contact.generateDefaultAlias(from: conversation.contact.address)
    }

    var body: some View {
        let lastMessage = conversation.lastMessage

        HStack(spacing: 12) {
            // Avatar
            KNSAvatarView(
                avatarURLString: avatarURLString,
                fallbackText: rowDisplayName,
                size: 50,
                contactAddress: conversation.contact.address
            )

            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(rowDisplayName)
                                .font(.headline)
                                .lineLimit(1)
                            // Silenced: no banner from this conversation, ever. Worth a mark on
                            // the row - a chat that never pings otherwise looks like a chat
                            // nobody is using.
                            if conversation.contact.notificationModeOverride == .off {
                                Image(systemName: "bell.slash.fill")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .accessibilityLabel("Silenced")
                            }
                        }
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
                            let status: DeliveryStatusLabel.Status = {
                                switch lastMessage.deliveryStatus {
                                case .sent: return .sent
                                case .pending: return .pending
                                case .failed: return .failed
                                case .warning: return .warning
                                }
                            }()
                            DeliveryStatusLabel(status: status, compact: true)
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
        // Cross-device placeholders never surface anywhere (see ChatMessage.isSentPlaceholder).
        // Conversation.lastMessage already skips them; this is a defensive backstop in case a
        // placeholder's content reaches the preview through any other route.
        if ChatMessage.isSentPlaceholder(content) { return "" }
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

        // A message that is nothing but a link back into KaChat previews as what it OPENS
        // rather than as a raw `kachat://…` URL - matching the rich card the bubble itself
        // renders for it (see `KaChatInternalLinkCardView`).
        if let internalLink = KaChatInternalLink.match(in: unwrapped), internalLink.coversWholeMessage {
            switch internalLink.link {
            case .kaPost:
                result = "Shared a KaPosts post"
            case .publicChatRoom(let channel):
                result = "Public chat room #\(channel)"
            case .profile:
                result = "Shared a KaChat profile"
            }
            Self.previewCache.setObject(result as NSString, forKey: key)
            return result
        }

        // Check if content is a file JSON payload
        let trimmed = unwrapped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else {
            result = LinkSafePreview.apply(to: unwrapped)
            Self.previewCache.setObject(result as NSString, forKey: key)
            return result
        }

        if let chessEnvelope = ChessCodec.parseAny(unwrapped) {
            if case .invite(let invite) = chessEnvelope, let minutes = invite.tcMinutes {
                result = "♟️ Chess game - \(minutes) | \(invite.tcIncSeconds ?? 0)"
            } else {
                result = "♟️ Chess game"
            }
            Self.previewCache.setObject(result as NSString, forKey: key)
            return result
        }

        if let callEnvelope = CallCodec.parseAny(unwrapped) {
            switch callEnvelope {
            case .request(let request): result = request.video ? "📹 Video call" : "📞 Voice call"
            case .invite(let invite): result = invite.video ? "📹 Video call" : "📞 Voice call"
            case .response(let response):
                result = response.reason == "no_host" ? "📞 Calls need Nextcloud Talk" : (response.accepted ? "📞 Call answered" : "📞 Call declined")
            case .end(let end):
                if let seconds = end.durationSeconds, seconds > 0 {
                    result = String(format: "📞 Call · %d:%02d", seconds / 60, seconds % 60)
                } else {
                    switch end.reason {
                    case "no_answer", "cancelled": result = "📞 Missed call"
                    case "declined": result = "📞 Call declined"
                    default: result = "📞 Call ended"
                    }
                }
            }
            Self.previewCache.setObject(result as NSString, forKey: key)
            return result
        }

        guard let data = unwrapped.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "file",
              let mimeType = json["mimeType"] as? String else {
            result = LinkSafePreview.apply(to: unwrapped)
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

/// The preview a link-bearing message gets in the chat and group lists: never the link itself.
///
/// A raw URL in a list row is noise at best, and for Nextcloud media it was worse - the message
/// IS a public share link, so the row showed the address of someone's photo to anyone glancing
/// at the phone. Any message carrying an http(s) link previews as an attachment instead,
/// whatever else it says. Only web links count: a message that is a `kaspa:` address must keep
/// reading as one, and the detector would otherwise take that for a URL too.
enum LinkSafePreview {
    static let sentALink = "📎 Sent a link"

    /// Keyed the same way `formatPreview`'s cache is - the group row has no cache of its own and
    /// renders its preview on every pass, and a detector scan per pass is exactly the kind of
    /// per-row cost the chat list has been shedding.
    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 512
        return cache
    }()

    static func apply(to text: String) -> String {
        let key = "\(text.utf8.count)|\(text.prefix(24))" as NSString
        if let cached = cache.object(forKey: key) { return cached as String }
        let result = containsWebLink(text) ? sentALink : text
        cache.setObject(result as NSString, forKey: key)
        return result
    }

    private static func containsWebLink(_ text: String) -> Bool {
        guard let detector = SharedDetectors.link else { return false }
        let range = NSRange(text.startIndex..., in: text)
        var found = false
        detector.enumerateMatches(in: text, options: [], range: range) { match, _, stop in
            guard let scheme = match?.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
            found = true
            stop.pointee = true
        }
        return found
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

struct GroupChatRow: View {
    let group: GroupChat
    @EnvironmentObject var groupChatService: GroupChatService
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var walletManager: WalletManager
    @ObservedObject private var knsService = KNSService.shared

    /// Messages are stored oldest-first (loaded sorted, then appended), so the newest is the
    /// last element. This used to be a `max` scan of the whole array - evaluated several times
    /// per row body, on every one of the service's frequent publishes during a sync.
    private var lastMessage: GroupMessage? {
        groupChatService.groupMessages[group.id]?.last
    }

    /// Group mirror of ConversationRow.reactionPreviewText: a reaction newer than the last
    /// message becomes the row's preview ("Alice reacted to a message") - reactions never
    /// become messages (they render as a corner pill), so without this the row would keep
    /// showing an older message as if nothing happened. `nil` when the newest activity is a
    /// regular message.
    private var reactionPreviewText: String? {
        guard let byTarget = groupChatService.reactionsByGroupId[group.id], !byTarget.isEmpty else { return nil }
        // Pick the newest reaction purely from the reaction snapshots, then resolve its target
        // once. Resolving inside the loop meant a linear search of the group's whole message
        // array for every reaction target that briefly held the lead.
        var newestSnapshot: (snapshot: GroupStore.ReactionSnapshot, targetTxId: String)?
        for (targetTxId, snapshots) in byTarget {
            guard let candidate = snapshots.max(by: { $0.blockTime < $1.blockTime }) else { continue }
            if newestSnapshot == nil || candidate.blockTime > newestSnapshot!.snapshot.blockTime {
                newestSnapshot = (candidate, targetTxId)
            }
        }
        guard let newestSnapshot else { return nil }
        let newest = (
            snapshot: newestSnapshot.snapshot,
            targetIsMine: groupChatService.groupMessages[group.id]?
                .first(where: { $0.txId == newestSnapshot.targetTxId })?.isOutgoing == true
        )
        let reactionDate = Date(timeIntervalSince1970: TimeInterval(newest.snapshot.blockTime) / 1000.0)
        if let lastMessage, lastMessage.timestamp >= reactionDate { return nil }
        if newest.snapshot.reactorAddress == walletManager.currentWallet?.publicAddress {
            return newest.targetIsMine ? "You reacted to your message" : "You reacted to a message"
        }
        let name = resolveDisplayName(for: newest.snapshot.reactorAddress)
        return newest.targetIsMine ? "\(name) reacted to your message" : "\(name) reacted to a message"
    }

    /// Same resolution as `GroupChatDetailView.displayName(for:)`.
    private func resolveDisplayName(for address: String) -> String {
        // The app's one rule (ContactsManager.displayName): your name for them, else their
        // .kachat name on testnet (KNS elsewhere), else the short address.
        contactsManager.displayName(for: address)
    }

    /// Decoded group photos, keyed on the group id, the hex length and the payload's tail:
    /// hex-decoding and then JPEG-decoding the photo on every body pass made each row pay for
    /// the whole image on every list refresh. A photo change always changes the hex payload
    /// (and almost always its length), so a stale entry could only survive a same-length
    /// replacement whose final bytes also match - and hashing only the tail keeps the key
    /// itself cheap for a payload that can run to hundreds of kilobytes.
    private static let groupPhotoCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        return cache
    }()

    /// The decoded group photo, cached - shared with the circles row.
    static func cachedPhoto(groupId: String, hex: String?) -> UIImage? {
        guard let hex else { return nil }
        let cacheKey = "\(groupId)|\(hex.count)|\(hex.suffix(256).hashValue)" as NSString
        if let cached = groupPhotoCache.object(forKey: cacheKey) {
            return cached
        }
        guard let data = Data(hexString: hex), let image = UIImage(data: data) else { return nil }
        groupPhotoCache.setObject(image, forKey: cacheKey)
        return image
    }

    private var groupPhotoImage: UIImage? {
        guard let hex = groupChatService.groupPhotos[group.id] else { return nil }
        let cacheKey = "\(group.id)|\(hex.count)|\(hex.suffix(256).hashValue)" as NSString
        if let cached = Self.groupPhotoCache.object(forKey: cacheKey) {
            return cached
        }
        guard let data = Data(hexString: hex), let image = UIImage(data: data) else { return nil }
        Self.groupPhotoCache.setObject(image, forKey: cacheKey)
        return image
    }

    var body: some View {
        HStack(spacing: 12) {
            if let img = groupPhotoImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 50, height: 50)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: 50, height: 50)
                    .overlay(
                        Image(systemName: "person.3.fill")
                            .font(.scaled(size: 18))
                            .foregroundColor(.accentColor)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(group.name)
                        .font(.headline)
                        .lineLimit(1)
                    // Silenced: no banner from this group, mentioned or not.
                    if groupChatService.silentNotifications(for: group.id) {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .accessibilityLabel("Silenced")
                    }

                    Spacer()

                    if let lastMessage {
                        Text(formatDate(lastMessage.timestamp))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    if let reactionPreview = reactionPreviewText {
                        Text(reactionPreview)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else if let lastMessage {
                        Text(GroupMentionCodec.decodeForDisplay(LinkSafePreview.apply(to: MessageReplyCodec.previewText(for: lastMessage.content)), members: group.members, resolveDisplayName: resolveDisplayName(for:)))
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

/// The red unread count - on the group and room circles.
private struct ChatsTabUnreadBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.caption2.weight(.bold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.red))
        }
    }
}

/// Group chats and public rooms as a row of circles above the chats list, under the search bar.
/// Swipe sideways for all of them. Pinned ones come first (in pin order), then the rest by latest
/// activity. Tap opens; hold pins to the front or unpins; in Select mode a tap selects, for the
/// list's mark read / unread / delete bar. Observes the room and group services itself, so room
/// traffic re-renders this row rather than the whole chat list.
private struct ChatCirclesStrip: View {
    @EnvironmentObject private var groupChatService: GroupChatService
    @ObservedObject private var publicChats = PublicChatService.shared
    @Environment(\.editMode) private var editMode
    let searchText: String
    let pins: [String]
    @Binding var selectedGroupIDs: Set<String>
    @Binding var selectedRooms: Set<String>
    let onOpenGroup: (GroupChat) -> Void
    let onOpenRoom: (String) -> Void
    let onTogglePin: (String) -> Void

    private enum Item: Identifiable {
        case group(GroupChat)
        case room(PublicChatChannel)

        var id: String {
            switch self {
            case .group(let group): return "g:\(group.id)"
            case .room(let room): return "r:\(room.channelName)"
            }
        }
    }

    private var isSelecting: Bool { editMode?.wrappedValue == .active }

    private var items: [Item] {
        let groupMessages = groupChatService.groupMessages
        var dated: [(item: Item, at: Date)] = groupChatService.groups.map { group in
            (.group(group), groupMessages[group.id]?.last?.timestamp ?? group.createdAt)
        }
        dated += publicChats.listedChannels.map { room in
            let last = publicChats.messages(forChannel: room.channelName).last?.blockTime
            let at = last.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } ?? (room.joinedAt ?? .distantPast)
            return (.room(room), at)
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            dated = dated.filter { title(of: $0.item).range(of: query, options: .caseInsensitive) != nil }
        }
        let byId = Dictionary(dated.map { ($0.item.id, $0.item) }, uniquingKeysWith: { a, _ in a })
        let pinned = pins.compactMap { byId[$0] }
        let pinnedIds = Set(pinned.map(\.id))
        let rest = dated.filter { !pinnedIds.contains($0.item.id) }.sorted { $0.at > $1.at }.map(\.item)
        return pinned + rest
    }

    var body: some View {
        let items = items
        if items.isEmpty {
            Color.clear.frame(height: 1)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        circle(item)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    private func title(of item: Item) -> String {
        switch item {
        case .group(let group): return group.name
        case .room(let room): return "#\(room.channelName)"
        }
    }

    private func unread(of item: Item) -> Int {
        switch item {
        case .group(let group): return groupChatService.unreadCount(for: group)
        case .room(let room): return publicChats.unreadCount(forChannel: room.channelName)
        }
    }

    private func isSelected(_ item: Item) -> Bool {
        switch item {
        case .group(let group): return selectedGroupIDs.contains(group.id)
        case .room(let room): return selectedRooms.contains(room.channelName)
        }
    }

    private func toggleSelection(_ item: Item) {
        switch item {
        case .group(let group):
            if selectedGroupIDs.contains(group.id) { selectedGroupIDs.remove(group.id) } else { selectedGroupIDs.insert(group.id) }
        case .room(let room):
            if selectedRooms.contains(room.channelName) { selectedRooms.remove(room.channelName) } else { selectedRooms.insert(room.channelName) }
        }
    }

    @ViewBuilder
    private func avatar(_ item: Item) -> some View {
        switch item {
        case .group(let group):
            if let image = GroupChatRow.cachedPhoto(groupId: group.id, hex: groupChatService.groupPhotos[group.id]) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(Color.accentColor.opacity(0.2))
                    .overlay(
                        Image(systemName: "person.3.fill")
                            .font(.scaled(size: 18))
                            .foregroundColor(.accentColor)
                    )
            }
        case .room:
            Circle()
                .fill(Color.accentColor.opacity(0.2))
                .overlay(
                    Text("#")
                        .font(.scaled(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(.accentColor)
                )
        }
    }

    private func circle(_ item: Item) -> some View {
        let selected = isSelected(item)
        let pinned = pins.contains(item.id)
        let unreadCount = unread(of: item)
        return Button {
            if isSelecting {
                toggleSelection(item)
            } else {
                switch item {
                case .group(let group): onOpenGroup(group)
                case .room(let room): onOpenRoom(room.channelName)
                }
            }
        } label: {
            VStack(spacing: 6) {
                avatar(item)
                    .frame(width: 60, height: 60)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: isSelecting && selected ? 3 : 0))
                    .opacity(isSelecting && !selected ? 0.55 : 1)
                    .overlay(alignment: .topTrailing) {
                        if isSelecting {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundColor(selected ? .accentColor : .secondary)
                                .background(Circle().fill(Color(.systemBackground)))
                                .offset(x: 4, y: -4)
                        } else if unreadCount > 0 {
                            ChatsTabUnreadBadge(count: unreadCount)
                                .offset(x: 6, y: -4)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if pinned && !isSelecting {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(4)
                                .background(Circle().fill(Color.accentColor))
                                .offset(x: -2, y: 2)
                        }
                    }
                Text(verbatim: title(of: item))
                    .font(.caption2)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .frame(width: 68)
            }
        }
        .buttonStyle(.plain)
        // A Button label needs simultaneousGesture (see the chat rows).
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                guard !isSelecting else { return }
                onTogglePin(item.id)
            }
        )
        .accessibilityLabel(Text(verbatim: title(of: item)))
        .accessibilityHint(Text(pinned ? "Hold to unpin" : "Hold to pin to the front"))
    }
}

// MARK: - Message Requests

/// The chat list's Message Requests row: everyone who wrote first and hasn't been accepted.
private struct MessageRequestsRow: View {
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.scaled(size: 20, weight: .semibold))
                .foregroundColor(.black)
                .frame(width: 50, height: 50)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 3) {
                Text("Message Requests")
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(count > 0 ? "People who wrote to you first" : "No new requests")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if count > 0 {
                Text(verbatim: "\(count)")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor))
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(Color(.tertiaryLabel))
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// Chats someone else started that you haven't accepted (NO_HANDSHAKE_MESSAGING.md). Open one to
/// read everything they sent, then Accept or Reject from inside it. Their messages never notify
/// you beyond the first "New message request".
struct MessageRequestsView: View {
    @EnvironmentObject private var chatService: ChatService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            let requests = chatService.messageRequests
            List {
                Section {
                    ForEach(requests) { conversation in
                        NavigationLink {
                            ChatDetailView(contact: conversation.contact, startInPaymentMode: false)
                        } label: {
                            ConversationRow(conversation: conversation)
                        }
                    }
                } footer: {
                    if !requests.isEmpty {
                        Text("Open a request to read it. Accept to reply and move it to your chats; Reject deletes it and stops that address reaching you until you write to them.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if requests.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.scaled(size: 40))
                            .foregroundColor(.secondary)
                        Text("No message requests")
                            .font(.headline)
                    }
                }
            }
            .navigationTitle("Message Requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// One square option in the Chats New sheet: an icon over a two-line title, on glass.
private struct CreateTile: View {
    let title: LocalizedStringKey
    let hint: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .padding(8)
            .frame(width: ChatListView.createTileSize, height: ChatListView.createTileSize)
            .background(sendKaspaGlass(cornerRadius: 18))
        }
        .buttonStyle(ChatRowPressStyle())
        .accessibilityHint(Text(hint))
    }
}

/// The New sheet's "Send Kaspa": the same send Profile opens for the current spending address,
/// once that address's balance is known (it shows in the screen's Available pill).
private struct SpendingSendLauncher: View {
    @EnvironmentObject private var walletManager: WalletManager
    @State private var balanceSompi: UInt64?

    var body: some View {
        Group {
            if let address = walletManager.currentSpendingAddress(), let balanceSompi {
                SpendingAddressWithdrawView(
                    entry: SpendingAddressEntry(
                        index: walletManager.currentSpendingAddressIndex,
                        address: address,
                        balanceSompi: balanceSompi,
                        isCurrent: true
                    )
                ) {}
            } else if walletManager.currentSpendingAddress() == nil {
                Text("Spending address is unlocking — go back and try again.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ProgressView()
            }
        }
        .task {
            guard let address = walletManager.currentSpendingAddress() else { return }
            let utxos = (try? await NodePoolService.shared.getUtxosByAddresses([address])) ?? []
            balanceSompi = utxos.reduce(UInt64(0)) { $0 + $1.amount }
        }
    }
}
