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
    var currentInstrument = "EURUSD" {
        didSet {
            // Keep the instrument in the Picker's tag list so SwiftUI never sees an
            // "invalid selection" — which can trigger undefined Picker behaviour
            // (including silently resetting the selection) and race with start().
            if !availableInstruments.contains(currentInstrument) {
                availableInstruments.append(currentInstrument)
            }
            onStateChanged?()
        }
    }
    var currentPeriod = "FIFTEEN_MINS" {
        didSet { onStateChanged?() }
    }
    var availableInstruments: [String] = ["EURUSD"]
    var showSessions = true {
        didSet { onStateChanged?() }
    }
    var showVolume = true {
        didSet { onStateChanged?() }
    }
    var showVolumeMA = true {
        didSet { onStateChanged?() }
    }
    var volumeMA: EMALine = EMALine(period: 20, color: .cyan) {
        didSet { onStateChanged?() }
    }
    var showEMA = true {
        didSet { onStateChanged?() }
    }
    var emaConfigs: [EMALine] = EMALine.defaults {
        didSet { onStateChanged?() }
    }
    var showATR = true {
        didSet { onStateChanged?() }
    }
    var atrPeriod = 14 {
        didSet {
            onStateChanged?()
            loadATR()
        }
    }
    var atrValue: Double?
    var atrPips: Double?
    var todayATRPercent: Double?

    var onStateChanged: (() -> Void)?

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

    private var coordinator: any MarketDataProviding
    private var startTask: Task<Void, Never>?
    private var wsTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var atrTask: Task<Void, Never>?
    private var todayTradingDayStart: Date?
    private var todayHigh: Double?
    private var todayLow: Double?
    private var hasStarted = false
    private var isLoadingEarlier = false

    init(coordinator: any MarketDataProviding = MarketDataCoordinator()) {
        self.coordinator = coordinator
    }

    /// Test helper to seed today's ATR tracking state.
    func setTodayATRRange(dayStart: Date, high: Double, low: Double) {
        todayTradingDayStart = dayStart
        todayHigh = high
        todayLow = low
    }

    func reconnect(port: Int) {
        stop()
        coordinator = MarketDataCoordinator(port: port, cache: coordinator.cache)
        hasStarted = false
        bars = []
        transform = ChartTransform()
        startAsync()
    }

    /// Launch `start()` in a tracked Task so it can be cancelled on instrument
    /// switches / reconnects instead of lingering with a pending HTTP request.
    func startAsync() {
        startTask = Task { await start() }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        // Retry initial connection until the server is reachable
        while !Task.isCancelled {
            if let instruments = try? await coordinator.fetchInstruments(), !instruments.isEmpty {
                availableInstruments = instruments
                // Re-add currentInstrument if it's not in the server's list (e.g.
                // restored from saved state with an instrument the server doesn't
                // subscribe to for live data, but can still serve history for).
                if !availableInstruments.contains(currentInstrument) {
                    availableInstruments.append(currentInstrument)
                }
                break
            }
            try? await Task.sleep(for: .seconds(2))
        }

        // Load history first so the REST call isn't starved by WebSocket
        // callbacks competing for MainActor time.
        await loadHistoryWithRetry()
        loadATR()
        connectWebSocket()
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

    func reloadCurrentChart() {
        reloadChart()
    }

    private func reloadChart() {
        startTask?.cancel()
        reloadTask?.cancel()
        wsTask?.cancel()
        atrTask?.cancel()
        isLoadingEarlier = false

        // Reset synchronously so the Canvas never sees a stale xOffset
        // paired with fewer bars from the new instrument/period.
        bars = []
        transform = ChartTransform()
        error = nil

        let key = CandleCache.CacheKey(instrument: currentInstrument, period: currentPeriod)
        reloadTask = Task {
            let cached = await coordinator.cache.getBars(for: key)
            if !cached.isEmpty {
                bars = cached
                scrollToEnd()
            }
            await loadHistoryWithRetry()
            loadATR()
            connectWebSocket()
        }
    }

    /// Load history, retrying until we get non-empty bars or the instrument/period changes.
    private func loadHistoryWithRetry() async {
        let instrument = currentInstrument
        let period = currentPeriod

        // Show cached bars immediately while waiting for server
        let key = CandleCache.CacheKey(instrument: instrument, period: period)
        let cached = await coordinator.cache.getBars(for: key)
        if Task.isCancelled { return }
        if !cached.isEmpty {
            bars = cached
            scrollToEnd()
        }

        while !Task.isCancelled {
            guard instrument == currentInstrument, period == currentPeriod else { return }
            do {
                let history = try await coordinator.fetchCandles(instrument: instrument, period: period, count: Self.barCount(for: period))
                if Task.isCancelled { return }
                guard instrument == currentInstrument, period == currentPeriod else { return }
                if !history.isEmpty {
                    bars = history
                    error = nil
                    scrollToEnd()
                    return
                }
            } catch is CancellationError {
                return
            } catch let e {
                error = "History: \(e.localizedDescription)"
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// Load history once (used by reloadChart where the server/data is already known to be available).
    private func loadHistory() async {
        let instrument = currentInstrument
        let period = currentPeriod
        do {
            let history = try await coordinator.fetchCandles(instrument: instrument, period: period, count: Self.barCount(for: period))
            guard instrument == currentInstrument, period == currentPeriod else { return }
            bars = history
            error = nil
            scrollToEnd()
        } catch {
            if bars.isEmpty {
                self.error = "Failed to load history: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - ATR

    func loadATR() {
        atrTask?.cancel()
        let instrument = currentInstrument
        atrTask = Task {
            do {
                // Fetch enough hourly candles to cover atrPeriod + 2 trading days.
                // Trading days ≈ 5/7 of calendar days, each has ~24 hourly bars.
                let tradingDaysNeeded = self.atrPeriod + 2
                let calendarDays = Int(ceil(Double(tradingDaysNeeded) * 7.0 / 5.0))
                let count = calendarDays * 24
                let hourlyBars = try await coordinator.fetchCandles(
                    instrument: instrument, period: "ONE_HOUR", count: count
                )
                guard !Task.isCancelled, instrument == currentInstrument else { return }
                if let result = TradingDayATR.compute(from: hourlyBars, instrument: instrument, period: self.atrPeriod) {
                    atrValue = result.atr
                    atrPips = result.pips
                    todayATRPercent = result.todayPercent

                    // Store today's trading day boundary and high/low so handleBar
                    // can update todayATRPercent in real-time.
                    let allDays = TradingDayATR.tradingDayRanges(from: hourlyBars)
                    if let today = allDays.last {
                        todayTradingDayStart = today.start
                        todayHigh = today.high
                        todayLow = today.low
                    }
                } else {
                    atrValue = nil
                    atrPips = nil
                    todayATRPercent = nil
                }
            } catch {
                // Non-critical — just clear values
                if !Task.isCancelled {
                    atrValue = nil
                    atrPips = nil
                    todayATRPercent = nil
                }
            }
        }
    }

    /// Update today's ATR percentage from a live bar if it falls within
    /// the current trading day.
    private func updateATRFromBar(_ bar: CandleBar) {
        guard let atr = atrValue, atr > 0,
              let dayStart = todayTradingDayStart,
              var high = todayHigh,
              var low = todayLow else { return }

        // Check the bar belongs to today's trading day
        let barDate = bar.date
        guard barDate >= dayStart else { return }

        var changed = false
        if bar.high > high { high = bar.high; todayHigh = high; changed = true }
        if bar.low < low { low = bar.low; todayLow = low; changed = true }

        if changed {
            let range = high - low
            todayATRPercent = (range / atr) * 100
        }
    }

    private func connectWebSocket() {
        wsTask?.cancel()
        let instrument = currentInstrument
        let period = currentPeriod
        wsTask = Task {
            while !Task.isCancelled {
                do {
                    for try await bar in coordinator.streamCandles(instrument: instrument, period: period) {
                        if !isConnected { isConnected = true }
                        handleBar(bar, expectedInstrument: instrument, expectedPeriod: period)
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

    func handleBar(_ bar: CandleBar, expectedInstrument: String, expectedPeriod: String) {
        // Discard bars from a stale WebSocket that hasn't been cancelled yet
        guard expectedInstrument == currentInstrument, expectedPeriod == currentPeriod else { return }
        if bar.partial {
            // Update the last bar if it has the same timestamp, otherwise append
            if let lastIndex = bars.indices.last, bars[lastIndex].time == bar.time {
                bars[lastIndex] = bar
            } else if bars.isEmpty || bar.time > bars[bars.count - 1].time {
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
            Task { await coordinator.cacheBar(bar, instrument: currentInstrument, period: currentPeriod) }
        }
        updateATRFromBar(bar)
    }

    func scrollToEnd() {
        let totalWidth = CGFloat(bars.count) * transform.candleSlotWidth
        transform.xOffset = max(0, totalWidth - chartWidth)

        // If bars don't fill the screen, fetch earlier bars automatically
        if totalWidth < chartWidth && !isLoadingEarlier && !bars.isEmpty {
            Task { await loadEarlierBars() }
        }
    }

    /// Shift the view by one candle slot so the new bar appears where the old last bar was.
    private func advanceByOneCandle() {
        transform.xOffset += transform.candleSlotWidth
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        reloadTask?.cancel()
        reloadTask = nil
        wsTask?.cancel()
        wsTask = nil
        atrTask?.cancel()
        atrTask = nil
        isConnected = false
    }

    /// Called by the interaction view when the user drags. Disables autoscroll
    /// if the user scrolled away from the right edge, and triggers loading
    /// earlier bars when scrolling near the left edge.
    func onUserScroll() {
        let totalWidth = CGFloat(bars.count) * transform.candleSlotWidth
        let rightEdge = transform.xOffset + chartWidth
        let atEnd = rightEdge >= totalWidth - transform.candleSlotWidth * 2
        autoScroll = atEnd

        // Scroll-back: load earlier bars when near the left edge
        let startIndex = Int(floor(transform.xOffset / transform.candleSlotWidth))
        if startIndex < 50 && !isLoadingEarlier && !bars.isEmpty {
            Task { await loadEarlierBars() }
        }
    }

    /// Bar count scaled to the timeframe — avoids multi-year CDN downloads for larger periods.
    private static func barCount(for period: String) -> Int {
        switch period {
        case "DAILY":      return 250  // ~1 year of trading days
        case "FOUR_HOURS": return 500  // ~3 months
        case "ONE_HOUR":   return 500  // ~3 weeks
        default:           return 1000 // intraday
        }
    }

    private func loadEarlierBars() async {
        isLoadingEarlier = true
        let instrument = currentInstrument
        let period = currentPeriod
        let oldCount = bars.count

        do {
            let allBars = try await coordinator.fetchEarlierCandles(
                instrument: instrument, period: period, count: Self.barCount(for: period)
            )
            guard instrument == currentInstrument, period == currentPeriod else {
                isLoadingEarlier = false
                return
            }
            let addedCount = allBars.count - oldCount
            if addedCount > 0 {
                bars = allBars
                // Shift scroll offset so the same candles stay in view
                transform.xOffset += CGFloat(addedCount) * transform.candleSlotWidth
            }
        } catch {
            self.error = "Earlier bars: \(error.localizedDescription)"
        }

        isLoadingEarlier = false
    }
}
