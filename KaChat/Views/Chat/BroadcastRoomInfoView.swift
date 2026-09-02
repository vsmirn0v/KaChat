import SwiftUI

/// Everything about one broadcast room that is not the messages: what it is, what is in it, how
/// to share it, who you have hidden, and which indexer it reads from.
///
/// Reached by tapping the `#name` title in the room. It replaced two toolbar buttons (share and
/// hidden users) that had no room to say what they were, and gave the per-room indexer somewhere
/// to live that is not the app-wide Connection Settings.
struct BroadcastRoomInfoView: View {
    let channelName: String

    @EnvironmentObject var broadcastService: BroadcastService

    @State private var indexerText: String = ""
    @State private var toastMessage: String?

    /// What the last Save attempt did. The point of testing is that a typo in an indexer URL is
    /// otherwise silent - the room just stops filling in, with nothing to say why.
    private enum IndexerCheck: Equatable {
        case idle
        case checking
        case reachable(Int)
        case failed(String)
    }
    @State private var indexerCheck: IndexerCheck = .idle

    private var normalized: String { BroadcastChannelName.normalize(channelName) }

    private var isCurated: Bool {
        BroadcastService.indexedChannels.contains(normalized)
    }

    private var messages: [BroadcastMessage] {
        broadcastService.messages(forChannel: normalized)
    }

    /// Everyone who has said something in what this device is holding. Not "members" - a
    /// broadcast room has no membership, anyone can post to it - so it is deliberately labelled
    /// as what it is.
    private var participantCount: Int {
        Set(messages.map(\.senderAddress)).count
    }

    private var oldestMessageDate: Date? {
        messages.map(\.blockTime).min().map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    private var latestMessageDate: Date? {
        messages.map(\.blockTime).max().map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    private var hiddenCount: Int {
        broadcastService.hiddenSenderAddresses(forChannel: normalized).count
    }

    private var channel: BroadcastChannel? {
        broadcastService.channels.first { $0.channelName == normalized }
    }

    private var retentionDescription: String? {
        guard let millis = channel?.retentionMillis, millis > 0 else { return nil }
        let days = Int((Double(millis) / 86_400_000).rounded())
        return days == 1 ? "1 day" : "\(days) days"
    }

    private var shareText: String {
        KaChatInternalLink.broadcastRoomShareText(channel: normalized)
    }

    /// What the field's placeholder should say: the app-wide indexer this room falls back to.
    private var appWideIndexer: String {
        let configured = AppSettings.load().broadcastIndexerURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? AppSettings.defaultBroadcastIndexerURL : configured
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Room") { Text("#\(normalized)") }
                if let language = BroadcastService.languageDisplayName(for: normalized) {
                    LabeledContent("Language") { Text(language) }
                }
                LabeledContent("Kind") {
                    Text(isCurated ? "Popular" : "Added by you")
                }
                if let joined = channel?.joinedAt {
                    LabeledContent("Joined") {
                        Text(joined.formatted(date: .abbreviated, time: .omitted))
                    }
                }
            } footer: {
                Text(isCurated
                     ? "A curated room, always in your list. Anyone running KaChat can post to it."
                     : "A room you added. Anyone who knows the name can post to it.")
            }

            Section("On this device") {
                LabeledContent("Messages") { Text("\(messages.count)") }
                LabeledContent("People who posted") { Text("\(participantCount)") }
                if let latest = latestMessageDate {
                    LabeledContent("Latest") {
                        Text(latest.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                if let oldest = oldestMessageDate {
                    LabeledContent("Oldest held") {
                        Text(oldest.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                if let retentionDescription {
                    LabeledContent("Kept for") { Text(retentionDescription) }
                }
            }

            Section {
                ShareLink(item: shareText) {
                    Label("Share this room", systemImage: "square.and.arrow.up")
                }
                NavigationLink {
                    HiddenBroadcastSendersView(channel: normalized)
                } label: {
                    LabeledContent {
                        Text("\(hiddenCount)")
                    } label: {
                        Label("Hidden users", systemImage: "person.crop.circle.badge.xmark")
                    }
                }
            } footer: {
                Text("Sharing sends a link that opens this room in KaChat, and a web link for anyone without it. Hiding is per room: someone hidden here still shows in every other room.")
            }

            Section {
                TextField(appWideIndexer, text: $indexerText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.done)
                    .onSubmit { saveIndexer() }

                indexerCheckRow

                Button {
                    saveIndexer()
                } label: {
                    HStack {
                        Text("Save").fontWeight(.semibold)
                        Spacer()
                        if indexerCheck == .checking { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(indexerCheck == .checking || !indexerChanged)

                if !indexerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Use the app's indexer", role: .destructive) {
                        indexerText = ""
                        saveIndexer()
                    }
                }
            } header: {
                Text("Indexer for this room")
            } footer: {
                // The honest explanation of why this is per room at all.
                Text("A broadcast lives on the Kaspa blockDAG, so any indexer watching the same network serves the same room. Point this one wherever you like - your own, or someone else's - without changing the indexer every other room uses. Leave it blank to follow \(appWideIndexer).")
            }
        }
        .navigationTitle("Room Info")
        .navigationBarTitleDisplayMode(.inline)
        .toast(message: toastMessage, style: .success)
        .onAppear {
            indexerText = broadcastService.indexerOverride(forChannel: normalized)
        }
    }

    /// Its own property: this switch inside the Form pushed the body past what the type checker
    /// will spend on one expression.
    @ViewBuilder
    private var indexerCheckRow: some View {
        switch indexerCheck {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking the indexer...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .reachable(let count):
            Label(
                count == 0
                    ? "Connected. It holds nothing for this room yet."
                    : "Connected, and it has this room's messages.",
                systemImage: "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundColor(.green)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.orange)
        }
    }

    private var indexerChanged: Bool {
        indexerText.trimmingCharacters(in: .whitespacesAndNewlines)
            != broadcastService.indexerOverride(forChannel: normalized)
    }

    /// Saves the override, then asks the indexer for this room. A wrong URL is otherwise silent:
    /// the room simply stops filling in, with nothing on screen to say why.
    private func saveIndexer() {
        let trimmed = indexerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != broadcastService.indexerOverride(forChannel: normalized) else { return }
        broadcastService.setIndexerOverride(trimmed, forChannel: normalized)
        toastMessage = trimmed.isEmpty
            ? "This room follows the app's indexer again."
            : "Indexer updated for #\(normalized)."

        // Whichever one the room now reads from - the override just saved, or the app-wide one
        // a cleared field falls back to.
        let target = trimmed.isEmpty ? appWideIndexer : trimmed
        indexerCheck = .checking
        Task {
            do {
                let page = try await BroadcastIndexerClient.fetchHistoryPage(
                    baseURL: target,
                    channel: normalized,
                    limit: 1
                )
                indexerCheck = .reachable(page.messages.count)
            } catch {
                indexerCheck = .failed("Could not reach it: \(error.localizedDescription)")
            }
        }
    }
}
