import Foundation
import UIKit

enum GiftClaimState: Equatable {
    case checking
    case eligible
    case claiming
    /// Kept for the screens that switch over it; the email flow never produces a txid.
    case claimed(txId: String)
    case alreadyClaimed
    case unavailable(String)
}

/// The welcome gift, by email.
///
/// There is no gift server any more - no claim endpoint, no DeviceCheck, no attestation, no
/// network call of any kind. "Claim Gift" opens the phone's mail composer addressed to the
/// person who hands the gifts out, with the request already written and the chatting address
/// filled in; a human reads it and sends the Kaspa. The service keeps the shape the claim
/// buttons around the app were built on (`claimState`, `claimGift(walletAddress:)`), so every
/// one of them now opens that email.
@MainActor
final class GiftService: NSObject, ObservableObject {
    static let shared = GiftService()

    @Published private(set) var claimState: GiftClaimState = .eligible

    static let requestEmail = "kaspasilver@gmail.com"
    /// Set by builds that claimed through the old server: that gift was paid out, so the
    /// button stays retired on this device.
    private static let claimedKey = "kachat_gift_claimed"

    private override init() {
        super.init()
        checkInitialState()
    }

    private func checkInitialState() {
        claimState = UserDefaults.standard.bool(forKey: Self.claimedKey) ? .alreadyClaimed : .eligible
    }

    func checkEligibility() async {
        guard claimState == .checking || claimState == .eligible else { return }
        checkInitialState()
    }

    func resetClaimStateForRetry() {
        UserDefaults.standard.removeObject(forKey: Self.claimedKey)
        checkInitialState()
    }

    /// The request as the email carries it. The chatting address is filled in; the rest is for
    /// the person to write.
    static func requestBody(walletAddress: String) -> String {
        """
        To claim a gift of 2 Kaspa to get started, fill out these fields.

        Your chatting address must have 0 Kaspa and never have been used before.

        Please share your chatting address:
        \(walletAddress)

        Please share at least 1-2 sentences describing how you found Kaspa and how you found KaChat:

        """
    }

    /// Opens the gift request email. Nothing is sent by the app: the person sends the email
    /// themselves, so the button stays available (they may need to open it again).
    func claimGift(walletAddress: String) async {
        guard claimState != .alreadyClaimed else { return }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = Self.requestEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "KaChat gift request"),
            URLQueryItem(name: "body", value: Self.requestBody(walletAddress: walletAddress))
        ]
        guard let url = components.url else { return }
        let opened = await UIApplication.shared.open(url)
        if opened {
            claimState = .eligible
        } else {
            // No mail app set up to take a mailto link: put the request on the clipboard and
            // say where to send it.
            UIPasteboard.general.string = Self.requestBody(walletAddress: walletAddress)
            claimState = .unavailable("No mail app is set up on this device. The request was copied - paste it into an email to \(Self.requestEmail).")
        }
    }
}
