import Foundation
import SwiftUI

@Observable
@MainActor
final class TradingViewModel {
    var positions: [Position] = []
    var pendingOrders: [PendingOrder] = []
    var account: Account?
    var isConnected = false
    var isSubmitting = false
    var orderError: String?
    var visualOrders: [String: VisualOrderState] = [:]

    private var coordinator: any TradingCoordinating
    private var wsTask: Task<Void, Never>?
    private var pendingWsTask: Task<Void, Never>?

    var amount = 0.01

    init(coordinator: any TradingCoordinating = TradingCoordinator()) {
        self.coordinator = coordinator
    }

    func start() {
        connectWebSocket()
        connectPendingOrdersWebSocket()
    }

    func stop() {
        wsTask?.cancel()
        wsTask = nil
        pendingWsTask?.cancel()
        pendingWsTask = nil
        isConnected = false
    }

    func reconnect(port: Int) {
        stop()
        coordinator = TradingCoordinator(port: port)
        positions = []
        pendingOrders = []
        start()
    }

    // MARK: - Order submission

    @discardableResult
    func submitMarketOrder(instrument: String, direction: String,
                           amount: Double? = nil, stopLoss: Double, takeProfit: Double) async throws -> Position {
        isSubmitting = true
        defer { isSubmitting = false }
        orderError = nil

        do {
            return try await coordinator.submitOrder(
                instrument: instrument, direction: direction,
                amount: amount ?? self.amount,
                stopLoss: stopLoss, takeProfit: takeProfit)
        } catch {
            orderError = error.localizedDescription
            throw error
        }
    }

    func beginVisualOrder(direction: String, instrument: String, bars: [CandleBar]) {
        guard bars.count >= 2, let currentPrice = bars.last?.close else {
            orderError = "Not enough candle data"
            return
        }

        let (sl, tp) = Self.visualOrderSLTP(direction: direction, bars: bars, currentPrice: currentPrice)
        let nextIndex = bars.count + 1

        var initialAmount = amount
        var marginCapped = false
        if let equity = account?.equity, let freeMargin = account?.freeMargin {
            let sizing = PositionSizing.calculate(
                equity: equity, freeMargin: freeMargin, riskFraction: 0.05,
                entryPrice: currentPrice, stopLoss: sl)
            initialAmount = sizing.lots
            marginCapped = sizing.isMarginCapped
        }

        visualOrders[instrument] = VisualOrderState(
            direction: direction,
            instrument: instrument,
            entryPrice: currentPrice,
            marketPrice: currentPrice,
            amount: initialAmount,
            stopLoss: sl,
            takeProfit: tp,
            startBarIndex: nextIndex,
            endBarIndex: nextIndex + 10,
            isAmountOverridden: false,
            isMarginCapped: marginCapped,
            isEntryOverridden: false
        )
    }

    /// Compute initial SL/TP for visual order. Always returns valid values
    /// by scanning recent bars for a reasonable stop level.
    nonisolated static func visualOrderSLTP(direction: String, bars: [CandleBar], currentPrice: Double) -> (stopLoss: Double, takeProfit: Double) {
        // Look at the last few completed bars to find a reasonable SL
        let lookback = min(5, bars.count)
        let recentBars = bars.suffix(lookback).filter { !$0.partial }

        if direction == "BUY" {
            let lowestLow = recentBars.map(\.low).min() ?? currentPrice
            // SL at the lowest low of recent bars, but always below current price
            let sl = min(lowestLow, currentPrice - abs(currentPrice) * 0.001)
            let risk = currentPrice - sl
            return (stopLoss: sl, takeProfit: currentPrice + risk * 3)
        } else {
            let highestHigh = recentBars.map(\.high).max() ?? currentPrice
            // SL at the highest high of recent bars, but always above current price
            let sl = max(highestHigh, currentPrice + abs(currentPrice) * 0.001)
            let risk = sl - currentPrice
            return (stopLoss: sl, takeProfit: currentPrice - risk * 3)
        }
    }

    func visualOrder(for instrument: String) -> VisualOrderState? {
        visualOrders[instrument]
    }

    func visualOrderWithLivePrice(for instrument: String, currentPrice: Double?, barCount: Int) -> VisualOrderState? {
        guard var order = visualOrders[instrument], let price = currentPrice else {
            return visualOrders[instrument]
        }
        order.marketPrice = price
        visualOrders[instrument]?.marketPrice = price
        // Only keep entryPrice pinned to market while the user hasn't dragged it.
        // Once overridden the entry becomes a limit/stop target and must stay put.
        if !order.isEntryOverridden {
            order.entryPrice = price
            visualOrders[instrument]?.entryPrice = price
        }
        let boxWidth = order.endBarIndex - order.startBarIndex
        order.startBarIndex = barCount + 1
        order.endBarIndex = barCount + 1 + boxWidth
        visualOrders[instrument]?.startBarIndex = order.startBarIndex
        visualOrders[instrument]?.endBarIndex = order.endBarIndex
        recalculateAmount(for: instrument)
        return visualOrders[instrument]
    }

    func updateVisualOrderEntry(instrument: String, price: Double) {
        guard var order = visualOrders[instrument] else { return }
        order.entryPrice = price
        order.isEntryOverridden = true
        visualOrders[instrument] = order
        recalculateAmount(for: instrument)
    }

    /// Keeps the visual-order state intact until the server confirms the fill.
    /// On failure, the user sees the error and still has the box to retry or cancel.
    func confirmVisualOrder(instrument: String) async {
        guard !isSubmitting, let order = visualOrders[instrument] else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        orderError = nil
        do {
            _ = try await coordinator.submitOrder(
                instrument: order.instrument,
                direction: order.direction,
                amount: order.amount,
                stopLoss: order.stopLoss,
                takeProfit: order.takeProfit,
                orderType: order.orderType,
                entryPrice: order.orderType == "MARKET" ? nil : order.entryPrice)
            visualOrders.removeValue(forKey: instrument)
        } catch {
            orderError = error.localizedDescription
            // keep the visual order for retry.
        }
    }

    func cancelVisualOrder(instrument: String) {
        guard !isSubmitting else { return }
        visualOrders.removeValue(forKey: instrument)
    }

    func adjustVisualOrderAmount(instrument: String, by delta: Double) {
        guard visualOrders[instrument] != nil else { return }
        let newAmount = max(0.001, (visualOrders[instrument]?.amount ?? 0.001) + delta)
        visualOrders[instrument]?.amount = newAmount
        visualOrders[instrument]?.isAmountOverridden = true
    }

    func updateVisualOrderSL(instrument: String, price: Double) {
        visualOrders[instrument]?.stopLoss = price
        recalculateAmount(for: instrument)
    }

    func resetVisualOrderAmount(instrument: String) {
        guard visualOrders[instrument] != nil else { return }
        visualOrders[instrument]?.isAmountOverridden = false
        recalculateAmount(for: instrument)
    }

    func closePosition(label: String) async {
        do {
            try await coordinator.closeOrder(label: label)
        } catch {
            orderError = error.localizedDescription
        }
    }

    func modifyPosition(label: String, stopLoss: Double, takeProfit: Double) async {
        do {
            _ = try await coordinator.modifyOrder(label: label, stopLoss: stopLoss, takeProfit: takeProfit)
        } catch {
            orderError = error.localizedDescription
        }
    }

    // MARK: - Order Calculation

    struct OneClickParams: Equatable {
        let stopLoss: Double
        let takeProfit: Double
    }

    enum OneClickError: Error, Equatable {
        case insufficientData
        case invalidRisk(String)
    }

    /// Pure calculation of one-click order SL/TP. Exposed for testing.
    nonisolated static func calculateOneClick(direction: String, bars: [CandleBar]) -> Result<OneClickParams, OneClickError> {
        guard let previous = lastCompletedBar(in: bars),
              let current = bars.last else {
            return .failure(.insufficientData)
        }

        let currentPrice = current.close
        if direction == "BUY" {
            let stopLoss = previous.low
            let risk = currentPrice - stopLoss
            guard risk > 0 else {
                return .failure(.invalidRisk("current price below previous low"))
            }
            return .success(OneClickParams(stopLoss: stopLoss, takeProfit: currentPrice + risk * 3))
        } else {
            let stopLoss = previous.high
            let risk = stopLoss - currentPrice
            guard risk > 0 else {
                return .failure(.invalidRisk("current price above previous high"))
            }
            return .success(OneClickParams(stopLoss: stopLoss, takeProfit: currentPrice - risk * 3))
        }
    }

    nonisolated static func lastCompletedBar(in bars: [CandleBar]) -> CandleBar? {
        guard !bars.isEmpty else { return nil }
        if let last = bars.last, !last.partial {
            return bars.count >= 2 ? bars[bars.count - 2] : nil
        }
        return bars.count >= 3 ? bars[bars.count - 3] : (bars.count >= 2 ? bars[bars.count - 2] : nil)
    }

    // MARK: - Private

    private func recalculateAmount(for instrument: String) {
        guard var order = visualOrders[instrument],
              !order.isAmountOverridden,
              let equity = account?.equity,
              let freeMargin = account?.freeMargin else { return }
        let result = PositionSizing.calculate(
            equity: equity, freeMargin: freeMargin,
            riskFraction: 0.05,
            entryPrice: order.entryPrice, stopLoss: order.stopLoss)
        order.amount = result.lots
        order.isMarginCapped = result.isMarginCapped
        visualOrders[instrument] = order
    }

    private func connectWebSocket() {
        wsTask?.cancel()
        wsTask = Task {
            while !Task.isCancelled {
                do {
                    for try await snapshot in coordinator.streamSnapshots() {
                        if !isConnected { isConnected = true }
                        positions = snapshot.positions
                        account = snapshot.account
                    }
                } catch is CancellationError {
                    break
                } catch {
                    isConnected = false
                    try? await Task.sleep(for: .seconds(3))
                }
            }
            isConnected = false
        }
    }

    private func connectPendingOrdersWebSocket() {
        pendingWsTask?.cancel()
        pendingWsTask = Task {
            while !Task.isCancelled {
                do {
                    for try await snapshot in coordinator.streamPendingOrders() {
                        pendingOrders = snapshot.pendingOrders
                    }
                } catch is CancellationError {
                    break
                } catch {
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }
}
