import Foundation
import DeviceCheck

enum GiftClaimState: Equatable {
    case checking
    case eligible
    case claiming
    case claimed(txId: String)
    case alreadyClaimed
    case unavailable(String)
}

@MainActor
final class GiftService: NSObject, ObservableObject {
    static let shared = GiftService()

    @Published private(set) var claimState: GiftClaimState = .checking

    private static let claimedKey = "kachat_gift_claimed"

    private override init() {
        super.init()
        checkInitialState()
        AppLog.log("%@", "[GiftService] Initialized, claimState = \(claimState)")
    }

    // MARK: - Initial State

    private func checkInitialState() {
        if UserDefaults.standard.bool(forKey: Self.claimedKey) {
            claimState = .alreadyClaimed
            AppLog.log("%@", "[GiftService] Already claimed (cached)")
            return
        }

        #if targetEnvironment(simulator)
        // Allow gift flow on simulator for testing (backend will reject)
        claimState = .eligible
        AppLog.log("%@", "[GiftService] Simulator: eligible for gift")
        #else
        // DeviceCheck only. App Attest used to gate this too, and it no longer takes any part in
        // the claim - a device that supports DeviceCheck but not App Attest was being turned away
        // from a gift it is perfectly able to claim.
        if !DCDevice.current.isSupported {
            claimState = .unavailable("Not available on this device")
            AppLog.log("%@", "[GiftService] DeviceCheck not supported")
            return
        }
        claimState = .eligible
        AppLog.log("%@", "[GiftService] Device eligible for gift")
        #endif
    }

    // MARK: - Check Eligibility (server-side)

    func checkEligibility() async {
        guard claimState == .checking || claimState == .eligible else { return }

        #if targetEnvironment(simulator)
        if UserDefaults.standard.bool(forKey: Self.claimedKey) {
            claimState = .alreadyClaimed
            return
        }
        claimState = .eligible
        #else
        if !DCDevice.current.isSupported {
            claimState = .unavailable("Not available on this device")
            return
        }

        if UserDefaults.standard.bool(forKey: Self.claimedKey) {
            claimState = .alreadyClaimed
            return
        }

        claimState = .eligible
        #endif
    }

    func resetClaimStateForRetry() {
        UserDefaults.standard.removeObject(forKey: Self.claimedKey)
        checkInitialState()
        AppLog.log("%@", "[GiftService] Local gift claim state reset")
    }

    // MARK: - Claim Gift

    func claimGift(walletAddress: String) async {
        guard claimState == .eligible else {
            AppLog.log("%@", "[GiftService] claimGift called but state is \(claimState), skipping")
            return
        }
        AppLog.log("%@", "[GiftService] Starting gift claim for \(walletAddress)")
        claimState = .claiming

        do {
            // A DeviceCheck token is the whole of what the server verifies for Apple. There is no
            // challenge round trip and no App Attest attestation any more: the server exposes
            // neither, and generating an attestation nothing checks was work that could fail and
            // block a claim for no gain.
            let deviceToken: Data
            #if targetEnvironment(simulator)
            // Simulator has no DeviceCheck. Send something shaped right and let the server say no.
            deviceToken = Data("simulator-test-token".utf8)
            #else
            deviceToken = try await DCDevice.current.generateToken()
            #endif

            AppLog.log("%@", "[GiftService] Submitting claim to server...")
            let result = try await submitClaim(deviceToken: deviceToken, address: walletAddress)

            guard let txId = result.txId, result.sent else {
                // Accepted, but nothing was paid - the service is in record-only mode. Saying
                // "claimed" here would be a lie, and marking it claimed locally would burn the
                // one attempt this device gets for a gift it never received.
                AppLog.log("%@", "[GiftService] Claim accepted but not paid (record-only)")
                claimState = .unavailable("The gift service isn't paying out right now. Try again later.")
                return
            }

            UserDefaults.standard.set(true, forKey: Self.claimedKey)
            claimState = .claimed(txId: txId)
            AppLog.log("%@", "[GiftService] Gift claimed successfully, txId: \(txId)")

        } catch let error as GiftError {
            AppLog.log("%@", "[GiftService] Gift claim failed: \(error)")
            switch error {
            case .alreadyClaimed:
                UserDefaults.standard.set(true, forKey: Self.claimedKey)
                claimState = .alreadyClaimed
            case .attestationFailed:
                claimState = .unavailable("Device verification failed")
            case .networkError(let message):
                claimState = .unavailable(message)
            case .serverError(let message):
                claimState = .unavailable(message)
            }
        } catch {
            AppLog.log("%@", "[GiftService] Gift claim unexpected error: \(error)")
            claimState = .unavailable(error.localizedDescription)
        }
    }

    // MARK: - Network

    /// The gift server. Hardcoded rather than a Settings entry, unlike the indexer/KNS/explorer
    /// endpoints: a claim is attested against THIS server's challenge, so pointing it elsewhere
    /// cannot work, it can only be used to aim an attestation somewhere it does not belong.
    ///
    /// Android sets the same host in `AppModule.provideGiftApi`. Keep the two in step - they
    /// drifted apart once (iOS on api.kachat.app, Android left on a host that had stopped
    /// serving the endpoints entirely) and nothing caught it, because each platform only ever
    /// reads its own copy.
    private var baseURL: String {
        "https://gift.kachat.duckdns.org"
    }

    /// The claim. `POST /v1/claim` with the platform, the destination address and the platform's
    /// one attestation token - that is the entire contract.
    ///
    /// It was `POST /gift/claim` with a challenge, an App Attest attestation and a key id, under
    /// the field name `walletAddress`. None of that exists on this server: `/gift/claim` and
    /// `/gift/challenge` are not routes it serves, and it wants `address`.
    private func submitClaim(deviceToken: Data, address: String) async throws -> ClaimResult {
        guard var components = URLComponents(string: baseURL) else {
            throw GiftError.networkError("Invalid server URL")
        }
        components.path = (components.path == "/" ? "" : components.path) + "/v1/claim"
        guard let url = components.url else {
            throw GiftError.networkError("Invalid claim URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "platform": "apple",
            "address": address,
            "deviceToken": deviceToken.base64EncodedString()
        ]
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GiftError.networkError("Invalid response")
        }

        let decoded = try? JSONDecoder().decode(ClaimResponse.self, from: data)

        if httpResponse.statusCode == 409 { throw GiftError.alreadyClaimed }
        guard httpResponse.statusCode == 200, decoded?.ok == true else {
            // The server says why in `reason`; every failure shape it returns carries one.
            throw GiftError.serverError(decoded?.reason ?? "Claim failed (HTTP \(httpResponse.statusCode))")
        }
        return ClaimResult(sent: decoded?.sent ?? false, txId: decoded?.resolvedTxId)
    }

    private struct ClaimResult {
        let sent: Bool
        let txId: String?
    }

    /// `{"ok":true,"sent":false}` in record-only mode; `sent` flips true and a transaction id
    /// appears once the service is paying out. The id's field name is read tolerantly because the
    /// live-mode shape has not been observed from here - only record-only has.
    private struct ClaimResponse: Decodable {
        let ok: Bool
        let sent: Bool?
        let reason: String?
        let txId: String?
        let txid: String?
        let transactionId: String?

        var resolvedTxId: String? {
            [txId, txid, transactionId].compactMap { $0 }.first { !$0.isEmpty }
        }
    }
}

// MARK: - Errors

private enum GiftError: LocalizedError {
    case alreadyClaimed
    case attestationFailed
    case networkError(String)
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .alreadyClaimed:
            return "Gift already claimed on this device"
        case .attestationFailed:
            return "Device verification failed"
        case .networkError(let message):
            return message
        case .serverError(let message):
            return message
        }
    }
}
