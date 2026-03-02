import Foundation

@MainActor
final class AttachmentTransferService {
    static let shared = AttachmentTransferService()

    private let authDomain = "kasia-attachments-auth:v1"
    private let uploadPreparePaths = ["/v1/attachments/init", "/attachments/init"]
    private let uploadCompletePaths = ["/v1/attachments/complete", "/attachments/complete"]
    private let downloadPaths = ["/v1/attachments/download", "/attachments/download"]
    private enum AttachmentRoute: String {
        case prepare
        case complete
        case download
    }
    private var cachedRoutes: [AttachmentRoute: String] = [:]

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    private var baseURL: String {
        AppSettings.load().indexerURL
    }

    func prepareUpload(
        fileName: String,
        mimeType: String,
        sizeBytes: Int,
        checksumSha256: String?
    ) async throws -> AttachmentUploadPrepareResponse {
        return try await postJSON(
            paths: uploadPreparePaths,
            route: .prepare,
            resourceId: fileName
        ) { auth in
            AttachmentUploadPrepareRequest(
                fileName: fileName,
                mimeType: mimeType,
                sizeBytes: sizeBytes,
                checksumSha256: checksumSha256,
                auth: auth
            )
        }
    }

    func completeUpload(
        attachmentId: String,
        objectKey: String,
        sizeBytes: Int,
        checksumSha256: String?
    ) async throws -> AttachmentUploadCompleteResponse {
        return try await postJSON(
            paths: uploadCompletePaths,
            route: .complete,
            resourceId: attachmentId
        ) { auth in
            AttachmentUploadCompleteRequest(
                attachmentId: attachmentId,
                objectKey: objectKey,
                sizeBytes: sizeBytes,
                checksumSha256: checksumSha256,
                auth: auth
            )
        }
    }

    func requestDownload(
        attachmentId: String
    ) async throws -> AttachmentDownloadResponse {
        return try await postJSON(
            paths: downloadPaths,
            route: .download,
            resourceId: attachmentId
        ) { auth in
            AttachmentDownloadRequest(
                attachmentId: attachmentId,
                auth: auth
            )
        }
    }

    func downloadCiphertext(
        attachmentId: String
    ) async throws -> Data {
        let downloadResponse = try await requestDownload(attachmentId: attachmentId)
        guard let url = URL(string: downloadResponse.downloadURL) else {
            throw AttachmentTransferError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (name, value) in downloadResponse.downloadHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AttachmentTransferError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw AttachmentTransferError.serverError(statusCode: httpResponse.statusCode, reason: nil)
        }

        return data
    }

    func uploadCiphertext(_ data: Data, using prepareResponse: AttachmentUploadPrepareResponse) async throws {
        guard let url = URL(string: prepareResponse.uploadURL) else {
            throw AttachmentTransferError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = prepareResponse.uploadMethod?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? "PUT"
        request.timeoutInterval = 300
        for (name, value) in prepareResponse.uploadHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (_, response) = try await session.upload(for: request, from: data)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AttachmentTransferError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw AttachmentTransferError.serverError(statusCode: httpResponse.statusCode, reason: nil)
        }
    }

    private func buildAuth(method: String, path: String, resourceId: String?) throws -> AttachmentAuthRequest {
        guard let wallet = WalletManager.shared.currentWallet else {
            throw AttachmentTransferError.walletUnavailable
        }

        let walletPubkey = wallet.publicKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !walletPubkey.isEmpty else {
            throw AttachmentTransferError.walletUnavailable
        }

        let walletAddress = wallet.publicAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !walletAddress.isEmpty else {
            throw AttachmentTransferError.walletUnavailable
        }

        let timestampMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let expiresAtMs = timestampMs + 120_000
        let nonce = UUID().uuidString.lowercased()
        let sanitizedResourceId = (resourceId ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let preimage = [
            "domain=\(authDomain)",
            "method=\(method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())",
            "path=\(path)",
            "wallet_pubkey=\(walletPubkey)",
            "wallet_address=\(walletAddress)",
            "timestamp_ms=\(timestampMs)",
            "expires_at_ms=\(expiresAtMs)",
            "nonce=\(nonce)",
            "resource_id=\(sanitizedResourceId)"
        ].joined(separator: "\n")

        let signature = try WalletManager.shared.signArbitraryMessage(preimage, mode: .sha256Digest)

        return AttachmentAuthRequest(
            walletPubkey: walletPubkey,
            walletAddress: walletAddress,
            nonce: nonce,
            timestampMs: timestampMs,
            expiresAtMs: expiresAtMs,
            signature: signature
        )
    }

    private func postJSON<Response: Decodable, Body: Encodable>(
        paths: [String],
        route: AttachmentRoute,
        resourceId: String,
        makeBody: (_ auth: AttachmentAuthRequest) throws -> Body
    ) async throws -> Response {
        if let cached = cachedRoutes[route] {
            do {
                let response: Response = try await postJSON(
                    path: cached,
                    resourceId: resourceId,
                    makeBody: makeBody
                )
                cachedRoutes[route] = cached
                return response
            } catch AttachmentTransferError.serverError(let statusCode, let reason) where statusCode == 404 {
                NSLog("[AttachmentTransferService] Cached endpoint %@ failed with 404: %@", cached, reason ?? "unknown")
                cachedRoutes.removeValue(forKey: route)
            }
        }

        var pathsToTry = paths
        if let cached = cachedRoutes[route] {
            pathsToTry = paths.filter { $0 != cached }
        }

        var lastResponseError: AttachmentTransferError?
        for path in pathsToTry {
            do {
                let response: Response = try await postJSON(
                    path: path,
                    resourceId: resourceId,
                    makeBody: makeBody
                )
                cachedRoutes[route] = path
                return response
            } catch let error as AttachmentTransferError {
                if case .serverError(let statusCode, _) = error, statusCode == 404 {
                    NSLog("[AttachmentTransferService] Tried attachment endpoint path %@ got 404", path)
                    lastResponseError = error
                    continue
                }
                throw error
            }
        }

        if let lastResponseError {
            throw AttachmentTransferError.endpointNotFound(
                route: route.rawValue,
                attempts: pathsToTry,
                reason: {
                    if case .serverError(_, let reason) = lastResponseError {
                        return reason
                    }
                    return nil
                }()
            )
        }

        throw AttachmentTransferError.invalidResponse
    }

    private func postJSON<Response: Decodable, Body: Encodable>(
        path: String,
        resourceId: String,
        makeBody: (_ auth: AttachmentAuthRequest) throws -> Body
    ) async throws -> Response {
        guard let url = URL(string: baseURL + path) else {
            throw AttachmentTransferError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let auth = try buildAuth(method: "POST", path: path, resourceId: resourceId)
        let authenticatedBody = try makeBody(auth)
        request.httpBody = try JSONEncoder().encode(authenticatedBody)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AttachmentTransferError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let reason = (try? JSONDecoder().decode(AttachmentErrorResponse.self, from: data))?.error
            throw AttachmentTransferError.serverError(statusCode: httpResponse.statusCode, reason: reason)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AttachmentTransferError.decodeFailed(error.localizedDescription)
        }
    }
}

struct AttachmentUploadPrepareRequest: Codable {
    let fileName: String
    let mimeType: String
    let sizeBytes: Int
    let checksumSha256: String?
    let auth: AttachmentAuthRequest

    enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
        case checksumSha256 = "checksum_sha256"
        case auth
    }
}

struct AttachmentUploadPrepareResponse: Codable {
    let attachmentId: String
    let provider: AttachmentProvider
    let objectKey: String
    let uploadURL: String
    let uploadMethod: String?
    let uploadHeaders: [String: String]
    let expiresAtMs: UInt64?

    enum CodingKeys: String, CodingKey {
        case attachmentId = "attachment_id"
        case provider
        case objectKey = "object_key"
        case uploadURL = "upload_url"
        case uploadMethod = "upload_method"
        case uploadHeaders = "upload_headers"
        case expiresAtMs = "expires_at_ms"
    }
}

struct AttachmentUploadCompleteRequest: Codable {
    let attachmentId: String
    let objectKey: String
    let sizeBytes: Int
    let checksumSha256: String?
    let auth: AttachmentAuthRequest

    enum CodingKeys: String, CodingKey {
        case attachmentId = "attachment_id"
        case objectKey = "object_key"
        case sizeBytes = "size_bytes"
        case checksumSha256 = "checksum_sha256"
        case auth
    }
}

struct AttachmentUploadCompleteResponse: Codable {
    let attachmentId: String
    let objectKey: String
    let sizeBytes: Int?
    let checksumSha256: String?

    enum CodingKeys: String, CodingKey {
        case attachmentId = "attachment_id"
        case objectKey = "object_key"
        case sizeBytes = "size_bytes"
        case checksumSha256 = "checksum_sha256"
    }
}

struct AttachmentDownloadRequest: Codable {
    let attachmentId: String
    let auth: AttachmentAuthRequest

    enum CodingKeys: String, CodingKey {
        case attachmentId = "attachment_id"
        case auth
    }
}

struct AttachmentDownloadResponse: Codable {
    let attachmentId: String
    let objectKey: String
    let downloadURL: String
    let downloadHeaders: [String: String]
    let fileName: String?
    let mimeType: String?
    let sizeBytes: Int?
    let expiresAtMs: UInt64?

    enum CodingKeys: String, CodingKey {
        case attachmentId = "attachment_id"
        case objectKey = "object_key"
        case downloadURL = "download_url"
        case downloadHeaders = "download_headers"
        case fileName = "file_name"
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
        case expiresAtMs = "expires_at_ms"
    }
}

struct AttachmentAuthRequest: Codable {
    let walletPubkey: String
    let walletAddress: String
    let nonce: String
    let timestampMs: UInt64
    let expiresAtMs: UInt64
    let signature: String

    enum CodingKeys: String, CodingKey {
        case walletPubkey = "wallet_pubkey"
        case walletAddress = "wallet_address"
        case nonce
        case timestampMs = "timestamp_ms"
        case expiresAtMs = "expires_at_ms"
        case signature
    }
}

private struct AttachmentErrorResponse: Decodable {
    let error: String
}

enum AttachmentTransferError: LocalizedError {
    case walletUnavailable
    case invalidURL
    case invalidResponse
    case decodeFailed(String)
    case serverError(statusCode: Int, reason: String?)
    case endpointNotFound(route: String, attempts: [String], reason: String?)

    var errorDescription: String? {
        switch self {
        case .walletUnavailable:
            return "Attachment auth is unavailable without an active wallet."
        case .invalidURL:
            return "Attachment endpoint URL is invalid."
        case .invalidResponse:
            return "Attachment endpoint returned an invalid response."
        case .decodeFailed(let message):
            return "Attachment response decode failed: \(message)"
        case .serverError(let statusCode, let reason):
            if let reason, !reason.isEmpty {
                return "Attachment request failed (\(statusCode)): \(reason)"
            }
            return "Attachment request failed (\(statusCode))."
        case .endpointNotFound(let route, let attempts, let reason):
            let attempted = attempts.joined(separator: ", ")
            if let reason, !reason.isEmpty {
                return "Attachment endpoint for \(route) not found (\(attempted)). Reason: \(reason)"
            }
            return "Attachment endpoint for \(route) not found. Tried: \(attempted)."
        }
    }
}
