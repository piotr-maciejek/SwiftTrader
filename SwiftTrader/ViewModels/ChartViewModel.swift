import Foundation
import SwiftUI

@Observable
@MainActor
final class ChartViewModel {
    var bars: [CandleBar] = []
    var transform = ChartTransform()
    var isConnected = false
    var error: String?
    var autoScroll = true
    var currentInstrument = "EURUSD"
    var currentPeriod = "ONE_MIN"
    var availableInstruments: [String] = ["EURUSD"]

    static let availablePeriods: [(value: String, label: String)] = [
        ("ONE_SEC", "1s"),
        ("TEN_SECS", "10s"),
        ("ONE_MIN", "1m"),
        ("FIVE_MINS", "5m"),
        ("TEN_MINS", "10m"),
        ("FIFTEEN_MINS", "15m"),
        ("THIRTY_MINS", "30m"),
        ("ONE_HOUR", "1h"),
        ("FOUR_HOURS", "4h"),
        ("DAILY", "D"),
        ("WEEKLY", "W"),
    ]

    /// Set by ChartView via GeometryReader so scroll calculations use real width
    var chartWidth: CGFloat = 1200

    private var coordinator: MarketDataCoordinator
    private var wsTask: Task<Void, Never>?
    private var hasStarted = false

    init(coordinator: MarketDataCoordinator = MarketDataCoordinator()) {
        self.coordinator = coordinator
    }

    func reconnect(port: Int) {
        stop()
        coordinator = MarketDataCoordinator(port: port)
        hasStarted = false
        bars = []
        transform = ChartTransform()
        Task { await start() }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        // Retry initial connection until the server is reachable
        while !Task.isCancelled {
            if let instruments = try? await coordinator.fetchInstruments(), !instruments.isEmpty {
                availableInstruments = instruments
                break
            }
            try? await Task.sleep(for: .seconds(2))
        }

        // Start WebSocket immediately so live data flows while history loads
        connectWebSocket()
        // Retry history until we get actual bars (server may be up but data source not yet connected)
        await loadHistoryWithRetry()
    }

    func switchInstrument(_ instrument: String) {
        guard instrument != currentInstrument else { return }
        currentInstrument = instrument
        reloadChart()
    }

    func switchPeriod(_ period: String) {
        guard period != currentPeriod else { return }
        currentPeriod = period
        reloadChart()
    }

    private func reloadChart() {
        wsTask?.cancel()
        bars = []
        transform = ChartTransform()
        Task {
            await loadHistory()
            connectWebSocket()
        }
    }

    /// Load history, retrying until we get non-empty bars or the instrument/period changes.
    private func loadHistoryWithRetry() async {
        let instrument = currentInstrument
        let period = currentPeriod
        while !Task.isCancelled {
            guard instrument == currentInstrument, period == currentPeriod else { return }
            do {
                let history = try await coordinator.fetchCandles(instrument: instrument, period: period, count: 1000)
                guard instrument == currentInstrument, period == currentPeriod else { return }
                if !history.isEmpty {
                    bars = history
                    error = nil
                    scrollToEnd()
                    return
                }
            } catch {}
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// Load history once (used by reloadChart where the server/data is already known to be available).
    private func loadHistory() async {
        let instrument = currentInstrument
        let period = currentPeriod
        do {
            let history = try await coordinator.fetchCandles(instrument: instrument, period: period, count: 1000)
            guard instrument == currentInstrument, period == currentPeriod else { return }
            bars = history
            error = nil
            scrollToEnd()
        } catch {
            self.error = "Failed to load history: \(error.localizedDescription)"
        }
    }

    private func connectWebSocket() {
        wsTask?.cancel()
        wsTask = Task {
            while !Task.isCancelled {
                do {
                    for try await bar in coordinator.streamCandles(instrument: currentInstrument, period: currentPeriod) {
                        if !isConnected { isConnected = true }
                        handleBar(bar)
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

    private func handleBar(_ bar: CandleBar) {
        if bar.partial {
            // Update the last bar if it has the same timestamp, otherwise append
            if let lastIndex = bars.indices.last, bars[lastIndex].time == bar.time {
                bars[lastIndex] = bar
            } else if let lastIndex = bars.indices.last, bar.time > bars[lastIndex].time {
                bars.append(bar)
                if autoScroll { advanceByOneCandle() }
            }
        } else {
            // Completed bar: replace partial or append
            if let lastIndex = bars.indices.last, bars[lastIndex].time == bar.time {
                bars[lastIndex] = bar
            } else {
                bars.append(bar)
                if autoScroll { advanceByOneCandle() }
            }
        }
    }

    func scrollToEnd() {
        let totalWidth = CGFloat(bars.count) * transform.candleSlotWidth
        transform.xOffset = max(0, totalWidth - chartWidth)
    }

    /// Shift the view by one candle slot so the new bar appears where the old last bar was.
    private func advanceByOneCandle() {
        transform.xOffset += transform.candleSlotWidth
    }

    func stop() {
        wsTask?.cancel()
        wsTask = nil
        isConnected = false
    }

    /// Called by the interaction view when the user drags. Disables autoscroll
    /// if the user scrolled away from the right edge.
    func onUserScroll() {
        let totalWidth = CGFloat(bars.count) * transform.candleSlotWidth
        let rightEdge = transform.xOffset + chartWidth
        let atEnd = rightEdge >= totalWidth - transform.candleSlotWidth * 2
        autoScroll = atEnd
    }
}
