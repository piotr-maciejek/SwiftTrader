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
    var oneClickMode = false

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

    func submitOneClickOrder(direction: String, instrument: String, bars: [CandleBar]) async {
        switch Self.calculateOneClick(direction: direction, bars: bars) {
        case .success(let params):
            await submitMarketOrder(instrument: instrument, direction: direction,
                                    stopLoss: params.stopLoss, takeProfit: params.takeProfit)
        case .failure(let error):
            switch error {
            case .insufficientData: orderError = "Not enough candle data"
            case .invalidRisk(let detail): orderError = "Invalid SL: \(detail)"
            }
        }
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
