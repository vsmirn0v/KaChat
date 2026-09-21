import Foundation
import MessageUI
import Security
import UIKit

enum GiftClaimState: Equatable {
    case checking
    case eligible
    case claiming
    /// Kept for the screens that switch over it; the email flow never produces a txid.
    case claimed(txId: String)
    /// The request has been sent from this device (or a gift was claimed through the old
    /// server). Final: the button is retired here for good.
    case alreadyClaimed
    case unavailable(String)
}

/// The welcome gift, by email.
///
/// There is no gift server: no claim endpoint, no DeviceCheck, no network call. "Claim Gift"
/// puts up the system mail composer, addressed to the person who hands the gifts out, with the
/// request written and the chatting address filled in.
///
/// ONE request per device. The composer reports how it was dismissed, and `.sent` - the person
/// tapped Send - retires the gift here permanently: the flag goes into UserDefaults and into the
/// Keychain, and a Keychain item outlives deleting and reinstalling the app, so reinstalling
/// does not bring the button back. Cancelling or saving a draft changes nothing. There is no
/// reset gesture any more.
///
/// A phone with no Mail account cannot show the composer (Gmail-app-only users); it gets a
/// `mailto:` hand-off instead, which cannot report what happened next. Opening it counts as the
/// request, after a confirmation that says so - otherwise the limit would not exist for them.
@MainActor
final class GiftService: NSObject, ObservableObject {
    static let shared = GiftService()

    @Published private(set) var claimState: GiftClaimState = .eligible
    static let requestEmail = "kaspasilver@gmail.com"
    /// Version 2 of both flags: 5.0 starts everyone fresh. Whatever an older build recorded - a
    /// gift claimed through the old server ("kachat_gift_claimed"), or a request sent while the
    /// email flow was being tested ("gift_request_sent") - is not read, and is cleaned up once.
    /// To start everyone fresh again in a later release, bump the suffix.
    private static let claimedKey = "kachat_gift_request_sent_v2"
    private static let keychainService = "com.kachat.app"
    private static let keychainAccount = "gift_request_sent_v2"
    private static let legacyClaimedKey = "kachat_gift_claimed"
    private static let legacyKeychainAccount = "gift_request_sent"

    private override init() {
        super.init()
        checkInitialState()
    }

    private func checkInitialState() {
        Self.removeLegacyFlags()
        #if DEBUG
        // Builds run from Xcode never hold the gift back, so the flow can be tested repeatedly.
        // TestFlight and App Store builds are Release and enforce the one request.
        claimState = .eligible
        return
        #else
        let used = UserDefaults.standard.bool(forKey: Self.claimedKey) || Self.keychainFlagIsSet()
        claimState = used ? .alreadyClaimed : .eligible
        if used { retireForGood() }
        #endif
    }

    private static func removeLegacyFlags() {
        UserDefaults.standard.removeObject(forKey: legacyClaimedKey)
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: legacyKeychainAccount
        ] as CFDictionary)
    }

    func checkEligibility() async {
        guard claimState == .checking || claimState == .eligible else { return }
        checkInitialState()
    }

    /// Kept so existing callers compile; a sent request is final and nothing resets it.
    func resetClaimStateForRetry() {}

    // MARK: - The request

    static func requestBody(walletAddress: String) -> String {
        """
        To claim a gift of 2 Kaspa to get started, fill out these fields.

        Your chatting address must have 0 Kaspa and never have been used before.

        Please share your chatting address:
        \(walletAddress)

        Please share at least 1-2 sentences describing how you found Kaspa and how you found KaChat:

        """
    }

    func claimGift(walletAddress: String) async {
        guard claimState != .alreadyClaimed else { return }
        guard let presenter = Self.topViewController() else { return }
        guard MFMailComposeViewController.canSendMail() else {
            // No Mail account: ask first, because opening the other mail app IS the request.
            // A UIKit alert on the topmost controller, so it shows over the gift sheet or the
            // welcome guide, whichever the button was in.
            let alert = UIAlertController(
                title: "Send your gift request?",
                message: "This opens your mail app with the request written for you. You can request the gift once on this device, and opening it counts as that request.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Open Mail App", style: .default) { [weak self] _ in
                Task { @MainActor in await self?.sendThroughExternalMailApp(walletAddress: walletAddress) }
            })
            presenter.present(alert, animated: true)
            return
        }
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = self
        composer.setToRecipients([Self.requestEmail])
        composer.setSubject("KaChat gift request")
        composer.setMessageBody(Self.requestBody(walletAddress: walletAddress), isHTML: false)
        presenter.present(composer, animated: true)
    }

    /// The confirmed mailto hand-off.
    private func sendThroughExternalMailApp(walletAddress: String) async {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = Self.requestEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "KaChat gift request"),
            URLQueryItem(name: "body", value: Self.requestBody(walletAddress: walletAddress))
        ]
        guard let url = components.url else { return }
        if await UIApplication.shared.open(url) {
            retireForGood()
        } else {
            UIPasteboard.general.string = Self.requestBody(walletAddress: walletAddress)
            claimState = .unavailable("No mail app is set up on this device. The request was copied - paste it into an email to \(Self.requestEmail).")
        }
    }

    private func retireForGood() {
        #if !DEBUG
        UserDefaults.standard.set(true, forKey: Self.claimedKey)
        Self.setKeychainFlag()
        #endif
        if claimState != .alreadyClaimed { claimState = .alreadyClaimed }
    }

    // MARK: - Keychain flag (survives reinstall)

    private static var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
    }

    private static func keychainFlagIsSet() -> Bool {
        var query = keychainQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private static func setKeychainFlag() {
        guard !keychainFlagIsSet() else { return }
        var query = keychainQuery
        query[kSecValueData as String] = Data("1".utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrSynchronizable as String] = kCFBooleanFalse!
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

extension GiftService: MFMailComposeViewControllerDelegate {
    nonisolated func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
        let sent = result == .sent
        Task { @MainActor in
            controller.dismiss(animated: true)
            // Only Send ends it. Cancel, a saved draft and a failure leave the gift claimable.
            if sent { self.retireForGood() }
        }
    }
}
