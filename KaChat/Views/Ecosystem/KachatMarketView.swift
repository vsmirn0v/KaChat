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
/// UI only. Nothing is wired yet: search answers "not live yet", listings and activity show
/// placeholder skeletons, and every action is disabled with "Coming soon". No invented names or
/// prices anywhere - the skeletons are redacted shapes, so nothing here can be mistaken for a
/// real listing.
struct KachatMarketView: View {
    private enum Page: String, CaseIterable {
        case market, myNames, activity

        var title: String {
            switch self {
            case .market: return "Marketplace"
            case .myNames: return "My Names"
            case .activity: return "Activity"
            }
        }
    }

    @State private var page: Page = .market
    @State private var searchText = ""
    @State private var showHowItWorks = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    hero
                    searchCard
                    UnderlineTabBar(
                        tabs: Page.allCases.map { (tab: $0, title: $0.title) },
                        selection: $page
                    )
                    switch page {
                    case .market: marketPage
                    case .myNames: myNamesPage
                    case .activity: activityPage
                    }
                }
                .padding(.bottom, 28)
            }
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
            comingSoonPill
        }
        .padding(.top, 20)
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
            if !typed.isEmpty {
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
                    ForEach(0..<4, id: \.self) { _ in featuredPlaceholder }
                }
                .padding(.horizontal, 16)
            }

            sectionHeader("Recently listed", detail: nil)
            VStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { index in
                    listingPlaceholderRow
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
            Text("000 KAS")
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
            Text("000 KAS")
                .font(.subheadline.weight(.semibold))
                .redacted(reason: .placeholder)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - My Names

    private var myNamesPage: some View {
        VStack(spacing: 12) {
            Image(systemName: "at.circle")
                .font(.system(size: 44, weight: .semibold))
                .foregroundColor(.accentColor)
            Text("No .kachat names yet")
                .font(.headline)
            Text("Names you claim or buy show here. From here you'll set one as your name in chats, list it for sale, or send it to someone.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {} label: {
                Text("Claim a Name")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(true)
            .padding(.horizontal, 32)
            .padding(.top, 4)
        }
        .padding(.top, 24)
    }

    // MARK: - Activity

    private var activityPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Recent activity", detail: "Claims, listings and sales across the marketplace.")
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
                        Text("000 KAS")
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
                        icon: "checkmark.shield",
                        title: "Trustless",
                        detail: "No middleman and no escrow account: Kaspa's own rules enforce every sale."
                    )
                } footer: {
                    Text("Nothing here is live yet.")
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
