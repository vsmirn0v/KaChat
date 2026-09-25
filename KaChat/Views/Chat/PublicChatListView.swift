import SwiftUI

struct PublicChatListView: View {
    @EnvironmentObject var publicChatService: PublicChatService

    /// Channel to auto-push into on first appearance - set when this view is opened by tapping a
    /// public chat-room notification (see `ChatListView.navigateToPublicChat`), so the notification
    /// lands the user directly in the room instead of just this list.
    let initialChannel: String?
    /// True when shown as the Chats screen's "Public Chats" tab: the Chats screen already owns
    /// the title and the header items, so this view adds none of its own.
    var embeddedInChats = false

    @State private var showJoinAlert = false
    @State private var joinFieldText = ""
    @FocusState private var joinFieldFocused: Bool
    @State private var joinError: String?
    @State private var ownSelectedChannel: String?
    /// When embedded in the Chats screen, the room selection lives THERE - the paged TabView
    /// this list sits in is a lazy container, and a navigation destination declared inside
    /// one is ignored (SwiftUI warns, and will drop it in a future release). The Chats screen
    /// owns the binding and declares the destination beside its chat and group ones.
    private var externalSelection: Binding<String?>?
    private var selectedChannel: String? {
        get { externalSelection?.wrappedValue ?? ownSelectedChannel }
        nonmutating set {
            if let externalSelection { externalSelection.wrappedValue = newValue } else { _ownSelectedChannel.wrappedValue = newValue }
        }
    }
    private var selectedChannelBinding: Binding<String?> {
        externalSelection ?? $ownSelectedChannel
    }
    @State private var channelToLeave: String?
    /// The room whose long-press half sheet is up.
    @State private var roomActionTarget: String?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var hasAppliedInitialChannel = false
    /// Collapsed by default: eleven language rooms would bury the two Popular rooms and the
    /// user's own channels under a wall of list.
    @State private var languagesExpanded = false

    init(initialChannel: String? = nil, embeddedInChats: Bool = false, selection: Binding<String?>? = nil) {
        self.embeddedInChats = embeddedInChats
        self.initialChannel = initialChannel
        self.externalSelection = selection
    }

    var body: some View {
        Group {
            switch PublicChatNavigationPolicy.currentChannelPresentationMode {
            case .inlineReplacement:
                if let selectedChannel {
                    inlineChannelView(selectedChannel)
                } else {
                    publicChatListContent
                }
            case .navigationDestination:
                if externalSelection != nil {
                    // The host declares the destination (see `externalSelection`).
                    publicChatListContent
                } else {
                    publicChatListContent
                        .modifier(PublicChatChannelDestination(selectedChannel: selectedChannelBinding))
                }
            }
        }
        .onAppear {
            // The curated Popular channels always have store rows so their bell state exists
            // before first entry.
            publicChatService.ensureFeaturedChannelsJoined()
            publicChatService.refreshChannels()
            if !hasAppliedInitialChannel, let initialChannel {
                hasAppliedInitialChannel = true
                selectedChannel = initialChannel
            }
            // Cold-start push tap: MainTabView routes here, and the pending channel (set by the
            // notification handler) is consumed on mount - ChatListView no longer brokers this.
            if let pending = publicChatService.pendingPublicChatNavigation {
                publicChatService.pendingPublicChatNavigation = nil
                openChannelFromHandoff(pending)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPublicChat)) { notification in
            // Already viewing the public chat list (or a room within it) when another public chat
            // notification is tapped - swap straight to the new room instead of no-oping, since
            // `ChatListView`'s own handling only covers opening the list from scratch.
            guard let channel = notification.userInfo?["channel"] as? String else { return }
            openChannelFromHandoff(channel)
        }
        .onChange(of: publicChatService.pendingPublicChatNavigation) { newValue in
            guard let channel = newValue else { return }
            publicChatService.pendingPublicChatNavigation = nil
            openChannelFromHandoff(channel)
        }
    }

    /// Opens a room handed over from outside the list: a tapped notification, or a shared room
    /// link (`KaChatInternalLink`). Two things this needs that a plain assignment doesn't:
    /// - the name is re-validated, since a pasted link's channel name is attacker-controlled and
    ///   this is the last hop before it becomes a store row;
    /// - a room with no store row yet gets one first. A link can name a room this device has
    ///   never joined, and on a cold start the router's own join runs before the store has
    ///   finished loading (a no-op), so the room would otherwise open while being absent from
    ///   the list behind it. Same join-then-open shape as `openCuratedChannel`.
    private func openChannelFromHandoff(_ rawName: String) {
        guard let normalized = KaChatInternalLink.normalizeAndValidateChannel(rawName) else { return }
        if !publicChatService.channels.contains(where: { $0.channelName == normalized }) {
            publicChatService.joinChannel(normalized)
        }
        selectedChannel = normalized
    }

    private var publicChatListContent: some View {
        // One page, no tabs: the curated Popular rooms pinned on top (enter/exit freely, no
        // leaving - they're permanent), then everything the user joined under Your Channels.
        combinedList
        .navigationTitle(embeddedInChats ? "Chats" : "Public Chats")
        .toolbar {
            // Same header anatomy as Chats/KaPosts: green connection dot leading, total
            // balance dead-center, actions trailing. The Chats screen supplies these itself
            // when this is its Public Chats tab.
            if !embeddedInChats {
                ToolbarItem(placement: .navigationBarLeading) {
                    ConnectionStatusIndicator()
                }
                ToolbarItem(placement: .principal) {
                    BalanceToolbarLabel()
                }
            }
        }
        .toast(message: toastMessage, style: .success)
        .sheet(isPresented: $showJoinAlert) { joinChannelSheet }
        .alert("Couldn't Join Channel", isPresented: Binding(
            get: { joinError != nil },
            set: { if !$0 { joinError = nil } }
        )) {
            Button("OK", role: .cancel) { joinError = nil }
        } message: {
            Text(joinError ?? "")
        }
        // Deleting a room asks on a half sheet, like every other menu here.
        .sheet(isPresented: Binding(
            get: { channelToLeave != nil },
            set: { if !$0 { channelToLeave = nil } }
        )) {
            if let name = channelToLeave {
                VStack(spacing: 14) {
                    Image(systemName: "trash")
                        .font(.system(size: 30))
                        .foregroundColor(.red)
                        .padding(.top, 26)
                    Text("Delete #\(name)?")
                        .font(.title3.weight(.bold))
                    Text("Every message cached for this room on this device is deleted. This cannot be undone - rejoining later starts with no history.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    ActionSheetRow(title: "Delete", subtitle: "Removes this room and its messages from this device.", systemImage: "trash", tint: .red) {
                        publicChatService.leaveChannel(name)
                        channelToLeave = nil
                    }
                    ActionSheetRow(title: "Keep", subtitle: "Leave the room as it is.", systemImage: "xmark") {
                        channelToLeave = nil
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .presentationDetents([.height(360)])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private func inlineChannelView(_ channel: String) -> some View {
        PublicChatChannelView(channelName: channel)
            .id(channel)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        selectedChannel = nil
                    } label: {
                        Label("Channels", systemImage: "chevron.left")
                    }
                }
            }
    }

    // MARK: - Rooms, laid out like the Chats and Group Chats lists

    /// The rooms in the list: the two curated rooms pinned on top, then every other joined room
    /// (your own, and any language room you opened) by latest activity.
    private var listedChannels: [PublicChatChannel] {
        let featured = PublicChatService.featuredChannels.compactMap { name in
            publicChatService.channels.first { $0.channelName == name }
        }
        .filter { publicChatService.isCuratedChannelShown($0.channelName) }
        let others = publicChatService.channels
            .filter { !PublicChatService.featuredChannels.contains($0.channelName) }
            .filter { !PublicChatService.serviceChannels.contains($0.channelName) }
            // A default room switched off in Public Chats settings stays out of the list.
            .filter { publicChatService.isCuratedChannelShown($0.channelName) }
            .sorted { lastActivity($0) > lastActivity($1) }
        return featured + others
    }

    private func lastActivity(_ channel: PublicChatChannel) -> Int64 {
        publicChatService.messages(forChannel: channel.channelName).last?.blockTime
            ?? Int64((channel.joinedAt ?? .distantPast).timeIntervalSince1970 * 1000)
    }

    /// Curated language rooms not opened yet - offered for discovery under "Other Languages".
    private var unjoinedLanguageChannels: [String] {
        let joined = Set(publicChatService.channels.map(\.channelName))
        return PublicChatService.languageChannels.filter {
            !joined.contains($0) && publicChatService.isCuratedChannelShown($0)
        }
    }

    private func roomRow(_ channel: PublicChatChannel) -> some View {
        Button {
            selectedChannel = channel.channelName
        } label: {
            PublicChatRow(channelName: channel.channelName, channel: channel)
        }
        .buttonStyle(.plain)
        // A Button label needs simultaneousGesture for the long press (as in the chat lists).
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                Haptics.impact(.medium)
                roomActionTarget = channel.channelName
            }
        )
        .listRowBackground(Color.clear)
    }

    private var combinedList: some View {
        List {
            ForEach(listedChannels) { channel in
                roomRow(channel)
            }

            if !unjoinedLanguageChannels.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { languagesExpanded.toggle() }
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color.accentColor.opacity(0.2))
                            .frame(width: 50, height: 50)
                            .overlay(Image(systemName: "globe").font(.system(size: 20)).foregroundColor(.accentColor))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Other Languages").font(.headline)
                            Text("\(unjoinedLanguageChannels.count) rooms").font(.subheadline).foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(languagesExpanded ? 0 : -90))
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)

                if languagesExpanded {
                    ForEach(unjoinedLanguageChannels, id: \.self) { name in
                        Button {
                            openCuratedChannel(name)
                        } label: {
                            PublicChatRow(channelName: name, channel: nil)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                    }
                }
            }

            Text("Public rooms are open to everyone. #kaspa, #kachat-bugs and the language rooms keep 30 days of history.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        // The same floating button the Chats and Group Chats pages carry, here for joining or
        // creating a room.
        .overlay(alignment: .bottomTrailing) {
            Button {
                Haptics.impact(.light)
                joinFieldText = ""
                joinError = nil
                showJoinAlert = true
            } label: {
                Image(systemName: "plus.bubble")
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
            .accessibilityLabel("Join or create a public room")
            .padding(.trailing, 20)
            .padding(.bottom, 16)
        }
        .onAppear { publicChatService.primeChannelSummaries() }
        .onChange(of: publicChatService.channels) { _ in publicChatService.primeChannelSummaries() }
        .sheet(item: Binding(
            get: { roomActionTarget.map(RoomActionTarget.init) },
            set: { if $0 == nil { roomActionTarget = nil } }
        )) { target in
            roomActionSheet(for: target.id)
        }
    }

    private struct RoomActionTarget: Identifiable { let id: String }

    /// The long-press half sheet, same shape as a group's: read state, notifications, the room
    /// link, and - for rooms you added yourself - listening, retention and delete. Curated rooms
    /// are permanent, so they offer no delete.
    @ViewBuilder
    private func roomActionSheet(for name: String) -> some View {
        let channel = publicChatService.channels.first { $0.channelName == name }
        let isCurated = PublicChatService.indexedChannels.contains(name)
        let notifyOn = channel?.notifyEnabled ?? false
        VStack(spacing: 12) {
            Text("#\(name)")
                .font(.headline)
                .lineLimit(1)
                .padding(.top, 20)
                .padding(.bottom, 4)

            if publicChatService.unreadCount(forChannel: name) > 0 {
                ActionSheetRow(title: "Mark as Read", subtitle: "Clears the unread badge on this room.", systemImage: "envelope.open") {
                    roomActionTarget = nil
                    publicChatService.markChannelRead(name)
                }
            } else {
                ActionSheetRow(title: "Mark as Unread", subtitle: "Puts the unread badge back so you come across it again.", systemImage: "envelope.badge") {
                    roomActionTarget = nil
                    publicChatService.markChannelUnread(name)
                }
            }

            ActionSheetRow(
                title: notifyOn ? "Turn Off Notifications" : "Turn On Notifications",
                subtitle: notifyOn
                    ? "No notification for new messages in this room."
                    : (isCurated ? "Notifies you of new messages, even when the app is closed."
                                 : "Notifies you of new messages while the app is open."),
                systemImage: notifyOn ? "bell.slash" : "bell"
            ) {
                roomActionTarget = nil
                if let channel { toggleNotify(channel) }
            }

            ActionSheetRow(title: "Copy Room Link", subtitle: "A kachat.app link that opens this room.", systemImage: "link") {
                roomActionTarget = nil
                UIPasteboard.general.string = KaChatInternalLink.publicChatRoom(channel: name).universalLinkString
                showToast("Room link copied")
            }

            if channel != nil, !isCurated {
                ActionSheetRow(title: "Delete", subtitle: "Removes this room and its messages from this device.", systemImage: "trash", tint: .red) {
                    roomActionTarget = nil
                    // One sheet closing, another opening: give the first its dismissal, or
                    // the second is silently dropped.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { channelToLeave = name }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(isCurated ? 330 : 410)])
        .presentationDragIndicator(.visible)
    }

    /// Opens a curated room, creating its store row first when it has none (the language rooms
    /// are not auto-joined). `joinChannel` is a no-op for an already-joined room.
    private func openCuratedChannel(_ name: String) {
        if !publicChatService.channels.contains(where: { $0.channelName == name }) {
            publicChatService.joinChannel(name)
        }
        selectedChannel = name
    }

    private func toggleNotify(_ channel: PublicChatChannel) {
        let newValue = !channel.notifyEnabled
        publicChatService.setNotifyEnabled(newValue, forChannel: channel.channelName)
        let isIndexed = PublicChatService.indexedChannels.contains(channel.channelName)
        showToast(newValue
            ? (isIndexed
                ? "You'll get notifications for new messages in this public chat, even when the app is closed"
                : "You'll get a notification for new messages in this public chat as long as your app remains open")
            : "Notifications are off for this public chat")
    }

    private func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }

    /// Joining and creating are the same action here - there is no ownership protocol, so a name
    /// nobody has used yet becomes a room the moment you post in it. A sheet rather than an alert
    /// because that is worth a sentence, and an alert's text field is a cramped afterthought.
    private var joinChannelSheet: some View {
        VStack(spacing: 12) {
            Text("Join or Create a Channel")
                .font(.headline)
                .padding(.top, 20)

            Text("Anyone who joins the same channel name can see and post messages there - there is no owner and no invite.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 4)

            HStack(spacing: 4) {
                Text("#")
                    .font(.headline)
                    .foregroundColor(.secondary)
                TextField("channel-name", text: $joinFieldText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.join)
                    .focused($joinFieldFocused)
                    .onSubmit { submitJoin() }
            }
            .padding(14)
            .background(glassBackground(cornerRadius: 16))

            HStack(spacing: 12) {
                Button("Cancel") { showJoinAlert = false }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundColor(.primary)
                    .background(glassBackground(cornerRadius: 16))

                Button("Join", action: submitJoin)
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundColor(.black)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.accentColor.opacity(joinIsEmpty ? 0.4 : 1))
                    )
                    .disabled(joinIsEmpty)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
        // A turn later: the field does not exist yet on the tap that presented this.
        .onAppear { DispatchQueue.main.async { joinFieldFocused = true } }
    }

    private var joinIsEmpty: Bool {
        joinFieldText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Closes first, then joins: `join` sets `joinError`, whose alert cannot present while this
    /// sheet is still up.
    private func submitJoin() {
        guard !joinIsEmpty else { return }
        let name = joinFieldText
        showJoinAlert = false
        DispatchQueue.main.async { _ = join(name) }
    }

    @discardableResult
    private func join(_ rawName: String) -> Bool {
        let normalized = PublicChatChannelName.normalize(rawName)
        guard PublicChatChannelName.isValid(normalized) else {
            joinError = "Channel names must be 1-\(PublicChatChannelName.maxLength) characters with no spaces or colons."
            return false
        }
        guard publicChatService.joinChannel(normalized) else {
            joinError = "Something went wrong joining that channel."
            return false
        }
        joinFieldText = ""
        Haptics.success()
        return true
    }
}

/// The app's frosted card. Every file that draws one carries its own file-private copy; this
/// one is for the join sheet.
private func glassBackground(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
}

/// `.navigationDestination(item:)` (iOS 17+) rather than `isPresented:` + a synthetic get/set
/// boolean: popping back (native back button/swipe) and immediately pushing a different channel
/// both drive the same destination, and toggling a hand-rolled boolean true→false→true in quick
/// succession can race with UIKit's own pop animation/cleanup, leaving the next push silently
/// inert until the list view is torn down and recreated. Binding directly to the optional item is
/// the API SwiftUI provides specifically for this swap; iOS 16 falls back to the older, slightly
/// more race-prone pattern since `item:` isn't available there.
struct PublicChatChannelDestination: ViewModifier {
    @Binding var selectedChannel: String?

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.navigationDestination(item: $selectedChannel) { channel in
                // `.id` forces a fresh `PublicChatChannelView` (not just a `channelName` update to
                // the existing one) when switching rooms in place, so `onAppear`/`onDisappear`
                // re-fire to correctly swap the live-view acquire/release tracking, and per-room
                // state (draft text, reply-in-progress, etc.) resets instead of leaking across
                // channels.
                PublicChatChannelView(channelName: channel)
                    .id(channel)
            }
        } else {
            content.navigationDestination(isPresented: Binding(
                get: { selectedChannel != nil },
                set: { if !$0 { selectedChannel = nil } }
            )) {
                if let selectedChannel {
                    PublicChatChannelView(channelName: selectedChannel)
                        .id(selectedChannel)
                } else {
                    EmptyView()
                }
            }
        }
    }
}

/// One public room, drawn like a chat row: a "#" avatar, the room name, the newest message and
/// its time, a bell-off mark when notifications are off, and the unread count.
struct PublicChatRow: View {
    let channelName: String
    /// nil for a curated room not opened yet (no store row): shows its language name instead.
    let channel: PublicChatChannel?
    @EnvironmentObject var publicChatService: PublicChatService
    @ObservedObject private var knsService = KNSService.shared

    private var lastMessage: PublicChatMessage? {
        publicChatService.messages(forChannel: channelName).last
    }

    private func senderName(_ address: String) -> String {
        if address == WalletManager.shared.currentWallet?.publicAddress { return "You" }
        if let assigned = ContactsManager.shared.getContact(byAddress: address)?.assignedName { return assigned }
        if let domain = knsService.profileCache[address]?.domainName, !domain.isEmpty { return domain }
        return Contact.generateDefaultAlias(from: address)
    }

    private func timeText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return SharedFormatting.chatTime.string(from: date) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private var emptyText: String {
        guard channel == nil else { return "No messages yet" }
        return PublicChatService.languageDisplayName(for: channelName).map { "\($0) - tap to open" } ?? "Tap to open"
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.accentColor.opacity(0.2))
                .frame(width: 50, height: 50)
                .overlay(
                    Text("#")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(.accentColor)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("#\(channelName)")
                        .font(.headline)
                        .lineLimit(1)
                    if let channel, !channel.notifyEnabled {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .accessibilityLabel("Notifications off")
                    }
                    Spacer()
                    if let lastMessage {
                        Text(timeText(Date(timeIntervalSince1970: TimeInterval(lastMessage.blockTime) / 1000)))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                HStack {
                    if let lastMessage {
                        Text("\(senderName(lastMessage.senderAddress)): \(LinkSafePreview.apply(to: MessageReplyCodec.previewText(for: lastMessage.content)))")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(emptyText)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .italic()
                    }
                    Spacer()
                    let unread = channel == nil ? 0 : publicChatService.unreadCount(forChannel: channelName)
                    if unread > 0 {
                        Text("\(unread)")
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
}

/// Public Chats settings, behind the gear at the top right of the tab: every default room with
/// a switch. Off takes the room out of the list and silences it for good; on brings it back.
struct PublicChatsSettingsView: View {
    @EnvironmentObject var publicChatService: PublicChatService
    @Environment(\.dismiss) private var dismiss

    private func row(_ name: String) -> some View {
        Toggle(isOn: Binding(
            get: { publicChatService.isCuratedChannelShown(name) },
            set: { publicChatService.setCuratedChannel(name, shown: $0) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("#\(name)")
                if let language = PublicChatService.languageDisplayName(for: name) {
                    Text(language)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(PublicChatService.featuredChannels, id: \.self) { row($0) }
                } header: {
                    Text("Popular")
                } footer: {
                    Text("A room that is switched off no longer appears in Public Chats and never sends a notification. Switch it back on at any time.")
                }
                Section("Other Languages") {
                    ForEach(PublicChatService.languageChannels, id: \.self) { row($0) }
                }
            }
            .navigationTitle("Public Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
