import SwiftUI

/// Search across KaPosts: posts by their text, and the people who wrote them.
///
/// CLIENT-SIDE, because the K indexer has no search endpoint - every one of its routes is a feed
/// or a lookup by id (see KAPOSTS_INDEXER.md). So this pages the global feed and filters what
/// comes back, which has one honest consequence worth stating in the UI rather than hiding: it
/// searches as far back as it has paged, not the whole chain. The "Keep looking" button is how
/// the user asks it to go further, and it says how far it has got.
///
/// People are derived from the authors of the posts it scans, which is what makes "only people
/// who have posted at least once" true by construction rather than by a filter that could be
/// wrong: an address is only ever offered here because a post of theirs was read.
struct KaPostsSearchView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case posts = "Posts"
        case people = "People"
        var id: String { rawValue }
    }

    /// Opening a result: the parent owns navigation, so it is handed back rather than pushed.
    /// A TXID rather than the post itself - the parent resolves it through the same path a
    /// shared link takes, which knows how to find a post that is not in the loaded feed. Every
    /// row here came from the indexer, so it always has one.
    var onOpenPost: (String) -> Void
    var onOpenProfile: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var knsService = KNSService.shared
    @ObservedObject private var moderationStore = KaPostsModerationStore.shared

    @State private var query = ""
    @State private var scope: Scope = .posts
    /// Everything paged so far this session, newest first, deduped by id.
    @State private var scanned: [KaPostsView.DraftPost] = []
    @State private var cursor: String?
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var loadFailed = false
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Results

    private var matchingPosts: [KaPostsView.DraftPost] {
        guard !trimmedQuery.isEmpty else { return [] }
        return scanned.filter { post in
            guard !moderationStore.isHidden(post.posterAddress) else { return false }
            if post.text.lowercased().contains(trimmedQuery) { return true }
            // A post also matches on WHO wrote it, so searching a name finds their posts without
            // having to switch tabs to find them first.
            return displayName(for: post.posterAddress).lowercased().contains(trimmedQuery)
        }
    }

    /// One row per author, with how many of their scanned posts matched - so the list is ordered
    /// by who is actually active on this term rather than by whoever posted most recently.
    private var matchingPeople: [(address: String, postCount: Int)] {
        guard !trimmedQuery.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for post in scanned where !post.posterAddress.isEmpty {
            guard !moderationStore.isHidden(post.posterAddress) else { continue }
            counts[post.posterAddress, default: 0] += 1
        }
        return counts
            .filter { address, _ in
                let name = displayName(for: address).lowercased()
                return name.contains(trimmedQuery) || address.lowercased().contains(trimmedQuery)
            }
            .map { (address: $0.key, postCount: $0.value) }
            .sorted { lhs, rhs in
                lhs.postCount == rhs.postCount
                    ? displayName(for: lhs.address) < displayName(for: rhs.address)
                    : lhs.postCount > rhs.postCount
            }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                if trimmedQuery.isEmpty {
                    promptState
                } else if scope == .posts {
                    postResults
                } else {
                    peopleResults
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Posts and people")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                // One page up front so the first search has something to answer with.
                if scanned.isEmpty { await loadMore() }
            }
        }
    }

    // MARK: - States

    private var promptState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("Search KaPosts")
                .font(.headline)
            Text("Find posts by what they say, and people by their name or domain. Only people who have posted appear.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }

    @ViewBuilder
    private var postResults: some View {
        if matchingPosts.isEmpty && !isLoading {
            emptyResults
        } else {
            List {
                ForEach(matchingPosts) { post in
                    Button {
                        guard let txId = post.remoteId else { return }
                        onOpenPost(txId)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(displayName(for: post.posterAddress))
                                .font(.subheadline.weight(.semibold))
                            Text(post.text)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                            Text(post.timestamp, style: .relative)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                depthFooter
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var peopleResults: some View {
        if matchingPeople.isEmpty && !isLoading {
            emptyResults
        } else {
            List {
                ForEach(matchingPeople, id: \.address) { person in
                    Button {
                        onOpenProfile(person.address)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            KNSAvatarView(
                                avatarURLString: knsService.profileCache[person.address]?.avatarURL,
                                fallbackText: displayName(for: person.address),
                                size: 36,
                                contactAddress: person.address
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayName(for: person.address))
                                    .font(.subheadline.weight(.semibold))
                                Text(person.postCount == 1 ? "1 post found" : "\(person.postCount) posts found")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                depthFooter
            }
            .listStyle(.plain)
        }
    }

    private var emptyResults: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("Nothing found yet")
                .font(.headline)
            Text(hasMore
                 ? "Searched the most recent \(scanned.count) posts. Older ones have not been read yet."
                 : "Searched every post available.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if hasMore {
                Button {
                    Task { await loadMore() }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("Keep looking")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)
            }
            Spacer()
        }
    }

    /// Says how deep the search has gone, and offers to go deeper. Shown under the results
    /// rather than only when empty: a handful of hits does not mean there are no more.
    @ViewBuilder
    private var depthFooter: some View {
        if hasMore {
            Button {
                Task { await loadMore() }
            } label: {
                HStack(spacing: 8) {
                    if isLoading { ProgressView() }
                    Text(isLoading ? "Reading older posts" : "Search older posts")
                        .font(.footnote.weight(.semibold))
                    Spacer(minLength: 0)
                    Text("\(scanned.count) read")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
        } else if loadFailed {
            Text("Could not read any further just now.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Paging

    private func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        loadFailed = false
        defer { isLoading = false }
        do {
            var seen = Set(scanned.map(\.id))
            let batch = try await KaPostsPaginator.collect(
                from: cursor,
                fetch: { before, limit in
                    let page = try await KaPostsAPIClient.shared.fetchGlobalFeed(limit: limit, before: before)
                    return (page.posts, page.pagination)
                },
                keep: { posts in
                    posts.compactMap { post -> KaPostsView.DraftPost? in
                        guard let mapped = KaPostsView.mapRemotePost(post),
                              seen.insert(mapped.id).inserted else { return nil }
                        return mapped
                    }
                }
            )
            scanned.append(contentsOf: batch.items)
            cursor = batch.cursor
            hasMore = batch.hasMore
            // Warm the names for whoever just arrived, so People rows are not a wall of
            // shortened addresses. Bounded and debounced inside KNSService.
            let addresses = Array(Set(batch.items.map(\.posterAddress).filter { !$0.isEmpty }))
            if !addresses.isEmpty {
                await knsService.refreshProfilesIfNeeded(for: addresses)
            }
        } catch {
            loadFailed = true
        }
    }

    private func displayName(for address: String) -> String {
        guard !address.isEmpty else { return "Unknown" }
        if let assigned = ContactsManager.shared.getContact(byAddress: address)?.assignedName {
            return KaPostsView.strippingKasSuffix(assigned)
        }
        if let domain = knsService.profileCache[address]?.domainName,
           !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return KaPostsView.strippingKasSuffix(domain)
        }
        if let domain = knsService.domainCache[address]?.primaryDomain,
           !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return KaPostsView.strippingKasSuffix(domain)
        }
        return String(address.suffix(8))
    }
}
