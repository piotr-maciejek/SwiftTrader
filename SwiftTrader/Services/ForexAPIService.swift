import Foundation

actor ForexAPIService {
    private let baseURL: URL
    /// History requests can take a long time when the Dukascopy data feed is
    /// cold-loading chunks. Use a generous timeout so the server has time to
    /// complete the JForex `getBars()` call instead of the client retrying in a
    /// loop and never letting it finish.
    private let historySession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        return URLSession(configuration: config)
    }()

    init(baseURL: URL = URL(string: "http://localhost:8080")!) {
        self.baseURL = baseURL
    }

    func fetchHistory(instrument: String = "EURUSD", period: String = "ONE_MIN", count: Int = 200, before: Int64? = nil, after: Int64? = nil) async throws -> [CandleBar] {
        precondition(before == nil || after == nil, "before and after are mutually exclusive")
        var components = URLComponents(url: baseURL.appendingPathComponent("/api/v1/history"), resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "instrument", value: instrument),
            URLQueryItem(name: "period", value: period),
            URLQueryItem(name: "count", value: String(count)),
        ]
        if let before {
            queryItems.append(URLQueryItem(name: "before", value: String(before)))
        }
        if let after {
            queryItems.append(URLQueryItem(name: "after", value: String(after)))
        }
        components.queryItems = queryItems

        let (data, response) = try await historySession.data(from: components.url!)
        try Self.checkSuccess(response: response, body: data)
        return try JSONDecoder().decode([CandleBar].self, from: data)
    }

    func clearCache(instrument: String) async throws -> Int {
        var components = URLComponents(url: baseURL.appendingPathComponent("/api/v1/history/cache"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "instrument", value: instrument)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "DELETE"
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkSuccess(response: response, body: data)
        struct Resp: Decodable { let filesDeleted: Int }
        return (try? JSONDecoder().decode(Resp.self, from: data).filesDeleted) ?? 0
    }

    func fetchInstruments() async throws -> [String] {
        let url = baseURL.appendingPathComponent("/api/v1/instruments")
        let (data, response) = try await URLSession.shared.data(from: url)
        try Self.checkSuccess(response: response, body: data)
        return try JSONDecoder().decode([String].self, from: data)
    }

    func forceReconnect() async throws {
        let url = baseURL.appendingPathComponent("/api/v1/admin/force-reconnect")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkSuccess(response: response, body: data)
    }

    /// Throws `APIError.serverError` for any non-2xx response. Parses `Retry-After`
    /// header (seconds) and JSON body's `retryAfterMs` (preferring header), clamped
    /// to [1s, 60s].
    private static func checkSuccess(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.serverError(statusCode: -1, retryAfterMs: nil)
        }
        guard !(200..<300).contains(http.statusCode) else { return }
        let retryAfterMs = parseRetryAfter(headers: http.allHeaderFields, body: body)
        throw APIError.serverError(statusCode: http.statusCode, retryAfterMs: retryAfterMs)
    }

    private static func parseRetryAfter(headers: [AnyHashable: Any], body: Data) -> Int? {
        let raw: Int?
        if let header = headers["Retry-After"] as? String, let seconds = Int(header) {
            raw = seconds * 1_000
        } else if let parsed = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let ms = parsed["retryAfterMs"] as? Int {
            raw = ms
        } else {
            raw = nil
        }
        return raw.map { min(60_000, max(1_000, $0)) }
    }

    enum APIError: Error, LocalizedError {
        case serverError(statusCode: Int, retryAfterMs: Int?)

        var statusCode: Int {
            if case .serverError(let code, _) = self { return code }
            return -1
        }

        var retryAfterMs: Int? {
            if case .serverError(_, let ms) = self { return ms }
            return nil
        }

        var errorDescription: String? {
            switch self {
            case .serverError(let code, _): return "Server error (HTTP \(code))"
            }
        }

        var isRetryable: Bool {
            switch self {
            case .serverError(let code, _): return code >= 500 || code == -1
            }
        }
    }
}
