import Foundation

/// Nextcloud Talk (spreed) REST client for KaChat calls: conversations, call join/leave, and the
/// *internal* signaling channel (long-poll pull + POST send). One instance per call, bound to one
/// server, and used in one of two modes:
///
/// - the CALLER's own account (`.basic` app-password auth), which creates the public conversation
///   the call lives in;
/// - a GUEST (`.guest`) on the other person's server, which is how the callee joins without a
///   Nextcloud account of their own. Talk's guest sessions live in the PHP session cookie, so the
///   client owns an ephemeral `URLSession` whose cookie jar keeps that session for the call's life
///   and is thrown away with it.
///
/// Only the internal signaling mode is spoken here (the one every Talk install has). A server
/// that runs the external High-Performance Backend reports `signalingMode == "external"` from
/// `signalingSettings`, and `CallService` refuses the call with a clear message rather than half
/// working.
final class NextcloudTalkClient: @unchecked Sendable {
    enum Auth {
        case basic(username: String, appPassword: String)
        case guest
    }

    struct IceServer: Sendable {
        let urls: [String]
        let username: String?
        let credential: String?
    }

    struct SignalingSettings: Sendable {
        let mode: String
        let iceServers: [IceServer]
    }

    struct RoomParticipant: Sendable {
        let sessionId: String
        let userId: String
        let inCall: Int
        let lastPing: Int
    }

    /// One pulled signaling event. `message` payloads are the peer JSON `{from,to,type,...}`
    /// exactly as the other side sent them (the server adds `from`).
    enum SignalingEvent {
        case usersInRoom([RoomParticipant])
        case message([String: Any])
    }

    /// A peer message on its way out; mirrors the Talk web client's `Peer.send` envelope.
    struct PeerMessage {
        let to: String
        let sid: String
        let roomType: String
        let type: String
        let payload: [String: Any]
    }

    enum TalkError: LocalizedError {
        case http(Int, String)
        case malformed(String)
        case sessionLost
        case conversationGone
        case externalSignalingUnsupported

        var errorDescription: String? {
            switch self {
            case .http(let code, let body):
                return body.isEmpty ? "Nextcloud Talk answered \(code)." : "Nextcloud Talk answered \(code): \(body)"
            case .malformed(let what):
                return "Unexpected answer from Nextcloud Talk (\(what))."
            case .sessionLost:
                return "This device's call session was replaced on the server."
            case .conversationGone:
                return "The call conversation no longer exists."
            case .externalSignalingUnsupported:
                return "This Nextcloud uses an external signaling server, which KaChat calls do not support yet."
            }
        }
    }

    let server: URL
    let auth: Auth
    private let session: URLSession
    /// Long-poll requests are cancelled through this so a hang-up returns immediately instead
    /// of waiting out the server's 30s pull window.
    private var activePullTask: URLSessionDataTask?
    private let pullLock = NSLock()

    /// In-call flag bits (Talk constants): in call, with audio, with video.
    static let flagInCall = 1
    static let flagWithAudio = 2
    static let flagWithVideo = 4

    init(server: URL, auth: Auth) {
        self.server = server
        self.auth = auth
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 120
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        session = URLSession(configuration: config)
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: - Conversations

    /// Creates a public conversation (type 3) the callee can join as a guest. Returns its token.
    func createPublicConversation(named name: String) async throws -> String {
        let data = try await ocs("POST", "/ocs/v2.php/apps/spreed/api/v4/room", form: [
            "roomType": "3",
            "roomName": String(name.prefix(255))
        ])
        guard let token = data["token"] as? String, !token.isEmpty else {
            throw TalkError.malformed("no room token")
        }
        return token
    }

    /// Joins the conversation as an active participant. Returns this participant's Talk
    /// session id, which is also what the internal signaling identifies us by.
    func joinConversation(token: String) async throws -> String {
        let data = try await ocs("POST", "/ocs/v2.php/apps/spreed/api/v4/room/\(token)/participants/active", form: [
            "force": "true"
        ])
        guard let sessionId = data["sessionId"] as? String, !sessionId.isEmpty else {
            throw TalkError.malformed("no session id")
        }
        return sessionId
    }

    func leaveConversation(token: String) async {
        _ = try? await ocs("DELETE", "/ocs/v2.php/apps/spreed/api/v4/room/\(token)/participants/active")
    }

    /// Owner only. Public conversations created for a call are throwaway; this keeps the
    /// caller's Talk from filling up with "KaChat call" rooms.
    func deleteConversation(token: String) async {
        _ = try? await ocs("DELETE", "/ocs/v2.php/apps/spreed/api/v4/room/\(token)")
    }

    /// Guests have no account name; this is what the caller's Talk shows for them.
    func setGuestDisplayName(token: String, name: String) async {
        _ = try? await ocs("POST", "/ocs/v2.php/apps/spreed/api/v1/guest/\(token)/name", form: [
            "displayName": String(name.prefix(64))
        ])
    }

    // MARK: - Calls

    func joinCall(token: String, video: Bool) async throws {
        let flags = Self.flagInCall | Self.flagWithAudio | (video ? Self.flagWithVideo : 0)
        _ = try await ocs("POST", "/ocs/v2.php/apps/spreed/api/v4/call/\(token)", form: [
            "flags": String(flags),
            "silent": "true"
        ])
    }

    func updateCallFlags(token: String, video: Bool) async {
        let flags = Self.flagInCall | Self.flagWithAudio | (video ? Self.flagWithVideo : 0)
        _ = try? await ocs("PUT", "/ocs/v2.php/apps/spreed/api/v4/call/\(token)", form: ["flags": String(flags)])
    }

    func leaveCall(token: String) async {
        _ = try? await ocs("DELETE", "/ocs/v2.php/apps/spreed/api/v4/call/\(token)")
    }

    // MARK: - Signaling

    func signalingSettings(token: String) async throws -> SignalingSettings {
        let data = try await ocs("GET", "/ocs/v2.php/apps/spreed/api/v3/signaling/settings", query: ["token": token])
        let mode = (data["signalingMode"] as? String) ?? "internal"
        var servers: [IceServer] = []
        for entry in (data["stunservers"] as? [[String: Any]]) ?? [] {
            if let urls = entry["urls"] as? [String], !urls.isEmpty {
                servers.append(IceServer(urls: urls, username: nil, credential: nil))
            }
        }
        for entry in (data["turnservers"] as? [[String: Any]]) ?? [] {
            if let urls = entry["urls"] as? [String], !urls.isEmpty {
                servers.append(IceServer(urls: urls,
                                         username: entry["username"] as? String,
                                         credential: entry["credential"] as? String))
            }
        }
        return SignalingSettings(mode: mode, iceServers: servers)
    }

    /// One long-poll of the internal signaling channel. Returns when the server has something
    /// (peer messages and/or a participant list) or its own ~30s window lapses, in which case
    /// the list alone comes back. 404 means the conversation or our session is gone; 409 means
    /// the server replaced our session (joined again elsewhere).
    func pullSignaling(token: String, sessionId: String) async throws -> [SignalingEvent] {
        var request = try makeRequest("GET", "/ocs/v2.php/apps/spreed/api/v3/signaling/\(token)", query: nil)
        request.timeoutInterval = 45
        let (data, http) = try await perform(request, trackAsPull: true)
        switch http.statusCode {
        case 200: break
        case 404, 403: throw TalkError.conversationGone
        case 409: throw TalkError.sessionLost
        default: throw TalkError.http(http.statusCode, Self.errorBody(data))
        }
        guard let list = try Self.ocsData(from: data) as? [[String: Any]] else {
            throw TalkError.malformed("signaling pull")
        }
        var events: [SignalingEvent] = []
        for item in list {
            switch item["type"] as? String {
            case "usersInRoom":
                let users = ((item["data"] as? [[String: Any]]) ?? []).map { user in
                    RoomParticipant(
                        sessionId: (user["sessionId"] as? String) ?? "",
                        userId: (user["userId"] as? String) ?? "",
                        inCall: Self.int(user["inCall"]),
                        lastPing: Self.int(user["lastPing"])
                    )
                }
                events.append(.usersInRoom(users))
            case "message":
                var payload: [String: Any]?
                if let text = item["data"] as? String, let bytes = text.data(using: .utf8) {
                    payload = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
                } else if let dict = item["data"] as? [String: Any] {
                    payload = dict
                }
                if let payload {
                    events.append(.message(payload))
                }
            default:
                break
            }
        }
        return events
    }

    /// Cancels the in-flight long poll, if any, so `pullSignaling` returns at once.
    func cancelPull() {
        pullLock.lock()
        let task = activePullTask
        activePullTask = nil
        pullLock.unlock()
        task?.cancel()
    }

    func sendSignaling(token: String, sessionId: String, messages: [PeerMessage]) async throws {
        let envelopes: [[String: Any]] = try messages.map { message in
            var body: [String: Any] = [
                "to": message.to,
                "sid": message.sid,
                "roomType": message.roomType,
                "type": message.type,
                "payload": message.payload
            ]
            body["from"] = sessionId
            let bytes = try JSONSerialization.data(withJSONObject: body)
            return [
                "ev": "message",
                "fn": String(decoding: bytes, as: UTF8.self),
                "sessionId": sessionId
            ]
        }
        let encoded = try JSONSerialization.data(withJSONObject: envelopes)
        _ = try await ocs("POST", "/ocs/v2.php/apps/spreed/api/v3/signaling/\(token)", form: [
            "messages": String(decoding: encoded, as: UTF8.self)
        ])
    }

    // MARK: - Plumbing

    @discardableResult
    private func ocs(_ method: String, _ path: String, query: [String: String]? = nil, form: [String: String]? = nil) async throws -> [String: Any] {
        var request = try makeRequest(method, path, query: query)
        if let form {
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(form.map { "\(Self.formEncoded($0.key))=\(Self.formEncoded($0.value))" }
                .joined(separator: "&").utf8)
        }
        let (data, http) = try await perform(request, trackAsPull: false)
        guard (200..<300).contains(http.statusCode) else {
            throw TalkError.http(http.statusCode, Self.errorBody(data))
        }
        if data.isEmpty { return [:] }
        let payload = try Self.ocsData(from: data)
        return (payload as? [String: Any]) ?? [:]
    }

    private func makeRequest(_ method: String, _ path: String, query: [String: String]?) throws -> URLRequest {
        guard var components = URLComponents(url: server.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw TalkError.malformed("url")
        }
        var items = [URLQueryItem(name: "format", value: "json")]
        for (key, value) in query ?? [:] {
            items.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = items
        guard let url = components.url else { throw TalkError.malformed("url") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if case .basic(let username, let appPassword) = auth {
            let token = Data("\(username):\(appPassword)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func perform(_ request: URLRequest, trackAsPull: Bool) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: TalkError.malformed("no HTTP response"))
                    return
                }
                continuation.resume(returning: (data ?? Data(), http))
            }
            if trackAsPull {
                pullLock.lock()
                activePullTask = task
                pullLock.unlock()
            }
            task.resume()
        }
    }

    private static func ocsData(from data: Data) throws -> Any {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ocs = root["ocs"] as? [String: Any] else {
            throw TalkError.malformed("ocs envelope")
        }
        return ocs["data"] ?? [:]
    }

    private static func errorBody(_ data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ocs = root["ocs"] as? [String: Any],
              let meta = ocs["meta"] as? [String: Any],
              let message = meta["message"] as? String else { return "" }
        return String(message.prefix(200))
    }

    private static func int(_ value: Any?) -> Int {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let text = value as? String, let number = Int(text) { return number }
        return 0
    }

    private static func formEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
