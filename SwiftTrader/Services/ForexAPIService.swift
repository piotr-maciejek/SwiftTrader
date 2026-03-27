import Foundation

actor ForexAPIService {
    private let baseURL: URL

    init(baseURL: URL = URL(string: "http://localhost:8080")!) {
        self.baseURL = baseURL
    }

    func fetchHistory(instrument: String = "EURUSD", period: String = "ONE_MIN", count: Int = 200) async throws -> [CandleBar] {
        var components = URLComponents(url: baseURL.appendingPathComponent("/api/v1/history"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "instrument", value: instrument),
            URLQueryItem(name: "period", value: period),
            URLQueryItem(name: "count", value: String(count)),
        ]

        let (data, response) = try await URLSession.shared.data(from: components.url!)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.serverError
        }

        return try JSONDecoder().decode([CandleBar].self, from: data)
    }

    func fetchInstruments() async throws -> [String] {
        let url = baseURL.appendingPathComponent("/api/v1/instruments")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.serverError
        }
        return try JSONDecoder().decode([String].self, from: data)
    }

    enum APIError: Error, LocalizedError {
        case serverError

        var errorDescription: String? {
            switch self {
            case .serverError: return "Server returned an error"
            }
        }
    }
}
