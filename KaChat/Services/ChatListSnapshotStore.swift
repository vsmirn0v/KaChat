import Foundation

enum ChatListSnapshotStore {
    private struct Snapshot: Codable {
        let version: Int
        let conversations: [SnapshotConversation]
    }

    private struct SnapshotConversation: Codable {
        let id: UUID
        let contact: Contact
        let lastMessage: ChatMessage?
        let unreadCount: Int
    }

    private static let currentVersion = 1
    private static let keyPrefix = "kachat_chat_list_snapshot_"

    static func load(walletAddress: String, userDefaults: UserDefaults = .standard) -> [Conversation] {
        guard let data = userDefaults.data(forKey: key(for: walletAddress)),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == currentVersion else {
            return []
        }

        return snapshot.conversations.map { cached in
            Conversation(
                id: cached.id,
                contact: cached.contact,
                messages: cached.lastMessage.map { [$0] } ?? [],
                unreadCount: cached.unreadCount
            )
        }
    }

    static func save(
        _ conversations: [Conversation],
        walletAddress: String,
        userDefaults: UserDefaults = .standard
    ) {
        let cachedConversations = conversations.map { conversation in
            SnapshotConversation(
                id: conversation.id,
                contact: conversation.contact,
                lastMessage: conversation.lastMessage,
                unreadCount: conversation.unreadCount
            )
        }
        let snapshot = Snapshot(version: currentVersion, conversations: cachedConversations)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        userDefaults.set(data, forKey: key(for: walletAddress))
    }

    static func clear(walletAddress: String, userDefaults: UserDefaults = .standard) {
        userDefaults.removeObject(forKey: key(for: walletAddress))
    }

    private static func key(for walletAddress: String) -> String {
        keyPrefix + walletAddress
    }
}
