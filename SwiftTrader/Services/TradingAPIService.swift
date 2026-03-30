import Foundation

actor TradingAPIService {
    private let baseURL: URL

    init(baseURL: URL = URL(string: "http://localhost:8080")!) {
        self.baseURL = baseURL
    }

    /// `/api/v1/orders` built segment-by-segment (avoids malformed paths from leading `/`).
    private var ordersCollectionURL: URL {
        baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
            .appendingPathComponent("orders")
    }

    private func orderByLabelURL(label: String) -> URL {
        ordersCollectionURL.appendingPathComponent(label)
    }

    func submitOrder(instrument: String, direction: String, amount: Double,
                     stopLoss: Double, takeProfit: Double) async throws -> Position {
        let url = ordersCollectionURL
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "instrument": instrument,
            "direction": direction,
            "amount": amount,
            "stopLoss": stopLoss,
            "takeProfit": takeProfit,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TradingError.serverError("No response")
        }

        if httpResponse.statusCode != 200 {
            if let errorBody = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw TradingError.serverError(errorBody.error)
            }
            throw TradingError.serverError("HTTP \(httpResponse.statusCode)")
        }

        return try JSONDecoder().decode(Position.self, from: data)
    }

    func closeOrder(label: String) async throws {
        let url = orderByLabelURL(label: label)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            if let data = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw TradingError.serverError(data.error)
            }
            throw TradingError.serverError("Failed to close order")
        }
    }

    func modifyOrder(label: String, stopLoss: Double, takeProfit: Double) async throws -> Position {
        let url = orderByLabelURL(label: label)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "stopLoss": stopLoss,
            "takeProfit": takeProfit,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TradingError.serverError("No response")
        }

        if httpResponse.statusCode != 200 {
            if let errorBody = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw TradingError.serverError(errorBody.error)
            }
            throw TradingError.serverError("HTTP \(httpResponse.statusCode)")
        }

        return try JSONDecoder().decode(Position.self, from: data)
    }

    func fetchPositions() async throws -> [Position] {
        let url = ordersCollectionURL
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw TradingError.serverError("Failed to fetch positions")
        }

        return try JSONDecoder().decode([Position].self, from: data)
    }

    private struct ErrorResponse: Codable {
        let error: String
    }

    enum TradingError: Error, LocalizedError {
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .serverError(let message): return message
            }
        }
    }
}
