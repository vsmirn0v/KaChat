import SwiftUI
import UIKit

/// The ".kachat" wordmark as a template image - the Kaspa Hub tile, the dock item and Customize
/// Dock draw it the way `ChessTabIcon` draws the chess pieces, tinted like any SF Symbol.
enum KachatTabIcon {
    private static var cache: [Int: UIImage] = [:]

    /// A template image `side` points tall; the word is wider than it is tall.
    static func image(side: CGFloat) -> UIImage {
        let key = Int(side.rounded())
        if let cached = cache[key] { return cached }
        let font = UIFont.systemFont(ofSize: side * 0.62, weight: .heavy)
        let rounded = font.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
        let text = NSAttributedString(string: ".kachat", attributes: [.font: rounded, .foregroundColor: UIColor.black])
        let measured = text.size()
        let width = max(measured.width, side)
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: width, height: side)).image { _ in
            text.draw(at: CGPoint(x: (width - measured.width) / 2, y: (side - measured.height) / 2))
        }
        let template = rendered.withRenderingMode(.alwaysTemplate)
        cache[key] = template
        return template
    }

    static func view(side: CGFloat) -> some View {
        Image(uiImage: image(side: side))
            .renderingMode(.template)
            .foregroundStyle(Color.accentColor)
    }
}

/// Kaspa Hub > .kachat: the marketplace for KaChat's own names - claim one, list it, buy one,
/// peer to peer and trustless (the name and the payment settle together on chain, no one holds
/// either in between).
///
/// On mainnet it is UI only: search answers "not live yet", listings and activity show
/// placeholder skeletons, and every action is disabled with "Coming soon". No invented names or
/// prices anywhere - the skeletons are redacted shapes, so nothing here can be mistaken for a
/// real listing.
///
/// On TESTNET (testnet-10, with the bundled registry manifest verified) it is live
/// (`KachatNamesLiveViews.swift`): search shows real availability and the price, Claim registers,
/// the tabs read the registry (`KachatNamesRegistry`), and registrations in flight show their
/// progress.
struct KachatMarketView: View {
    /// Names for sale, names anyone may reclaim, and everything that happens in the registry.
    /// Your own names (and the offers you made) live in Profile > Your Domains.
    private enum Page: String, CaseIterable {
        case market, reclaimable, activity

        var title: String {
            switch self {
            case .market: return "Marketplace"
            case .reclaimable: return "Reclaimable"
            case .activity: return "Activity"
            }
        }
    }

    @State private var page: Page = .market
    @State private var searchText = ""
    @State private var showHowItWorks = false
    @StateObject private var live = KachatHubModel()
    @ObservedObject private var actions = KachatNamesActions.shared
    @State private var claimTarget: KachatClaimTarget?
    /// A name opened from a notification (`KachatDeepLink`).
    @State private var nameRoute: KachatNameRoute?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    hero
                    searchCard
                    if live.isLive {
                        ForEach(actions.pending.filter(\.isOpen)) { registration in
                            KachatRegistrationCard(registration: registration)
                        }
                    }
                    UnderlineTabBar(
                        tabs: Page.allCases.map { (tab: $0, title: $0.title) },
                        selection: $page
                    )
                    // Live, or not launched here (mainnet): the same pages - empty on mainnet. The
                    // placeholder pages remain only for a testnet registry that is setting up.
                    if live.isLive || !KachatNamesService.isLaunched {
                        switch page {
                        case .market: KachatLiveMarketPage(model: live)
                        case .reclaimable: KachatLiveReclaimablePage(model: live)
                        case .activity: KachatLiveActivityPage(model: live)
                        }
                    } else {
                        switch page {
                        case .market: marketPage
                        case .reclaimable: reclaimablePage
                        case .activity: activityPage
                        }
                    }
                }
                .padding(.bottom, 28)
            }
            // Pull to refresh on testnet only; mainnet has nothing to refresh.
            .modifier(KachatRefreshable(enabled: live.isLive) { await live.refresh() })
            .task { await live.start() }
            .onReceive(KachatNamesRegistry.shared.$revision.dropFirst()) { _ in
                guard live.isLive else { return }
                Task { await live.reload() }
            }
            .sheet(item: $claimTarget) { target in
                KachatClaimSheet(target: target)
            }
            .modifier(KachatNameRouteDestination(route: $nameRoute))
            .onAppear { takePendingName() }
            .onReceive(NotificationCenter.default.publisher(for: .openKachatName)) { _ in takePendingName() }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(".kachat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { ConnectionStatusIndicator() }
                ToolbarItem(placement: .principal) { BalanceToolbarLabel() }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showHowItWorks = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .accessibilityLabel(Text("How it works"))
                }
            }
            .sheet(isPresented: $showHowItWorks) { howItWorksSheet }
        }
    }

    /// Opens the name a tapped notification pointed at (testnet only, where names are live).
    private func takePendingName() {
        guard let name = KachatDeepLink.pendingName, KachatLive.isEnabled else { return }
        KachatDeepLink.pendingName = nil
        nameRoute = KachatNameRoute(name: name)
    }

    // MARK: - Hero and search

    private var hero: some View {
        VStack(spacing: 8) {
            KachatTabIcon.view(side: 64)
            Text("Your name on KaChat")
                .font(.title2.weight(.bold))
            Text("Claim a .kachat name, or buy and sell them peer to peer. The name and the payment settle together on Kaspa - nobody holds either in between.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if live.isLive {
                KachatTestnetBadge()
            } else if KachatLive.isEnabled, live.upgrading {
                // the bundled manifest is for the previous registry: a calm "setting up", no error
                HStack(spacing: 6) {
                    KachatTestnetBadge()
                    settingUpPill
                }
                Text("The .kachat registry on Testnet is being upgraded. Names open here again once the new registry is live.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                comingSoonPill
                if KachatLive.isEnabled, live.ready == false, let error = live.setupError {
                    Text(verbatim: error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
        }
        .padding(.top, 20)
    }

    private var settingUpPill: some View {
        Label("Setting up", systemImage: "hammer")
            .font(.caption.weight(.bold))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }

    private var comingSoonPill: some View {
        Text("Coming soon")
            .font(.caption.weight(.bold))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Find a name", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text(".kachat")
                    .font(.body.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))

            let typed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !typed.isEmpty && live.isLive {
                KachatLiveSearchResult(model: live, typed: typed) { claimTarget = $0 }
            } else if !typed.isEmpty {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(typed).kachat")
                            .font(.headline)
                            .lineLimit(1)
                        Text("Registration isn't open yet.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Claim") {}
                        .buttonStyle(.borderedProminent)
                        .disabled(true)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Marketplace

    private var marketPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader("Featured", detail: "Names their owners have put up for sale.")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(0..<4, id: \.self) { _ in
                        NavigationLink { KachatListingDetailView() } label: { featuredPlaceholder }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }

            sectionHeader("Recently listed", detail: nil)
            VStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { index in
                    NavigationLink { KachatListingDetailView() } label: { listingPlaceholderRow.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                    if index < 4 { Divider().padding(.leading, 16) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
            .padding(.horizontal, 16)

            Button {} label: {
                Label("List a Name for Sale", systemImage: "tag")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.bordered)
            .disabled(true)
            .padding(.horizontal, 16)

            Text("Listings appear here once .kachat names launch.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 4)
    }

    private func sectionHeader(_ title: LocalizedStringKey, detail: LocalizedStringKey?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
    }

    /// A featured card's shape, redacted: no invented name or price.
    private var featuredPlaceholder: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor)
                .frame(width: 170, height: 90)
                .overlay(
                    Text("name.kachat")
                        .font(.headline.weight(.bold))
                        .foregroundColor(.black)
                        .redacted(reason: .placeholder)
                )
            Text(verbatim: "000 \(KaspaUnit.symbol)")
                .font(.subheadline.weight(.semibold))
                .redacted(reason: .placeholder)
            Text("Buy")
                .font(.caption.weight(.bold))
                .foregroundColor(.accentColor)
                .redacted(reason: .placeholder)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var listingPlaceholderRow: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.accentColor.opacity(0.25))
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text("somename.kachat")
                    .font(.subheadline.weight(.semibold))
                Text("listed 1h ago")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .redacted(reason: .placeholder)
            Spacer()
            Text(verbatim: "000 \(KaspaUnit.symbol)")
                .font(.subheadline.weight(.semibold))
                .redacted(reason: .placeholder)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(Color(.tertiaryLabel))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - My Names

    private var reclaimablePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader("Reclaimable", detail: "Names whose owners let them lapse. Anyone may reclaim one: the bond goes back to its last owner, you keep the freed deposit as a bounty, and the name is free to claim.")
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { index in
                    listingPlaceholderRow
                    if index < 2 { Divider().padding(.leading, 16) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
            .padding(.horizontal, 16)
            Text("Reclaimable names appear here once .kachat names launch.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 4)
    }

    // MARK: - Activity

    private var activityPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Recent activity", detail: "Every claim, renewal, listing, sale, offer, transfer and reclaim across the registry.")
            VStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { index in
                    HStack(spacing: 12) {
                        Image(systemName: ["tag", "cart", "at", "arrow.left.arrow.right"][index])
                            .foregroundColor(.accentColor)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("somename.kachat sold")
                                .font(.subheadline.weight(.semibold))
                            Text("2h ago")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .redacted(reason: .placeholder)
                        Spacer()
                        Text(verbatim: "000 \(KaspaUnit.symbol)")
                            .font(.subheadline)
                            .redacted(reason: .placeholder)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    if index < 3 { Divider().padding(.leading, 56) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
            .padding(.horizontal, 16)
            Text("Activity appears here once .kachat names launch.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 4)
    }

    // MARK: - How it works

    private var howItWorksSheet: some View {
        NavigationStack {
            List {
                Section {
                    howItWorksRow(
                        icon: "at.badge.plus",
                        title: "Claim",
                        detail: "Pick a free name and register it on Kaspa. It's yours: your name in chats, your profile, your link."
                    )
                    howItWorksRow(
                        icon: "tag",
                        title: "List",
                        detail: "Set a price. The name waits in an on-chain covenant, not with KaChat or anyone else, until someone buys it or you take it back."
                    )
                    howItWorksRow(
                        icon: "cart",
                        title: "Buy",
                        detail: "Pay the listed price. The payment reaches the seller and the name reaches you in the same transaction - both happen, or neither does."
                    )
                    howItWorksRow(
                        icon: "hand.raised",
                        title: "Offer",
                        detail: LocalizedStringKey(KaspaUnit.label(AppLocalization.string("Name your own price. Your KAS waits on chain until the seller accepts, you withdraw the offer, or it expires - and you can message the seller first.")))
                    )
                    howItWorksRow(
                        icon: "checkmark.shield",
                        title: "Trustless",
                        detail: "No middleman and no escrow account: Kaspa's own rules enforce every sale."
                    )
                } footer: {
                    if live.isLive {
                        Text("Live on Testnet: names, prices and payments here use TKAS on testnet-10. Mainnet names come after an audit.")
                    } else {
                        Text("Nothing here is live yet.")
                    }
                }
            }
            .navigationTitle("How .kachat works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showHowItWorks = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func howItWorksRow(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Listing

/// One listing in the .kachat marketplace: the name and its price, the three ways to act on it
/// - buy it at the listed price, make an offer, or message the seller first - the offers already
/// on it, and its history.
///
/// UI only, like the rest of the marketplace: no listing exists yet, so the name, price, seller
/// and offers are redacted shapes and every final action is disabled. Buy and Make an Offer still
/// open their sheets so the flow can be looked at. `sellerAddress` is where a real listing hands
/// in its seller - Message Seller opens a 1:1 chat with it.
struct KachatListingDetailView: View {
    var sellerAddress: String? = nil
    /// A real name (testnet only): the live detail with its actions instead of the mockup.
    var info: KachatNames.NameInfo? = nil

    @State private var showBuy = false
    @State private var showOffer = false

    var body: some View {
        if let info, KachatLive.isEnabled {
            KachatLiveNameDetail(info: info)
        } else {
            mockup
        }
    }

    private var mockup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                nameCard
                actionButtons
                sellerCard
                offersSection
                historySection
                notes
            }
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Listing")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showBuy) { KachatBuySheet() }
        .sheet(isPresented: $showOffer) { KachatOfferSheet() }
    }

    private var nameCard: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.accentColor)
                .frame(height: 120)
                .overlay(
                    Text(verbatim: "name.kachat")
                        .font(.title2.weight(.heavy))
                        .foregroundColor(.black)
                        .redacted(reason: .placeholder)
                )
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Price")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(verbatim: "000 \(KaspaUnit.symbol)")
                        .font(.title3.weight(.bold))
                        .redacted(reason: .placeholder)
                }
                Spacer()
                Text(verbatim: "listed 1h ago")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .redacted(reason: .placeholder)
            }
            KachatComingSoonPill()
        }
        .padding(14)
        .background(KachatCardBackground())
        .padding(.horizontal, 16)
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button { showBuy = true } label: {
                Label("Buy Now", systemImage: "cart")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)

            Button { showOffer = true } label: {
                Label("Make an Offer", systemImage: "hand.raised")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
    }

    private var sellerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            KachatSectionHeader(title: "Seller", detail: nil)
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.accentColor.opacity(0.25))
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: sellerAddress.map(Contact.generateDefaultAlias(from:)) ?? "kaspa:xxxx....xxxx")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .redacted(reason: sellerAddress == nil ? .placeholder : [])
                    Text("Ask about the name, or agree on a price before you offer.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                Button {} label: {
                    Label("Message", systemImage: "bubble.left.and.bubble.right")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                // Opens a 1:1 chat with `sellerAddress` once listings are real.
                .disabled(true)
            }
            .padding(14)
            .background(KachatCardBackground())
            .padding(.horizontal, 16)
        }
    }

    private var offersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            KachatSectionHeader(title: "Offers", detail: "Open offers on this name, highest first. The seller can accept any of them.")
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { index in
                    HStack(spacing: 12) {
                        Image(systemName: "hand.raised")
                            .foregroundColor(.accentColor)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: "kaspa:xxxx....xxxx")
                                .font(.subheadline.weight(.semibold))
                            Text(verbatim: "expires in 2d")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .redacted(reason: .placeholder)
                        Spacer()
                        Text(verbatim: "000 \(KaspaUnit.symbol)")
                            .font(.subheadline.weight(.semibold))
                            .redacted(reason: .placeholder)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    if index < 2 { Divider().padding(.leading, 50) }
                }
            }
            .background(KachatCardBackground())
            .padding(.horizontal, 16)
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            KachatSectionHeader(title: "History", detail: nil)
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { index in
                    HStack(spacing: 12) {
                        Image(systemName: ["tag", "arrow.left.arrow.right", "at.badge.plus"][index])
                            .foregroundColor(.accentColor)
                            .frame(width: 24)
                        Text(verbatim: "listed by kaspa:xxxx")
                            .font(.subheadline)
                            .redacted(reason: .placeholder)
                        Spacer()
                        Text(verbatim: "3d ago")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .redacted(reason: .placeholder)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    if index < 2 { Divider().padding(.leading, 50) }
                }
            }
            .background(KachatCardBackground())
            .padding(.horizontal, 16)
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Buying pays the seller and moves the name to you in one transaction.", systemImage: "cart")
            Label(KaspaUnit.label(AppLocalization.string("An offer locks your KAS on chain until the seller accepts it, you withdraw it, or it expires.")), systemImage: "lock")
            Label("Messages go to the seller like any KaChat chat.", systemImage: "bubble.left.and.bubble.right")
        }
        .font(.footnote)
        .foregroundColor(.secondary)
        .padding(.horizontal, 20)
    }
}

/// Buy at the listed price: what you pay, then one confirmation. Opens full height with Cancel
/// top left, the same as the offer sheet. Disabled until names launch.
struct KachatBuySheet: View {
    /// A real listing (testnet only): the live purchase instead of the mockup.
    var info: KachatNames.NameInfo? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let info, KachatLive.isEnabled {
            KachatLiveBuySheet(info: info)
        } else {
            mockup
        }
    }

    private var mockup: some View {
        NavigationStack {
            Form {
                Section {
                    summaryRow("Name", value: "name.kachat")
                    summaryRow("Price", value: "000 \(KaspaUnit.symbol)")
                    summaryRow("Network fee", value: "0.0000 \(KaspaUnit.symbol)")
                    summaryRow("Total", value: "000 \(KaspaUnit.symbol)", bold: true)
                } footer: {
                    Text("The payment reaches the seller and the name reaches you in the same transaction - both happen, or neither does.")
                }

                Section {
                    Button {} label: {
                        Text("Confirm Purchase")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(true)
                } footer: {
                    Text("Buying opens when .kachat names launch.")
                }
            }
            .navigationTitle("Buy Name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func summaryRow(_ title: LocalizedStringKey, value: String, bold: Bool = false) -> some View {
        HStack {
            Text(title).fontWeight(bold ? .semibold : .regular)
            Spacer()
            Text(verbatim: value)
                .fontWeight(bold ? .semibold : .regular)
                .redacted(reason: .placeholder)
        }
    }
}

/// Make an offer: an amount, how long it stands, and what happens to the KAS meanwhile. The
/// amount and expiry can be set so the form can be tried; sending is disabled until names launch.
struct KachatOfferSheet: View {
    /// A real name (testnet only): the live offer instead of the mockup.
    var info: KachatNames.NameInfo? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var expiry: Expiry = .threeDays

    private enum Expiry: String, CaseIterable, Hashable {
        // up to 7 days, the app's cap on offers (KachatNamesActions.maxOfferDays)
        case oneDay, threeDays, sevenDays

        var title: LocalizedStringKey {
            switch self {
            case .oneDay: return "1 Day"
            case .threeDays: return "3 Days"
            case .sevenDays: return "7 Days"
            }
        }
    }

    var body: some View {
        if let info, KachatLive.isEnabled {
            KachatLiveOfferSheet(name: info.name, info: info)
        } else {
            mockup
        }
    }

    private var mockup: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Name")
                        Spacer()
                        Text(verbatim: "name.kachat").redacted(reason: .placeholder)
                    }
                    HStack {
                        Text("Listed at")
                        Spacer()
                        Text(verbatim: "000 \(KaspaUnit.symbol)").redacted(reason: .placeholder)
                    }
                }

                Section {
                    HStack {
                        TextField("0", text: $amount)
                            .keyboardType(.decimalPad)
                            .font(.title3.weight(.semibold))
                        Text(verbatim: KaspaUnit.symbol)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Your offer")
                } footer: {
                    KaspaUnit.text("Your KAS stays locked on chain until the owner accepts or declines, you withdraw the offer, or it expires - then anyone can send it back to you.")
                }

                Section {
                    Picker("Expires", selection: $expiry) {
                        ForEach(Expiry.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Expires after")
                }

                Section {
                    Button {} label: {
                        Text("Send Offer")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(true)
                } footer: {
                    Text("Offers open when .kachat names launch.")
                }
            }
            .navigationTitle("Make an Offer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Shared pieces

private struct KachatRefreshable: ViewModifier {
    let enabled: Bool
    let action: () async -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.refreshable { await action() }
        } else {
            content
        }
    }
}

private struct KachatSectionHeader: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
    }
}

private struct KachatCardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }
}

private struct KachatComingSoonPill: View {
    var body: some View {
        Text("Coming soon")
            .font(.caption.weight(.bold))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }
}

// MARK: - An address's .kachat names

/// The ".kachat" tab of every screen that shows an address's history - Manage Addresses,
/// Cold Storage and the chatting address: the .kachat names that address holds. It replaced the
/// KNS Domains tab (5.2), and is empty until .kachat names launch.
struct KachatAddressDomainsList: View {
    /// The address whose names to show. On testnet (live registry) the list is that address's
    /// own .kachat names; nil, or mainnet, shows the "coming" note.
    var address: String? = nil

    var body: some View {
        if let address, KachatNamesService.isEnabled {
            KachatAddressLiveNamesList(address: address)
        } else {
            comingNote
        }
    }

    private var comingNote: some View {
        List {
            VStack(spacing: 10) {
                KachatTabIcon.view(side: 40)
                Text("No .kachat names on this address")
                    .font(.headline)
                Text("Names this address claims or buys show here once .kachat names launch.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
    }
}

/// One address's .kachat names on testnet - Manage Addresses (spending), the chatting address and
/// KasSigner each show their own address's names in its .kachat tab. Same cards and detail screen
/// as Your Domains > .kachat. Names on an address this wallet can't sign for (a KasSigner address)
/// open read-only: their actions need that address's key.
struct KachatAddressLiveNamesList: View {
    let address: String
    @ObservedObject private var registry = KachatNamesRegistry.shared
    @ObservedObject private var service = KachatNamesService.shared
    @State private var names: [KachatNames.NameInfo] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if !loaded {
                    ProgressView().padding(.vertical, 24)
                } else if service.registryUpgrading || names.isEmpty {
                    VStack(spacing: 10) {
                        KachatTabIcon.view(side: 40)
                        Text("No .kachat names on this address")
                            .font(.headline)
                        Text("Names this address owns show here.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    ForEach(names) { n in
                        NavigationLink {
                            KachatListingDetailView(info: n)
                        } label: {
                            DomainNameCardView(title: n.display, badge: KachatLiveDomainsTab.badge(for: n, graceMs: registry.graceMs))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
        .refreshable { await registry.refresh() }
        .task(id: "\(address)|\(registry.revision)") { await load() }
    }

    private func load() async {
        guard let key = KachatNamesRegistry.keyOf(address) else { loaded = true; return }
        if registry.refreshedAt == nil { await registry.refresh() }
        names = (try? await registry.names(owner: key, includeInactive: true)) ?? []
        loaded = true
    }
}
