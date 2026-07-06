import Foundation

@main
struct ChatListSnapshotStoreTest {
    static func main() {
        let suiteName = "ChatListSnapshotStoreTest-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fputs("FAIL: could not create isolated UserDefaults\n", stderr)
            exit(1)
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let walletAddress = "kaspa:test-wallet"
        let contact = Contact(address: "kaspa:test-contact", alias: "Test Contact")
        let first = ChatMessage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            txId: "tx-1",
            senderAddress: walletAddress,
            receiverAddress: contact.address,
            content: "Older",
            timestamp: Date(timeIntervalSince1970: 100),
            blockTime: 100,
            isOutgoing: true
        )
        let latest = ChatMessage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            txId: "tx-2",
            senderAddress: contact.address,
            receiverAddress: walletAddress,
            content: "Latest",
            timestamp: Date(timeIntervalSince1970: 200),
            blockTime: 200,
            isOutgoing: false
        )
        let conversation = Conversation(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            contact: contact,
            messages: [first, latest],
            unreadCount: 3
        )

        ChatListSnapshotStore.save([conversation], walletAddress: walletAddress, userDefaults: defaults)
        let loaded = ChatListSnapshotStore.load(walletAddress: walletAddress, userDefaults: defaults)

        expect(loaded.count == 1, "expected one cached conversation")
        expect(loaded[0].id == conversation.id, "conversation id should be preserved")
        expect(loaded[0].contact == contact, "contact should be preserved")
        expect(loaded[0].unreadCount == 3, "unread count should be preserved")
        expect(loaded[0].messages.map(\.txId) == ["tx-2"], "only the latest message should be cached")

        ChatListSnapshotStore.clear(walletAddress: walletAddress, userDefaults: defaults)
        expect(
            ChatListSnapshotStore.load(walletAddress: walletAddress, userDefaults: defaults).isEmpty,
            "clear should remove the cached snapshot"
        )

        print("PASS: ChatListSnapshotStore")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
