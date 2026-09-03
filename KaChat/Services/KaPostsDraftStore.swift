import Foundation

/// A post saved for later: the whole composer state, not just its text.
///
/// Stored per wallet and never sent anywhere - a draft is a private note to yourself until you
/// deliberately post it, so it has no on-chain footprint at all.
struct KaPostSavedDraft: Codable, Identifiable, Equatable {
    let id: UUID
    /// The in-progress text, i.e. what was in the editor when it was saved.
    var text: String
    /// Earlier segments of a thread, in order. Empty for a single post.
    var threadSegments: [String]
    /// The post being quoted, if the draft was written as a quote. Only the remote id is kept -
    /// the quoted post itself is re-fetched on open, so a draft never carries a stale copy.
    var quotedRemoteId: String?
    var savedAt: Date

    /// One line for the drafts list: the first segment that has anything in it.
    var preview: String {
        let first = ([text] + threadSegments).first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return (first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Everything this draft would post, for the "3 posts" count on its row.
    var segmentCount: Int {
        ([text] + threadSegments).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }
}

/// Local, per-wallet storage for saved post drafts.
///
/// Deliberately local-only and unsynced. A draft is unfinished writing; putting it on chain or in
/// a backup would publish something the author never chose to publish.
@MainActor
final class KaPostsDraftStore: ObservableObject {
    static let shared = KaPostsDraftStore()

    @Published private(set) var drafts: [KaPostSavedDraft] = []

    private let baseKey = "kachat_kaposts_drafts"
    private var loadedWallet: String?

    private init() { reloadForCurrentWallet() }

    private var scopedKey: String? {
        guard let address = WalletManager.shared.currentWallet?.publicAddress, !address.isEmpty else { return nil }
        return "\(baseKey)_\(address.replacingOccurrences(of: ":", with: "_"))"
    }

    /// Re-reads for whichever wallet is active now. Cheap and idempotent, so callers can just
    /// call it when a drafts surface appears rather than tracking wallet changes themselves.
    func reloadForCurrentWallet() {
        let address = WalletManager.shared.currentWallet?.publicAddress
        guard let key = scopedKey else {
            drafts = []
            loadedWallet = nil
            return
        }
        if loadedWallet == address, !drafts.isEmpty { return }
        loadedWallet = address
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([KaPostSavedDraft].self, from: data) else {
            drafts = []
            return
        }
        drafts = decoded.sorted { $0.savedAt > $1.savedAt }
    }

    /// Saves a new draft, or updates `id` when re-saving one that was opened for editing.
    @discardableResult
    func save(
        id: UUID? = nil,
        text: String,
        threadSegments: [String],
        quotedRemoteId: String?
    ) -> KaPostSavedDraft? {
        let hasContent = !([text] + threadSegments)
            .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard hasContent else { return nil }

        let draft = KaPostSavedDraft(
            id: id ?? UUID(),
            text: text,
            threadSegments: threadSegments,
            quotedRemoteId: quotedRemoteId,
            savedAt: Date()
        )
        drafts.removeAll { $0.id == draft.id }
        drafts.insert(draft, at: 0)
        persist()
        return draft
    }

    func delete(_ id: UUID) {
        guard drafts.contains(where: { $0.id == id }) else { return }
        drafts.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let key = scopedKey, let data = try? JSONEncoder().encode(drafts) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
