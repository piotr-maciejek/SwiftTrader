import DukascopyClient
import Foundation
import os

private let nativeLog = Logger(subsystem: "com.swifttrader", category: "native")

/// Standalone market-data provider: talks the Dukascopy protocol directly via the
/// `DukascopyClient` package (no jforex-server). Conforms to `MarketDataProviding`
/// so the view-model layer is identical to server mode.
///
/// 4H/Daily/3m are ALWAYS aggregated client-side here (the `rebucketing` flag is
/// ignored) — see `fetchAggregated`. Two properties keep the native client from
/// flooding Dukascopy's single connection (which the DFS answers with empty results
/// and then drops):
///   1. **Cache-first** — a warm cache (hydrated from disk or filled by another tab)
///      is served without any network fetch. Most startup loads hit this.
///   2. **Coalescing** — concurrent fetches for the same (instrument, period) share one
///      subscribe, and at most `maxConcurrentFetches` network fetches run at once.
final class NativeMarketDataCoordinator: MarketDataProviding, Sendable {
    /// The single wire-touching leaf: raw bars (1H/1M, …) for one instrument/period,
    /// optionally ending before a millisecond timestamp. Injectable so the routing /
    /// aggregation logic above it is testable without a live session.
    typealias RawFetch = @Sendable (
        _ instrument: String, _ period: String, _ count: Int, _ before: Int64?
    ) async throws -> [SwiftTrader.CandleBar]

    let cache: CandleCache
    /// Connected session, supplied once standalone auth reaches `.ready`. Nil before
    /// connect — data calls then fail with `.missingCredentials`.
    private let session: DukascopySession?
    private let rawFetch: RawFetch
    private let coalescer = HistoryCoalescer(limit: 4)
    /// Fills deep history for all pairs in the background, one idle-gated request at a
    /// time. Only present with a live session (a real `rawFetch`); nil for tests.
    private let prefetcher: HistoryPrefetcher?

    init(
        session: DukascopySession? = nil,
        cache: CandleCache = CandleCache(),
        rawFetch: RawFetch? = nil
    ) {
        self.session = session
        self.cache = cache
        if let rawFetch {
            self.rawFetch = rawFetch
        } else if let session {
            self.rawFetch = { instrument, period, count, before in
                try await Self.fetchViaSession(
                    session, instrument: instrument, period: period, count: count, before: before
                )
            }
        } else {
            self.rawFetch = { _, _, _, _ in throw NativeProviderError.missingCredentials }
        }

        // The background prefetcher only makes sense against a live session. Its closures
        // capture the cache / coalescer / rawFetch values (not `self`), so there's no
        // retain cycle keeping a stale coordinator alive across a reconnect.
        if session != nil {
            let coalescer = self.coalescer
            let cache = self.cache
            let rawFetch = self.rawFetch
            self.prefetcher = HistoryPrefetcher(
                instruments: Self.defaultInstruments,
                cache: cache,
                awaitIdle: { await coalescer.awaitForegroundIdle() },
                fetchPage: { instrument, period, before, count in
                    let key = "\(instrument)|\(period)|\(before ?? -1)|\(count)"
                    let bars = (try? await coalescer.run(key: key, foreground: false) {
                        NativeMarketDataCoordinator.stripWeekendFillers(
                            try await rawFetch(instrument, period, count, before)
                        )
                    }) ?? []
                    if !bars.isEmpty {
                        _ = await cache.merge(
                            bars,
                            for: CandleCache.CacheKey(instrument: instrument, period: period, source: .server)
                        )
                    }
                    return bars
                }
            )
        } else {
            self.prefetcher = nil
        }
    }

    /// Native mode talks to a single Dukascopy socket + bulk CDN, so a grid must cold-load
    /// its cells a few at a time rather than firing every deep fetch at once (that storms
    /// the socket and times out bulk chunks → gaps). Server mode keeps its effectively
    /// unbounded default (its own cache absorbs the burst).
    var maxConcurrentColdLoads: Int { 3 }

    func fetchInstruments() async throws -> [String] {
        Self.defaultInstruments
    }

    func fetchCandles(
        instrument: String, period: String, count: Int, rebucketing: Bool
    ) async throws -> [SwiftTrader.CandleBar] {
        // Once the first visible chart starts loading, kick off the background prefetcher
        // (idempotent). It waits for foreground idle before each request, so it never
        // competes with the cells the user is actually looking at.
        await prefetcher?.ensureStarted()
        // Native mode aggregates everything except the two periods the datafeed actually
        // stores (1H, 1m): 4H/Daily from 1H; 3m/5m/15m/30m from 1m. The datafeed has no
        // 5m/15m/30m candle files, so they MUST be built from 1m (exactly as JForex does).
        // The only thing native caches as `.server` is raw 1H/1m. `rebucketing` is ignored.
        if let spec = Self.aggSpec(for: period) {
            return try await fetchAggregated(instrument: instrument, spec: spec, count: count)
        }
        let key = CandleCache.CacheKey(instrument: instrument, period: period, source: .server)
        // Cache-first, but only when the cache is BOTH fresh and deep enough for `count` —
        // a shallow cache (e.g. a 1H chart's recent window) must not satisfy a deeper
        // request, and a stale one triggers a refetch. Otherwise the live tail catches up
        // via the stream (Slice C).
        if let latest = await cache.latestTime(for: key),
           Self.isCacheFresh(latestMs: latest, period: period),
           await cacheCoversWindow(key: key, period: period, count: count) {
            return await cache.getBars(for: key)
        }
        let fetched = try await fetchRawCandles(instrument: instrument, period: period, count: count)
        let cached = await cache.merge(fetched, for: key)
        if let last = fetched.last, last.partial { return cached + [last] }
        return cached
    }

    func fetchEarlierCandles(
        instrument: String, period: String, count: Int, rebucketing: Bool
    ) async throws -> [SwiftTrader.CandleBar] {
        if let spec = Self.aggSpec(for: period) {
            return try await fetchEarlierAggregated(instrument: instrument, spec: spec, count: count)
        }
        let key = CandleCache.CacheKey(instrument: instrument, period: period, source: .server)
        guard let before = await cache.earliestTime(for: key) else {
            return await cache.getBars(for: key)
        }
        let fetched = try await fetchRawCandles(
            instrument: instrument, period: period, count: count, before: before
        )
        return await cache.merge(fetched, for: key)
    }

    func cacheBar(
        _ bar: SwiftTrader.CandleBar, instrument: String, period: String, rebucketing: Bool
    ) async {
        let key = CandleCache.CacheKey(instrument: instrument, period: period, source: .server)
        await cache.appendBar(bar, for: key)
    }

    func streamCandles(
        instrument: String, period: String, rebucketing: Bool
    ) -> AsyncThrowingStream<SwiftTrader.CandleBar, Error> {
        // Live path lands with the native session. It will mirror the fetch policy:
        // 4H/Daily/3m aggregated client-side from a raw 1H/1M bar stream.
        AsyncThrowingStream { $0.finish(throwing: NativeProviderError.notImplemented("live bar stream")) }
    }

    func clearServerCache(instrument: String) async throws -> Int {
        await cache.clear(instrument: instrument)
        return 0
    }

    func forceReconnect() async throws {
        throw NativeProviderError.notImplemented("reconnect")
    }

    // MARK: - Client-side aggregation

    /// Which periods native mode derives (rather than fetches raw), and from what. The
    /// shared `AggregatedPeriod` covers 4H/Daily/3m (used by server mode too); native adds
    /// 5m/15m/30m from 1m on a fixed grid, since the datafeed has no files for them.
    struct AggSpec {
        let sourcePeriod: String   // "ONE_HOUR" or "ONE_MIN"
        let sourceSpan: Int        // source bars per target bar (sizes the source fetch)
        let periodCode: String
        let bucket: @Sendable ([SwiftTrader.CandleBar], SwiftTrader.CandleBar?) -> [SwiftTrader.CandleBar]
    }

    static func aggSpec(for period: String) -> AggSpec? {
        if let target = AggregatedPeriod(period) {
            return AggSpec(
                sourcePeriod: target.sourcePeriod, sourceSpan: target.sourceSpan, periodCode: target.periodCode,
                bucket: { src, partial in BarAggregator.aggregate(hourly: src, openPartial: partial, target: target) }
            )
        }
        let granularityMs: Int64
        switch period {
        case "FIVE_MINS": granularityMs = 300_000
        case "FIFTEEN_MINS": granularityMs = 900_000
        case "THIRTY_MINS": granularityMs = 1_800_000
        default: return nil
        }
        return AggSpec(
            sourcePeriod: "ONE_MIN", sourceSpan: Int(granularityMs / 60_000), periodCode: period,
            bucket: { src, partial in
                BarAggregator.aggregateFixedGrid(src, granularityMs: granularityMs, openPartial: partial)
            }
        )
    }

    private func fetchAggregated(
        instrument: String, spec: AggSpec, count: Int
    ) async throws -> [SwiftTrader.CandleBar] {
        let source = spec.sourcePeriod  // ONE_HOUR (4H/Daily) or ONE_MIN (3m/5m/15m/30m)
        let sourceKey = CandleCache.CacheKey(instrument: instrument, period: source, source: .server)

        let neededSource = count * spec.sourceSpan
        let merged: [SwiftTrader.CandleBar]
        var partial: SwiftTrader.CandleBar?
        // Cache-first on the SOURCE series. All periods sharing a source (e.g. D/4H/1H on
        // ONE_HOUR; 3m/5m/15m/30m on ONE_MIN) reuse it — but only when the cached source
        // is fresh AND reaches back far enough for `neededSource` bars. A Daily request
        // (6000 1H) must not be served from a 1H chart's shallow 500-bar cache.
        if let latest = await cache.latestTime(for: sourceKey),
           Self.isCacheFresh(latestMs: latest, period: source),
           await cacheCoversWindow(key: sourceKey, period: source, count: neededSource) {
            merged = await cache.getBars(for: sourceKey)
        } else {
            let fetched = try await fetchRawCandles(
                instrument: instrument, period: source, count: neededSource
            )
            merged = await cache.merge(fetched, for: sourceKey)
            partial = fetched.last.flatMap { $0.partial ? $0 : nil }
        }

        let aggregated = spec.bucket(merged, partial)
        let aggKey = CandleCache.CacheKey(
            instrument: instrument, period: spec.periodCode, source: .aggregated
        )
        let cached = await cache.merge(aggregated, for: aggKey)
        if let last = aggregated.last, last.partial { return cached + [last] }
        return cached
    }

    private func fetchEarlierAggregated(
        instrument: String, spec: AggSpec, count: Int
    ) async throws -> [SwiftTrader.CandleBar] {
        let source = spec.sourcePeriod
        let sourceKey = CandleCache.CacheKey(instrument: instrument, period: source, source: .server)
        guard let before = await cache.earliestTime(for: sourceKey) else {
            let aggKey = CandleCache.CacheKey(
                instrument: instrument, period: spec.periodCode, source: .aggregated
            )
            return await cache.getBars(for: aggKey)
        }
        let fetched = try await fetchRawCandles(
            instrument: instrument, period: source, count: count * spec.sourceSpan, before: before
        )
        let merged = await cache.merge(fetched, for: sourceKey)
        let aggregated = spec.bucket(merged, nil)
        let aggKey = CandleCache.CacheKey(
            instrument: instrument, period: spec.periodCode, source: .aggregated
        )
        return await cache.merge(aggregated, for: aggKey)
    }

    /// The single leaf that talks to the native Dukascopy client. Each forward load pulls
    /// exactly `count` bars (no over-fetch) so a chart's initial window stays inside the
    /// socket's warm range when it can — deep history is filled lazily on scroll-back and
    /// by the background prefetcher. Concurrent callers for the same (instrument, period,
    /// before, count) share one subscribe; `foreground: false` requests (the prefetcher)
    /// don't count toward the foreground-idle signal that gates background work.
    private func fetchRawCandles(
        instrument: String, period: String, count: Int, before: Int64? = nil, foreground: Bool = true
    ) async throws -> [SwiftTrader.CandleBar] {
        let key = "\(instrument)|\(period)|\(before ?? -1)|\(count)"
        let rawFetch = self.rawFetch
        return try await coalescer.run(key: key, foreground: foreground) {
            Self.stripWeekendFillers(try await rawFetch(instrument, period, count, before))
        }
    }

    /// Dukascopy candle files (socket + `.bi5`) include weekend filler bars — one per slot
    /// through the Fri 17:00 ET → Sun 17:00 ET closure. Server mode never sees them (JForex
    /// `Filter.WEEKENDS` strips them upstream); native must strip them too, or the chart
    /// shows weekend gaps and the EMAs flatten across the dead hours. Uses the same detector
    /// the 4H/Daily aggregator already relies on.
    static func stripWeekendFillers(_ bars: [SwiftTrader.CandleBar]) -> [SwiftTrader.CandleBar] {
        bars.filter { !BarAggregator.isWeekendFiller($0) }
    }

    /// True when the cache for `key` already reaches back far enough to satisfy a forward
    /// request of `count` bars — measured against the SAME `now - count·period` window the
    /// fetch itself would request, so once that window is filled the gate stays satisfied
    /// (weekend gaps make the bar count smaller than `count`, so a count-based test would
    /// refetch forever). Unknown periods (no `CandlePeriod`) report "not covered".
    private func cacheCoversWindow(key: CandleCache.CacheKey, period: String, count: Int) async -> Bool {
        guard let earliest = await cache.earliestTime(for: key),
              let seconds = CandlePeriod.parse(period)?.seconds else { return false }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let windowStartMs = nowMs - Int64(count) * seconds * 1000
        // After weekend-filler stripping the oldest real bar can sit a closure (weekend or
        // holiday) past the requested window start even when fully fetched, so allow ~4 days
        // of slack. A genuinely too-shallow cache misses by weeks/months and still refetches.
        let closureSlackMs: Int64 = 4 * 24 * 60 * 60 * 1000
        return earliest <= windowStartMs + closureSlackMs
    }

    /// Bridges a raw history request to `DukascopySession.fetchHistory`: computes the
    /// `[start, end]` window and maps `DukascopyClient.CandleBar` → `SwiftTrader.CandleBar`.
    /// History is fetched on the **Bid** side to match server mode. The newest bar is
    /// flagged `partial` only when its bucket hasn't closed (the live-forming candle);
    /// scroll-back windows (`before` set) never trip it.
    private static func fetchViaSession(
        _ session: DukascopySession,
        instrument: String, period: String, count: Int, before: Int64?
    ) async throws -> [SwiftTrader.CandleBar] {
        guard let cp = CandlePeriod.parse(period) else {
            throw NativeProviderError.notImplemented("period \(period)")
        }
        let endSec = before.map { $0 / 1000 } ?? Int64(Date().timeIntervalSince1970)
        let startSec = endSec - cp.seconds * Int64(count)
        let t0 = Date()
        let wireInstrument = Self.toSlashedPair(instrument)
        nativeLog.debug("history \(instrument, privacy: .public) \(period, privacy: .public) count=\(count) before=\(before ?? -1)")
        do {
            let raw = try await session.fetchHistory(
                instrument: wireInstrument, side: .bid, period: cp,
                startSeconds: startSec, endSeconds: endSec
            )
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            nativeLog.debug("history \(instrument, privacy: .public) \(period, privacy: .public) -> \(raw.count) bars in \(ms)ms")
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let periodMs = cp.seconds * 1000
            return raw
                .sorted { $0.timeMillis < $1.timeMillis }
                .map { bar in
                    SwiftTrader.CandleBar(
                        time: bar.timeMillis,
                        open: bar.open, high: bar.high, low: bar.low, close: bar.close,
                        volume: bar.volume,
                        partial: bar.timeMillis + periodMs > nowMs
                    )
                }
        } catch {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            nativeLog.error("history \(instrument, privacy: .public) \(period, privacy: .public) FAILED after \(ms)ms: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Period-aware cache freshness, clamped to the newest bar that *can* exist (the last
    /// session close over a weekend), mirroring server mode's staleness logic. A fresh
    /// cache is served as-is; a stale one triggers a (coalesced) refetch.
    private static func isCacheFresh(latestMs: Int64, period: String) -> Bool {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let referenceMs = min(nowMs, NYTradingCalendar.lastSessionCloseMs(at: Date()))
        let ageMs = referenceMs - latestMs
        if ageMs <= 0 { return true }
        let threshold: Int64 = switch period {
        case "ONE_MIN": 2 * 24 * 60 * 60 * 1000
        case "FIVE_MINS", "FIFTEEN_MINS", "THIRTY_MINS": 7 * 24 * 60 * 60 * 1000
        case "ONE_HOUR": 14 * 24 * 60 * 60 * 1000
        default: 60 * 24 * 60 * 60 * 1000
        }
        return ageMs < threshold
    }

    /// The app identifies pairs by slashless code ("EURUSD"); DukascopyClient's instrument
    /// format is the slashed pair ("EUR/USD"). History for a slashless code comes back
    /// empty, so convert at the boundary before requesting.
    static func toSlashedPair(_ code: String) -> String {
        guard !code.contains("/"), code.count == 6 else { return code }
        let split = code.index(code.startIndex, offsetBy: 3)
        return "\(code[..<split])/\(code[split...])"
    }

    /// Major + minor FX pairs in the app's slashless instrument-code form.
    /// Replaced by a live roster once the session lifecycle lands.
    private static let defaultInstruments: [String] = [
        "EURUSD", "GBPUSD", "USDJPY", "USDCHF", "USDCAD", "AUDUSD", "NZDUSD",
        "EURGBP", "EURJPY", "EURCHF", "EURCAD", "EURAUD", "EURNZD",
        "GBPJPY", "GBPCHF", "GBPCAD", "GBPAUD", "GBPNZD",
        "AUDJPY", "AUDCHF", "AUDCAD", "AUDNZD",
        "NZDJPY", "NZDCHF", "NZDCAD",
        "CADJPY", "CADCHF", "CHFJPY",
    ]
}

/// Deduplicates concurrent history fetches by key and caps how many run at once, so a
/// burst of chart tabs can't flood Dukascopy's single connection (which it answers with
/// empty results and then closes). Late callers for an in-flight key await the same task.
private actor HistoryCoalescer {
    private var inFlight: [String: Task<[SwiftTrader.CandleBar], Error>] = [:]
    private let limit: Int
    private var active = 0
    private var queue: [CheckedContinuation<Void, Never>] = []
    // Foreground (user-driven) requests in flight. The background prefetcher gates on this
    // hitting zero so it only runs in the gaps between visible loads.
    private var foregroundInFlight = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func run(
        key: String,
        foreground: Bool = true,
        _ work: @escaping @Sendable () async throws -> [SwiftTrader.CandleBar]
    ) async throws -> [SwiftTrader.CandleBar] {
        if let existing = inFlight[key] {
            return try await existing.value
        }
        if foreground { foregroundInFlight += 1 }
        let task = Task<[SwiftTrader.CandleBar], Error> { [self] in
            await acquire()
            defer { Task { await self.release() } }
            return try await work()
        }
        inFlight[key] = task
        defer {
            inFlight[key] = nil
            if foreground {
                foregroundInFlight -= 1
                if foregroundInFlight == 0 {
                    let waiters = idleWaiters
                    idleWaiters.removeAll()
                    for w in waiters { w.resume() }
                }
            }
        }
        return try await task.value
    }

    /// Suspends until no foreground fetch is in flight. Used by the background prefetcher
    /// so it never competes with a user-driven load for the single socket.
    func awaitForegroundIdle() async {
        if foregroundInFlight == 0 { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func acquire() async {
        if active < limit { active += 1; return }
        await withCheckedContinuation { queue.append($0) }
        // Resumed by release(), which hands off its slot without decrementing `active`.
    }

    private func release() {
        if !queue.isEmpty {
            queue.removeFirst().resume()
        } else {
            active -= 1
        }
    }
}

/// Background warm-up that gradually fills deep history for every pair, mirroring
/// jforex-server's prefetching. It works ONE request at a time and waits for foreground
/// idle before each, so user-driven loads always win the single socket. Work is finite —
/// each series stops once it reaches its target depth or the datafeed runs out — so a
/// prefetcher left behind by a reconnect drains quickly instead of looping forever.
private actor HistoryPrefetcher {
    /// A basic period to warm and how deep. 1H feeds 1H/4H/Daily; 1m feeds 1m/3m/5m/15m/30m.
    private struct Series {
        let period: String
        let targetSpanSeconds: Int64
        let pageCount: Int
    }

    // 1H first (most-used; powers Daily/4H for every pair), then 1m. Depths are modest to
    // bound CDN load — scroll-back still fetches deeper on demand.
    private static let plan: [Series] = [
        Series(period: "ONE_HOUR", targetSpanSeconds: 2 * 365 * 24 * 3600, pageCount: 2000),
        Series(period: "ONE_MIN", targetSpanSeconds: 30 * 24 * 3600, pageCount: 5000),
    ]
    private static let maxPagesPerSeries = 80

    private let instruments: [String]
    private let cache: CandleCache
    private let awaitIdle: @Sendable () async -> Void
    private let fetchPage: @Sendable (_ instrument: String, _ period: String, _ before: Int64?, _ count: Int) async -> [SwiftTrader.CandleBar]

    private var started = false
    private var task: Task<Void, Never>?

    init(
        instruments: [String],
        cache: CandleCache,
        awaitIdle: @escaping @Sendable () async -> Void,
        fetchPage: @escaping @Sendable (_ instrument: String, _ period: String, _ before: Int64?, _ count: Int) async -> [SwiftTrader.CandleBar]
    ) {
        self.instruments = instruments
        self.cache = cache
        self.awaitIdle = awaitIdle
        self.fetchPage = fetchPage
    }

    /// Launch the warm-up loop once. Safe to call on every fetch.
    func ensureStarted() {
        guard !started else { return }
        started = true
        task = Task { [self] in await runLoop() }
    }

    func stop() { task?.cancel() }

    private func runLoop() async {
        // Let the initial visible grid load before we start competing for idle windows.
        try? await Task.sleep(for: .seconds(5))
        nativeLog.info("prefetch: starting background warm-up for \(self.instruments.count) pairs")
        for series in Self.plan {
            for instrument in instruments {
                if Task.isCancelled { return }
                await deepen(instrument: instrument, series: series)
            }
        }
        nativeLog.info("prefetch: warm-up complete")
    }

    /// Page `series.period` for one instrument backward until it reaches the target depth
    /// or the datafeed has nothing older. Each page waits for foreground idle first.
    private func deepen(instrument: String, series: Series) async {
        let key = CandleCache.CacheKey(instrument: instrument, period: series.period, source: .server)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let targetStartMs = nowMs - series.targetSpanSeconds * 1000
        var pages = 0
        while !Task.isCancelled, pages < Self.maxPagesPerSeries {
            await awaitIdle()
            if Task.isCancelled { return }
            let earliest = await cache.earliestTime(for: key)
            if let earliest, earliest <= targetStartMs { return }   // deep enough
            let page = await fetchPage(instrument, series.period, earliest, series.pageCount)
            pages += 1
            if page.isEmpty { return }   // hit the start of available history
            // Pace so a freshly-arrived foreground load always gets the next idle window.
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}

enum NativeProviderError: LocalizedError {
    case notImplemented(String)
    case missingCredentials

    var errorDescription: String? {
        switch self {
        case .notImplemented(let what):
            return "Standalone mode: \(what) is not implemented yet."
        case .missingCredentials:
            return "Standalone mode requires Dukascopy credentials."
        }
    }
}
