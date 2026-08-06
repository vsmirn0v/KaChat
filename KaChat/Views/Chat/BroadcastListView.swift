import SwiftUI

/// A per-channel local retention setting: how long messages stay cached on this device once
/// joined, up to `BroadcastStore.maxRetentionMillis`. Mirrors Android's `BroadcastRetention.Unit`.
enum BroadcastRetentionUnit: String, CaseIterable, Identifiable {
    case seconds, minutes, hours, days

    var id: String { rawValue }
    var label: String { rawValue }

    var millisPerUnit: Int64 {
        switch self {
        case .seconds: return 1_000
        case .minutes: return 60_000
        case .hours: return 60 * 60 * 1_000
        case .days: return 24 * 60 * 60 * 1_000
        }
    }

    var maxAmount: Int64 {
        BroadcastStore.maxRetentionMillis / millisPerUnit
    }

    /// Splits a stored millis value into an (amount, unit) pair for pre-filling the retention
    /// sheet - picks the largest unit that divides it evenly, falling back to seconds.
    static func fromMillis(_ millis: Int64) -> (amount: Int64, unit: BroadcastRetentionUnit) {
        for unit in [BroadcastRetentionUnit.days, .hours, .minutes] {
            let amount = millis / unit.millisPerUnit
            if millis % unit.millisPerUnit == 0, amount >= 1, amount <= unit.maxAmount {
                return (amount, unit)
            }
        }
        return (max(1, millis / BroadcastRetentionUnit.seconds.millisPerUnit), .seconds)
    }
}

/// Join/create broadcast channels and browse joined + popular channels.
/// Pushed from `ChatListView`'s "Broadcasts" row - mirrors Android's placement
/// (reachable from the Chats screen, not a separate tab) while keeping iOS's own
/// list/row visual language.
struct BroadcastListView: View {
    @EnvironmentObject var broadcastService: BroadcastService

    /// Channel to auto-push into on first appearance - set when this view is opened by tapping a
    /// broadcast-room notification (see `ChatListView.navigateToBroadcast`), so the notification
    /// lands the user directly in the room instead of just this list.
    let initialChannel: String?

    @State private var showJoinAlert = false
    @State private var joinFieldText = ""
    @State private var joinError: String?
    @State private var selectedChannel: String?
    @State private var channelToLeave: String?
    @State private var retentionSettingsChannel: BroadcastChannel?
    @State private var showBroadcastSettings = false
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var hasAppliedInitialChannel = false

    init(initialChannel: String? = nil) {
        self.initialChannel = initialChannel
    }

    var body: some View {
        Group {
            switch BroadcastNavigationPolicy.currentChannelPresentationMode {
            case .inlineReplacement:
                if let selectedChannel {
                    inlineChannelView(selectedChannel)
                } else {
                    broadcastListContent
                }
            case .navigationDestination:
                broadcastListContent
                    .modifier(BroadcastChannelDestination(selectedChannel: $selectedChannel))
            }
        }
        .onAppear {
            // The curated Popular channels always have store rows so their bell state exists
            // before first entry.
            broadcastService.ensureFeaturedChannelsJoined()
            broadcastService.refreshChannels()
            if !hasAppliedInitialChannel, let initialChannel {
                hasAppliedInitialChannel = true
                selectedChannel = initialChannel
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openBroadcast)) { notification in
            // Already viewing the broadcast list (or a room within it) when another broadcast
            // notification is tapped - swap straight to the new room instead of no-oping, since
            // `ChatListView`'s own handling only covers opening the list from scratch.
            guard let channel = notification.userInfo?["channel"] as? String else { return }
            selectedChannel = channel
        }
        .onChange(of: broadcastService.pendingBroadcastNavigation) { newValue in
            guard let channel = newValue else { return }
            selectedChannel = channel
        }
    }

    private var broadcastListContent: some View {
        // One page, no tabs: the curated Popular rooms pinned on top (enter/exit freely, no
        // leaving - they're permanent), then everything the user joined under Your Channels.
        combinedList
        .navigationTitle("Broadcasts")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showBroadcastSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    joinFieldText = ""
                    joinError = nil
                    showJoinAlert = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .toast(message: toastMessage, style: .success)
        .alert("Join or Create a Channel", isPresented: $showJoinAlert) {
            TextField("channel-name", text: $joinFieldText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Join") { join(joinFieldText) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anyone who joins the same channel name can see and post messages there - there's no owner or invite.")
        }
        .alert("Couldn't Join Channel", isPresented: Binding(
            get: { joinError != nil },
            set: { if !$0 { joinError = nil } }
        )) {
            Button("OK", role: .cancel) { joinError = nil }
        } message: {
            Text(joinError ?? "")
        }
        .alert(
            channelToLeave.map { "Leave #\($0)" } ?? "Leave Channel",
            isPresented: Binding(
                get: { channelToLeave != nil },
                set: { if !$0 { channelToLeave = nil } }
            )
        ) {
            Button("Leave & Delete", role: .destructive) {
                if let channelToLeave {
                    broadcastService.leaveChannel(channelToLeave)
                }
                channelToLeave = nil
            }
            Button("Cancel", role: .cancel) { channelToLeave = nil }
        } message: {
            Text("Leaving this broadcast permanently deletes every message cached for it on this device. This cannot be undone - rejoining later starts with no history.")
        }
        .sheet(item: $retentionSettingsChannel) { channel in
            NavigationStack {
                RetentionSettingsView(channel: channel)
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showBroadcastSettings) {
            NavigationStack {
                BroadcastSettingsView()
            }
            .presentationDetents([.large])
        }
    }

    private func inlineChannelView(_ channel: String) -> some View {
        BroadcastChannelView(channelName: channel)
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

    private var combinedList: some View {
        List {
            Section {
                ForEach(BroadcastService.featuredChannels, id: \.self) { name in
                    let channel = broadcastService.channels.first { $0.channelName == name }
                    HStack(spacing: 4) {
                        Button {
                            selectedChannel = name
                        } label: {
                            Text("#\(name)")
                                .font(.body)
                                .fontWeight(.bold)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        // Curated rooms are permanent (no Leave) with fixed 3-day retention
                        // (no gear) and indexer-backed history (no listen toggle) - the bell
                        // is the only control, gating in-app banners AND remote push.
                        if let channel {
                            Button {
                                toggleNotify(channel)
                            } label: {
                                Image(systemName: channel.notifyEnabled ? "bell.fill" : "bell.slash")
                                    .foregroundColor(channel.notifyEnabled ? .accentColor : .secondary)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(16)
                    .background(Color(UIColor.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            } header: {
                sectionHeader("Popular")
            }

            Section {
                let ownChannels = broadcastService.channels.filter {
                    !BroadcastService.featuredChannels.contains($0.channelName)
                }
                if ownChannels.isEmpty {
                    Text("No channels yet - tap + to join or create one.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                } else {
                    ForEach(ownChannels) { channel in
                        ownChannelRow(channel)
                    }
                }
            } header: {
                sectionHeader("Your Channels")
            }
        }
        .listStyle(.plain)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.bold))
            .foregroundColor(.accentColor)
            .textCase(nil)
            .padding(.leading, 4)
    }

    private func ownChannelRow(_ channel: BroadcastChannel) -> some View {
        HStack(spacing: 4) {
            Button {
                selectedChannel = channel.channelName
            } label: {
                Text("#\(channel.channelName)")
                    .font(.body)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                toggleAlwaysListen(channel)
            } label: {
                Image(systemName: channel.alwaysListen ? "speaker.wave.2.fill" : "speaker.slash")
                    .foregroundColor(channel.alwaysListen ? .accentColor : .secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)

            Button {
                toggleNotify(channel)
            } label: {
                Image(systemName: channel.notifyEnabled ? "bell.fill" : "bell.slash")
                    .foregroundColor(channel.notifyEnabled ? .accentColor : .secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)

            Button {
                retentionSettingsChannel = channel
            } label: {
                Image(systemName: "gearshape")
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)

            Button {
                channelToLeave = channel.channelName
            } label: {
                Text("Leave")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .background(Color(UIColor.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                channelToLeave = channel.channelName
            } label: {
                Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    private func toggleAlwaysListen(_ channel: BroadcastChannel) {
        let newValue = !channel.alwaysListen
        broadcastService.setAlwaysListen(newValue, forChannel: channel.channelName)
        showToast(newValue
            ? "You will now listen for new chats as long as your app remains open"
            : "You will no longer see messages in this broadcast unless you are in the broadcast at the same time chats come in")
    }

    private func toggleNotify(_ channel: BroadcastChannel) {
        let newValue = !channel.notifyEnabled
        broadcastService.setNotifyEnabled(newValue, forChannel: channel.channelName)
        let isIndexed = BroadcastService.featuredChannels.contains(channel.channelName)
        showToast(newValue
            ? (isIndexed
                ? "You'll get notifications for new messages in this broadcast, even when the app is closed"
                : "You'll get a notification for new messages in this broadcast as long as your app remains open")
            : "Notifications are off for this broadcast")
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

    @discardableResult
    private func join(_ rawName: String) -> Bool {
        let normalized = BroadcastChannelName.normalize(rawName)
        guard BroadcastChannelName.isValid(normalized) else {
            joinError = "Channel names must be 1-\(BroadcastChannelName.maxLength) characters with no spaces or colons."
            return false
        }
        guard broadcastService.joinChannel(normalized) else {
            joinError = "Something went wrong joining that channel."
            return false
        }
        joinFieldText = ""
        Haptics.success()
        return true
    }
}

/// `.navigationDestination(item:)` (iOS 17+) rather than `isPresented:` + a synthetic get/set
/// boolean: popping back (native back button/swipe) and immediately pushing a different channel
/// both drive the same destination, and toggling a hand-rolled boolean true→false→true in quick
/// succession can race with UIKit's own pop animation/cleanup, leaving the next push silently
/// inert until the list view is torn down and recreated. Binding directly to the optional item is
/// the API SwiftUI provides specifically for this swap; iOS 16 falls back to the older, slightly
/// more race-prone pattern since `item:` isn't available there.
private struct BroadcastChannelDestination: ViewModifier {
    @Binding var selectedChannel: String?

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.navigationDestination(item: $selectedChannel) { channel in
                // `.id` forces a fresh `BroadcastChannelView` (not just a `channelName` update to
                // the existing one) when switching rooms in place, so `onAppear`/`onDisappear`
                // re-fire to correctly swap the live-view acquire/release tracking, and per-room
                // state (draft text, reply-in-progress, etc.) resets instead of leaking across
                // channels.
                BroadcastChannelView(channelName: channel)
                    .id(channel)
            }
        } else {
            content.navigationDestination(isPresented: Binding(
                get: { selectedChannel != nil },
                set: { if !$0 { selectedChannel = nil } }
            )) {
                if let selectedChannel {
                    BroadcastChannelView(channelName: selectedChannel)
                        .id(selectedChannel)
                } else {
                    EmptyView()
                }
            }
        }
    }
}

/// Per-channel message retention settings, matching Android's retention dialog.
private struct RetentionSettingsView: View {
    let channel: BroadcastChannel
    @EnvironmentObject var broadcastService: BroadcastService
    @Environment(\.dismiss) private var dismiss

    @State private var amountText: String
    @State private var selectedUnit: BroadcastRetentionUnit

    init(channel: BroadcastChannel) {
        self.channel = channel
        let (amount, unit) = BroadcastRetentionUnit.fromMillis(channel.retentionMillis)
        _amountText = State(initialValue: String(amount))
        _selectedUnit = State(initialValue: unit)
    }

    private var amount: Int64? { Int64(amountText) }
    private var isValid: Bool {
        guard let amount else { return false }
        return amount >= 1 && amount <= selectedUnit.maxAmount
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Amount", text: $amountText)
                        .keyboardType(.numberPad)
                    Picker("Unit", selection: $selectedUnit) {
                        ForEach(BroadcastRetentionUnit.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text("Message Retention for #\(channel.channelName)")
            } footer: {
                Text("How long messages in this broadcast stay cached on this device, up to a maximum of 3 days. Max: \(selectedUnit.maxAmount) \(selectedUnit.label).")
            }

            Section {
                Text("Longer retention means more messages stay cached on your device - this can slow the app down over time, especially for busy rooms.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .navigationTitle("Message Retention")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") {
                    // Dismiss first, then apply on the next run-loop tick: `setRetentionMillis`
                    // prunes messages and mutates `@Published channels`/`messagesByChannel`, which
                    // the presenting `BroadcastListView` observes for both this sheet and its own
                    // `navigationDestination(isPresented:)` push into a room - mutating that state
                    // in the same transaction as `dismiss()` races SwiftUI's presentation
                    // bookkeeping and can leave a room's row tap silently inert until the list view
                    // is torn down and recreated (e.g. backing out to Chats and back in).
                    let millis = amount.map { $0 * selectedUnit.millisPerUnit }
                    dismiss()
                    if let millis {
                        DispatchQueue.main.async {
                            broadcastService.setRetentionMillis(millis, forChannel: channel.channelName)
                        }
                    }
                }
                .disabled(!isValid)
            }
        }
    }
}

/// Global broadcast settings, matching Android's "Broadcast Settings" dialog.
private struct BroadcastSettingsView: View {
    @EnvironmentObject var broadcastService: BroadcastService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { broadcastService.showKnsAvatarsEnabled },
                    set: { broadcastService.setShowKnsAvatarsEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("KNS Profile Pictures")
                        Text("Shows senders' KNS avatars in rooms and looks them up automatically as messages appear. Off shows plain initials for everyone and never fetches avatars.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section {
                NavigationLink {
                    HiddenBroadcastSendersView()
                } label: {
                    HStack {
                        Text("Hidden Broadcast Room Users")
                        Spacer()
                        Text("\(broadcastService.hiddenSenderAddresses().count)")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Broadcast Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }
}

#Preview {
    NavigationStack {
        BroadcastListView()
            .environmentObject(BroadcastService.shared)
    }
}
