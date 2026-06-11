import Foundation
import os.log
import SwiftUI

private let chartLogger = Logger(subsystem: "com.swifttrader", category: "chart")

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
    /// Which side of the market the candles are built from. Switching reloads the chart from the
    /// matching cache/feed (see `switchSide`).
    var currentSide: ChartSide = .bid {
        didSet { onStateChanged?() }
    }
    /// Show both the live bid and ask as moving price lines (the candle-side line + the opposite side).
    var showBidAsk = false {
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
    /// True while a warm-but-stale cache painted at launch is being caught up — the newest
    /// painted bar ends well before the last session close, so recently-closed bars are
    /// missing and a forward-fill / history fetch is in flight. Drives the header
    /// "Updating…" badge and suppresses the live forming bar (see `handleBar`) so we don't
    /// jam a fresh candle against the stale tail across the unfilled gap. Cleared when the
    /// history fetch returns (the full, current series replaces the stale bars).
    var isBackfilling = false

    /// User-drawn lines/arrows anchored in (time, price). Persisted with the tab.
    var drawings: [Drawing] = [] {
        didSet { onStateChanged?() }
    }
    /// Active drawing tool while in drawing mode (nil = normal pan/select).
    /// Ephemeral; not persisted.
    var drawingTool: DrawingKind?
    /// ID of the currently selected drawing, for highlight + Delete key.
    /// Ephemeral; not persisted.
    var selectedDrawingID: UUID?

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
        ("THREE_MINS", "3m"),
        ("FIVE_MINS", "5m"),
        ("FIFTEEN_MINS", "15m"),
        ("ONE_HOUR", "1h"),
        ("FOUR_HOURS", "4h"),
        ("DAILY", "D"),
        ("WEEKLY", "W"),
    ]

    /// Latest measured cell width in points, reported by `ChartView` once it's laid out
    /// (`0` before first layout). Used only for the short-chart earlier-history check and
    /// `onUserScroll`'s at-edge detection — NOT for positioning: the view owns the live-edge
    /// snap (it always has the correct width at render). Resizing while autoscrolling
    /// re-requests a snap so the margin tracks the new width.
    var chartWidth: CGFloat = 0 {
        didSet {
            guard chartWidth != oldValue, chartWidth > 0 else { return }
            // Following the edge → re-snap so the margin tracks the new width; parked → re-center the
            // anchored time so a width change (e.g. opening the order box) doesn't shift the view.
            repositionViewport()
        }
    }

    private var coordinator: any MarketDataProviding
    private var startTask: Task<Void, Never>?
    private var wsTask: Task<Void, Never>?
    private var liveWatchdogTask: Task<Void, Never>?
    private var gapHealTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?
    /// Set when a live stream drops with bars already on screen; the next bar after we
    /// re-subscribe triggers a closed-bar reconcile so a bucket frozen mid-formation at the
    /// instant of the drop (e.g. an MTF cell stuck on a 2-minute-old 15m bar) is healed
    /// immediately — not only if this chart happens to witness the next bucket rollover.
    private var resyncClosedBarsOnResume = false
    private var atrTask: Task<Void, Never>?
    private var todayTradingDayStart: Date?
    private var todayHigh: Double?
    private var todayLow: Double?
    private var hasStarted = false
    private var isLoadingEarlier = false

    init(coordinator: any MarketDataProviding) {
        self.coordinator = coordinator
    }

    /// Test helper to seed today's ATR tracking state.
    func setTodayATRRange(dayStart: Date, high: Double, low: Double) {
        todayTradingDayStart = dayStart
        todayHigh = high
        todayLow = low
    }

    /// Adopt a fresh coordinator (port change). The workspace builds one new
    /// coordinator and broadcasts it so every tab swaps atomically.
    func reconnect(coordinator: any MarketDataProviding) {
        // Keep the zoom across a connection blip; the position is restored from the persistent
        // viewport anchor (and autoScroll) once start() repaints — see repositionViewport.
        let keptScale = transform.xScale
        stop()
        self.coordinator = coordinator
        hasStarted = false
        bars = []
        transform = ChartTransform()
        transform.xScale = keptScale
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
            clientSideRebucketing: clientSideRebucketing, side: currentSide
        )
        let cached = await coordinator.cache.getBars(for: displayKey)
        if !cached.isEmpty {
            bars = cached
            repositionViewport()
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

        // Open the live tick feed FIRST. connectWebSocket() only launches a background
        // task (non-blocking), so the chart goes live on the warm-painted cached bars within
        // ~1s instead of waiting out the history load — which can lag tens of seconds while
        // the launch fetch storm saturates the history slots, leaving the chart looking dead
        // and stuck on "Market Closed". Safe ordering: handleBar drops live bars while `bars`
        // is empty (cold cache, so nothing to stale-overwrite), and loadHistoryWithRetry
        // guards on currentInstrument/period so an in-flight switch can't paint stale data.
        connectWebSocket()
        await loadHistoryWithRetry()
        if Task.isCancelled { return }
        loadATR()
    }

    func switchInstrument(_ instrument: String) {
        guard instrument != currentInstrument else { return }
        // Drawings are anchored in (time, price). A different instrument's price scale
        // makes those anchors meaningless, so we drop them rather than render them
        // in nonsensical positions.
        drawings = []
        selectedDrawingID = nil
        drawingTool = nil
        currentInstrument = instrument
        // A different instrument opens at the live edge (the old time anchor is meaningless here).
        viewportAnchorTimeMs = nil
        autoScroll = true
        reloadChart()
    }

    /// The bar-time to keep horizontally centered while the user is scrolled back (NOT following the
    /// live edge). Set whenever the user pans/zooms away from the edge (`onUserScroll`) and persists
    /// across reloads, reconnects, reconcile swaps and timeframe switches — so none of those paths
    /// yank a parked chart to the live edge. `nil` ⇒ follow the live edge. The companion flag is
    /// `autoScroll` (true ⇒ following). The two are kept in lock-step by `onUserScroll`.
    var viewportAnchorTimeMs: Int64?

    /// "Is the chart pinned at the live-edge resting position?" — i.e. genuinely following live ticks,
    /// not merely showing the newest bar. Tested as `xOffset ≈ liveEdgeOffset` (within 2 slots), in
    /// BOTH directions: scrolling back into history OR pulling the newest bar inward to leave empty
    /// "future" room on the right both count as parked, so neither gets yanked to the edge on a
    /// reload/reconnect/timeframe switch. Empty/unmeasured ⇒ following (the default).
    var isViewAtLiveEdge: Bool {
        guard chartWidth > 0, !bars.isEmpty else { return true }
        let liveEdge = ChartView.liveEdgeOffset(
            barCount: bars.count, slotWidth: transform.candleSlotWidth, chartWidth: chartWidth)
        return abs(transform.xOffset - liveEdge) <= transform.candleSlotWidth * 2
    }

    /// The bar-time at the horizontal center of the viewport, or nil if we can't map it yet.
    private func currentViewportCenterTimeMs() -> Int64? {
        guard chartWidth > 0, !bars.isEmpty else { return nil }
        return DrawingMath.timeMsForX(chartWidth / 2,
                                      barTimes: bars.map(\.time),
                                      xOffset: transform.xOffset,
                                      slotWidth: transform.candleSlotWidth)
    }

    /// Re-anchor the viewport so `ms` sits at the horizontal center (clamped). Pure offset math.
    private func setViewportCenter(toTimeMs ms: Int64) {
        guard chartWidth > 0, !bars.isEmpty else { return }
        transform.xOffset = DrawingMath.xOffsetCenteringTime(
            ms, barTimes: bars.map(\.time),
            slotWidth: transform.candleSlotWidth, chartWidth: chartWidth)
    }

    /// THE single entry point that positions the chart horizontally after ANY bars mutation —
    /// initial load, reload, reconnect, history backfill, reconcile swap, width change. Following the
    /// live edge ⇒ snap to it; scrolled back ⇒ re-pin the anchored center time so nothing drifts to
    /// the edge. Because the anchor is an absolute TIME (not a pixel offset or index), it survives
    /// timeframe switches and fixed-window swaps. Setting `hasAutoScrolledToEnd` suppresses the
    /// view's one-shot live-edge snap while parked so it doesn't fight the restored center.
    func repositionViewport() {
        let willCenter = viewportAnchorTimeMs != nil && !autoScroll && chartWidth > 0 && !bars.isEmpty
        if willCenter, let ms = viewportAnchorTimeMs {
            setViewportCenter(toTimeMs: ms)
            transform.hasAutoScrolledToEnd = true
        } else {
            scrollToEnd()
        }
    }

    func switchPeriod(_ period: String) {
        guard period != currentPeriod else { return }
        // The viewport anchor (an absolute time) and `autoScroll` persist across the reload, so the
        // new timeframe re-centers on the same moment (or stays at the live edge). Keep the zoom too.
        currentPeriod = period
        reloadChart(keepZoom: true)
    }

    /// Switch the candle side (bid/ask) and reload from the matching cache/feed, mirroring
    /// `switchPeriod` — the time anchor + zoom carry over.
    func switchSide(_ side: ChartSide) {
        guard side != currentSide else { return }
        currentSide = side
        reloadChart(keepZoom: true)
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

    /// Lightweight refresh: drop the in-memory client cache for this instrument
    /// and re-issue a normal history fetch through the coordinator. The server
    /// usually already has the bars in its own cache, so this completes in
    /// milliseconds.
    ///
    /// Does **not** call `DELETE /api/v1/history/cache`. Deleting the server-side
    /// Dukascopy `.bi5` cache forces a CDN re-download that empirically takes
    /// 2–3 minutes on a thin-cross 15m timeframe — and during that window
    /// `HistoryController` returns 503s, exhausting the client's retry budget
    /// and wedging the chart for the user. Use {@link hardRefresh} when a
    /// server-cache wipe is actually warranted.
    func refreshCache() {
        guard !isRefreshingCache else { return }
        let instrument = currentInstrument
        isRefreshingCache = true
        loadingStatus = .refreshing()
        Task {
            defer { isRefreshingCache = false }
            await coordinator.cache.clear(instrument: instrument)
            guard instrument == currentInstrument else {
                loadingStatus = nil
                return
            }
            reloadChart()
        }
    }

    /// Like `refreshCache`, but also force-reconnects the JForex session so
    /// any in-memory bars that JForex has already cached get re-fetched from
    /// Dukascopy. Heavier than `refreshCache` (5–30s outage hitting all
    /// charts), so it's a separate explicit user action.
    func hardRefresh() {
        guard !isRefreshingCache else { return }
        let instrument = currentInstrument
        isRefreshingCache = true
        loadingStatus = .reconnectingServer()
        Task {
            defer { isRefreshingCache = false }
            do {
                _ = try await coordinator.clearServerCache(instrument: instrument)
            } catch {
                self.error = "Hard refresh: \(error.localizedDescription)"
                loadingStatus = nil
                return
            }
            guard instrument == currentInstrument else {
                loadingStatus = nil
                return
            }
            await coordinator.cache.clear(instrument: instrument)
            do {
                try await coordinator.forceReconnect()
            } catch {
                self.error = "Hard refresh: force reconnect failed: \(error.localizedDescription)"
                loadingStatus = nil
                return
            }
            // Server mode: wait past the JForex restart cycle (~10s scheduleReconnect
            // delay + LIVE handshake + strategy init) so the chart's first history
            // request hits a ready strategy instead of cycling through 503s.
            // Native mode: no reconnect, so this resolves to zero — see
            // `MarketDataProviding.hardRefreshGraceSeconds`.
            let grace = coordinator.hardRefreshGraceSeconds
            if grace > 0 { try? await Task.sleep(for: .seconds(grace)) }
            reloadChart()
        }
    }

    private func reloadChart(keepZoom: Bool = false) {
        startTask?.cancel()
        reloadTask?.cancel()
        wsTask?.cancel()
        liveWatchdogTask?.cancel()
        gapHealTask?.cancel()
        atrTask?.cancel()
        isLoadingEarlier = false

        // Reset synchronously so the Canvas never sees a stale xOffset
        // paired with fewer bars from the new instrument/period.
        let keptScale = transform.xScale
        bars = []
        transform = ChartTransform()
        // Keep the pre-switch zoom across a timeframe switch; the position is restored from the
        // persistent viewport anchor once bars paint (see repositionViewport).
        if keepZoom { transform.xScale = keptScale }
        error = nil

        let key = CandleCache.CacheKey.forDisplay(
            instrument: currentInstrument,
            period: currentPeriod,
            clientSideRebucketing: clientSideRebucketing, side: currentSide
        )
        let logInstrument = currentInstrument
        let logPeriod = currentPeriod
        let rebucketingFlag = clientSideRebucketing
        let side = currentSide
        chartLogger.info("reloadChart \(logInstrument, privacy: .public) \(logPeriod, privacy: .public) rebucketing=\(rebucketingFlag)")
        reloadTask = Task {
            let cacheT0 = Date()
            let cached = await coordinator.cache.getBars(for: key)
            if !cached.isEmpty, Self.intraSessionGapIndex(in: cached, period: logPeriod) == nil {
                bars = cached
                repositionViewport()
                chartLogger.info("reloadChart \(logInstrument, privacy: .public) \(logPeriod, privacy: .public) painted \(cached.count) cached bars in \(Int(Date().timeIntervalSince(cacheT0) * 1000))ms")
            } else if !cached.isEmpty {
                // The display cache transiently holds an intra-session hole (e.g. the aggregated
                // cache rebuilt while the 1m source was briefly gappy). Painting it flashes a gap
                // until the history fetch below rebuilds and heals it. Skip the stale paint and let
                // loadHistoryWithRetry paint the healed, contiguous series instead — the loading
                // card shows for that brief window rather than a broken chart.
                chartLogger.warning("reloadChart \(logInstrument, privacy: .public) \(logPeriod, privacy: .public): cached series has an intra-session hole — deferring paint to the healed history fetch")
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
        let side = currentSide
        let t0 = Date()

        // Cache paint is done by the caller (start / reloadChart). `bars.isEmpty` here
        // tells us whether we have a warm or cold cache — drives the loading-card detail.
        let coldCache = bars.isEmpty

        // A warm cache that ends well before the last session close means we painted stale
        // bars and are about to backfill the missing ones. Flag it (synchronously, before
        // the first await — so the live feed that opened in parallel can't append a forming
        // bar across the gap before the flag is set) and clear it however we leave here.
        isBackfilling = !coldCache && Self.cacheIsBehind(bars: bars, period: period)
        defer { isBackfilling = false }

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
                    rebucketing: rebucketing, side: side
                )
                if Task.isCancelled { return }
                guard instrument == currentInstrument, period == currentPeriod else { return }
                if !history.isEmpty {
                    bars = history
                    error = nil
                    loadingStatus = nil
                    repositionViewport()
                    chartLogger.info("loadHistoryWithRetry \(instrument, privacy: .public) \(period, privacy: .public) painted \(history.count) bars in \(Int(Date().timeIntervalSince(t0) * 1000))ms (attempt \(attempt), coldCache=\(coldCache))")
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
            chartLogger.info("loadHistoryWithRetry \(instrument, privacy: .public) \(period, privacy: .public) exhausted after \(Int(Date().timeIntervalSince(t0) * 1000))ms — staying on cached bars (lastError=\(lastError ?? "nil", privacy: .public))")
            return
        }
        chartLogger.error("loadHistoryWithRetry \(instrument, privacy: .public) \(period, privacy: .public) exhausted after \(Int(Date().timeIntervalSince(t0) * 1000))ms (lastError=\(lastError ?? "nil", privacy: .public))")
        loadingStatus = .exhausted(.historyUnavailable, lastError: lastError)
    }

    /// Load history once (used by reloadChart where the server/data is already known to be available).
    private func loadHistory() async {
        let instrument = currentInstrument
        let period = currentPeriod
        let rebucketing = clientSideRebucketing
        let side = currentSide
        do {
            let history = try await coordinator.fetchCandles(
                instrument: instrument, period: period,
                count: Self.barCount(for: period),
                rebucketing: rebucketing, side: side
            )
            guard instrument == currentInstrument, period == currentPeriod else { return }
            bars = history
            error = nil
            repositionViewport()
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
                let fetched = try await coordinator.fetchCandles(
                    instrument: instrument, period: "ONE_HOUR", count: count
                )
                guard !Task.isCancelled, instrument == currentInstrument else { return }
                // The cache can hold years of deep 1H history (the background prefetcher warms
                // it), but ATR only needs the recent window. Slice to the newest `count` bars
                // so the per-bar Calendar math in TradingDayATR stays cheap regardless of how
                // deep the cache is — otherwise every chart re-scans ~12k bars on each load.
                let hourlyBars = fetched.count > count ? Array(fetched.suffix(count)) : fetched
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
        startLiveWatchdog()
        startGapHeal()
        let instrument = currentInstrument
        let period = currentPeriod
        let rebucketing = clientSideRebucketing
        let side = currentSide
        wsTask = Task {
            var attempt = 1
            var lastError: String?
            while !Task.isCancelled, attempt <= Self.maxWebSocketAttempts {
                do {
                    for try await bar in coordinator.streamCandles(
                        instrument: instrument, period: period, rebucketing: rebucketing, side: side
                    ) {
                        // Reset retry budget once we've successfully received bars —
                        // future drops should get the full retry window again.
                        attempt = 1
                        lastError = nil
                        handleBar(bar, expectedInstrument: instrument, expectedPeriod: period)
                        // Only flag "Live" once there's a drawable chart. A live tick with no
                        // history is meaningless — handleBar drops it until history paints — so
                        // opening the feed early (parallel with the history load) never shows a
                        // live-but-empty chart; the badge stays "Connecting…" until bars exist.
                        if !isConnected && !bars.isEmpty { isConnected = true }
                        // First bar after re-subscribing post-drop: heal any closed bar that froze
                        // at a mid-bucket partial when the stream died. Reconcile is period-agnostic
                        // (swaps closed bars for the authoritative aggregation, keeps the live one),
                        // so this re-converges every chart on the cache, not just ones that witness
                        // the next rollover.
                        if resyncClosedBarsOnResume {
                            resyncClosedBarsOnResume = false
                            scheduleAggregatedReconcile()
                        }
                    }
                    // Stream ended cleanly without an error — treat as a transient
                    // disconnect and try to reconnect within the same retry budget.
                } catch is CancellationError {
                    break
                } catch {
                    isConnected = false
                    lastError = error.localizedDescription
                }
                // Stream ended (clean drop or error) with a chart already on screen: mark that the
                // closed-bar window needs a reconcile once we re-subscribe, so a bar frozen at the
                // instant of the drop doesn't linger until the next witnessed rollover.
                if !bars.isEmpty { resyncClosedBarsOnResume = true }
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

    /// Recover from a chart that has history but no live ticks — the symptom of a quote
    /// subscription that didn't take. If the market is open and we still aren't `Live`
    /// after the interval, nudge the provider to re-assert its subscriptions (a no-op in
    /// server mode; native re-sends the quote set). Cheap and self-disarming: it only acts
    /// while `!isConnected`, and the session debounces concurrent nudges from every chart.
    private func startLiveWatchdog() {
        liveWatchdogTask?.cancel()
        let instrument = currentInstrument
        liveWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(12))
                guard let self, !Task.isCancelled else { return }
                let now = Date()
                let marketOpen = !NYTradingCalendar.isMarketClosed(at: now)
                    && !NYTradingCalendar.isFXHoliday(at: now)
                guard marketOpen, !self.isConnected, !self.bars.isEmpty,
                      self.currentInstrument == instrument else { continue }
                chartLogger.warning("live watchdog: \(instrument, privacy: .public) has bars but no ticks — nudging resubscribe")
                await self.coordinator.resubscribeLiveData()
            }
        }
    }

    /// First intra-session hole in the live `bars` (cheap, in-memory), or `nil` when contiguous.
    func firstIntraSessionGapIndex() -> Int? {
        Self.intraSessionGapIndex(in: bars, period: currentPeriod)
    }

    /// On-demand dump of this chart's exact state when the user sees a (suspected) gap, so we can
    /// tell a DATA hole (missing/degenerate bars) from a RENDER/layout artifact (bars contiguous
    /// but drawn with a band). Triggered by Cmd+Shift+G. Read back with:
    ///   log show --predicate 'subsystem == "com.swifttrader"' --last 5m | grep GAP-DIAG
    func captureGapDiagnostic() {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; f.timeZone = .current
        func ts(_ ms: Int64) -> String { f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)) }
        func emit(_ s: String) { chartLogger.notice("\(s, privacy: .public)") }

        let slot = transform.candleSlotWidth
        // Mirror ChartView.visibleBarRange so the dump covers exactly what's on screen.
        let canMeasure = !bars.isEmpty && chartWidth > 0 && slot > 0
        let start = canMeasure ? max(0, Int((transform.xOffset / slot).rounded(.down))) : 0
        let end = canMeasure ? min(bars.count, Int(((transform.xOffset + chartWidth) / slot).rounded(.up)) + 1) : 0

        emit(String(format: "GAP-DIAG %@ %@: bars=%d visible=%d..<%d xOffset=%.0f xScale=%.2f slot=%.1f chartW=%.0f snappedEnd=%@",
                    currentInstrument, currentPeriod, bars.count, start, end,
                    transform.xOffset, transform.xScale, slot, chartWidth,
                    transform.hasAutoScrolledToEnd ? "Y" : "N"))

        // Whole-series continuity (uniform-grid periods): is there an actual time-hole in `bars`?
        if let step = Self.fixedGridStepMs(for: currentPeriod), bars.count > 1 {
            var gaps: [String] = []
            for i in 1..<bars.count {
                let d = bars[i].time - bars[i - 1].time
                if d != step { gaps.append("idx\(i-1)->\(i) \(ts(bars[i-1].time))->\(ts(bars[i].time)) \(d/1000)s(\(d/step)x)") }
            }
            emit(gaps.isEmpty
                 ? "GAP-DIAG \(currentInstrument) \(currentPeriod): bars CONTIGUOUS — no data hole (gap is render/layout)"
                 : "GAP-DIAG \(currentInstrument) \(currentPeriod): \(gaps.count) time-gap(s): " + gaps.suffix(8).joined(separator: " | "))
        } else {
            emit("GAP-DIAG \(currentInstrument) \(currentPeriod): session-aligned/raw period — step-continuity scan skipped")
        }

        // Dump the LIVE-EDGE tail (last ~25 on-screen bars) — where a just-closed derived bar can
        // render thin/incomplete — not the head. Flags degenerate OHLC, partials, and a suspiciously
        // small body (range < 1/4 of the neighbours' median) that hints at an unfilled just-closed bar.
        let lo = max(start, end - 25)
        if lo < end {
            for i in lo..<end {
                let b = bars[i]
                let bad = (b.open <= 0 || b.high <= 0 || b.low <= 0 || b.close <= 0) ? " ZERO" : ""
                emit(String(format: "GAP-DIAG bar[%d] %@ O%.5f H%.5f L%.5f C%.5f range=%.1fpip V%.0f %@%@",
                            i, ts(b.time), b.open, b.high, b.low, b.close,
                            (b.high - b.low) * PnLConverter.pipFactor(for: currentInstrument),
                            b.volume, b.partial ? "P" : "-", bad))
            }
        }
    }

    /// Safety net for chart-series gaps. A hole can creep into the in-memory `bars` through more
    /// than one live path — a late subscriber replaying a forming bar that's already ahead of its
    /// loaded tail, a brief stream skip between buckets — and the on-disk cache is the continuous
    /// source of truth. Rather than chase every path, periodically detect a hole cheaply and
    /// reconcile (which re-fetches the authoritative series and splices it in). This bounds any
    /// visible gap to one tick instead of "until the user reloads / churns timeframes". A fetch
    /// only happens when a hole actually exists, so the idle cost is a tiny in-memory scan.
    private func startGapHeal() {
        gapHealTask?.cancel()
        let instrument = currentInstrument
        gapHealTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, self.currentInstrument == instrument else { return }
                guard self.firstIntraSessionGapIndex() != nil else { continue }
                chartLogger.warning("gap-heal \(instrument, privacy: .public) \(self.currentPeriod, privacy: .public): intra-session hole in series — reconciling from cache")
                self.scheduleAggregatedReconcile()
            }
        }
    }

    /// True when the current period is built client-side by bundling smaller bars (3m always;
    /// 5m/15m/30m/4H/Daily/Weekly when rebucketing is on). For these the live "forming" bar is
    /// assembled per-instance and is NOT written to the shared cache, so a just-closed bucket can
    /// freeze with an incomplete OHLC/volume until reconciled against the authoritative bundle.
    var isDerivedAggregatedPeriod: Bool {
        currentPeriod == "THREE_MINS"
            || (clientSideRebucketing && (currentPeriod == "FOUR_HOURS" || currentPeriod == "DAILY"
                || currentPeriod == "WEEKLY" || currentPeriod == "FIVE_MINS"
                || currentPeriod == "FIFTEEN_MINS" || currentPeriod == "THIRTY_MINS"))
    }

    /// Nominal bucket span (ms) for the uniform-grid periods. `nil` for the session-aligned
    /// periods (4H/Daily/Weekly) where gaps across weekends/holidays are legitimate and a fixed
    /// step doesn't apply — there a "missing" bucket isn't a defect, so we never suppress it.
    private static func fixedGridStepMs(for period: String) -> Int64? {
        switch period {
        case "ONE_MIN": return 60_000
        case "THREE_MINS": return 180_000
        case "FIVE_MINS": return 300_000
        case "FIFTEEN_MINS": return 900_000
        case "THIRTY_MINS": return 1_800_000
        case "ONE_HOUR": return 3_600_000
        default: return nil
        }
    }
    private var fixedGridStepMs: Int64? { Self.fixedGridStepMs(for: currentPeriod) }

    /// Largest hole (ms) we treat as an intra-session drift to heal rather than accept. Anything
    /// bigger is a weekend/holiday close — a legitimate non-contiguous reopen. 6h clears the
    /// longest real gap (a stall) while staying well under a weekend.
    private static let maxHealableGapMs: Int64 = 6 * 60 * 60 * 1000

    /// Index of the first intra-session hole in `series` for `period` — a non-contiguous step on
    /// the uniform grid too small to be a weekend/holiday — or `nil` when contiguous. Static so the
    /// live series and the load path (vetting a cached series before painting it) share one rule.
    /// `nil` for session-aligned periods (4H/Daily/Weekly), where a missing bucket is legitimate.
    static func intraSessionGapIndex(in series: [CandleBar], period: String) -> Int? {
        guard let step = fixedGridStepMs(for: period), series.count > 1 else { return nil }
        for i in 1..<series.count {
            let d = series[i].time - series[i - 1].time
            if d > step && d <= maxHealableGapMs { return i }
        }
        return nil
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
            } else if let last = bars.last, bar.time > last.time {
                // While catching up a stale launch cache, don't append a forming bar beyond
                // the tail — the bars between the stale tail and this bucket haven't been
                // filled yet, so it would render as a candle jammed against a gap. The
                // in-flight history fetch will paint the full series (this bucket included).
                guard !isBackfilling else { return }
                // Same artifact, different cause: a late subscriber (e.g. an MTF cell) loads
                // history up to its tail, then the shared multicaster replays the live forming
                // bar — which can already be several buckets ahead. Appending it paints a lone
                // candle floating past an empty gap ("missing data"). For the uniform grid,
                // suppress that paint when the hole is small (an intra-session drift, NOT a
                // weekend) and reconcile to splice the real bars from the continuous cache. The
                // next contiguous tick then appends normally. Big (weekend/holiday) holes fall
                // through and append — a legitimate non-contiguous reopen.
                if let step = fixedGridStepMs,
                   bar.time - last.time > step,
                   bar.time - last.time <= Self.maxHealableGapMs {
                    chartLogger.warning("gap-suppress \(self.currentInstrument, privacy: .public) \(self.currentPeriod, privacy: .public): forming bar \((bar.time - last.time) / step) buckets past tail — reconciling instead of painting a floating candle")
                    scheduleAggregatedReconcile()
                    return
                }
                bars.append(bar)
                if autoScroll { advanceByOneCandle() }
                // A derived bucket just rolled over: the bar that was forming is now frozen and
                // may hold an incomplete client-side bundle. Reconcile the recent window against
                // the authoritative aggregation so the just-closed bar gets its real OHLC/volume.
                if isDerivedAggregatedPeriod { scheduleAggregatedReconcile() }
            }
        } else {
            // Mirror the partial-branch guard: don't paint a lone completed bar
            // on an empty chart (rule 3). History either failed (the exhausted
            // banner is up) or is still loading — either way a single candle in
            // isolation is misleading. Skipping the cacheBar call too is fine:
            // the next successful history fetch will return this bar and merge
            // it into the cache anyway.
            guard !bars.isEmpty else { return }
            if let lastIndex = bars.indices.last, bars[lastIndex].time == bar.time {
                bars[lastIndex] = bar
            } else {
                // Same gap guard as the partial branch: don't paint a completed bar beyond
                // the stale tail mid-backfill. Skipping the cacheBar write below is fine —
                // the history fetch returns and merges this bar anyway.
                guard !isBackfilling else { return }
                bars.append(bar)
                if autoScroll { advanceByOneCandle() }
            }
            // For the aggregated derived path the coordinator already writes into the
            // `.aggregated` cache itself; the outer write would target the wrong key.
            // The cache key must be the GUARD-time identity, not re-read inside the Task:
            // an instrument/period switch between this synchronous code and the Task body
            // running would file this bar under the new chart's key — poisoning another
            // pair's disk cache with a wildly-off-price bar that survives restarts.
            if !isDerivedAggregatedPeriod {
                let side = currentSide
                Task {
                    await coordinator.cacheBar(bar, instrument: expectedInstrument,
                                               period: expectedPeriod, rebucketing: false, side: side)
                }
            }
        }
        updateATRFromBar(bar)
    }

    /// Re-fetch the derived series and swap our recent CLOSED bars for the authoritative
    /// re-bundled ones, while keeping the live forming bar. Triggered when a derived bucket
    /// rolls over, so the just-closed bar's client-side bundle (possibly incomplete — see
    /// `isDerivedAggregatedPeriod`) is corrected promptly instead of only on the next full
    /// reload. The fetch is coalesced across charts, and we never touch `transform`, so scroll
    /// position and the one-time live-edge snap are preserved.
    private func scheduleAggregatedReconcile() {
        reconcileTask?.cancel()
        let instrument = currentInstrument
        let period = currentPeriod
        let rebucketing = clientSideRebucketing
        let side = currentSide
        reconcileTask = Task {
            guard let authoritative = try? await coordinator.fetchCandles(
                instrument: instrument, period: period,
                count: Self.barCount(for: period), rebucketing: rebucketing, side: side
            ) else { return }
            guard !Task.isCancelled,
                  instrument == currentInstrument, period == currentPeriod,
                  !authoritative.isEmpty else { return }
            let livePartial = (bars.last?.partial == true) ? bars.last : nil
            let corrected = Self.reconciledBars(authoritative: authoritative, current: bars, liveForming: livePartial)
            guard corrected != bars else { return }
            // A reconcile REPLACES the series with a fresh fixed-count window ending at now, so its
            // FRONT advances as time passes. `xOffset` is a pixel offset measured in bars, so without
            // re-anchoring a scrolled-back view silently drifts toward the live edge every reconcile
            // (and a count change opens a right-margin gap at the live edge). repositionViewport
            // re-pins the anchored center time (or snaps to the live edge when following).
            bars = corrected
            repositionViewport()
        }
    }

    /// Merge the authoritative re-aggregation with our own live forming bar. The authoritative
    /// CLOSED bars correct any just-frozen bucket, but the live forming bar — shared across every
    /// chart via `LiveCandleMulticaster`, so it holds the complete in-progress bucket — must always
    /// win for its own bucket. The re-aggregation can otherwise emit the in-progress bucket as a
    /// mis-flagged, incomplete CLOSED bar (the rebuild path bundles only the 1m bars already on
    /// disk, missing the latest minutes that live only in the tick stream); keeping it would
    /// overwrite the good live bar and render as a thin "missing-data" candle that differs between
    /// two charts of the same instrument/period. So drop any authoritative bar at or after the
    /// forming bucket and re-append the live bar.
    static func reconciledBars(authoritative: [CandleBar], current: [CandleBar], liveForming: CandleBar?) -> [CandleBar] {
        // Non-shrinking merge. The authoritative re-aggregation can LAG at a bucket rollover — its 1m
        // source hasn't flushed the just-closed bucket's last minutes yet — so blindly swapping a
        // just-closed bar for the authoritative one DOWNGRADES it (a thin bar that loses the low/close
        // the live aggregation already captured, then "heals" only on a later reload). Instead, merge:
        // take the WIDER high/low of (current, authoritative), and keep the live open/close when the
        // live bar already spans the authoritative range (its OHLC is the complete one); otherwise
        // trust authoritative (the live bar opened mid-bucket and is the incomplete one).
        var curByTime: [Int64: CandleBar] = [:]
        for b in current { curByTime[b.time] = b }
        var corrected = authoritative.filter { !$0.partial }.map { auth -> CandleBar in
            guard let cur = curByTime[auth.time] else { return auth }
            let liveSpansAuth = cur.low <= auth.low && cur.high >= auth.high
            return CandleBar(
                time: auth.time,
                open: liveSpansAuth ? cur.open : auth.open,
                high: max(auth.high, cur.high),
                low: min(auth.low, cur.low),
                close: liveSpansAuth ? cur.close : auth.close,
                volume: max(auth.volume, cur.volume),
                partial: false)
        }
        // Only keep the live forming bar if it's actually CURRENT — its time is at/after the newest
        // authoritative closed bar. A STALE last bar (the chart's live feed stalled, then authoritative
        // backfilled newer bars on recovery) must NOT pin the series to the past: drop it and adopt the
        // fresher authoritative series, so a stalled chart catches up on its own without a manual reload
        // / timeframe switch (the next live tick then appends the real forming bar contiguously).
        if let live = liveForming, live.partial, live.time >= (corrected.last?.time ?? .min) {
            corrected.removeAll { $0.time >= live.time }
            corrected.append(live)
        }
        return corrected
    }

    /// Request the chart to (re)position at the live edge. The actual snap is performed by
    /// `ChartView`, which alone has the reliably-correct cell width — it fires once per loaded
    /// dataset (gated by `transform.hasAutoScrolledToEnd`) and never fights a manual scroll or
    /// a tab switch. Here we just clear that one-shot guard and, if we already know the width,
    /// pull older bars when the chart is too short to fill the viewport.
    func scrollToEnd() {
        transform.hasAutoScrolledToEnd = false
        if chartWidth > 0 {
            let totalWidth = CGFloat(bars.count) * transform.candleSlotWidth
            if totalWidth < chartWidth && !isLoadingEarlier && !bars.isEmpty {
                isLoadingEarlier = true
                Task { await loadEarlierBars() }
            }
        }
    }

    /// Jump back to the live edge and resume following it (the chart's "scroll to live edge" button).
    /// Clears any parked anchor, re-enables autoscroll, and reuses `scrollToEnd()`: that resets the
    /// view's one-shot snap guard, so `ChartView` re-snaps to the live edge using its own reliably-
    /// correct geometry width (the same path a fresh load takes). Works identically for the main chart
    /// and grid cells. Setting `autoScroll` / `viewportAnchorTimeMs` in lock-step (as `onUserScroll`
    /// does) keeps the chart following live afterwards instead of re-parking on the next reconcile.
    func jumpToLiveEdge() {
        autoScroll = true
        viewportAnchorTimeMs = nil
        scrollToEnd()
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
        reconcileTask?.cancel()
        reconcileTask = nil
        wsTask?.cancel()
        wsTask = nil
        liveWatchdogTask?.cancel()
        liveWatchdogTask = nil
        gapHealTask?.cancel()
        gapHealTask = nil
        atrTask?.cancel()
        atrTask = nil
        isConnected = false
    }

    /// Called by the interaction view when the user drags. Disables autoscroll
    /// if the user scrolled away from the right edge, and triggers loading
    /// earlier bars when scrolling near the left edge.
    func onUserScroll() {
        let atEnd = isViewAtLiveEdge
        // Record the anchor in lock-step: pinned at the live-edge resting spot ⇒ follow it (nil);
        // otherwise (scrolled back OR future-room) ⇒ remember the centered time so
        // reloads/reconnects/reconcile swaps/timeframe switches keep this position.
        autoScroll = atEnd
        viewportAnchorTimeMs = atEnd ? nil : currentViewportCenterTimeMs()

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
        case "WEEKLY":     return 104  // ~2 years (fits the warm 1H cache → no deep .bi5 on open)
        case "DAILY":      return 250  // ~1 year of trading days
        case "FOUR_HOURS": return 500  // ~3 months
        case "ONE_HOUR":   return 500  // ~3 weeks
        case "THREE_MINS": return 1000 // ~2 days (×3 = ~3000 ONE_MIN bars fetched)
        default:           return 1000 // intraday
        }
    }

    /// True when the newest painted (closed) bar ends more than ~2 intervals before the
    /// last possible session close — i.e. the warm cache is stale and recently-closed bars
    /// are missing. Clamped to the last session close (via `NYTradingCalendar`) so a
    /// Friday-evening cache opened over the weekend reads as current, not stale. The ~2x
    /// slack absorbs the normal lag of the newest *closed* bar (the current bucket is still
    /// forming, so the last closed bar's timestamp already sits up to ~2 intervals behind
    /// "now"), so only a genuine multi-bar gap trips it.
    static func cacheIsBehind(bars: [CandleBar], period: String, now: Date = Date()) -> Bool {
        guard let cadenceSeconds = periodSeconds(period) else { return false }
        guard let latest = (bars.last { !$0.partial } ?? bars.last)?.time else { return false }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let referenceMs = min(nowMs, NYTradingCalendar.lastSessionCloseMs(at: now))
        return referenceMs - latest > cadenceSeconds * 1000 * 2
    }

    /// Bar interval in seconds for the chart's period codes (incl. the client-only
    /// `THREE_MINS` aggregation). nil for an unrecognised code.
    private static func periodSeconds(_ period: String) -> Int64? {
        switch period {
        case "ONE_MIN":      return 60
        case "THREE_MINS":   return 180
        case "FIVE_MINS":    return 300
        case "FIFTEEN_MINS": return 900
        case "THIRTY_MINS":  return 1800
        case "ONE_HOUR":     return 3600
        case "FOUR_HOURS":   return 14400
        case "DAILY":        return 86400
        case "WEEKLY":       return 604800
        default:             return nil
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
        let side = currentSide
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
                    rebucketing: rebucketing, side: side
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

extension Array where Element == ChartViewModel {
    /// Cold-start each chart with bounded concurrency, in array order, so a grid loads
    /// gradually instead of firing every cell's deep history fetch at once — which storms
    /// the native client's single socket + bulk CDN and causes slow loads and gaps.
    /// `maxConcurrent` comes from the coordinator (`.max` for server mode = unbounded,
    /// matching the previous behaviour; a small number for native).
    @MainActor
    func startGradually(maxConcurrent: Int) async {
        let limit = Swift.max(1, maxConcurrent)
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func schedule() {
                guard next < count else { return }
                let vm = self[next]
                next += 1
                group.addTask { await vm.start() }
            }
            for _ in 0..<Swift.min(limit, count) { schedule() }
            while await group.next() != nil { schedule() }
        }
    }
}
