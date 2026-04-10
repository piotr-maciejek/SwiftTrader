import Foundation
import SwiftUI

@Observable
@MainActor
final class TradingViewModel {
    var positions: [Position] = []
    var account: Account?
    var isConnected = false
    var isSubmitting = false
    var orderError: String?
    var visualMode = true
    var visualOrders: [String: VisualOrderState] = [:]

    private var coordinator: TradingCoordinator
    private var wsTask: Task<Void, Never>?

    var amount = 0.001

    init(coordinator: TradingCoordinator = TradingCoordinator()) {
        self.coordinator = coordinator
    }

    func start() {
        connectWebSocket()
    }

    func stop() {
        wsTask?.cancel()
        wsTask = nil
        isConnected = false
    }

    func reconnect(port: Int) {
        stop()
        coordinator = TradingCoordinator(port: port)
        positions = []
        start()
    }

    // MARK: - Order submission

    func submitMarketOrder(instrument: String, direction: String,
                           amount: Double? = nil, stopLoss: Double, takeProfit: Double) async {
        isSubmitting = true
        defer { isSubmitting = false }
        orderError = nil

        do {
            _ = try await coordinator.submitOrder(
                instrument: instrument, direction: direction,
                amount: amount ?? self.amount,
                stopLoss: stopLoss, takeProfit: takeProfit)
        } catch {
            orderError = error.localizedDescription
        }
    }

    func beginVisualOrder(direction: String, instrument: String, bars: [CandleBar]) {
        guard bars.count >= 2, let currentPrice = bars.last?.close else {
            orderError = "Not enough candle data"
            return
        }

        let (sl, tp) = Self.visualOrderSLTP(direction: direction, bars: bars, currentPrice: currentPrice)
        let nextIndex = bars.count + 1
        visualOrders[instrument] = VisualOrderState(
            direction: direction,
            instrument: instrument,
            entryPrice: currentPrice,
            stopLoss: sl,
            takeProfit: tp,
            startBarIndex: nextIndex,
            endBarIndex: nextIndex + 10
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

    func confirmVisualOrder(instrument: String) async {
        guard let order = visualOrders.removeValue(forKey: instrument) else { return }
        await submitMarketOrder(
            instrument: order.instrument, direction: order.direction,
            stopLoss: order.stopLoss, takeProfit: order.takeProfit)
    }

    func cancelVisualOrder(instrument: String) {
        visualOrders.removeValue(forKey: instrument)
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
}
