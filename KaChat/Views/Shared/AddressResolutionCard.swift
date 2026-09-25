import SwiftUI

/// Who is behind an address you are typing - the card the create-chat screen shows, for every
/// other place an address or a `.kas` domain goes in (withdrawals, sends from an address, the
/// portfolio, a group invite). Resolves on its own: a valid address fetches its KNS profile,
/// a domain resolves to its owner first. Shown only once the input is something the app is
/// confident about - a half-typed address gets nothing rather than a card flickering through
/// wrong faces.
struct AddressResolutionCard: View {
    let input: String

    @State private var address: String?
    @State private var domain: String?
    @State private var profile: KNSAddressProfileInfo?
    @State private var isLooking = false
    @State private var domainNotFound = false

    private var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Group {
            if let address {
                HStack(spacing: 12) {
                    KNSAvatarView(
                        avatarURLString: profile?.avatarURL,
                        fallbackText: profile?.domainName ?? domain ?? address,
                        size: 44,
                        contactAddress: address
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        let name = profile?.domainName ?? domain
                        Text(name ?? (isLooking ? "Looking up..." : "No KNS domain"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(name == nil ? .secondary : .primary)
                            .lineLimit(1)
                        Text(address)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if isLooking { ProgressView().controlSize(.small) }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
            } else if isLooking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking up \(trimmed)...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if domainNotFound {
                Label("No KNS domain named \(trimmed)", systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                // Present but invisible. With nothing to show the Group would be an EmptyView,
                // and SwiftUI never runs `.task` on one - so the lookup that fills the card
                // would never start. A zero-height anchor keeps the task alive.
                Color.clear
                    .frame(height: 0)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
        }
        .task(id: trimmed) { await resolve(trimmed) }
    }

    private func resolve(_ text: String) async {
        domainNotFound = false
        guard !text.isEmpty else {
            address = nil; domain = nil; profile = nil; isLooking = false
            return
        }
        if KaspaAddress.isValid(text) {
            address = text
            domain = nil
            await loadProfile(for: text)
            return
        }
        if KNSService.looksLikeDomain(text) {
            address = nil; profile = nil
            isLooking = true
            // A pause while the domain is still being typed.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            if let resolution = await KNSService.shared.resolveDomain(text) {
                guard !Task.isCancelled else { return }
                address = resolution.ownerAddress
                domain = resolution.domain
                await loadProfile(for: resolution.ownerAddress)
            } else {
                guard !Task.isCancelled else { return }
                isLooking = false
                domainNotFound = true
            }
            return
        }
        address = nil; domain = nil; profile = nil; isLooking = false
    }

    private func loadProfile(for address: String) async {
        if let cached = KNSService.shared.profileCache[address] {
            profile = cached
            isLooking = false
            return
        }
        isLooking = true
        let fetched = await KNSService.shared.fetchProfile(for: address)
        guard !Task.isCancelled else { return }
        profile = fetched
        isLooking = false
    }
}
