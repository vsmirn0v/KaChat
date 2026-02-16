import Foundation
import DeviceCheck
import CryptoKit

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
        print("[GiftService] Initialized, claimState = \(claimState)")
    }

    // MARK: - Initial State

    private func checkInitialState() {
        if UserDefaults.standard.bool(forKey: Self.claimedKey) {
            claimState = .alreadyClaimed
            print("[GiftService] Already claimed (cached)")
            return
        }

        #if targetEnvironment(simulator)
        // Allow gift flow on simulator for testing (backend will reject)
        claimState = .eligible
        print("[GiftService] Simulator: eligible for gift")
        #else
        if !DCDevice.current.isSupported || !DCAppAttestService.shared.isSupported {
            claimState = .unavailable("Not available on this device")
            print("[GiftService] DeviceCheck/AppAttest not supported")
            return
        }
        claimState = .eligible
        print("[GiftService] Device eligible for gift")
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
        if !DCDevice.current.isSupported || !DCAppAttestService.shared.isSupported {
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
        print("[GiftService] Local gift claim state reset")
    }

    // MARK: - Claim Gift

    func claimGift(walletAddress: String) async {
        guard claimState == .eligible else {
            print("[GiftService] claimGift called but state is \(claimState), skipping")
            return
        }
        print("[GiftService] Starting gift claim for \(walletAddress)")
        claimState = .claiming

        do {
            // 1. Get challenge from server
            let challenge = try await fetchChallenge()
            print("[GiftService] Got challenge: \(challenge)")

            let deviceToken: Data
            let attestation: Data
            let keyId: String

            #if targetEnvironment(simulator)
            // Simulator: send dummy data — backend will reject
            deviceToken = Data("simulator-test-token".utf8)
            attestation = Data("simulator-test-attestation".utf8)
            keyId = "simulator-key-id"
            #else
            // 2. Generate App Attest key
            keyId = try await DCAppAttestService.shared.generateKey()

            // 3. Hash challenge for attestation
            let challengeData = Data(challenge.utf8)
            let clientDataHash = Data(SHA256.hash(data: challengeData))

            // 4. Attest the key
            attestation = try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash)

            // 5. Generate DeviceCheck token
            deviceToken = try await DCDevice.current.generateToken()
            #endif

            // 6. Submit claim
            print("[GiftService] Submitting claim to server...")
            let txId = try await submitClaim(
                deviceToken: deviceToken,
                walletAddress: walletAddress,
                attestation: attestation,
                keyId: keyId,
                challenge: challenge
            )

            // 7. Cache claimed status
            UserDefaults.standard.set(true, forKey: Self.claimedKey)
            claimState = .claimed(txId: txId)
            print("[GiftService] Gift claimed successfully, txId: \(txId)")

        } catch let error as GiftError {
            print("[GiftService] Gift claim failed: \(error)")
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
            print("[GiftService] Gift claim unexpected error: \(error)")
            claimState = .unavailable(error.localizedDescription)
        }
    }

    // MARK: - Network

    private var baseURL: String {
        "https://api.kachat.app"
    }

    private func fetchChallenge() async throws -> String {
        guard var components = URLComponents(string: baseURL) else {
            throw GiftError.networkError("Invalid server URL")
        }
        components.path = (components.path == "/" ? "" : components.path) + "/gift/challenge"
        guard let url = components.url else {
            throw GiftError.networkError("Invalid challenge URL")
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GiftError.networkError("Invalid response")
        }
        guard httpResponse.statusCode == 200 else {
            throw GiftError.serverError("Challenge request failed (HTTP \(httpResponse.statusCode))")
        }

        struct ChallengeResponse: Decodable {
            let challenge: String
        }
        let decoded = try JSONDecoder().decode(ChallengeResponse.self, from: data)
        return decoded.challenge
    }

    private func submitClaim(
        deviceToken: Data,
        walletAddress: String,
        attestation: Data,
        keyId: String,
        challenge: String
    ) async throws -> String {
        guard var components = URLComponents(string: baseURL) else {
            throw GiftError.networkError("Invalid server URL")
        }
        components.path = (components.path == "/" ? "" : components.path) + "/gift/claim"
        guard let url = components.url else {
            throw GiftError.networkError("Invalid claim URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "deviceToken": deviceToken.base64EncodedString(),
            "walletAddress": walletAddress,
            "attestation": attestation.base64EncodedString(),
            "keyId": keyId,
            "challenge": challenge
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GiftError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            struct ClaimResponse: Decodable {
                let txId: String
            }
            let decoded = try JSONDecoder().decode(ClaimResponse.self, from: data)
            return decoded.txId
        case 409:
            throw GiftError.alreadyClaimed
        default:
            if let errorBody = try? JSONDecoder().decode([String: String].self, from: data),
               let message = errorBody["error"] {
                throw GiftError.serverError(message)
            }
            throw GiftError.serverError("Claim failed (HTTP \(httpResponse.statusCode))")
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
