import SwiftUI
import UIKit

// The live `.kachat` screens, TESTNET ONLY (testnet-10 and a verified registry manifest): the hub's
// search, registrations in flight, Marketplace / My Names / Activity, the name detail with its
// actions, every transaction sheet and the address profile editor. On mainnet none of this is
// reached - `KachatMarketView`, `KachatListingDetailView` and the profile editor keep their
// "Coming soon" mockups. Every spending or destructive action shows its cost first, asks to
// confirm, then passes the device's own lock (`DeviceAuth`) before anything is signed.

// MARK: - Amounts

extension KaspaUnit {
    /// "35 TKAS", "0.2 TKAS", "1.99831 TKAS": exact, trailing zeros dropped.
    static func amount(_ sompi: UInt64) -> String {
        "\(plain(sompi)) \(symbol)"
    }

    static func plain(_ sompi: UInt64) -> String {
        let whole = sompi / 100_000_000
        let frac = sompi % 100_000_000
        guard frac > 0 else { return "\(whole)" }
        var f = String(format: "%08llu", frac)
        while f.hasSuffix("0") { f.removeLast() }
        return "\(whole).\(f)"
    }

    /// "+1.99 TKAS" / "-36.002 TKAS".
    static func signed(_ delta: Int64) -> String {
        delta >= 0 ? "+\(amount(UInt64(delta)))" : "-\(amount(delta.magnitude))"
    }

    /// "12.5" or "12,5" (KAS) -> sompi; nil for anything else or more than 8 decimals.
    static func parseSompi(_ text: String) -> UInt64? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty else { return nil }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let whole = UInt64(parts[0].isEmpty ? "0" : String(parts[0])) else { return nil }
        var frac: UInt64 = 0
        if parts.count == 2 {
            let f = String(parts[1])
            guard f.count <= 8, f.allSatisfy(\.isNumber) else { return nil }
            frac = UInt64(f.padding(toLength: 8, withPad: "0", startingAt: 0)) ?? 0
        }
        let (w, o) = whole.multipliedReportingOverflow(by: 100_000_000)
        guard !o else { return nil }
        return w + frac
    }
}

// MARK: - Shared pieces

enum KachatLive {
    static var isEnabled: Bool { KachatNamesService.isEnabled }
    /// What the device lock prompt says before any .kachat transaction is signed.
    static var authReason: String { AppLocalization.string("Confirm this .kachat transaction") }
    /// testnet-10 runs at 10 blocks per second
    static let daaPerSecond: UInt64 = 10

    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }

    /// A unix-ms day as a row value ("Oct 12, 2027"), in the in-app language.
    static func day(_ ms: Int64) -> String {
        date(ms).formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(AppLocalization.locale))
    }

    /// The registry parameters, once the manifest is verified.
    @MainActor static var params: KachatNames.Params? { KachatNamesService.shared.manifest?.params }

    /// An event party: an address (indexer) or an x-only key in hex (walker), as a short address.
    static func party(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        if s.hasPrefix("kaspa") { return KachatNamesRegistry.shortAddress(s) }
        if let key = try? KachatNames.unhex32(s), let a = KachatNamesRegistry.address(of: key) {
            return KachatNamesRegistry.shortAddress(a)
        }
        return s
    }

    @MainActor static func isMine(_ key: Data) -> Bool { KachatNamesActions.shared.myKey == key }

    static func eventIcon(_ op: String) -> String {
        switch op {
        case "register": return "at.badge.plus"
        case "transfer": return "arrow.left.arrow.right"
        case "list": return "tag"
        case "delist": return "tag.slash"
        case "sale", "offer_accepted": return "cart"
        case "extend": return "calendar.badge.plus"
        case "renew": return "arrow.clockwise"
        case "release": return "arrow.uturn.backward"
        case "reclaim": return "arrow.3.trianglepath"
        default: return "hand.raised"
        }
    }

    static func eventTitle(_ op: String) -> LocalizedStringKey {
        switch op {
        case "register": return "Registered"
        case "transfer": return "Transferred"
        case "list": return "Listed"
        case "delist": return "Delisted"
        case "sale": return "Sold"
        case "offer_accepted", "offer_accept": return "Offer accepted"
        case "extend": return "Extended"
        case "renew": return "Renewed"
        case "release": return "Released"
        case "reclaim": return "Reclaimed"
        case "offer": return "Offer made"
        case "offer_withdraw": return "Offer withdrawn"
        case "offer_refund": return "Offer refunded"
        default: return "Activity"
        }
    }

    /// Why a typed name is not a name.
    static func invalidReason(_ name: String) -> LocalizedStringKey? {
        let b = Array(name.utf8)
        if b.isEmpty || b.count > 32 { return "A name is 1 to 32 characters." }
        if !b.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2d }) {
            return "Use a-z, 0-9 and hyphens only."
        }
        if b.first == 0x2d || b.last == 0x2d { return "A name can't start or end with a hyphen." }
        return nil
    }

    /// Opens (or starts) a 1:1 chat with `address`.
    @MainActor
    static func message(_ address: String) {
        _ = ContactsManager.shared.getOrCreateContact(address: address)
        ChatService.shared.pendingChatNavigation = address
        NotificationCenter.default.post(name: .openChat, object: nil, userInfo: ["contactAddress": address])
    }
}

/// The app's glass card (`.regularMaterial`, hairline, soft shadow).
struct KachatGlass: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.8))
                .shadow(color: Color.black.opacity(0.10), radius: 8, x: 0, y: 4)
        )
    }
}

extension View {
    func kachatGlass(cornerRadius: CGFloat = 16) -> some View { modifier(KachatGlass(cornerRadius: cornerRadius)) }
}

struct KachatTestnetBadge: View {
    var body: some View {
        Text("Testnet")
            .font(.caption.weight(.bold))
            .foregroundColor(.orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.orange.opacity(0.15)))
    }
}

struct KachatStatusPill: View {
    let status: KachatNames.Status

    var body: some View {
        Group {
            switch status {
            case .active: Text("Active")
            case .grace: Text("Expired")
            case .lapsed: Text("Lapsed")
            }
        }
        .font(.caption2.weight(.bold))
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.15)))
    }

    private var color: Color {
        switch status {
        case .active: return .green
        case .grace: return .orange
        case .lapsed: return .red
        }
    }
}

/// One name in a list: the name, a line about it, and its price or status.
struct KachatLiveNameRow: View {
    let info: KachatNames.NameInfo
    var showPrice = true
    /// My Names: say when an active name's renewal window is open.
    var showRenewal = false

    private var status: KachatNames.Status { info.status(graceMs: KachatNamesRegistry.shared.graceMs) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "at")
                .font(.headline)
                .foregroundColor(.accentColor)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: info.display)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if KachatLive.isMine(info.owner) {
                        Text("Yours")
                    } else if let a = KachatNamesRegistry.address(of: info.owner) {
                        Text(verbatim: KachatNamesRegistry.shortAddress(a))
                    }
                    Text(verbatim: "·")
                    Text("until \(KachatLive.date(info.expiresAt), format: .dateTime.year().month().day())")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if showRenewal && status == .active, let p = KachatLive.params, info.renewOpen(p) {
                Text("Renewal open")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
            } else if showPrice && info.isListed && status == .active {
                Text(verbatim: KaspaUnit.amount(info.price))
                    .font(.subheadline.weight(.semibold))
            } else if status != .active {
                KachatStatusPill(status: status)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(Color(.tertiaryLabel))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

// MARK: - Hub model

@MainActor
final class KachatHubModel: ObservableObject {
    enum Search: Equatable {
        case idle
        case checking
        case invalid(String)
        case free(String, KachatNames.GapInfo?)
        case registered(KachatNames.NameInfo)
        case failed(String)
    }

    /// nil until the manifest is checked; false when it fails (the hub then stays a mockup).
    @Published private(set) var ready: Bool?
    @Published private(set) var setupError: String?
    @Published private(set) var search: Search = .idle
    @Published private(set) var listings: [KachatNames.NameInfo] = []
    @Published private(set) var lapsed: [KachatNames.NameInfo] = []
    @Published private(set) var mine: [KachatNames.NameInfo] = []
    @Published private(set) var myOffers: [KachatNames.OfferInfo] = []
    @Published private(set) var activity: [KachatNames.Event] = []
    @Published private(set) var loadError: String?
    @Published private(set) var loaded = false

    var registry: KachatNamesRegistry { .shared }
    var params: KachatNames.Params? { KachatNamesService.shared.manifest?.params }
    var isLive: Bool { KachatLive.isEnabled && ready == true }

    func start() async {
        guard KachatLive.isEnabled else {
            ready = nil
            return
        }
        do {
            try await registry.prepare(forceSourceCheck: true)
            ready = true
            setupError = nil
        } catch {
            ready = false
            setupError = error.localizedDescription
            return
        }
        KachatNamesActions.shared.resume()
        await registry.refresh()
        await reload()
    }

    func refresh() async {
        guard isLive else { return }
        await registry.refresh()
        await reload()
    }

    func reload() async {
        guard isLive else { return }
        do {
            listings = try await registry.listings()
            lapsed = try await registry.lapsed()
            if let me = KachatNamesActions.shared.myKey {
                mine = try await registry.names(owner: me, includeInactive: true)
                myOffers = try await registry.myOffers(buyer: me)
                if !myOffers.isEmpty { await KachatNamesActions.shared.refreshVirtualDaa() }
            } else {
                mine = []
                myOffers = []
            }
            activity = try await registry.activity()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
    }

    func lookup(_ text: String) async {
        let typed = KachatNames.Codec.normalize(text)
        guard !typed.isEmpty else { search = .idle; return }
        guard KachatLive.invalidReason(typed) == nil else { search = .invalid(typed); return }
        search = .checking
        do {
            switch try await registry.lookup(typed) {
            case .registered(let n): search = .registered(n)
            case .free(let name, let gap): search = .free(name, gap)
            }
        } catch {
            search = .failed(error.localizedDescription)
        }
    }

    func pricePerYear(_ name: String) -> UInt64? { params?.price(forLength: name.utf8.count) }
}

// MARK: - Hub: search result

struct KachatClaimTarget: Identifiable {
    let name: String
    let gap: KachatNames.GapInfo
    var id: String { name }
}

struct KachatLiveSearchResult: View {
    @ObservedObject var model: KachatHubModel
    let typed: String
    let onClaim: (KachatClaimTarget) -> Void

    var body: some View {
        content
            .padding(12)
            .kachatGlass(cornerRadius: 12)
            .task(id: typed) {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await model.lookup(typed)
            }
    }

    private var name: String { KachatNames.Codec.normalize(typed) }

    @ViewBuilder
    private var content: some View {
        switch model.search {
        case .registered(let n) where n.name == name:
            NavigationLink {
                KachatListingDetailView(info: n)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: n.display).font(.headline).lineLimit(1)
                        registeredLine(n)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundColor(Color(.tertiaryLabel))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .free(let free, let gap) where free == name:
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(free).kachat").font(.headline).lineLimit(1)
                    if let price = model.pricePerYear(free) {
                        Text("Available · \(KaspaUnit.amount(price)) a year")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                Spacer()
                Button("Claim") {
                    if let gap { onClaim(KachatClaimTarget(name: free, gap: gap)) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(gap == nil)
            }
        case .invalid:
            row(subtitle: KachatLive.invalidReason(name).map { Text($0) } ?? Text("Not a valid name."))
        case .failed(let message):
            row(subtitle: Text(verbatim: message))
        default:
            HStack(spacing: 10) {
                Text(verbatim: "\(name).kachat").font(.headline).lineLimit(1)
                Spacer()
                ProgressView()
            }
        }
    }

    private func row(subtitle: Text) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(name).kachat").font(.headline).lineLimit(1)
                subtitle.font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func registeredLine(_ n: KachatNames.NameInfo) -> some View {
        switch n.status(graceMs: KachatNamesRegistry.shared.graceMs) {
        case .active:
            if KachatLive.isMine(n.owner) {
                Text("Yours").font(.caption).foregroundColor(.secondary)
            } else if n.isListed {
                Text("Taken · for sale at \(KaspaUnit.amount(n.price))").font(.caption).foregroundColor(.secondary)
            } else {
                Text("Taken").font(.caption).foregroundColor(.secondary)
            }
        case .grace:
            Text("Expired - the owner can still renew it").font(.caption).foregroundColor(.orange)
        case .lapsed:
            Text("Lapsed - reclaim it, then claim it").font(.caption).foregroundColor(.red)
        }
    }
}

// MARK: - A finished transaction

/// A name transaction that went out: what it did and its id, for the half sheet below.
struct KachatTxDone: Identifiable, Equatable {
    var id: String { txId }
    let txId: String
    /// Localization key of the headline ("Listed for sale", "Profile saved", ...).
    var title: String = "Transaction sent"
}

/// The half sheet every finished name transaction shows: what happened, the transaction id
/// (copyable), and a link to it on the block explorer - the one picked in Settings, which on
/// testnet is the testnet-10 explorer. It opens in the in-app browser.
struct KachatTxDoneSheet: View {
    let done: KachatTxDone
    @Environment(\.dismiss) private var dismiss
    @State private var browserURL: URL?
    @State private var copied = false

    private var explorerURL: URL? { AppSettings.load().kaspaExplorer.txURL(for: done.txId) }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundColor(.green)
                .padding(.top, 24)
            Text(LocalizedStringKey(done.title))
                .font(.title3.weight(.bold))
            Text("It shows here once the network accepts it, usually within seconds.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                UIPasteboard.general.string = done.txId
                copied = true
                Haptics.success()
            } label: {
                HStack(spacing: 6) {
                    Text(verbatim: done.txId)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color(.secondarySystemBackground)))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            if let explorerURL {
                Button {
                    browserURL = explorerURL
                } label: {
                    Label("View in Explorer", systemImage: "safari")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 24)
            }
            Button("Done") { dismiss() }
                .font(.headline)
            Spacer(minLength: 0)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .fullScreenCover(isPresented: Binding(
            get: { browserURL != nil },
            set: { if !$0 { browserURL = nil } }
        )) {
            if let browserURL {
                InAppBrowserScreen(url: browserURL) { self.browserURL = nil }
            }
        }
    }
}

// MARK: - Hub: registrations in flight

struct KachatRegistrationCard: View {
    let registration: KachatNames.PendingRegistration
    @ObservedObject private var actions = KachatNamesActions.shared
    @State private var confirmCancel = false
    @State private var working = false
    @State private var error: String?
    @State private var done: KachatTxDone?

    private var tCommit: UInt64 { KachatNamesService.shared.manifest?.params.tCommit ?? 600 }

    /// The finished registration (or cancelled commit) as the half sheet shows it.
    private var finished: KachatTxDone? {
        switch registration.stage {
        case .registered: return registration.registerTxId.map { KachatTxDone(txId: $0, title: "Name registered") }
        case .cancelled: return registration.cancelTxId.map { KachatTxDone(txId: $0, title: "Commit cancelled") }
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(verbatim: "\(registration.name).kachat")
                    .font(.headline)
                Spacer()
                if registration.needsDriving {
                    ProgressView()
                } else if registration.stage == .registered {
                    Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                } else {
                    Image(systemName: "exclamationmark.circle.fill").foregroundColor(.orange)
                }
            }
            stageText
                .font(.subheadline)
                .foregroundColor(.secondary)
            if registration.stage == .waiting, let daa = registration.commitDaa, let now = actions.virtualDaa {
                let target = Double(tCommit + 20)
                let done = Double(now > daa ? now - daa : 0)
                ProgressView(value: min(done, target), total: target)
                let left = max(0, Int((target - done) / Double(KachatLive.daaPerSecond)))
                Text("About \(left) s to go").font(.caption).foregroundColor(.secondary)
            }
            if let message = error ?? (registration.stage == .failed ? registration.lastError : nil) {
                Text(verbatim: message).font(.caption).foregroundColor(.red)
            }
            buttons
        }
        .padding(14)
        .kachatGlass()
        .padding(.horizontal, 16)
        // Pops up the moment the registration lands (or the commit is cancelled).
        .onChange(of: registration.stage) { _ in if let finished { done = finished } }
        .sheet(item: $done) { KachatTxDoneSheet(done: $0) }
        .alert(Text("Cancel the commit?"), isPresented: $confirmCancel) {
            Button("Cancel Commit", role: .destructive) { authorizeCancel() }
            Button("Keep", role: .cancel) {}
        } message: {
            KaspaUnit.text("The registration stops and the commit's 0.2 KAS comes back to you, less the network fee.")
        }
    }

    @ViewBuilder
    private var stageText: some View {
        switch registration.stage {
        case .committing: Text("Sending the hidden commit...")
        case .waiting:
            if registration.commitDaa == nil {
                Text("Waiting for the commit to confirm...")
            } else {
                Text("The commit has to age for about a minute before the name can be registered. Keep KaChat open - it registers by itself, and picks up where it left off if you leave.")
            }
        case .registering: Text("Registering...")
        case .registered: Text("Registered. It's yours.")
        case .taken: KaspaUnit.text("Someone registered this name first. Cancel the commit to get its 0.2 KAS back.")
        case .failed: Text("The registration stopped.")
        case .cancelling: Text("Cancelling the commit...")
        case .cancelled: Text("Cancelled.")
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch registration.stage {
        case .registered, .cancelled:
            HStack {
                if let finished {
                    Button("View Transaction") { done = finished }
                        .buttonStyle(.borderedProminent)
                }
                Button("Done") { actions.dismiss(registration) }
                    .buttonStyle(.bordered)
            }
        case .taken:
            Button("Cancel Commit", role: .destructive) { confirmCancel = true }
                .buttonStyle(.bordered)
                .disabled(working)
        case .failed:
            HStack {
                Button("Try Again") { actions.retry(registration) }
                    .buttonStyle(.borderedProminent)
                Button("Cancel Commit", role: .destructive) { confirmCancel = true }
                    .buttonStyle(.bordered)
                    .disabled(working)
            }
        default:
            EmptyView()
        }
    }

    private func authorizeCancel() {
        DeviceAuth.authenticate(reason: KachatLive.authReason) {
            working = true
            error = nil
            Task { @MainActor in
                do { try await actions.cancel(registration) } catch { self.error = error.localizedDescription }
                working = false
            }
        }
    }
}

// MARK: - Hub: pages

struct KachatLiveMarketPage: View {
    @ObservedObject var model: KachatHubModel
    @State private var reclaimTarget: KachatNames.NameInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            KachatLiveSectionHeader(title: "For sale", detail: "Names their owners have listed. Buying pays the owner and moves the name to you in one transaction.")
            if model.listings.isEmpty {
                KachatLiveEmpty(text: model.loaded ? "No names are listed right now." : nil)
            } else {
                list(model.listings)
            }

            KachatLiveSectionHeader(title: "Reclaimable", detail: "Names whose owners let them lapse. Anyone may reclaim one: the bond goes back to its last owner, you keep the freed deposit as a bounty, and the name is free to claim.")
            if model.lapsed.isEmpty {
                KachatLiveEmpty(text: model.loaded ? "Nothing to reclaim." : nil)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.lapsed.enumerated()), id: \.element.id) { index, n in
                        HStack(spacing: 8) {
                            NavigationLink { KachatListingDetailView(info: n) } label: { KachatLiveNameRow(info: n, showPrice: false) }
                                .buttonStyle(.plain)
                            Button("Reclaim") { reclaimTarget = n }
                                .buttonStyle(.bordered)
                                .padding(.trailing, 12)
                        }
                        if index < model.lapsed.count - 1 { Divider().padding(.leading, 62) }
                    }
                }
                .kachatGlass()
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 4)
        .sheet(item: $reclaimTarget) { n in KachatReclaimSheet(info: n) }
    }

    private func list(_ names: [KachatNames.NameInfo]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(names.enumerated()), id: \.element.id) { index, n in
                NavigationLink { KachatListingDetailView(info: n) } label: { KachatLiveNameRow(info: n) }
                    .buttonStyle(.plain)
                if index < names.count - 1 { Divider().padding(.leading, 62) }
            }
        }
        .kachatGlass()
        .padding(.horizontal, 16)
    }
}

struct KachatLiveMyNamesPage: View {
    @ObservedObject var model: KachatHubModel
    @ObservedObject private var registry = KachatNamesRegistry.shared
    @State private var offerAction: KachatOfferAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            KachatLiveSectionHeader(title: "My Names", detail: "Extend, renew, list, transfer or release them, and pick the one KaChat shows for you.")
            if model.mine.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "at.circle")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundColor(.accentColor)
                    Text("No .kachat names yet")
                        .font(.headline)
                    Text("Search for a name above and claim it.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.mine.enumerated()), id: \.element.id) { index, n in
                        NavigationLink { KachatListingDetailView(info: n) } label: { KachatLiveNameRow(info: n, showRenewal: true) }
                            .buttonStyle(.plain)
                        if index < model.mine.count - 1 { Divider().padding(.leading, 62) }
                    }
                }
                .kachatGlass()
                .padding(.horizontal, 16)
            }

            KachatLiveSectionHeader(title: "My Offers", detail: "Offers you made. Withdraw one any time; once it passes its refund time anyone can return it to you.")
            if model.myOffers.isEmpty {
                KachatLiveEmpty(text: model.loaded ? "No open offers." : nil)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.myOffers.enumerated()), id: \.element.id) { index, o in
                        KachatOfferRow(offer: o, isBuyer: true, isOwner: false) { offerAction = $0 }
                        if index < model.myOffers.count - 1 { Divider().padding(.leading, 50) }
                    }
                }
                .kachatGlass()
                .padding(.horizontal, 16)
            }
            if registry.source == .chain {
                Text("Offers from others appear once a names indexer is connected.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 20)
            }
        }
        .padding(.top, 4)
        .sheet(item: $offerAction) { action in action.sheet }
    }
}

struct KachatLiveActivityPage: View {
    @ObservedObject var model: KachatHubModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KachatLiveSectionHeader(title: "Recent activity", detail: "Claims, renewals, listings, sales and transfers across the registry.")
            if model.activity.isEmpty {
                KachatLiveEmpty(text: model.loaded ? "Nothing yet." : nil)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.activity.prefix(100).enumerated()), id: \.element.id) { index, e in
                        KachatEventRow(event: e, showName: true)
                        if index < min(model.activity.count, 100) - 1 { Divider().padding(.leading, 56) }
                    }
                }
                .kachatGlass()
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 4)
    }
}

struct KachatLiveSectionHeader: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let detail {
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
    }
}

struct KachatLiveEmpty: View {
    /// nil while loading
    let text: LocalizedStringKey?

    var body: some View {
        Group {
            if let text {
                Text(text).font(.subheadline).foregroundColor(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .kachatGlass()
        .padding(.horizontal, 16)
    }
}

struct KachatEventRow: View {
    let event: KachatNames.Event
    var showName = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: KachatLive.eventIcon(event.op))
                .foregroundColor(.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(KachatLive.eventTitle(event.op))
                    if showName, let name = event.name {
                        Text(verbatim: "\(name).kachat")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                HStack(spacing: 4) {
                    if let to = KachatLive.party(event.to), event.op != "offer" {
                        Text(verbatim: "→ \(to)")
                    }
                    if let at = event.at {
                        Text(KachatLive.date(at), format: .relative(presentation: .named))
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let price = event.price {
                Text(verbatim: KaspaUnit.amount(price)).font(.subheadline)
            } else if let years = event.years {
                Text(verbatim: "+\(years)").font(.subheadline).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

// MARK: - Offers

/// What the person wants to do with an offer.
struct KachatOfferAction: Identifiable {
    enum Kind { case withdraw, refund, accept }
    let kind: Kind
    let offer: KachatNames.OfferInfo
    var name: KachatNames.NameInfo?

    var id: String { "\(kind)-\(offer.id)" }

    @ViewBuilder @MainActor
    var sheet: some View {
        switch kind {
        case .withdraw:
            KachatTxSheet(
                title: "Withdraw Offer", confirmTitle: "Withdraw",
                authReason: KachatLive.authReason, doneTitle: "Offer withdrawn",
                rows: [.init(title: "Offer", value: KaspaUnit.amount(offer.amount))],
                operation: .withdraw(offer), operationKey: offer.id
            )
        case .refund:
            KachatTxSheet(
                title: "Refund Offer", confirmTitle: "Refund",
                authReason: KachatLive.authReason, doneTitle: "Offer refunded",
                rows: [.init(title: "Offer", value: KaspaUnit.amount(offer.amount))],
                operation: .refund(offer), operationKey: offer.id
            )
        case .accept:
            if let n = name {
                KachatTxSheet(
                    title: "Accept Offer", confirmTitle: "Accept and Transfer",
                    authReason: KachatLive.authReason, doneTitle: "Offer accepted",
                    warning: "The name goes to the buyer and the offer's amount comes to you, in one transaction. This can't be undone.",
                    rows: [.init(title: "Name", value: n.display), .init(title: "Offer", value: KaspaUnit.amount(offer.amount)),
                           .init(title: "Buyer", value: KachatNamesRegistry.address(of: offer.buyer).map(KachatNamesRegistry.shortAddress) ?? "")],
                    operation: .accept(offer, name: n), operationKey: offer.id
                )
            }
        }
    }
}

struct KachatOfferRow: View {
    let offer: KachatNames.OfferInfo
    let isBuyer: Bool
    let isOwner: Bool
    let onAction: (KachatOfferAction) -> Void
    var name: KachatNames.NameInfo?

    @ObservedObject private var actions = KachatNamesActions.shared

    private var refundable: Bool { actions.virtualDaa.map { offer.refundable(atDaa: $0) } ?? false }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised").foregroundColor(.accentColor).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                if let n = offer.name {
                    Text(verbatim: "\(n).kachat").font(.subheadline.weight(.semibold))
                }
                Group {
                    if isBuyer {
                        Text("Your offer")
                    } else if let a = KachatNamesRegistry.address(of: offer.buyer) {
                        Text(verbatim: KachatNamesRegistry.shortAddress(a))
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
                if refundable {
                    Text("Refundable now").font(.caption2).foregroundColor(.orange)
                }
            }
            Spacer(minLength: 8)
            Text(verbatim: KaspaUnit.amount(offer.amount)).font(.subheadline.weight(.semibold))
            if isBuyer {
                Menu {
                    Button("Withdraw") { onAction(KachatOfferAction(kind: .withdraw, offer: offer)) }
                    if refundable {
                        Button("Refund") { onAction(KachatOfferAction(kind: .refund, offer: offer)) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            } else if isOwner {
                Button("Accept") { onAction(KachatOfferAction(kind: .accept, offer: offer, name: name)) }
                    .buttonStyle(.borderedProminent)
            } else if refundable {
                Button("Refund") { onAction(KachatOfferAction(kind: .refund, offer: offer)) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

// MARK: - The transaction sheet

struct KachatTxRow: Identifiable {
    let id = UUID()
    let title: LocalizedStringKey
    let value: String
}

/// Every action's sheet: its inputs, what it costs (built against live UTXOs, nothing sent),
/// one Confirm - an extra warning for the destructive ones - then the device lock, then the
/// transaction. Shows the txid when it is sent.
struct KachatTxSheet<Inputs: View>: View {
    let title: LocalizedStringKey
    let confirmTitle: LocalizedStringKey
    let authReason: String
    /// The headline of the finished-transaction half sheet (a localization key).
    var doneTitle: String = "Transaction sent"
    var warning: LocalizedStringKey? = nil
    var footer: LocalizedStringKey? = nil
    var rows: [KachatTxRow] = []
    let operation: KachatNamesActions.Operation?
    let operationKey: String
    var onDone: (String) -> Void = { _ in }
    @ViewBuilder var inputs: () -> Inputs

    @Environment(\.dismiss) private var dismiss
    @State private var plan: KachatNames.Plan?
    @State private var planError: String?
    @State private var building = false
    @State private var sending = false
    @State private var confirmWarning = false
    @State private var txId: String?
    @State private var done: KachatTxDone?
    @State private var sendError: String?

    var body: some View {
        NavigationStack {
            Form {
                inputs()
                Section {
                    ForEach(rows) { row in
                        LabeledRow(title: row.title, value: row.value)
                    }
                    if let plan {
                        if plan.priceFee > 0 {
                            LabeledRow(title: "Price (to miners)", value: KaspaUnit.amount(plan.priceFee))
                        }
                        LabeledRow(title: "Network fee", value: KaspaUnit.amount(plan.networkFee))
                        // Names always spend from, and pay back to, the chatting address: show its
                        // real balance and what it will be once this is sent.
                        if let me = KachatNamesActions.shared.myKey {
                            let change = Self.balanceChange(plan, me: me)
                            if let balance = WalletManager.shared.currentWallet?.balanceSompi {
                                LabeledRow(title: "Chatting address balance", value: KaspaUnit.amount(balance))
                                LabeledRow(title: "Balance after", value: KaspaUnit.amount(UInt64(max(0, Int64(balance) + change))), bold: true)
                            } else {
                                LabeledRow(title: "Balance change", value: KaspaUnit.signed(change), bold: true)
                            }
                        }
                    } else if building {
                        HStack { Text("Network fee"); Spacer(); ProgressView() }
                    }
                } footer: {
                    if let planError {
                        Text(verbatim: planError).foregroundColor(.red)
                    } else if let footer {
                        Text(footer)
                    }
                }
                if let warning {
                    Section {
                        Label { Text(warning) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                            .foregroundColor(.red)
                    }
                }
                Section {
                    if let txId {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Sent", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                            Text(verbatim: txId)
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                            Text("It shows here once the network accepts it, usually within seconds.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Button(role: warning == nil ? nil : ButtonRole.destructive) {
                            if warning != nil { confirmWarning = true } else { authorize() }
                        } label: {
                            HStack {
                                Spacer()
                                if sending { ProgressView() } else { Text(confirmTitle).font(.headline) }
                                Spacer()
                            }
                        }
                        .disabled(plan == nil || sending)
                    }
                } footer: {
                    if let sendError { Text(verbatim: sendError).foregroundColor(.red) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: txId == nil ? .cancellationAction : .confirmationAction) {
                    Button { dismiss() } label: {
                        if txId == nil { Text("Cancel") } else { Text("Done") }
                    }
                }
            }
            .task(id: operationKey) { await rebuild() }
            .sheet(item: $done, onDismiss: { dismiss() }) { KachatTxDoneSheet(done: $0) }
            .alert(Text(title), isPresented: $confirmWarning) {
                Button(confirmTitle, role: .destructive) { authorize() }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let warning { Text(warning) }
            }
        }
    }

    private func rebuild() async {
        plan = nil
        planError = nil
        guard let operation else { return }
        building = true
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        do {
            plan = try await KachatNamesActions.shared.plan(operation)
        } catch {
            planError = error.localizedDescription
        }
        building = false
    }

    private func authorize() {
        DeviceAuth.authenticate(reason: authReason) {
            Task { @MainActor in await send() }
        }
    }

    private func send() async {
        guard let operation else { return }
        sending = true
        sendError = nil
        do {
            let id = try await KachatNamesActions.shared.perform(operation)
            txId = id
            Haptics.success()
            onDone(id)
            done = KachatTxDone(txId: id, title: doneTitle)
        } catch {
            sendError = error.localizedDescription
        }
        sending = false
    }

    /// What the transaction does to the wallet: its outputs to the wallet minus its inputs from it.
    static func balanceChange(_ plan: KachatNames.Plan, me: Data) -> Int64 {
        let mine = KachatNames.Codec.p2pkScript(me)
        let received = plan.unsignedTx.outputs.filter { $0.script == mine }.reduce(UInt64(0)) { $0 + $1.value }
        let spent = plan.entries.filter { $0.script == mine }.reduce(UInt64(0)) { $0 + $1.amount }
        return Int64(bitPattern: received &- spent)
    }
}

extension KachatTxSheet where Inputs == EmptyView {
    init(title: LocalizedStringKey, confirmTitle: LocalizedStringKey, authReason: String, doneTitle: String = "Transaction sent",
         warning: LocalizedStringKey? = nil, footer: LocalizedStringKey? = nil, rows: [KachatTxRow] = [],
         operation: KachatNamesActions.Operation?, operationKey: String, onDone: @escaping (String) -> Void = { _ in }) {
        self.init(title: title, confirmTitle: confirmTitle, authReason: authReason, doneTitle: doneTitle, warning: warning, footer: footer,
                  rows: rows, operation: operation, operationKey: operationKey, onDone: onDone, inputs: { EmptyView() })
    }
}

private struct LabeledRow: View {
    let title: LocalizedStringKey
    let value: String
    var bold = false

    var body: some View {
        HStack {
            Text(title).fontWeight(bold ? .semibold : .regular)
            Spacer()
            Text(verbatim: value)
                .fontWeight(bold ? .semibold : .regular)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
    }
}

// MARK: - Claim

struct KachatClaimSheet: View {
    let target: KachatClaimTarget
    var onStarted: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var years: Int64 = 1
    @State private var quote: KachatNamesActions.Quote?
    @State private var quoteError: String?
    @State private var starting = false
    @State private var startError: String?

    private var maxYears: Int64 { KachatNamesService.shared.manifest?.params.maxYears ?? 2 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Name")
                        Spacer()
                        Text(verbatim: "\(target.name).kachat").fontWeight(.semibold)
                    }
                    Picker("Years", selection: $years) {
                        ForEach(1...max(1, Int(maxYears)), id: \.self) { y in
                            KachatYearsText(years: y).tag(Int64(y))
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    if let q = quote {
                        LabeledRow(title: "Price (to miners)", value: "\(KaspaUnit.amount(q.price / UInt64(max(q.years, 1)))) × \(q.years)")
                        LabeledRow(title: "Bond (returned on release)", value: KaspaUnit.amount(q.bond))
                        LabeledRow(title: "Registry deposit (returned on release)", value: KaspaUnit.amount(q.gapDeposit))
                        LabeledRow(title: "Commit (returned at registration)", value: KaspaUnit.amount(q.commit))
                        LabeledRow(title: "Network fees", value: KaspaUnit.amount(q.networkFee))
                        LabeledRow(title: "Total", value: KaspaUnit.amount(q.total), bold: true)
                        LabeledRow(title: "Available", value: KaspaUnit.amount(q.spendable))
                    } else if let quoteError {
                        Text(verbatim: quoteError).foregroundColor(.red)
                    } else {
                        HStack { Text("Total"); Spacer(); ProgressView() }
                    }
                } header: {
                    Text("Cost")
                } footer: {
                    if let q = quote, !q.affordable {
                        KaspaUnit.text("Not enough KAS on your chatting address for this name.")
                            .foregroundColor(.red)
                    } else {
                        Text("The price goes to the miners - KaChat takes nothing. The bond and the deposit come back when you release the name.")
                    }
                }

                Section {
                    stepRow(1, "A hidden commit goes on chain first. Nobody can see which name it is for.")
                    stepRow(2, "About a minute later KaChat registers the name by itself. Keep the app open; if you leave, it continues next time.")
                    stepRow(3, "The name is yours for the years you paid, at most 2 ahead. A 1-year name can be extended to 2 years; from 10 days before it expires you can renew it.")
                } header: {
                    Text("How claiming works")
                }

                Section {
                    Button {
                        DeviceAuth.authenticate(reason: KachatLive.authReason) {
                            Task { @MainActor in await start() }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if starting { ProgressView() } else { Text("Claim \(target.name).kachat").font(.headline) }
                            Spacer()
                        }
                    }
                    .disabled(quote?.affordable != true || starting)
                } footer: {
                    if let startError { Text(verbatim: startError).foregroundColor(.red) }
                }
            }
            .navigationTitle("Claim Name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task(id: years) {
                quote = nil
                quoteError = nil
                do {
                    quote = try await KachatNamesActions.shared.quote(name: target.name, years: years, gap: target.gap)
                } catch {
                    quoteError = error.localizedDescription
                }
            }
        }
    }

    private func stepRow(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: "\(n)")
                .font(.caption.weight(.bold))
                .foregroundColor(.accentColor)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            Text(text).font(.subheadline)
        }
    }

    private func start() async {
        starting = true
        startError = nil
        do {
            try await KachatNamesActions.shared.startRegistration(name: target.name, years: years)
            Haptics.success()
            onStarted()
            dismiss()
        } catch {
            startError = error.localizedDescription
        }
        starting = false
    }
}

// MARK: - Name detail

/// A registered name, live: who owns it, its status and expiry, its price, and what the person
/// can do with it - buy, offer or message the owner; or, for their own names, renew, list,
/// transfer, release and make it their primary name. Offers and history below.
struct KachatLiveNameDetail: View {
    @State var info: KachatNames.NameInfo
    @ObservedObject private var registry = KachatNamesRegistry.shared
    @ObservedObject private var actions = KachatNamesActions.shared

    private enum Sheet: Identifiable {
        case buy, offer, extend, renew, list, delist, transfer, release, reclaim
        var id: Int { hashValue }
    }

    @State private var sheet: Sheet?
    @State private var offerAction: KachatOfferAction?
    @State private var ownerLabel: String?
    @State private var offers: [KachatNames.OfferInfo] = []
    @State private var history: [KachatNames.Event] = []
    @State private var gone = false
    @State private var confirmPrimary = false

    private var mine: Bool { KachatLive.isMine(info.owner) }
    private var status: KachatNames.Status { info.status(graceMs: registry.graceMs) }
    private var ownerAddress: String? { KachatNamesRegistry.address(of: info.owner) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                nameCard
                if gone {
                    Text("This name was released or reclaimed. It's free to claim again.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 20)
                } else {
                    actionButtons
                    ownerCard
                    offersSection
                }
                historySection
            }
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(info.display)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await registry.refresh() }
        .task(id: registry.revision) { await reload() }
        .sheet(item: $sheet) { s in sheetView(s) }
        .sheet(item: $offerAction) { action in action.sheet }
        .sheet(isPresented: $confirmPrimary) {
            KachatProfileSaveSheet(title: "Set as Primary", confirmTitle: "Set as Primary", doneTitle: "Primary name set",
                                   makeProfile: { await primaryProfile() })
        }
    }

    // MARK: Parts

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.accentColor)
                .frame(height: 110)
                .overlay(
                    Text(verbatim: info.display)
                        .font(.title2.weight(.heavy))
                        .foregroundColor(.black)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 16)
                )
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        if info.isListed { Text("Price") } else { Text("Not for sale") }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    if info.isListed {
                        Text(verbatim: KaspaUnit.amount(info.price)).font(.title3.weight(.bold))
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    KachatStatusPill(status: status)
                    Text("Expires \(KachatLive.date(info.expiresAt), format: .dateTime.year().month().day())")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            if let start = info.periodStart {
                // registry v2: the paid period, from its start to the expiry (at most 2 years)
                Label {
                    Text("Paid from \(KachatLive.date(start), format: .dateTime.year().month().day()) to \(KachatLive.date(info.expiresAt), format: .dateTime.year().month().day())")
                } icon: {
                    Image(systemName: "calendar")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            switch status {
            case .grace where mine:
                Text("Expired - renew to keep it. Until the grace period ends nobody else can take it.")
                    .font(.footnote).foregroundColor(.orange)
            case .grace:
                Text("Expired. It no longer resolves; the owner can still renew it.")
                    .font(.footnote).foregroundColor(.orange)
            case .lapsed:
                Text("Lapsed: anyone may reclaim it, and then claim it again.")
                    .font(.footnote).foregroundColor(.red)
            case .active:
                EmptyView()
            }
        }
        .padding(14)
        .kachatGlass(cornerRadius: 18)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 10) {
            if mine {
                periodActions
                HStack(spacing: 10) {
                    actionButton(info.isListed ? "Change Price" : "List for Sale", "tag") { sheet = .list }
                        .disabled(status != .active)
                    actionButton("Transfer", "arrow.left.arrow.right") { sheet = .transfer }
                }
                HStack(spacing: 10) {
                    if info.isListed {
                        actionButton("Delist", "tag.slash") { sheet = .delist }
                    }
                    actionButton("Set as Primary", "person.crop.circle.badge.checkmark") { confirmPrimary = true }
                        .disabled(status != .active)
                }
                Button(role: .destructive) { sheet = .release } label: {
                    Label("Release Name", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
            } else {
                switch status {
                case .lapsed:
                    actionButton("Reclaim", "arrow.3.trianglepath", prominent: true) { sheet = .reclaim }
                default:
                    HStack(spacing: 10) {
                        if info.isListed && status == .active {
                            actionButton("Buy Now", "cart", prominent: true) { sheet = .buy }
                        }
                        actionButton("Make an Offer", "hand.raised") { sheet = .offer }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    /// Registry v2: "Extend" while the paid period holds less than 2 years (labelled "Extend to
    /// 2 years" when that fills it), "Renew" once the renewal window is open (10 days before
    /// the expiry, and on through grace and lapse), otherwise "Renewal opens on <date>".
    @ViewBuilder
    private var periodActions: some View {
        if let p = KachatLive.params {
            let extendable = info.extendableYears(p)
            let renewOpen = info.renewOpen(p)
            if extendable > 0 || renewOpen {
                HStack(spacing: 10) {
                    if extendable > 0 {
                        if KachatExtendSheet.fillsPeriod(info, years: extendable, params: p) {
                            actionButton("Extend to \(p.maxYears) years", "calendar.badge.plus", prominent: status != .active && !renewOpen) { sheet = .extend }
                        } else {
                            actionButton("Extend", "calendar.badge.plus", prominent: status != .active && !renewOpen) { sheet = .extend }
                        }
                    }
                    if renewOpen {
                        actionButton("Renew", "arrow.clockwise", prominent: status != .active) { sheet = .renew }
                    }
                }
            }
            if !renewOpen {
                Button {} label: {
                    Label {
                        Text("Renewal opens on \(KachatLive.date(info.renewOpens(p)), format: .dateTime.year().month().day())")
                    } icon: {
                        Image(systemName: "calendar.badge.clock")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .disabled(true)
            }
        }
    }

    private func actionButton(_ title: LocalizedStringKey, _ icon: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Group {
            if prominent {
                Button(action: action) {
                    Label(title, systemImage: icon).font(.subheadline.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(action: action) {
                    Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var ownerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            KachatLiveSectionHeader(title: "Owner", detail: nil)
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 34))
                    .foregroundColor(.accentColor.opacity(0.6))
                VStack(alignment: .leading, spacing: 3) {
                    if mine {
                        Text("You").font(.subheadline.weight(.semibold))
                    } else if let ownerLabel {
                        Text(verbatim: "\(ownerLabel).kachat").font(.subheadline.weight(.semibold))
                    }
                    if let ownerAddress {
                        Text(verbatim: ownerAddress)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
                if !mine, let ownerAddress {
                    Button {
                        KachatLive.message(ownerAddress)
                    } label: {
                        Label("Message", systemImage: "bubble.left.and.bubble.right").font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(14)
            .kachatGlass()
            .padding(.horizontal, 16)
        }
    }

    private var offersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            KachatLiveSectionHeader(title: "Offers", detail: mine ? "Accept one to sell the name for it." : nil)
            if offers.isEmpty {
                Text("No open offers.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .kachatGlass()
                    .padding(.horizontal, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(offers.enumerated()), id: \.element.id) { index, o in
                        KachatOfferRow(offer: o, isBuyer: KachatLive.isMine(o.buyer), isOwner: mine && registry.source?.isIndexer == true,
                                       onAction: { offerAction = $0 }, name: info)
                        if index < offers.count - 1 { Divider().padding(.leading, 50) }
                    }
                }
                .kachatGlass()
                .padding(.horizontal, 16)
            }
            if registry.source == .chain {
                Text("Offers from others appear once a names indexer is connected.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 20)
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            KachatLiveSectionHeader(title: "History", detail: nil)
            if history.isEmpty {
                Text("No history yet.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .kachatGlass()
                    .padding(.horizontal, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(history.prefix(50).enumerated()), id: \.element.id) { index, e in
                        KachatEventRow(event: e)
                        if index < min(history.count, 50) - 1 { Divider().padding(.leading, 56) }
                    }
                }
                .kachatGlass()
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetView(_ s: Sheet) -> some View {
        switch s {
        case .buy: KachatBuySheet(info: info)
        case .offer: KachatOfferSheet(info: info)
        case .extend: KachatExtendSheet(info: info)
        case .renew: KachatRenewSheet(info: info)
        case .list: KachatListSheet(info: info)
        case .delist:
            KachatTxSheet(
                title: "Delist", confirmTitle: "Delist",
                authReason: KachatLive.authReason, doneTitle: "Delisted",
                rows: [.init(title: "Name", value: info.display), .init(title: "Listed at", value: KaspaUnit.amount(info.price))],
                operation: .list(info, price: 0), operationKey: "delist-\(info.outpoint.index)-\(KachatNames.hex(info.outpoint.txid))"
            )
        case .transfer: KachatTransferSheet(info: info)
        case .release:
            KachatTxSheet(
                title: "Release Name", confirmTitle: "Release",
                authReason: KachatLive.authReason, doneTitle: "Name released",
                warning: "Releasing gives the name up for good: it becomes free for anyone to register, and the time you paid for is lost. You get the bond and the registry deposit back.",
                rows: [.init(title: "Name", value: info.display)],
                operation: .release(info), operationKey: "release-\(KachatNames.hex(info.outpoint.txid))"
            )
        case .reclaim: KachatReclaimSheet(info: info)
        }
    }

    // MARK: Loading

    private func reload() async {
        do {
            switch try await registry.lookup(info.name) {
            case .registered(let n):
                info = n
                gone = false
            case .free:
                gone = true
            }
        } catch {}
        if !mine, let ownerAddress, let id = try? await registry.identity(address: ownerAddress) {
            ownerLabel = id.label
        }
        offers = (try? await registry.offers(for: info.name)) ?? []
        history = (try? await registry.history(name: info.name)) ?? []
        if !offers.isEmpty {
            await actions.refreshVirtualDaa()
        }
    }

    /// Your current profile with this name as the primary one: setting it rewrites the record.
    private func primaryProfile() async -> KachatNames.Profile {
        var profile = KachatNames.Profile()
        if let address = actions.myAddress {
            if let own = registry.ownProfile(for: address)?.profile {
                profile = own
            } else if let p = try? await registry.identity(address: address).profile {
                profile = p
            }
        }
        profile.primaryName = info.name
        return profile
    }
}

// MARK: - Sheets with inputs

struct KachatLiveBuySheet: View {
    let info: KachatNames.NameInfo

    var body: some View {
        KachatTxSheet(
            title: "Buy Name", confirmTitle: "Confirm Purchase",
            authReason: KachatLive.authReason, doneTitle: "Name bought",
            footer: soon ? "Less than 30 days are left before this name expires. You'd have to renew it soon." : "The payment reaches the seller and the name reaches you in the same transaction - both happen, or neither does.",
            rows: [.init(title: "Name", value: info.display), .init(title: "Price (to the seller)", value: KaspaUnit.amount(info.price)),
                   .init(title: "Expires", value: KachatLive.date(info.expiresAt).formatted(date: .abbreviated, time: .omitted))],
            operation: .buy(info), operationKey: "buy-\(KachatNames.hex(info.outpoint.txid))"
        )
    }

    private var soon: Bool { info.expiresAt - 30 * 86_400_000 < KachatNames.nowMs() }
}

struct KachatLiveOfferSheet: View {
    let name: String
    let info: KachatNames.NameInfo?

    @State private var amountText = ""
    @State private var days = 3
    @State private var virtualDaa: UInt64?

    private var amount: UInt64? { KaspaUnit.parseSompi(amountText).flatMap { $0 > 0 ? $0 : nil } }
    private var refundAfter: UInt64? { virtualDaa.map { $0 + UInt64(days) * 86_400 * KachatLive.daaPerSecond } }

    private var operation: KachatNamesActions.Operation? {
        guard let amount, let refundAfter else { return nil }
        return .offer(name: name, amount: amount, refundAfterDaa: refundAfter, target: info)
    }

    var body: some View {
        KachatTxSheet(
            title: "Make an Offer", confirmTitle: "Send Offer",
            authReason: KachatLive.authReason, doneTitle: "Offer sent",
            footer: belowListing ? "This name is listed for less than your offer. Anyone could buy the listing with your offer, so consider buying it instead." : nil,
            rows: rows,
            operation: operation, operationKey: "\(amount ?? 0)-\(days)-\(virtualDaa ?? 0)"
        ) {
            Section {
                HStack {
                    TextField("0", text: $amountText)
                        .keyboardType(.decimalPad)
                        .font(.title3.weight(.semibold))
                    Text(verbatim: KaspaUnit.symbol).foregroundColor(.secondary)
                }
            } header: {
                Text("Your offer")
            } footer: {
                KaspaUnit.text("Your KAS stays locked on chain until the owner accepts, you withdraw the offer, or it expires - then anyone can send it back to you.")
            }
            Section {
                Picker("Expires", selection: $days) {
                    Text("1 Day").tag(1)
                    Text("3 Days").tag(3)
                    Text("7 Days").tag(7)
                    Text("30 Days").tag(30)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Refundable after")
            }
        }
        .task {
            virtualDaa = await NodePoolService.shared.currentVirtualDaaScore()
        }
    }

    private var belowListing: Bool {
        guard let info, info.isListed, let amount else { return false }
        return info.price < amount
    }

    private var rows: [KachatTxRow] {
        var r: [KachatTxRow] = [.init(title: "Name", value: "\(name).kachat")]
        if let info, info.isListed { r.append(.init(title: "Listed at", value: KaspaUnit.amount(info.price))) }
        if let info { r.append(.init(title: "Expires", value: KachatLive.date(info.expiresAt).formatted(date: .abbreviated, time: .omitted))) }
        if let amount { r.append(.init(title: "Offer", value: KaspaUnit.amount(amount))) }
        return r
    }
}

/// Registry v2 `extend`: years added to the current paid period (periodStart kept), up to 2
/// years past its start - in practice a 1-year name extended to 2. Anyone may extend any name.
struct KachatExtendSheet: View {
    let info: KachatNames.NameInfo
    @State private var years: Int64 = 1

    private var params: KachatNames.Params? { KachatLive.params }
    private var maxYears: Int64 { params?.maxYears ?? 2 }
    /// The years that still fit in the period (in practice 1).
    private var available: Int64 { max(1, params.map { info.extendableYears($0) } ?? 1) }
    private var perYear: UInt64 { params?.renewPrice(forLength: info.name.utf8.count) ?? 0 }

    /// Whether extending by `years` fills the period to exactly `maxYears`.
    static func fillsPeriod(_ info: KachatNames.NameInfo, years: Int64, params p: KachatNames.Params) -> Bool {
        guard let start = info.periodStart else { return false }
        return info.expiresAt + years * KachatNames.yearMs == start + p.maxYears * KachatNames.yearMs
    }

    private var title: LocalizedStringKey {
        if let params, Self.fillsPeriod(info, years: years, params: params) { return "Extend to \(maxYears) years" }
        return "Extend"
    }

    var body: some View {
        KachatTxSheet(
            title: title, confirmTitle: "Extend",
            authReason: KachatLive.authReason, doneTitle: "Extended",
            footer: "Extending adds years to the current paid period, which holds at most 2 years. The price goes to the miners.",
            rows: [
                .init(title: "Name", value: info.display),
                .init(title: "Price per year", value: KaspaUnit.amount(perYear)),
                .init(title: "Expires", value: KachatLive.day(info.expiresAt)),
                .init(title: "New expiry", value: KachatLive.day(info.expiresAt + years * KachatNames.yearMs))
            ],
            operation: .extend(info, years: min(years, available)), operationKey: "extend-\(years)"
        ) {
            if available > 1 {
                Section {
                    Picker("Years", selection: $years) {
                        ForEach(1...Int(available), id: \.self) { y in
                            KachatYearsText(years: y).tag(Int64(y))
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }
}

/// Registry v2 `renew`: the next period, from the current expiry, for 1 or 2 years - only once
/// the renewal window is open (10 days before the expiry; the detail screen says when).
struct KachatRenewSheet: View {
    let info: KachatNames.NameInfo
    @State private var years: Int64 = 1

    private var maxYears: Int64 { KachatLive.params?.maxYears ?? 2 }
    private var perYear: UInt64 { KachatLive.params?.renewPrice(forLength: info.name.utf8.count) ?? 0 }

    var body: some View {
        KachatTxSheet(
            title: "Renew", confirmTitle: "Renew",
            authReason: KachatLive.authReason, doneTitle: "Renewed",
            footer: "A renewal starts the next period at the current expiry, so no time is lost or gained, even after it passed. The price goes to the miners.",
            rows: [
                .init(title: "Name", value: info.display),
                .init(title: "Price per year", value: KaspaUnit.amount(perYear)),
                .init(title: "New period", value: "\(KachatLive.day(info.expiresAt)) – \(KachatLive.day(info.expiresAt + years * KachatNames.yearMs))")
            ],
            operation: .renew(info, years: years), operationKey: "renew-\(years)"
        ) {
            Section {
                Picker("Years", selection: $years) {
                    ForEach(1...max(1, Int(maxYears)), id: \.self) { y in
                        KachatYearsText(years: y).tag(Int64(y))
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }
}

struct KachatListSheet: View {
    let info: KachatNames.NameInfo
    @State private var priceText = ""

    private var price: UInt64? { KaspaUnit.parseSompi(priceText).flatMap { $0 > 0 ? $0 : nil } }

    var body: some View {
        KachatTxSheet(
            title: info.isListed ? "Change Price" : "List for Sale", confirmTitle: info.isListed ? "Change Price" : "List",
            authReason: KachatLive.authReason, doneTitle: info.isListed ? "Price changed" : "Listed for sale",
            footer: "Anyone can buy it at this price: the payment reaches you and the name reaches them in one transaction. Delist any time.",
            rows: info.isListed ? [.init(title: "Listed at", value: KaspaUnit.amount(info.price))] : [],
            operation: price.map { .list(info, price: $0) }, operationKey: "list-\(price ?? 0)"
        ) {
            Section {
                HStack {
                    TextField("0", text: $priceText)
                        .keyboardType(.decimalPad)
                        .font(.title3.weight(.semibold))
                    Text(verbatim: KaspaUnit.symbol).foregroundColor(.secondary)
                }
            } header: {
                Text("Price")
            }
        }
    }
}

struct KachatTransferSheet: View {
    let info: KachatNames.NameInfo
    @State private var input = ""
    @State private var resolved: (address: String, key: Data)?
    @State private var resolveError: LocalizedStringKey?
    @State private var resolving = false

    var body: some View {
        KachatTxSheet(
            title: "Transfer", confirmTitle: "Transfer",
            authReason: KachatLive.authReason, doneTitle: "Name transferred",
            warning: "A transfer can't be undone. The new owner gets the name with its current expiry; your profile stays with your address.",
            rows: [KachatTxRow(title: "Name", value: info.display)] + (resolved.map { [KachatTxRow(title: "To", value: $0.address)] } ?? []),
            operation: resolved.map { .transfer(info, to: $0.key) }, operationKey: resolved?.address ?? "-"
        ) {
            Section {
                TextField("kaspatest:... or name.kachat", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if resolving {
                    ProgressView()
                } else if let resolved {
                    Text(verbatim: resolved.address)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                } else if let resolveError {
                    Text(resolveError).font(.caption).foregroundColor(.red)
                }
            } header: {
                Text("New owner")
            } footer: {
                Text("A testnet address, or a .kachat name - it's resolved to the address shown.")
            }
        }
        .task(id: input) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await resolve()
        }
    }

    private func resolve() async {
        resolved = nil
        resolveError = nil
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return }
        if t.hasPrefix("kaspatest:") || t.hasPrefix("kaspa:") {
            guard let key = KachatNamesRegistry.keyOf(t) else {
                resolveError = "Not a testnet Schnorr address."
                return
            }
            guard (try? KachatNamesActions.validateKey(key, "")) != nil else {
                resolveError = "That address's key is not valid."
                return
            }
            resolved = (t, key)
            return
        }
        let name = KachatNames.Codec.normalize(t)
        guard KachatLive.invalidReason(name) == nil else {
            resolveError = "Enter an address or a .kachat name."
            return
        }
        resolving = true
        defer { resolving = false }
        do {
            switch try await KachatNamesRegistry.shared.lookup(name) {
            case .registered(let n) where n.status(graceMs: KachatNamesRegistry.shared.graceMs) == .active:
                if let a = KachatNamesRegistry.address(of: n.owner) { resolved = (a, n.owner) }
            default:
                resolveError = "No active .kachat name by that name."
            }
        } catch {
            resolveError = "Couldn't look that name up."
        }
    }
}

struct KachatReclaimSheet: View {
    let info: KachatNames.NameInfo

    var body: some View {
        KachatTxSheet(
            title: "Reclaim", confirmTitle: "Reclaim",
            authReason: KachatLive.authReason, doneTitle: "Name reclaimed",
            footer: "The name's bond goes back to its last owner, you keep the freed registry deposit (less the fee) as a bounty, and the name is free. To own it, claim it afterwards.",
            rows: [
                .init(title: "Name", value: info.display),
                .init(title: "Bond to the last owner", value: KaspaUnit.amount(KachatNamesService.shared.manifest?.params.bond ?? 0))
            ],
            operation: .reclaim(info), operationKey: "reclaim-\(KachatNames.hex(info.outpoint.txid))"
        )
    }
}

// MARK: - Your Domains > .kachat

struct KachatLiveDomainsTab: View {
    let walletAddress: String
    @ObservedObject private var registry = KachatNamesRegistry.shared
    @State private var names: [KachatNames.NameInfo] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if !loaded {
                    ProgressView().padding(.vertical, 24)
                } else if names.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "at.circle")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundColor(.accentColor)
                        Text("No .kachat names yet")
                            .font(.headline)
                        Text("Claim one in Kaspa Hub > .kachat.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    ForEach(names) { n in
                        NavigationLink {
                            KachatListingDetailView(info: n)
                        } label: {
                            DomainNameCardView(title: n.display, badge: badge(n))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
        .refreshable { await registry.refresh() }
        .task(id: registry.revision) { await load() }
    }

    private func badge(_ n: KachatNames.NameInfo) -> String? {
        switch n.status(graceMs: registry.graceMs) {
        case .active: return n.isListed ? AppLocalization.string("Listed") : nil
        case .grace: return AppLocalization.string("Expired")
        case .lapsed: return AppLocalization.string("Lapsed")
        }
    }

    private func load() async {
        guard let key = KachatNamesRegistry.keyOf(walletAddress) else { loaded = true; return }
        if registry.refreshedAt == nil { await registry.refresh() }
        names = (try? await registry.names(owner: key, includeInactive: true)) ?? []
        loaded = true
    }
}

// MARK: - Edit .kachat Profile

/// Where a social link's lookup stands - the editor saves only a field whose lookup found what
/// that field shows, so what gets saved is what was reviewed.
enum KachatSocialLookup: Equatable {
    case none, looking, found, empty, unreachable
}

/// One profile field's source (avatar, banner or bio) looked up on this device, showing exactly
/// the piece other people will see.
struct KachatSocialPreview: View {
    let link: String
    let kind: KachatNames.SocialSource.Kind
    @Binding var lookup: KachatSocialLookup

    @ObservedObject private var resolver = KachatSocialImageResolver.shared
    @State private var resolved: KachatNames.SocialProfile?
    @State private var attempt = 0
    /// The lookup whose answer may land: a newer one (edited link, Retry) supersedes it.
    @State private var activeKey = ""

    private var source: KachatNames.SocialSource? { KachatNames.SocialSource(link: link, for: kind) }

    private func piece(_ p: KachatNames.SocialProfile?) -> String? {
        switch kind {
        case .avatar: return p?.avatar
        case .banner: return p?.banner
        case .bio: return p?.bio
        }
    }

    var body: some View {
        // A VStack, not a Group: a Group hands its modifiers to each child, so `.task` below
        // would belong to whichever child shows - and switching from the spinner to the result
        // would cancel it and start the lookup again, endlessly. The VStack is one stable view.
        VStack(alignment: .leading, spacing: 0) {
            if let source {
                switch lookup {
                case .none, .looking:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking up the profile...").font(.footnote).foregroundColor(.secondary)
                    }
                case .found:
                    found(source)
                case .empty:
                    note("person.crop.circle.badge.exclamationmark", missingText(source.platform))
                case .unreachable:
                    HStack(spacing: 10) {
                        Image(systemName: "wifi.exclamationmark").foregroundColor(.secondary)
                        Text(verbatim: String(format: AppLocalization.string("Couldn't reach %@."), source.platform.displayName))
                            .font(.footnote).foregroundColor(.secondary)
                        Spacer()
                        Button("Retry") { attempt += 1 }.font(.footnote.weight(.semibold))
                    }
                }
            }
        }
        // Debounced: one lookup once typing pauses. `attempt` reruns it for Retry. Whatever
        // happens - cancelled, restarted, failed - the state always lands somewhere final.
        .task(id: "\(source?.link ?? "")#\(attempt)") {
            let myKey = "\(source?.link ?? "")#\(attempt)"
            activeKey = myKey
            guard let source else { resolved = nil; lookup = .none; return }
            lookup = .looking
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard activeKey == myKey else { return }
            let result = await resolver.resolve(source)
            guard activeKey == myKey else { return }
            resolved = result.profile
            switch result {
            case .answered(let p):
                lookup = piece(p) == nil ? .empty : .found
            case .unreachable(let cached):
                lookup = piece(cached) == nil ? .unreachable : .found
            }
        }
    }

    @ViewBuilder
    private func found(_ source: KachatNames.SocialSource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch kind {
            case .avatar:
                KNSAvatarView(avatarURLString: resolved?.avatar, fallbackText: "", size: 64)
            case .banner:
                KNSBannerImageView(bannerURLString: resolved?.banner, height: 90, cornerRadius: 8)
            case .bio:
                Text(verbatim: resolved?.bio ?? "").font(.subheadline)
            }
            Text(verbatim: String(format: AppLocalization.string("From %@"), source.platform.displayName))
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func missingText(_ platform: KachatNames.SocialSource.Platform) -> String {
        let key: String
        switch kind {
        case .avatar: key = "No avatar on this %@ profile."
        case .banner: key = "No banner on this %@ profile."
        case .bio: key = "No bio on this %@ profile."
        }
        return String(format: AppLocalization.string(key), platform.displayName)
    }

    private func note(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(.secondary)
            Text(verbatim: text).font(.footnote).foregroundColor(.secondary)
        }
    }
}

/// One profile field's source as the editor holds it: the platform picked and the handle typed.
struct KachatSourceInput: Equatable {
    var platform: KachatNames.SocialSource.Platform = .x
    var handle = ""

    init(platform: KachatNames.SocialSource.Platform = .x, handle: String = "") {
        self.platform = platform
        self.handle = handle
    }

    /// From a stored profile link.
    init(stored link: String?, _ kind: KachatNames.SocialSource.Kind) {
        if let s = KachatNames.SocialSource(link: link ?? "", for: kind) {
            self.init(platform: s.platform, handle: s.displayHandle)
        } else {
            self.init()
        }
    }

    var isEmpty: Bool { handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func source(_ kind: KachatNames.SocialSource.Kind) -> KachatNames.SocialSource? {
        KachatNames.SocialSource.from(platform: platform, handle: handle, for: kind)
    }

    func isBad(_ kind: KachatNames.SocialSource.Kind) -> Bool { !isEmpty && source(kind) == nil }

    /// The source when the handle field holds a whole pasted link (rather than a handle).
    func pastedSource(_ kind: KachatNames.SocialSource.Kind) -> KachatNames.SocialSource? {
        let t = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.lowercased().hasPrefix("http") || (t.contains(".") && t.contains("/")) else { return nil }
        return source(kind)
    }
}

/// The address profile (KACHAT_NAMES.md section 7): where the avatar, banner and bio come from
/// (a social profile link each - they can be different accounts), a Linktree link, and which of
/// your names labels you - written as a `kchat:1:profile:` self-transfer. No free text and no
/// uploads: what shows comes from a platform that moderates it.
struct KachatLiveProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var registry = KachatNamesRegistry.shared

    /// Each piece's source: a platform from the picker plus the handle typed after its prefix.
    @State private var avatarIn = KachatSourceInput()
    @State private var bannerIn = KachatSourceInput()
    @State private var bioIn = KachatSourceInput()
    @State private var avatarLookup: KachatSocialLookup = .none
    @State private var bannerLookup: KachatSocialLookup = .none
    @State private var bioLookup: KachatSocialLookup = .none
    @State private var linktree = ""
    @State private var primary = ""
    @State private var activeNames: [String] = []
    @State private var loaded = false
    @State private var showSave = false

    private typealias Kind = KachatNames.SocialSource.Kind

    private var profile: KachatNames.Profile {
        var p = KachatNames.Profile()
        p.avatar = avatarIn.source(.avatar)?.link
        p.banner = bannerIn.source(.banner)?.link
        p.bio = bioIn.source(.bio)?.link
        p.linktree = KachatNames.Profile.linktreeLink(username: linktree)
        p.primaryName = primary.isEmpty ? nil : primary
        return p.sanitized()
    }

    /// A field is saved only once its lookup found what it shows - what you reviewed.
    private func notReviewed(_ input: KachatSourceInput, _ lookup: KachatSocialLookup) -> Bool {
        !input.isEmpty && lookup != .found
    }

    private var blocked: Bool {
        avatarIn.isBad(.avatar) || bannerIn.isBad(.banner) || bioIn.isBad(.bio) || badLinktree
            || notReviewed(avatarIn, avatarLookup) || notReviewed(bannerIn, bannerLookup) || notReviewed(bioIn, bioLookup)
    }

    /// The Linktree field holds just the username (`linktr.ee/` is shown in front of it).
    private var badLinktree: Bool {
        let t = linktree.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && KachatNames.Profile.linktreeLink(username: t) == nil
    }

    /// Once one field's account is found, the empty fields take the same account where its
    /// platform can fill them - one handle sets up the whole profile, and each stays editable.
    private func fillEmpty(from input: KachatSourceInput) {
        let fits = { (kind: Kind) in KachatNames.SocialSource.Platform.choices(for: kind).contains(input.platform) }
        if avatarIn.isEmpty, fits(.avatar) { avatarIn = input }
        if bannerIn.isEmpty, fits(.banner) { bannerIn = input }
        if bioIn.isEmpty, fits(.bio) { bioIn = input }
    }

    /// Platform picker, the handle after the platform's prefix, and the preview of what it shows.
    private func sourceField(_ input: Binding<KachatSourceInput>, _ kind: Kind, _ lookup: Binding<KachatSocialLookup>) -> some View {
        Group {
            Picker("Account on", selection: input.platform) {
                ForEach(KachatNames.SocialSource.Platform.choices(for: kind), id: \.self) { p in
                    Text(verbatim: p.displayName).tag(p)
                }
            }
            .pickerStyle(.menu)
            HStack(spacing: 0) {
                Text(verbatim: input.wrappedValue.platform.prefix).foregroundColor(.secondary)
                TextField(input.wrappedValue.platform == .discord ? LocalizedStringKey("invite") : LocalizedStringKey("handle"), text: input.handle)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: input.wrappedValue.handle) { _ in
                        // A whole pasted link: switch the picker to its platform, keep the handle.
                        if let pasted = input.wrappedValue.pastedSource(kind) {
                            input.wrappedValue = KachatSourceInput(platform: pasted.platform, handle: pasted.displayHandle)
                        }
                    }
            }
            // Only while the handle names an account: no empty row, and the lookup starts when it
            // appears.
            if let link = input.wrappedValue.source(kind)?.link {
                KachatSocialPreview(link: link, kind: kind, lookup: lookup)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text("Your profile belongs to your address, not to a name: it stays the same when you buy, sell or let a name go.")
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "person.text.rectangle").foregroundColor(.accentColor)
                    }
                } footer: {
                    Text("Each piece comes from a social profile you link, exactly as that platform shows it, so its moderation applies here too. You can use one account for all three, or mix them.")
                }
                Section {
                    sourceField($avatarIn, .avatar, $avatarLookup)
                } header: { Text("Avatar") } footer: {
                    if avatarIn.isBad(.avatar) { invalidHandleNote }
                }
                Section {
                    sourceField($bannerIn, .banner, $bannerLookup)
                } header: { Text("Banner") } footer: {
                    if bannerIn.isBad(.banner) { invalidHandleNote }
                }
                Section {
                    sourceField($bioIn, .bio, $bioLookup)
                } header: { Text("Bio") } footer: {
                    if bioIn.isBad(.bio) { invalidHandleNote }
                }
                Section {
                    HStack(spacing: 0) {
                        Text(verbatim: "linktr.ee/").foregroundColor(.secondary)
                        TextField("username", text: $linktree)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } header: { Text("Links") } footer: {
                    if badLinktree {
                        Text("Enter your Linktree username: letters, numbers, dots, dashes or underscores.").foregroundColor(.red)
                    } else {
                        Text("Add your Linktree to point people to your other accounts and websites.")
                    }
                }
                Section {
                    Picker("Primary name", selection: $primary) {
                        Text("None").tag("")
                        ForEach(activeNames, id: \.self) { n in Text(verbatim: "\(n).kachat").tag(n) }
                    }
                } header: {
                    Text(".kachat Name")
                } footer: {
                    Text("KaChat shows you by your primary name while you own it and it's active; otherwise by your oldest active name, or your address.")
                }
                Section {
                    Button {
                        showSave = true
                    } label: {
                        HStack { Spacer(); Text("Save Profile").font(.headline); Spacer() }
                    }
                    .disabled(!loaded || blocked)
                } footer: {
                    Text("Saving writes your profile to the chain from your address to itself, for a network fee. Profiles are public.")
                }
            }
            .sheet(isPresented: $showSave) {
                KachatProfileSaveSheet(title: "Save Profile", confirmTitle: "Save Profile", doneTitle: "Profile saved",
                                       makeProfile: { profile }, onSaved: { dismiss() })
            }
            .onChange(of: avatarLookup) { v in if v == .found { fillEmpty(from: avatarIn) } }
            .onChange(of: bannerLookup) { v in if v == .found { fillEmpty(from: bannerIn) } }
            .onChange(of: bioLookup) { v in if v == .found { fillEmpty(from: bioIn) } }
            .navigationTitle("Edit .kachat Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private var invalidHandleNote: some View {
        Text("That doesn't look like a handle on this platform.").foregroundColor(.red)
    }

    private func load() async {
        guard let address = KachatNamesActions.shared.myAddress else { loaded = true; return }
        await registry.refreshIfStale()
        var p = registry.ownProfile(for: address)?.profile
        if p == nil { p = try? await registry.identity(address: address).profile }
        if let p {
            avatarIn = KachatSourceInput(stored: p.avatar, .avatar)
            bannerIn = KachatSourceInput(stored: p.banner, .banner)
            bioIn = KachatSourceInput(stored: p.bio, .bio)
            linktree = KachatNames.Profile.linktreeUsername(p.linktree)
        }
        if let key = KachatNamesRegistry.keyOf(address) {
            activeNames = ((try? await registry.names(owner: key, includeInactive: false)) ?? []).map(\.name)
        }
        if let pn = p?.primaryName, activeNames.contains(pn) { primary = pn }
        loaded = true
    }

}

/// Review before a profile record goes out - what will be saved, the network fee, the chatting
/// address's balance before and after - the same confirmation every other name action shows.
/// Used by Edit .kachat Profile and by Set as Primary.
struct KachatProfileSaveSheet: View {
    let title: LocalizedStringKey
    let confirmTitle: LocalizedStringKey
    /// The finished-transaction half sheet's headline (a localization key).
    let doneTitle: String
    /// Builds the record to save when the sheet opens (Set as Primary reads your current profile).
    let makeProfile: () async -> KachatNames.Profile
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var profile: KachatNames.Profile?
    @State private var fee: UInt64?
    @State private var quoteError: String?
    @State private var sending = false
    @State private var sendError: String?
    @State private var done: KachatTxDone?
    @AppStorage("kachat_profile_privacy_seen") private var privacySeen = false

    private func source(_ link: String?, _ kind: KachatNames.SocialSource.Kind) -> String {
        guard let s = KachatNames.SocialSource(link: link ?? "", for: kind) else { return AppLocalization.string("None") }
        return "\(s.platform.displayName) · \(s.platform.prefix)\(s.displayHandle)"
    }

    var body: some View {
        NavigationStack {
            Form {
                if let profile {
                    Section {
                        LabeledRow(title: "Avatar", value: source(profile.avatar, .avatar))
                        LabeledRow(title: "Banner", value: source(profile.banner, .banner))
                        LabeledRow(title: "Bio", value: source(profile.bio, .bio))
                        LabeledRow(title: "Linktree", value: profile.linktree.map { $0.replacingOccurrences(of: "https://", with: "") } ?? AppLocalization.string("None"))
                        LabeledRow(title: "Primary name", value: profile.primaryName.map { "\($0).kachat" } ?? AppLocalization.string("None"))
                    } header: {
                        Text("Your Profile")
                    }
                }
                Section {
                    if let fee {
                        LabeledRow(title: "Network fee", value: KaspaUnit.amount(fee))
                        if let balance = WalletManager.shared.currentWallet?.balanceSompi {
                            LabeledRow(title: "Chatting address balance", value: KaspaUnit.amount(balance))
                            LabeledRow(title: "Balance after", value: KaspaUnit.amount(balance > fee ? balance - fee : 0), bold: true)
                        }
                    } else if quoteError == nil {
                        HStack { Text("Network fee"); Spacer(); ProgressView() }
                    }
                } footer: {
                    if let quoteError {
                        Text(verbatim: quoteError).foregroundColor(.red)
                    } else if privacySeen {
                        Text("Saved on chain from your chatting address to itself.")
                    } else {
                        Text("Profiles are public and on chain: anyone can read them, and earlier versions stay readable after you change them.")
                    }
                }
                Section {
                    Button {
                        authorize()
                    } label: {
                        HStack { Spacer(); if sending { ProgressView() } else { Text(confirmTitle).font(.headline) }; Spacer() }
                    }
                    .disabled(fee == nil || profile == nil || sending || done != nil)
                } footer: {
                    if let sendError { Text(verbatim: sendError).foregroundColor(.red) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { await quote() }
            .sheet(item: $done, onDismiss: { dismiss(); onSaved() }) { KachatTxDoneSheet(done: $0) }
        }
    }

    private func quote() async {
        let p = await makeProfile()
        profile = p
        do {
            fee = try await KachatNamesActions.shared.profileFee(p)
        } catch {
            quoteError = error.localizedDescription
        }
    }

    private func authorize() {
        guard let profile else { return }
        DeviceAuth.authenticate(reason: KachatLive.authReason) {
            Task { @MainActor in
                sending = true
                sendError = nil
                do {
                    let tx = try await KachatNamesActions.shared.saveProfile(profile)
                    privacySeen = true
                    done = KachatTxDone(txId: tx, title: doneTitle)
                    Haptics.success()
                } catch {
                    sendError = error.localizedDescription
                }
                sending = false
            }
        }
    }
}

/// "1 year" / "2 years".
struct KachatYearsText: View {
    let years: Int

    var body: some View {
        if years == 1 { Text("1 year") } else { Text("\(years) years") }
    }
}
