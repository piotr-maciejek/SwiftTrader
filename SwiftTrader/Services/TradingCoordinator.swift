import Foundation

/// Protocol-driven surface of TradingCoordinator so TradingViewModel can be unit-tested
/// with a fake (no real network, no URLSession). Production code always uses the concrete class.
protocol TradingCoordinating: Sendable {
    func submitOrder(instrument: String, direction: String, amount: Double,
                     stopLoss: Double, takeProfit: Double,
                     orderType: String, entryPrice: Double?) async throws -> Position
    func closeOrder(label: String) async throws
    func modifyOrder(label: String, stopLoss: Double, takeProfit: Double) async throws -> Position
    /// Amend a resting pending (limit/stop) order's ENTRY/trigger price in place. `label` is the
    /// pending order's id (its opening order's orderId). Standalone-only; server mode is unsupported.
    func modifyPendingEntry(label: String, newTriggerPrice: Double) async throws
    func streamSnapshots() -> AsyncThrowingStream<TradingSnapshot, Error>
    func streamPendingOrders() -> AsyncThrowingStream<PendingOrdersSnapshot, Error>
    /// Latest live (bid, ask) for an instrument from the trading feed, or nil if unavailable. Used to
    /// capture the real press-time, fill-side price for slippage (not the lagging chart bar close).
    func currentQuote(instrument: String) async -> (bid: Double, ask: Double)?
    /// Make a quote→account-currency conversion rate available (subscribe the cross pair).
    /// Standalone-only; the default is a no-op.
    func ensureConversionRate(quoteCurrency: String, accountCurrency: String) async
}

extension TradingCoordinating {
    /// Default: no live quote (server mode / test fakes) → callers fall back to the chart price.
    func currentQuote(instrument: String) async -> (bid: Double, ask: Double)? { nil }

    /// Default no-op: only standalone mode can subscribe the cross pair that supplies a
    /// quote→account conversion rate for position sizing (server mode sends no rates).
    func ensureConversionRate(quoteCurrency: String, accountCurrency: String) async {}

    /// Default: entry-trigger amend is standalone-only (server mode / test fakes don't support it).
    func modifyPendingEntry(label: String, newTriggerPrice: Double) async throws {
        throw NativeTradingError.notSupported("modifying a pending order's entry price")
    }

    /// Back-compat for market-order callers (tests, existing code).
    func submitOrder(instrument: String, direction: String, amount: Double,
                     stopLoss: Double, takeProfit: Double) async throws -> Position {
        try await submitOrder(
            instrument: instrument, direction: direction, amount: amount,
            stopLoss: stopLoss, takeProfit: takeProfit,
            orderType: "MARKET", entryPrice: nil)
    }
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
                     stopLoss: Double, takeProfit: Double,
                     orderType: String, entryPrice: Double?) async throws -> Position {
        try await apiService.submitOrder(
            instrument: instrument, direction: direction, amount: amount,
            stopLoss: stopLoss, takeProfit: takeProfit,
            orderType: orderType, entryPrice: entryPrice)
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

    func streamPendingOrders() -> AsyncThrowingStream<PendingOrdersSnapshot, Error> {
        PendingOrdersWebSocketService(host: host, port: port).snapshots()
    }
}
