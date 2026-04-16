import Foundation

/// Protocol-driven surface of TradingCoordinator so TradingViewModel can be unit-tested
/// with a fake (no real network, no URLSession). Production code always uses the concrete class.
protocol TradingCoordinating: Sendable {
    func submitOrder(instrument: String, direction: String, amount: Double,
                     stopLoss: Double, takeProfit: Double) async throws -> Position
    func closeOrder(label: String) async throws
    func modifyOrder(label: String, stopLoss: Double, takeProfit: Double) async throws -> Position
    func streamSnapshots() -> AsyncThrowingStream<TradingSnapshot, Error>
}

final class TradingCoordinator: TradingCoordinating, Sendable {
    private let apiService: TradingAPIService
    private let host: String
    private let port: Int

    init(host: String = "localhost", port: Int = 8080) {
        self.apiService = TradingAPIService(baseURL: URL(string: "http://\(host):\(port)")!)
        self.host = host
        self.port = port
    }

    func submitOrder(instrument: String, direction: String, amount: Double,
                     stopLoss: Double, takeProfit: Double) async throws -> Position {
        try await apiService.submitOrder(
            instrument: instrument, direction: direction, amount: amount,
            stopLoss: stopLoss, takeProfit: takeProfit)
    }

    func closeOrder(label: String) async throws {
        try await apiService.closeOrder(label: label)
    }

    func modifyOrder(label: String, stopLoss: Double, takeProfit: Double) async throws -> Position {
        try await apiService.modifyOrder(label: label, stopLoss: stopLoss, takeProfit: takeProfit)
    }

    func fetchPositions() async throws -> [Position] {
        try await apiService.fetchPositions()
    }

    func streamSnapshots() -> AsyncThrowingStream<TradingSnapshot, Error> {
        TradingWebSocketService(host: host, port: port).snapshots()
    }
}
