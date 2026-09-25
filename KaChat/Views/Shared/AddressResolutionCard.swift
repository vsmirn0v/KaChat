import SwiftUI

/// Who is behind the address a screen has resolved - the card the create-chat screen shows,
/// for every other place an address or a `.kas` domain goes in (withdrawals, sends from an
/// address, the portfolio, a group invite). The SCREEN does the resolving, exactly as
/// create-chat does (its own validity check and KNS lookup); this card takes the outcome and
/// fetches the profile for the face and the domain. Nil address, no card - a half-typed
/// address gets nothing rather than a card flickering through wrong faces.
struct AddressResolutionCard: View {
    /// The address the input stands for: a valid typed address, or a domain's resolved owner.
    let address: String?
    /// The domain that resolved to it, when the user typed one (shown at once, before the
    /// profile fetch lands).
    var domain: String? = nil

    @State private var profile: KNSAddressProfileInfo?
    @State private var isLoadingProfile = false

    var body: some View {
        if let address, !address.isEmpty {
            HStack(spacing: 12) {
                KNSAvatarView(
                    avatarURLString: profile?.avatarURL,
                    fallbackText: profile?.domainName ?? domain ?? address,
                    size: 44,
                    contactAddress: address
                )
                VStack(alignment: .leading, spacing: 2) {
                    let name = profile?.domainName ?? domain
                    Text(name ?? (isLoadingProfile ? "Looking up..." : "No KNS domain"))
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
                if isLoadingProfile { ProgressView().controlSize(.small) }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .task(id: address) { await loadProfile(for: address) }
        }
    }

    /// Cached by KNSService, so an address already looked at costs nothing.
    private func loadProfile(for address: String) async {
        guard KaspaAddress.isValid(address) else {
            profile = nil
            return
        }
        if let cached = KNSService.shared.profileCache[address] {
            profile = cached
            return
        }
        isLoadingProfile = true
        let fetched = await KNSService.shared.fetchProfile(for: address)
        guard !Task.isCancelled else { return }
        profile = fetched
        isLoadingProfile = false
    }
}
