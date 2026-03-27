import Foundation
import SwiftUI

@Observable
@MainActor
final class TradingViewModel {
    var positions: [Position] = []
    var isConnected = false
    var isSubmitting = false
    var orderError: String?
    var oneClickMode = false

    private var coordinator: TradingCoordinator
    private var wsTask: Task<Void, Never>?

    static let defaultAmount = 0.001

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
                           stopLoss: Double, takeProfit: Double) async {
        isSubmitting = true
        orderError = nil

        do {
            _ = try await coordinator.submitOrder(
                instrument: instrument, direction: direction,
                amount: Self.defaultAmount,
                stopLoss: stopLoss, takeProfit: takeProfit)
        } catch {
            orderError = error.localizedDescription
        }

        isSubmitting = false
    }

    func submitOneClickOrder(direction: String, instrument: String, bars: [CandleBar]) async {
        // Find the last completed candle
        guard let previous = lastCompletedBar(in: bars),
              let current = bars.last else {
            orderError = "Not enough candle data"
            return
        }

        let currentPrice = current.close
        let stopLoss: Double
        let takeProfit: Double

        if direction == "BUY" {
            stopLoss = previous.low
            let risk = currentPrice - stopLoss
            guard risk > 0 else {
                orderError = "Invalid SL: current price below previous low"
                return
            }
            takeProfit = currentPrice + risk * 3
        } else {
            stopLoss = previous.high
            let risk = stopLoss - currentPrice
            guard risk > 0 else {
                orderError = "Invalid SL: current price above previous high"
                return
            }
            takeProfit = currentPrice - risk * 3
        }

        await submitMarketOrder(instrument: instrument, direction: direction,
                                stopLoss: stopLoss, takeProfit: takeProfit)
    }

    func closePosition(label: String) async {
        do {
            try await coordinator.closeOrder(label: label)
        } catch {
            orderError = error.localizedDescription
        }
    }

    // MARK: - Private

    private func lastCompletedBar(in bars: [CandleBar]) -> CandleBar? {
        guard !bars.isEmpty else { return nil }
        if let last = bars.last, !last.partial {
            return bars.count >= 2 ? bars[bars.count - 2] : nil
        }
        return bars.count >= 3 ? bars[bars.count - 3] : (bars.count >= 2 ? bars[bars.count - 2] : nil)
    }

    private func connectWebSocket() {
        wsTask?.cancel()
        wsTask = Task {
            while !Task.isCancelled {
                do {
                    for try await update in coordinator.streamPositions() {
                        if !isConnected { isConnected = true }
                        positions = update
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
