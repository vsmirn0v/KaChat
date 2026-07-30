import Foundation

/// ChangeNOW's v2 exchange API — lets KaChat swap KAS for another coin (and back) without
/// leaving the app. Auth is a per-request `x-changenow-api-key` header, read from the
/// `CHANGENOW_API_KEY` environment variable (set it under Xcode > Product > Scheme > Edit
/// Scheme > Run > Arguments > Environment Variables - schemes are per-user/gitignored, so the
/// real key never lands in source control) - mirrors Android's own compile-time key (sourced
/// from a local, gitignored `local.properties` value via BuildConfig).
struct ChangeNowEstimateResponse: Decodable {
    let fromAmount: Double
    let toAmount: Double
    let transactionSpeedForecast: String?
    let warningMessage: String?
}

struct ChangeNowRangeResponse: Decodable {
    let minAmount: Double?
    let maxAmount: Double?
}

private struct ChangeNowCreateTransactionRequest: Encodable {
    let fromCurrency: String
    let fromNetwork: String
    let toCurrency: String
    let toNetwork: String
    let fromAmount: String
    let address: String
    let flow: String
}

/// Shape shared by "create exchange" and "check status" responses — ChangeNOW returns the same
/// fields for both.
struct ChangeNowTransactionResponse: Decodable {
    let id: String
    /// "new" | "waiting" | "confirming" | "exchanging" | "sending" | "finished" | "failed" |
    /// "refunded" | "verifying"
    let status: String?
    let payinAddress: String?
    let payoutAddress: String?
    let payinExtraId: String?
    let fromAmount: Double?
    let toAmount: Double?
    let fromCurrency: String?
    let toCurrency: String?
    let payinHash: String?
    let payoutHash: String?
}

enum ChangeNowError: LocalizedError {
    case invalidURL
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid ChangeNOW request URL."
        case .httpError(let code, let body):
            return body.isEmpty ? "ChangeNOW error (\(code))." : "ChangeNOW error (\(code)): \(body)"
        }
    }
}

final class ChangeNowAPIClient {
    static let shared = ChangeNowAPIClient()
    private init() {}

    private let baseURL = "https://api.changenow.io"
    private let apiKey = ProcessInfo.processInfo.environment["CHANGENOW_API_KEY"] ?? ""

    private func makeRequest(path: String, queryItems: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard var components = URLComponents(string: baseURL + path) else { throw ChangeNowError.invalidURL }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw ChangeNowError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "x-changenow-api-key")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ChangeNowError.httpError(-1, "No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            // ChangeNOW's 4xx responses carry the real reason in the JSON body — a bare
            // "HTTP 400" tells the user nothing actionable.
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw ChangeNowError.httpError(http.statusCode, String(bodyText.prefix(300)))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// A live quote for how much `toAmount` a given `fromAmount` converts to right now.
    func getEstimatedAmount(fromCurrency: String, fromNetwork: String, toCurrency: String, toNetwork: String, fromAmount: String) async throws -> ChangeNowEstimateResponse {
        let request = try makeRequest(path: "/v2/exchange/estimated-amount", queryItems: [
            URLQueryItem(name: "fromCurrency", value: fromCurrency),
            URLQueryItem(name: "fromNetwork", value: fromNetwork),
            URLQueryItem(name: "toCurrency", value: toCurrency),
            URLQueryItem(name: "toNetwork", value: toNetwork),
            URLQueryItem(name: "fromAmount", value: fromAmount),
            URLQueryItem(name: "flow", value: "standard")
        ])
        return try await send(request)
    }

    /// The minimum/maximum `fromAmount` ChangeNOW will accept for this pair.
    func getRange(fromCurrency: String, fromNetwork: String, toCurrency: String, toNetwork: String) async throws -> ChangeNowRangeResponse {
        let request = try makeRequest(path: "/v2/exchange/range", queryItems: [
            URLQueryItem(name: "fromCurrency", value: fromCurrency),
            URLQueryItem(name: "fromNetwork", value: fromNetwork),
            URLQueryItem(name: "toCurrency", value: toCurrency),
            URLQueryItem(name: "toNetwork", value: toNetwork),
            URLQueryItem(name: "flow", value: "standard")
        ])
        return try await send(request)
    }

    /// Opens a new exchange — the response's `payinAddress` is where the "from" coin needs to
    /// arrive.
    func createTransaction(fromCurrency: String, fromNetwork: String, toCurrency: String, toNetwork: String, fromAmount: String, address: String) async throws -> ChangeNowTransactionResponse {
        let body = ChangeNowCreateTransactionRequest(
            fromCurrency: fromCurrency,
            fromNetwork: fromNetwork,
            toCurrency: toCurrency,
            toNetwork: toNetwork,
            fromAmount: fromAmount,
            address: address,
            flow: "standard"
        )
        let bodyData = try JSONEncoder().encode(body)
        let request = try makeRequest(path: "/v2/exchange", method: "POST", body: bodyData)
        return try await send(request)
    }

    /// Current status of a previously-created exchange, by its `id`.
    func getTransactionStatus(id: String) async throws -> ChangeNowTransactionResponse {
        let request = try makeRequest(path: "/v2/exchange/by-id", queryItems: [URLQueryItem(name: "id", value: id)])
        return try await send(request)
    }
}
