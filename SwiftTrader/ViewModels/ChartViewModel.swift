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
    var isRefreshingCache = false
    var loadingStatus: LoadingStatus?

    /// Snapshot of the rebucketing toggle for current Tasks. Read-through to
    /// `AppSettings` at reload time so flipping the toggle takes effect on the
    /// next chart reload.
    private var clientSideRebucketing: Bool = AppSettings.shared.clientSideRebucketing

    var onStateChanged: (() -> Void)?

    /// Bounded retry caps. Past these the user sees an "exhausted" banner with
    /// Retry / Force-reconnect buttons instead of more silent retries.
    private static let maxInstrumentAttempts = 5
    private static let maxHistoryAttempts = 6
    private static let maxWebSocketAttempts = 6

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

        // Paint cached bars first so the user sees data immediately on cold start —
        // before fetchInstruments() finishes its server roundtrip. Mirrors reloadChart().
        let displayKey = CandleCache.CacheKey.forDisplay(
            instrument: currentInstrument,
            period: currentPeriod,
            clientSideRebucketing: clientSideRebucketing
        )
        let cached = await coordinator.cache.getBars(for: displayKey)
        if !cached.isEmpty {
            bars = cached
            scrollToEnd()
            // ContentView hides ChartLoadingCard when bars are non-empty, so no
            // overlay is shown over the cached bars while we refresh in the background.
        } else {
            loadingStatus = .connecting()
        }

        var instrumentAttempt = 1
        var instrumentLastError: String?
        var fetchedInstruments: [String]?
        while !Task.isCancelled, instrumentAttempt <= Self.maxInstrumentAttempts {
            do {
                let instruments = try await coordinator.fetchInstruments()
                if !instruments.isEmpty {
                    fetchedInstruments = instruments
                    break
                }
                instrumentLastError = "Server returned no instruments."
            } catch is CancellationError {
                return
            } catch {
                instrumentLastError = error.localizedDescription
            }
            instrumentAttempt += 1
            if instrumentAttempt <= Self.maxInstrumentAttempts {
                try? await Task.sleep(for: .seconds(2))
            }
        }
        if Task.isCancelled { return }
        if let instruments = fetchedInstruments {
            availableInstruments = instruments
            // Re-add currentInstrument if it's not in the server's list (e.g.
            // restored from saved state with an instrument the server doesn't
            // subscribe to for live data, but can still serve history for).
            if !availableInstruments.contains(currentInstrument) {
                availableInstruments.append(currentInstrument)
            }
        } else {
            loadingStatus = .exhausted(.serverUnreachable, lastError: instrumentLastError)
            return
        }

        // Load history first so the REST call isn't starved by WebSocket
        // callbacks competing for MainActor time. Also: WS must open AFTER
        // loadHistoryWithRetry so a stale REST snapshot can't overwrite a fresher
        // WS-pushed completed bar via timestamp-keyed merge.
        await loadHistoryWithRetry()
        // loadHistoryWithRetry returns on Task.isCancelled too — without this guard
        // a switchInstrument/switchPeriod that fires mid-retry would let this OLD
        // task spawn a wsTask using the NEW currentPeriod, racing the new reloadTask.
        if Task.isCancelled { return }
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

    /// Called from Settings when the rebucketing toggle flips; re-snapshots
    /// and reloads so the new source variant takes effect immediately.
    func applyRebucketingChange() {
        clientSideRebucketing = AppSettings.shared.clientSideRebucketing
        reloadChart()
    }

    /// Called from the exhausted-banner "Retry" button. Clears the exhausted
    /// status and re-enters the full reload pipeline (history + WS).
    func retryFromExhausted() {
        loadingStatus = nil
        error = nil
        hasStarted = false
        startAsync()
    }

    /// Called from the exhausted-banner "Force reconnect" button. Asks the
    /// server to drop and re-establish its Dukascopy session, then reloads.
    func forceReconnectAndRetry() {
        loadingStatus = .reconnectingServer()
        error = nil
        Task {
            do {
                try await coordinator.forceReconnect()
            } catch {
                self.error = "Force reconnect: \(error.localizedDescription)"
                loadingStatus = .exhausted(.serverUnreachable, lastError: error.localizedDescription)
                return
            }
            // Give the server a moment to flip back to CONNECTING after
            // forceReconnect() returns. The new connect cycle starts on a
            // 10s scheduled task on the server side.
            try? await Task.sleep(for: .seconds(2))
            hasStarted = false
            startAsync()
        }
    }

    func refreshCache() {
        guard !isRefreshingCache else { return }
        let instrument = currentInstrument
        isRefreshingCache = true
        loadingStatus = .refreshing()
        Task {
            defer { isRefreshingCache = false }
            do {
                _ = try await coordinator.clearServerCache(instrument: instrument)
            } catch {
                self.error = "Refresh cache: \(error.localizedDescription)"
                loadingStatus = nil
                return
            }
            guard instrument == currentInstrument else {
                loadingStatus = nil
                return
            }
            await coordinator.cache.clear(instrument: instrument)
            reloadChart()
        }
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

        let key = CandleCache.CacheKey.forDisplay(
            instrument: currentInstrument,
            period: currentPeriod,
            clientSideRebucketing: clientSideRebucketing
        )
        reloadTask = Task {
            let cached = await coordinator.cache.getBars(for: key)
            if !cached.isEmpty {
                bars = cached
                scrollToEnd()
            }
            await loadHistoryWithRetry()
            // See start(): guard against a cancelled-but-still-executing outer Task
            // racing the new reloadTask's WebSocket subscription.
            if Task.isCancelled { return }
            loadATR()
            connectWebSocket()
        }
    }

    /// Load history, retrying up to `maxHistoryAttempts` times. Surfaces an
    /// `.exhausted` status afterwards so the user can choose to retry or
    /// force-reconnect the server. Non-retryable errors (e.g. 4xx) break the
    /// loop on the first attempt — no point in retrying a bad request.
    private func loadHistoryWithRetry() async {
        let instrument = currentInstrument
        let period = currentPeriod
        let rebucketing = clientSideRebucketing

        // Cache paint is done by the caller (start / reloadChart). `bars.isEmpty` here
        // tells us whether we have a warm or cold cache — drives the loading-card detail.
        let coldCache = bars.isEmpty

        var attempt = 1
        var lastError: String?
        var serverHintMs: Int?
        var nonRetryable = false
        // Clear loadingStatus only on success; exhaustion overwrites it explicitly.
        while !Task.isCancelled, attempt <= Self.maxHistoryAttempts, !nonRetryable {
            guard instrument == currentInstrument, period == currentPeriod else { return }
            loadingStatus = .loadingHistory(
                attempt: attempt, period: period, rebucketing: rebucketing,
                coldCache: coldCache, lastError: lastError
            )
            do {
                let history = try await coordinator.fetchCandles(
                    instrument: instrument, period: period,
                    count: Self.barCount(for: period),
                    rebucketing: rebucketing
                )
                if Task.isCancelled { return }
                guard instrument == currentInstrument, period == currentPeriod else { return }
                if !history.isEmpty {
                    bars = history
                    error = nil
                    loadingStatus = nil
                    scrollToEnd()
                    return
                }
                lastError = "Server returned no bars."
                serverHintMs = nil
            } catch is CancellationError {
                return
            } catch let e {
                lastError = e.localizedDescription
                error = "History: \(e.localizedDescription)"
                if let api = e as? ForexAPIService.APIError {
                    serverHintMs = api.retryAfterMs
                    if !api.isRetryable { nonRetryable = true }
                } else {
                    serverHintMs = nil
                }
            }
            attempt += 1
            if attempt <= Self.maxHistoryAttempts && !nonRetryable {
                let backoffSeconds: Int
                if let hint = serverHintMs {
                    backoffSeconds = min(60, max(1, hint / 1_000))
                } else {
                    backoffSeconds = min(30, 3 * (1 << min(attempt - 1, 4)))
                }
                try? await Task.sleep(for: .seconds(backoffSeconds))
            }
        }
        if Task.isCancelled { return }
        if !bars.isEmpty {
            // Warm cache already painted — exhaustion shouldn't blank it. Surface
            // via the inline error string only.
            loadingStatus = nil
            return
        }
        loadingStatus = .exhausted(.historyUnavailable, lastError: lastError)
    }

    /// Load history once (used by reloadChart where the server/data is already known to be available).
    private func loadHistory() async {
        let instrument = currentInstrument
        let period = currentPeriod
        let rebucketing = clientSideRebucketing
        do {
            let history = try await coordinator.fetchCandles(
                instrument: instrument, period: period,
                count: Self.barCount(for: period),
                rebucketing: rebucketing
            )
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
        let rebucketing = clientSideRebucketing
        wsTask = Task {
            var attempt = 1
            var lastError: String?
            while !Task.isCancelled, attempt <= Self.maxWebSocketAttempts {
                do {
                    for try await bar in coordinator.streamCandles(
                        instrument: instrument, period: period, rebucketing: rebucketing
                    ) {
                        if !isConnected { isConnected = true }
                        // Reset retry budget once we've successfully received bars —
                        // future drops should get the full retry window again.
                        attempt = 1
                        lastError = nil
                        handleBar(bar, expectedInstrument: instrument, expectedPeriod: period)
                    }
                    // Stream ended cleanly without an error — treat as a transient
                    // disconnect and try to reconnect within the same retry budget.
                } catch is CancellationError {
                    break
                } catch {
                    isConnected = false
                    lastError = error.localizedDescription
                }
                attempt += 1
                if attempt <= Self.maxWebSocketAttempts {
                    let backoffSeconds = min(30, 3 * (1 << min(attempt - 1, 4)))
                    try? await Task.sleep(for: .seconds(backoffSeconds))
                }
            }
            isConnected = false
            if Task.isCancelled { return }
            // Exhausted: if we never got bars at all, surface the full-overlay
            // exhausted state. If bars are already loaded, keep the chart and
            // surface the failure via the inline `error` string per the user's
            // chosen UX so they don't lose visual context.
            if bars.isEmpty {
                loadingStatus = .exhausted(.liveFeedDisconnected, lastError: lastError)
            } else {
                let suffix = lastError.map { ": \($0)" } ?? ""
                error = "Live feed disconnected after \(Self.maxWebSocketAttempts) attempts. Click Retry or Force reconnect\(suffix)"
            }
        }
    }

    func handleBar(_ bar: CandleBar, expectedInstrument: String, expectedPeriod: String) {
        // Discard bars from a stale WebSocket that hasn't been cancelled yet
        guard expectedInstrument == currentInstrument, expectedPeriod == currentPeriod else { return }
        if bar.partial {
            // Drop a forming bar when no history is loaded yet — a chart showing a
            // single live candle and nothing else is misleading. The ChartLoadingCard
            // overlay is bound to bars.isEmpty, so accepting the partial here would
            // also dismiss the overlay prematurely.
            guard !bars.isEmpty else { return }
            // Update the last bar if it has the same timestamp, otherwise append
            if let lastIndex = bars.indices.last, bars[lastIndex].time == bar.time {
                bars[lastIndex] = bar
            } else if bar.time > bars[bars.count - 1].time {
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
            // For the aggregated derived path the coordinator already writes into the
            // `.aggregated` cache itself; the outer write would target the wrong key.
            let rebucketing = clientSideRebucketing
            let isDerivedAggregated = rebucketing && (currentPeriod == "FOUR_HOURS" || currentPeriod == "DAILY")
            if !isDerivedAggregated {
                Task { await coordinator.cacheBar(bar, instrument: currentInstrument, period: currentPeriod) }
            }
        }
        updateATRFromBar(bar)
    }

    func scrollToEnd() {
        let totalWidth = CGFloat(bars.count) * transform.candleSlotWidth
        transform.xOffset = max(0, totalWidth - chartWidth)

        // If bars don't fill the screen, fetch earlier bars automatically
        if totalWidth < chartWidth && !isLoadingEarlier && !bars.isEmpty {
            isLoadingEarlier = true
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
            // Flip the guard synchronously — otherwise the Task's `isLoadingEarlier = true`
            // doesn't run until the MainActor actually picks it up, and a burst of scroll
            // events queues many overlapping fetches that each compute `addedCount` off
            // the same stale `oldCount`, compounding the xOffset shift until the chart
            // slams back to the live edge.
            isLoadingEarlier = true
            Task { await loadEarlierBars() }
        }
    }

    /// Bar count scaled to the timeframe — avoids multi-year CDN downloads for larger periods.
    private static func barCount(for period: String) -> Int {
        switch period {
        case "WEEKLY":     return 150  // ~3 years
        case "DAILY":      return 250  // ~1 year of trading days
        case "FOUR_HOURS": return 500  // ~3 months
        case "ONE_HOUR":   return 500  // ~3 weeks
        default:           return 1000 // intraday
        }
    }

    /// Scroll-back batch size. Smaller than the initial load for larger timeframes
    /// because each page hits Dukascopy's CDN — and under rebucketing a DAILY page
    /// expands to count*24 1H bars.
    private static func earlierBarCount(for period: String) -> Int {
        switch period {
        case "WEEKLY":     return 100
        case "DAILY":      return 100
        default:           return barCount(for: period)
        }
    }

    private func loadEarlierBars() async {
        // Callers must flip `isLoadingEarlier = true` synchronously before scheduling
        // the Task so duplicate onUserScroll ticks don't enqueue overlapping fetches.
        defer { isLoadingEarlier = false }
        let instrument = currentInstrument
        let period = currentPeriod
        let rebucketing = clientSideRebucketing
        let oldCount = bars.count
        let maxAttempts = 3

        var attempt = 1
        var lastError: String?
        defer { loadingStatus = nil }
        while attempt <= maxAttempts {
            guard instrument == currentInstrument, period == currentPeriod else { return }
            loadingStatus = LoadingStatus(
                stage: .loadingEarlier,
                message: attempt == 1 ? "Loading earlier history…" : "Retrying (attempt \(attempt) of \(maxAttempts))…",
                detail: nil,
                lastError: lastError
            )
            do {
                let allBars = try await coordinator.fetchEarlierCandles(
                    instrument: instrument, period: period,
                    count: Self.earlierBarCount(for: period),
                    rebucketing: rebucketing
                )
                guard instrument == currentInstrument, period == currentPeriod else { return }
                let addedCount = allBars.count - oldCount
                if addedCount > 0 {
                    bars = allBars
                    transform.xOffset += CGFloat(addedCount) * transform.candleSlotWidth
                }
                return
            } catch is CancellationError {
                return
            } catch let e {
                lastError = e.localizedDescription
            }
            attempt += 1
            if attempt <= maxAttempts {
                try? await Task.sleep(for: .seconds(2))
            }
        }
        if let lastError {
            self.error = "Earlier bars: \(lastError)"
        }
    }
}
