import Foundation

actor TradeHistoryService {
    private let baseURL: URL

    init(baseURL: URL = URL(string: "http://localhost:8080")!) {
        self.baseURL = baseURL
    }

    func fetchClosedTrades(from: Date, to: Date) async throws -> [TradeRecord] {
        let fromMs = Int64(from.timeIntervalSince1970 * 1000)
        let toMs = Int64(to.timeIntervalSince1970 * 1000)

        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("api")
                .appendingPathComponent("v1")
                .appendingPathComponent("trades")
                .appendingPathComponent("closed"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "from", value: String(fromMs)),
            URLQueryItem(name: "to", value: String(toMs)),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)

        guard let http = response as? HTTPURLResponse else {
            throw TradeHistoryError.serverError("No response")
        }
        if http.statusCode != 200 {
            if let body = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw TradeHistoryError.serverError(body.error)
            }
            throw TradeHistoryError.serverError("HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode([TradeRecord].self, from: data)
    }

    private struct ErrorResponse: Codable { let error: String }

    enum TradeHistoryError: Error, LocalizedError {
        case serverError(String)
        var errorDescription: String? {
            switch self { case .serverError(let m): return m }
        }
    }
}
