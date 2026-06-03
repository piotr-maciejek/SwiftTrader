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
    /// True when this coordinator has a real network path (session or injected closure).
    /// Used to short-circuit proactive operations (forward gap-fill, prefetch) on the
    /// stub coordinator that exists before standalone auth completes — without this,
    /// every cached-data chart load before auth fires a noisy "missing credentials"
    /// error from `forwardGapFillIfNeeded`.
    private let canFetch: Bool
    private let coalescer = HistoryCoalescer(limit: 4)
    /// Per-instrument cache of the server's in-progress candle set (the wire path the
    /// JForex SDK uses internally for `getHistory().getBar(period, BID, 0)`). Re-fetched
    /// every `inProgressTtl` so the seed for a forming bucket reflects the server's
    /// authoritative OHLC instead of being derived from our cached 1m bars.
    private let inProgressStore = InProgressStore()
    private let inProgressTtl: TimeInterval = 30
    /// Fills deep history for all pairs in the background, one idle-gated request at a
    /// time. Only present with a live session (a real `rawFetch`); nil for tests.
    private let prefetcher: HistoryPrefetcher?
    /// One shared live-candle aggregation per (instrument, period), fanned out to every chart —
    /// so a main chart, MTF panel and correlation cell of the same pair+timeframe show the
    /// identical live bar instead of each building (and diverging on) its own. See `streamCandles`.
    private let multicaster = LiveCandleMulticaster()

    deinit {
        // Safety net: if any chart subscription leaked, make sure its driver stops consuming this
        // (about-to-be-replaced) session's ticks. Normal teardown already happens via unsubscribe.
        let multicaster = self.multicaster
        Task { await multicaster.shutdown() }
    }

    init(
        session: DukascopySession? = nil,
        cache: CandleCache = CandleCache(),
        rawFetch: RawFetch? = nil
    ) {
        self.session = session
        self.cache = cache
        if let rawFetch {
            self.rawFetch = rawFetch
            self.canFetch = true
        } else if let session {
            self.rawFetch = { instrument, period, count, before in
                try await Self.fetchViaSession(
                    session, instrument: instrument, period: period, count: count, before: before
                )
            }
            self.canFetch = true
        } else {
            self.rawFetch = { _, _, _, _ in throw NativeProviderError.missingCredentials }
            self.canFetch = false
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
        // Forward gap-fill: when the app sat closed during a trading session (e.g.
        // overnight, or for a few hours on Friday afternoon), the disk cache ends well
        // before the last session close. `isCacheFresh` only decides "do we need a full
        // refetch" — without a forward fill, a 5-hour-behind cache stays 5 hours behind
        // every launch. Mirrors server mode's `MarketDataCoordinator.gapFill`. For
        // aggregated targets (4H/Daily/3m/5m/15m/30m) we fill the SOURCE (1H or 1m) so
        // the re-aggregation below builds on fresh data.
        let sourcePeriod = Self.aggSpec(for: period)?.sourcePeriod ?? period
        await forwardGapFillIfNeeded(instrument: instrument, period: sourcePeriod)
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
           let periodSeconds = CandlePeriod.parse(period)?.seconds,
           await cacheCoversWindow(key: key, periodSeconds: periodSeconds, count: count) {
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
        guard session != nil else {
            return AsyncThrowingStream { $0.finish(throwing: NativeProviderError.missingCredentials) }
        }
        // One shared aggregation per (instrument, period): all charts of the same pair+timeframe
        // (main chart, MTF panel, correlation cell) attach to the SAME live bar instead of each
        // building its own from the shared tick feed (which diverged). A freshly-attaching chart
        // replays the current forming bar immediately, so it matches the others on the spot.
        let key = LiveCandleMulticaster.Key(instrument: instrument, period: period)
        return multicaster.subscribe(key: key) { [weak self] in
            guard let self else { return AsyncThrowingStream { $0.finish() } }
            return self.rawCandleStream(instrument: instrument, period: period, rebucketing: rebucketing)
        }
    }

    /// The single per-(instrument, period) live aggregation: subscribe quotes, consume the shared
    /// tick feed, and build the forming bar (seed on a bucket change via `seedLiveBucket`, extend
    /// within a bucket). Run ONCE per key by `LiveCandleMulticaster` and fanned out to every
    /// chart — never per chart. (Body unchanged from the previous per-call `streamCandles`.)
    private func rawCandleStream(
        instrument: String, period: String, rebucketing: Bool
    ) -> AsyncThrowingStream<SwiftTrader.CandleBar, Error> {
        guard let session else {
            return AsyncThrowingStream { $0.finish(throwing: NativeProviderError.missingCredentials) }
        }
        let wireInstrument = Self.toSlashedPair(instrument)
        return AsyncThrowingStream<SwiftTrader.CandleBar, Error> { continuation in
            let task = Task {
                // Subscribe to quotes for THIS instrument only. The session unions
                // additions across all open streams, so opening AUD/CAD multi-tf
                // doesn't pull ticks for the other 27 default pairs. Surface a subscribe
                // failure (don't swallow with `try?`) so the chart's retry loop re-attempts
                // instead of waiting forever for ticks that will never arrive.
                do {
                    try await session.ensureSubscribedQuotes([wireInstrument])
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                var current: SwiftTrader.CandleBar?
                for await tick in await session.tickStream() {
                    if Task.isCancelled { break }
                    guard tick.instrument == wireInstrument else { continue }
                    guard let bid = tick.bestBid?.doubleValue else { continue }
                    // FX is 24/5 — over Fri 17 ET → Sun 17 ET (and Dec 25 / Jan 1) any
                    // tick that arrives is a stale "last quote" replay from Dukascopy.
                    // Yielding it creates a flat partial bar (no in-progress snapshot
                    // exists when market is closed, so `seedLiveBucket` falls back to
                    // open=high=low=close=bid) that overwrites the real last-closed bar's
                    // OHLC in the chart's display via `handleBar`'s same-timestamp swap.
                    let nowDate = Date()
                    if NYTradingCalendar.isMarketClosed(at: nowDate)
                        || NYTradingCalendar.isFXHoliday(at: nowDate) {
                        continue
                    }
                    let bucketMs = Self.liveBucketStartMs(tickMs: tick.creationTimestampMillis, period: period)
                    if let c = current, c.time == bucketMs {
                        current = SwiftTrader.CandleBar(
                            time: c.time, open: c.open,
                            high: max(c.high, bid), low: min(c.low, bid),
                            close: bid, volume: c.volume, partial: true
                        )
                    } else {
                        // New bucket: seed from the cached source bars that already fall in
                        // this bucket (e.g., today's 1H bars for the live Daily candle), so
                        // the live bar isn't a fresh open at the current tick price — it
                        // inherits the bucket's accumulated OHLC and is only EXTENDED by the
                        // tick. For raw 1H/1m (no in-bucket source) there's no history to
                        // seed and the live bar opens at the tick price as before.
                        current = await self.seedLiveBucket(
                            instrument: instrument, period: period, bucketMs: bucketMs, bid: bid
                        )
                    }
                    if let c = current { continuation.yield(c) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Seed the live bar for `bucketMs` by fetching the server's authoritative
    /// in-progress candle (the same wire path JForex SDK uses for
    /// `getHistory().getBar(period, BID, 0)`), then routing it through `BarAggregator`
    /// exactly the way server mode's `aggregatedStream` does. The server has been
    /// accumulating the in-progress OHLC from real ticks since the bucket opened, so
    /// the seed is correct to the tick (modulo network latency) — no "tick aggregation
    /// from the cached 1m suffix" approximation. The live tick that triggered this
    /// call is folded in as a `max(high,bid) / min(low,bid) / close=bid` extension.
    /// Raw 1H/1m yield the server's partial directly; 4H/Daily feed the server's 1H
    /// partial into `BarAggregator.aggregate(hourly:, openPartial:, target:)`; the
    /// fixed-grid intraday periods (3m/5m/15m/30m) feed the server's 1m partial into
    /// `aggregateFixedGrid(..., openPartial:)`.
    private func seedLiveBucket(
        instrument: String, period: String, bucketMs: Int64, bid: Double
    ) async -> SwiftTrader.CandleBar {
        let snap = await ensureInProgress(instrument: instrument)
        func extend(_ bar: SwiftTrader.CandleBar?) -> SwiftTrader.CandleBar {
            // A non-positive seed (zero-OHLC in-progress/placeholder bar) would drag the
            // live bar's low to 0 via min(low, bid); treat it as no-seed and open at the
            // tick price. Same invariant the cache enforces for persisted bars.
            guard let b = bar, b.open > 0, b.high > 0, b.low > 0, b.close > 0 else {
                return SwiftTrader.CandleBar(
                    time: bucketMs, open: bid, high: bid, low: bid, close: bid,
                    volume: 0, partial: true
                )
            }
            return SwiftTrader.CandleBar(
                time: bucketMs, open: b.open,
                high: max(b.high, bid), low: min(b.low, bid),
                close: bid, volume: b.volume, partial: true
            )
        }
        switch period {
        case "ONE_HOUR":
            let seed = Self.inProgressSeed(snap?.oneHour, bucketMs: bucketMs)
            if seed == nil, let h = snap?.oneHour {
                nativeLog.notice("live 1H seed mismatch \(instrument, privacy: .public): in-progress partial bucket \(h.time) != \(bucketMs); opening fresh to avoid inheriting a stale high")
            }
            return extend(seed)
        case "ONE_MIN":
            return extend(Self.inProgressSeed(snap?.oneMin, bucketMs: bucketMs))
        case "DAILY", "FOUR_HOURS":
            // Only the trailing window of the source can affect the currently-forming
            // bucket — mirrors server mode's `aggregatedStream` tail cap (Daily=30,
            // 4H=6). Re-aggregating the full cache on every tick is exactly what
            // pegged 1500% CPU the last two times.
            let target: AggregatedPeriod = period == "DAILY" ? .daily : .fourHours
            let tail = period == "DAILY" ? 30 : 6
            let cached1H = await cache.getBars(
                for: CandleCache.CacheKey(instrument: instrument, period: "ONE_HOUR", source: .server)
            )
            let inputs = Array(cached1H.suffix(tail))
            let aggregated = BarAggregator.aggregate(
                hourly: inputs, openPartial: snap?.oneHour, target: target
            )
            if let last = aggregated.last, last.time == bucketMs {
                return extend(last)
            }
            return extend(snap?.oneHour)
        case "THIRTY_MINS", "FIFTEEN_MINS", "FIVE_MINS", "THREE_MINS":
            // Prefer the server's authoritative in-progress bar for THIS period. It holds the
            // full OHLC accumulated since the bucket opened, so opening the chart 10 minutes
            // into a 15m candle shows the whole forming bar — not one that starts fresh at the
            // current tick (the data before connect would otherwise be lost). These grids are
            // epoch-aligned, so the server bar's time matches `bucketMs`. 3m has no server
            // bucket, so it always falls through to the 1m aggregation below.
            let serverPartial: SwiftTrader.CandleBar?
            switch period {
            case "THIRTY_MINS":  serverPartial = snap?.thirtyMin
            case "FIFTEEN_MINS": serverPartial = snap?.fifteenMin
            case "FIVE_MINS":    serverPartial = snap?.fiveMin
            default:             serverPartial = nil  // THREE_MINS — no server bucket
            }
            if let sp = serverPartial, sp.time == bucketMs {
                return extend(sp)
            }
            // Fallback: aggregate the cached 1m suffix (3m always; other periods only if the
            // server omitted the partial). Tail = a few buckets' worth so re-aggregation is
            // O(constant) not O(cache).
            let granularityMs: Int64 = period == "THREE_MINS" ? 180_000
                : period == "FIVE_MINS" ? 300_000
                : period == "FIFTEEN_MINS" ? 900_000
                : 1_800_000
            let tail = period == "THIRTY_MINS" ? 60
                : period == "FIFTEEN_MINS" ? 30
                : period == "FIVE_MINS" ? 15
                : 10
            let cached1m = await cache.getBars(
                for: CandleCache.CacheKey(instrument: instrument, period: "ONE_MIN", source: .server)
            )
            let inputs = Array(cached1m.suffix(tail))
            let aggregated = BarAggregator.aggregateFixedGrid(
                inputs, granularityMs: granularityMs, openPartial: snap?.oneMin
            )
            if let last = aggregated.last, last.time == bucketMs {
                return extend(last)
            }
            return extend(snap?.oneMin)
        case "WEEKLY":
            // Seed the forming week from the 1H bars already in this FX week (the warm
            // shared 1H cache, same source the weekly history fetch aggregates), then
            // extend by the tick and the in-progress 1H partial.
            let hourlyKey = CandleCache.CacheKey(instrument: instrument, period: "ONE_HOUR", source: .server)
            let weekHours = await cache.getBars(for: hourlyKey)
                .filter { BarAggregator.weekStartMs($0.date) == bucketMs }
            let aggregated = BarAggregator.aggregateWeekly(weekHours, openPartial: snap?.oneHour)
            return extend(aggregated.first)
        default:
            return extend(nil)
        }
    }

    /// Returns the cached or freshly-fetched in-progress snapshot for `instrument`,
    /// re-fetching from the server every `inProgressTtl`. Bursty arrival is deduped
    /// by `InProgressStore.awaitOrLaunch` — concurrent callers share one fetch.
    private func ensureInProgress(instrument: String) async -> InProgressSnapshot? {
        if let cached = await inProgressStore.freshSnapshot(instrument, ttl: inProgressTtl) {
            return cached
        }
        guard let session else { return nil }
        let wireInstrument = Self.toSlashedPair(instrument)
        return await inProgressStore.awaitOrLaunch(instrument) {
            do {
                let bars = try await session.fetchInProgressCandles(instrument: wireInstrument)
                // Positional layout (confirmed against live 2026-05-29 capture, ASK/BID interleaved):
                //   [0,1] MONTHLY  [2,3] WEEKLY  [4,5] DAILY  [6,7] 4H  [8,9] 1H
                //   [10,11] 30m  [12,13] 15m  [14,15] 10m  [16,17] 5m  [18,19] 1m  [20,21] 10s
                // Even indices are ASK, odd indices are BID. We use BID.
                func bid(at idx: Int) -> SwiftTrader.CandleBar? {
                    guard bars.count > idx else { return nil }
                    let b = bars[idx]
                    // The freshest in-progress buckets (1m/10s) come back all-zero from
                    // Dukascopy until the first tick lands in them. Used as a live-bar
                    // `openPartial` seed, a zero OHLC drags the aggregated bucket's low to 0
                    // via min(low, bid) and collapses the chart's price scale. Treat a
                    // non-positive snapshot as "not formed yet" (nil) — `seedLiveBucket`
                    // then opens the live bar at the tick price instead. Mirrors the
                    // wire-boundary filter in `fetchViaSession`.
                    guard b.low > 0, b.high > 0, b.open > 0, b.close > 0 else { return nil }
                    return SwiftTrader.CandleBar(
                        time: b.timeMillis, open: b.open, high: b.high, low: b.low,
                        close: b.close, volume: b.volume, partial: true
                    )
                }
                return InProgressSnapshot(
                    oneHour: bid(at: 9), oneMin: bid(at: 19),
                    fiveMin: bid(at: 17), fifteenMin: bid(at: 13), thirtyMin: bid(at: 11),
                    fetchedAt: Date()
                )
            } catch {
                nativeLog.error(
                    "in-progress fetch failed for \(wireInstrument, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                return nil
            }
        }
    }

    /// Bucket start (epoch ms) for a live tick under the given chart period — matches the
    /// alignment of cached/historical bars so the chart's `handleBar` cleanly replaces or
    /// appends. Most periods are simple epoch-grid floors; 4H/Daily defer to the NY session
    /// calendar that the offline aggregator uses.
    private static func liveBucketStartMs(tickMs: Int64, period: String) -> Int64 {
        switch period {
        case "ONE_MIN":      return (tickMs / 60_000) * 60_000
        case "THREE_MINS":   return (tickMs / 180_000) * 180_000
        case "FIVE_MINS":    return (tickMs / 300_000) * 300_000
        case "FIFTEEN_MINS": return (tickMs / 900_000) * 900_000
        case "THIRTY_MINS":  return (tickMs / 1_800_000) * 1_800_000
        case "ONE_HOUR":     return (tickMs / 3_600_000) * 3_600_000
        case "FOUR_HOURS":
            let d = Date(timeIntervalSince1970: Double(tickMs) / 1000.0)
            return Int64((NYTradingCalendar.fourHourBucketStart(at: d).timeIntervalSince1970 * 1000).rounded())
        case "DAILY":
            let d = Date(timeIntervalSince1970: Double(tickMs) / 1000.0)
            return Int64((NYTradingCalendar.bucketStart(at: d, period: .daily).timeIntervalSince1970 * 1000).rounded())
        case "WEEKLY":
            return BarAggregator.weekStartMs(Date(timeIntervalSince1970: Double(tickMs) / 1000.0))
        default:             return (tickMs / 60_000) * 60_000
        }
    }

    /// Standalone has a single shared disk cache (no JForex-server cache to purge
    /// remotely), so a "hard refresh" wipes both layers here: disk plist + in-memory
    /// for the instrument, plus the in-progress candle snapshot the live-bar seed
    /// would otherwise reuse for up to 30s. The session itself isn't reconnected —
    /// that would kill every other chart's live tick feed, and a healthy session
    /// re-fetching after a clean cache is what actually fixes a gap.
    func clearServerCache(instrument: String) async throws -> Int {
        await cache.clear(instrument: instrument)
        await inProgressStore.clear(instrument)
        return 0
    }

    /// User-invoked recovery from a stuck chart (the loading card's "Force reconnect"
    /// button). Rebuilds the session transport in place and re-subscribes quotes via
    /// `session.reconnect()` — the fix for a wedged/dead DDS channel or a failed session
    /// that a cache wipe (see `clearServerCache`) can't revive. `reconnect()` is debounced
    /// internally, so concurrent triggers collapse to one rebuild. This briefly interrupts
    /// every chart's live feed, which is acceptable for an explicit recovery action the
    /// user reaches for only when a chart is already broken.
    func forceReconnect() async throws {
        guard let session else { return }
        try await session.reconnect()
    }

    /// Re-assert the live quote subscription without rebuilding the transport — the cheap
    /// recovery a chart reaches for when it has history but no ticks. Debounced inside the
    /// session, so many charts nudging at once collapse to one re-send.
    func resubscribeLiveData() async {
        await session?.resubscribeQuotes()
    }

    /// Server mode waits ~12s for the JForex restart cycle; native has no
    /// reconnect step, so the chart can reload immediately after the cache wipe.
    var hardRefreshGraceSeconds: TimeInterval { 0 }

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
        // WEEKLY is native-only (server mode fetches it from jforex-server). Dukascopy
        // serves NO weekly history to the client, and its deep DAILY .bi5 files 503, so
        // we build weekly from ONE_HOUR — the same source as the daily chart (deep, via
        // validated hourly .bi5 + the warm 1H cache). `aggregateWeekly` groups the
        // weekend-stripped hourly bars into FX weeks; a weekly candle is exactly that
        // week's daily candles' span, so weekly stays consistent with the daily chart.
        // ~120 trading hours/week sizes the source fetch.
        if period == "WEEKLY" {
            return AggSpec(
                sourcePeriod: "ONE_HOUR", sourceSpan: 120, periodCode: "WEEKLY",
                bucket: { src, partial in BarAggregator.aggregateWeekly(src, openPartial: partial) }
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
        let aggKey = CandleCache.CacheKey(instrument: instrument, period: spec.periodCode, source: .aggregated)
        let neededSource = count * spec.sourceSpan
        let sourceSeconds = CandlePeriod.parse(source)?.seconds ?? (source == "ONE_HOUR" ? 3600 : 60)
        let targetSeconds = sourceSeconds * Int64(spec.sourceSpan)

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let srcLatest = await cache.latestTime(for: sourceKey)

        // Aggregated-cache-first: the derived series (4H/Daily/3m/5m/15m/30m) is itself cached
        // and persisted to disk. Serve it straight from disk when it's fresh, deep enough for
        // `count`, and the source hasn't formed a newer bucket — INDEPENDENT of how deep the
        // raw source is (source depth only matters for scroll-back / re-aggregation). So a
        // repeat open paints the cached candles immediately without touching the 1m/1H source.
        // The last condition catches a forward-fill that advanced the source past the agg's
        // last bucket (re-aggregate the tail in that case).
        let aggLatestOpt = await cache.latestTime(for: aggKey)
        if let aggLatest = aggLatestOpt,
           Self.isCacheFresh(latestMs: aggLatest, period: spec.periodCode),
           await cacheCoversWindow(key: aggKey, periodSeconds: targetSeconds, count: count),
           (srcLatest ?? aggLatest) < aggLatest + targetSeconds * 1000,
           // Don't serve an agg cache that's missing the just-closed bucket. `isCacheFresh`
           // is a days-scale gate (weekend/gap detection); on its own it happily serves a
           // cache 30 min behind, leaving a hole at the most-recent closed bucket (e.g. the
           // 08:45 15m bar). The source-advanced guard above only catches it when the 1m/1H
           // source is itself fresh — which it may not be in the launch window before the
           // forward-fill lands. This makes the staleness check tight enough to rebuild.
           Self.aggCacheReachesLatestClosedBucket(aggLatestMs: aggLatest, period: spec.periodCode, targetSeconds: targetSeconds) {
            let cached = await cache.getBars(for: aggKey)
            // Don't serve a derived cache that has a SPURIOUS internal hole. The aggregated cache
            // can persist a non-weekend gap — a rebuild that ran while the 1m source was
            // transiently gappy aggregated+stored the hole; the source later healed but nothing
            // re-checks the derived cache (the background gap-repair only scans 1m/1H), so the
            // hole is served forever. Fall through to rebuild from the now-complete source, which
            // `merge` stitches (it appends the missing timestamps). Bounded to the served window
            // so an out-of-window deep hole can't cause repeated rebuilds.
            if !Self.hasSpuriousGap(Array(cached.suffix(count)), periodSeconds: targetSeconds) {
                nativeLog.debug("fetchAggregated \(instrument, privacy: .public) \(spec.periodCode, privacy: .public): served cache (aggLatest=\(aggLatest), srcLatest=\(srcLatest ?? -1))")
                return cached
            }
            nativeLog.notice("fetchAggregated \(instrument, privacy: .public) \(spec.periodCode, privacy: .public): cached series has a non-weekend gap — rebuilding from source to heal")
        }
        nativeLog.debug("fetchAggregated \(instrument, privacy: .public) \(spec.periodCode, privacy: .public): rebuilding (aggLatest=\(aggLatestOpt ?? -1), srcLatest=\(srcLatest ?? -1))")

        // Otherwise (re)build the window. Ensure the raw source covers it, but fetch ONLY the
        // MISSING slice — never refetch bars already on disk. `fetchCandles` has already
        // forward-filled the source's recent tail, so the only gap here is DEPTH: top up the
        // older bars before the earliest cached one. A genuinely empty cache fetches the full
        // window; a partially-deep cache fetches just the shortfall.
        var merged = await cache.getBars(for: sourceKey)
        var partial: SwiftTrader.CandleBar?
        let windowStartMs = nowMs - Int64(neededSource) * sourceSeconds * 1000
        let closureSlackMs: Int64 = 4 * 24 * 60 * 60 * 1000   // mirrors cacheCoversWindow

        if merged.isEmpty {
            let fetched = try await fetchRawCandles(
                instrument: instrument, period: source, count: neededSource
            )
            merged = await cache.merge(fetched, for: sourceKey)
            partial = fetched.last.flatMap { $0.partial ? $0 : nil }
        } else if let earliest = merged.first?.time, earliest > windowStartMs + closureSlackMs {
            let missing = Int((earliest - windowStartMs) / (sourceSeconds * 1000)) + 2
            let older = try await fetchRawCandles(
                instrument: instrument, period: source, count: missing, before: earliest
            )
            merged = await cache.merge(older, for: sourceKey)
            nativeLog.info("fetchAggregated \(instrument, privacy: .public) \(spec.periodCode, privacy: .public): deepened source by \(older.count) \(source, privacy: .public) bars (window needs \(neededSource))")
        }
        // else: cache already covers the window — aggregate it as-is, no fetch.

        // Aggregate only the recent `neededSource` bars, not the entire (possibly years-deep,
        // prefetched) source cache. Scroll-back fills older buckets via fetchEarlierAggregated.
        let window = merged.count > neededSource ? Array(merged.suffix(neededSource)) : merged
        let aggregated = spec.bucket(window, partial)
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

    /// Pull any bars between the cache's latest and the most recent possible bar (the
    /// last session close, since FX is 24/5). No-op when the cache is current. Skipped
    /// for caches more than `forwardGapFillCap` bars behind — those land on the regular
    /// fresh-fetch path via `isCacheFresh` instead of paging forever. Called at the top
    /// of every `fetchCandles` (raw periods directly; aggregated targets fill the source
    /// 1H/1m so the re-aggregation below builds on fresh data).
    private func forwardGapFillIfNeeded(
        instrument: String, period: String
    ) async {
        // Pre-auth (no session, no injected fetch) the stub `rawFetch` always throws —
        // running it logs a misleading "missing credentials" error per call across all
        // 28 default instruments. The live coordinator that gets built post-auth runs
        // the fill for real.
        guard canFetch else { return }
        // Only the basic stored periods make sense to forward-fill — aggregated targets
        // get fixed via their source. Unknown periods fall through.
        guard let cp = CandlePeriod.parse(period) else { return }
        let key = CandleCache.CacheKey(instrument: instrument, period: period, source: .server)
        guard let latestMs = await cache.latestTime(for: key) else { return }
        let cadenceMs = cp.seconds * 1000
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // Clamp expected-newest to the last session close — over a weekend that's Friday
        // 17:00 ET, not "now," so a cache already at Friday close doesn't refetch.
        let referenceMs = min(nowMs, NYTradingCalendar.lastSessionCloseMs(at: Date()))
        let gapMs = referenceMs - latestMs
        if gapMs <= cadenceMs { return }
        // Bounded incremental fill. A 14-day window @ 1H = 336 bars; @ 1m = 20k — past
        // that, let the staleness gate take over with a clean fetch instead.
        let cap = Self.forwardGapFillCap(period: period)
        let count = Int(gapMs / cadenceMs) + 2
        guard count <= cap else { return }
        // Anchor the fetch window to the last session close, NOT to "now." When the app
        // launches over a weekend, "now" sits in closed time — the window
        // [now − count·cadence, now] is entirely Sat/Sun, every returned bar is flagged
        // by `stripWeekendFillers`, and we'd merge zero bars while observing
        // `history ... -> N bars in Xms` in the log. `before = referenceMs + cadenceMs`
        // gives us a window ending at the slot after the close, so the server returns
        // the actual final-hour Friday bars we're missing.
        let beforeMs = referenceMs + cadenceMs
        nativeLog.info(
            "forwardGapFill \(instrument, privacy: .public) \(period, privacy: .public): gap=\(gapMs / 1000)s, fetching count=\(count) before=\(beforeMs)"
        )
        do {
            let bars = try await fetchRawCandles(
                instrument: instrument, period: period, count: count, before: beforeMs
            )
            if !bars.isEmpty {
                _ = await cache.merge(bars, for: key)
                nativeLog.info(
                    "forwardGapFill \(instrument, privacy: .public) \(period, privacy: .public): pulled \(bars.count) bars to catch up \(gapMs / 1000)s"
                )
            } else {
                nativeLog.warning(
                    "forwardGapFill \(instrument, privacy: .public) \(period, privacy: .public): fetch returned 0 bars (window may have been all weekend / stripped)"
                )
            }
        } catch {
            nativeLog.warning(
                "forwardGapFill \(instrument, privacy: .public) \(period, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Max bars a single forward-fill will pull. Past this the staleness gate is the
    /// right tool (one clean fetch) instead of paging incrementally — chosen so a
    /// typical "app was off for a few days" closes cleanly without a long catch-up.
    private static func forwardGapFillCap(period: String) -> Int {
        switch period {
        case "ONE_MIN": return 20_000     // ~14 days
        case "ONE_HOUR": return 5_000     // ~7 months (FX trading hours)
        default: return 2_000
        }
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
    private func cacheCoversWindow(key: CandleCache.CacheKey, periodSeconds: Int64, count: Int) async -> Bool {
        guard let earliest = await cache.earliestTime(for: key) else { return false }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let windowStartMs = nowMs - Int64(count) * periodSeconds * 1000
        // After weekend-filler stripping the oldest real bar can sit a closure (weekend or
        // holiday) past the requested window start even when fully fetched, so allow ~4 days
        // of slack. A genuinely too-shallow cache misses by weeks/months and still refetches.
        let closureSlackMs: Int64 = 4 * 24 * 60 * 60 * 1000
        return earliest <= windowStartMs + closureSlackMs
    }

    /// Bridges a raw history request to `DukascopySession.fetchHistoryDetailed`: computes the
    /// `[start, end]` window and maps `DukascopyClient.CandleBar` → `SwiftTrader.CandleBar`.
    /// History is fetched on the **Bid** side to match server mode. The newest bar is
    /// flagged `partial` only when its bucket hasn't closed (the live-forming candle);
    /// scroll-back windows (`before` set) never trip it. A non-empty `missingWindows`
    /// on the result is logged as a warning — the gap-detection / recovery pass picks
    /// these up via `CandleCache.findGaps` rather than the call-site retrying inline.
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
            let result = try await session.fetchHistoryDetailed(
                instrument: wireInstrument, side: .bid, period: cp,
                startSeconds: startSec, endSeconds: endSec
            )
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            nativeLog.debug("history \(instrument, privacy: .public) \(period, privacy: .public) -> \(result.bars.count) bars in \(ms)ms (missing=\(result.missingWindows.count))")
            if !result.isComplete {
                nativeLog.warning("history \(instrument, privacy: .public) \(period, privacy: .public) PARTIAL: \(result.missingWindows.count) window(s) still missing after retry")
            }
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let periodMs = cp.seconds * 1000
            return result.bars
                .sorted { $0.timeMillis < $1.timeMillis }
                .compactMap { bar -> SwiftTrader.CandleBar? in
                    // Dukascopy occasionally emits boundary/filler bars with zero or
                    // negative OHLC values around session close — slipping one through
                    // collapses the chart's price scale (a single 0-prefixed bar makes
                    // every other candle invisible) and corrupts EMA/ATR. Drop them at
                    // the wire boundary so the cache never sees a non-positive price.
                    guard bar.low > 0, bar.high > 0, bar.open > 0, bar.close > 0 else {
                        nativeLog.warning(
                            "history \(instrument, privacy: .public) \(period, privacy: .public): dropping bar t=\(bar.timeMillis) with non-positive price (o=\(bar.open) h=\(bar.high) l=\(bar.low) c=\(bar.close))"
                        )
                        return nil
                    }
                    return SwiftTrader.CandleBar(
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

    /// True if `bars` has an internal hole wider than one bucket that is NOT a weekend/holiday
    /// closure — i.e. a spurious gap in a derived series that should be healed by re-aggregating
    /// from the (gap-free) source. Weekend/holiday closures are expected and ignored (via
    /// `NYTradingCalendar.isClosedThroughout`, which early-exits on the first trading slot).
    /// A raw 1H/1m live bar may only inherit OHLC from an in-progress partial that belongs to the
    /// SAME bucket. The cached in-progress snapshot can lag by a bucket at a rollover (30s TTL, and
    /// `seedLiveBucket` runs only once per bucket), so an unchecked seed grafts the PREVIOUS bucket's
    /// OHLC — e.g. a 1H bar inheriting the prior hour's high, which then sticks for the whole hour
    /// because nothing re-seeds it. Returns the partial only when its `time` matches `bucketMs`;
    /// otherwise the caller opens the live bar fresh at the tick. (The derived periods already guard
    /// this via their `last.time == bucketMs` / `sp.time == bucketMs` checks.)
    static func inProgressSeed(_ partial: SwiftTrader.CandleBar?, bucketMs: Int64) -> SwiftTrader.CandleBar? {
        guard let p = partial, p.time == bucketMs else { return nil }
        return p
    }

    static func hasSpuriousGap(_ bars: [SwiftTrader.CandleBar], periodSeconds: Int64) -> Bool {
        guard bars.count >= 2, periodSeconds > 0 else { return false }
        let cadenceMs = periodSeconds * 1000
        for i in 1..<bars.count {
            let prev = bars[i - 1].time, curr = bars[i].time
            if curr <= prev + cadenceMs { continue }
            if NYTradingCalendar.isClosedThroughout(fromMs: prev + cadenceMs, toMs: curr - cadenceMs) { continue }
            return true
        }
        return false
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

    /// True when an aggregated cache reaches the most-recent CLOSED bucket — i.e. it isn't
    /// missing a bar that has already closed. Used to gate the aggregated-cache-first path so
    /// a cache one bucket behind (the just-closed bar) triggers a rebuild instead of being
    /// served with a hole. Only the fixed epoch-grid intraday periods (3m/5m/15m/30m) use a
    /// simple floor; session-aligned 4H/Daily/Weekly keep the prior guards (return true). When
    /// the market is closed no new bucket forms, so the cache can't be missing one (return true).
    static func aggCacheReachesLatestClosedBucket(
        aggLatestMs: Int64, period: String, targetSeconds: Int64, now: Date = Date()
    ) -> Bool {
        guard ["THREE_MINS", "FIVE_MINS", "FIFTEEN_MINS", "THIRTY_MINS"].contains(period) else { return true }
        guard !NYTradingCalendar.isMarketClosed(at: now), !NYTradingCalendar.isFXHoliday(at: now) else { return true }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let targetMs = targetSeconds * 1000
        let currentBucketStart = (nowMs / targetMs) * targetMs
        // The latest completed bar must be at least the just-closed bucket (currentBucketStart − 1).
        return aggLatestMs >= currentBucketStart - targetMs
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
    // Background requests (the prefetcher) are capped below `limit` so they can never fill
    // every slot, and a freed slot always goes to a waiting FOREGROUND request first — a
    // user-driven (visible-chart) load never queues behind the prefetcher's slow deep
    // fetches, which previously starved the focused chart for tens of seconds at launch.
    private let backgroundLimit: Int
    private var active = 0
    private var activeBackground = 0
    private var fgQueue: [CheckedContinuation<Void, Never>] = []
    private var bgQueue: [CheckedContinuation<Void, Never>] = []
    // Foreground (user-driven) requests in flight. The background prefetcher also gates on
    // this hitting zero so it only *submits* in the gaps between visible loads.
    private var foregroundInFlight = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
        self.backgroundLimit = max(1, limit - 2)   // reserve ≥2 slots for foreground
    }

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
            await acquire(foreground: foreground)
            defer { Task { await self.release(foreground: foreground) } }
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

    private func acquire(foreground: Bool) async {
        if active < limit, foreground || activeBackground < backgroundLimit {
            active += 1
            if !foreground { activeBackground += 1 }
            return
        }
        await withCheckedContinuation { c in
            if foreground { fgQueue.append(c) } else { bgQueue.append(c) }
        }
        // Resumed by release(), which accounts the slot before resuming.
    }

    private func release(foreground: Bool) {
        active -= 1
        if !foreground { activeBackground -= 1 }
        // Hand the freed slot to a waiting FOREGROUND request first; only feed the
        // background queue when no foreground work is waiting and a background slot is free.
        if !fgQueue.isEmpty {
            active += 1
            fgQueue.removeFirst().resume()
        } else if !bgQueue.isEmpty, activeBackground < backgroundLimit {
            active += 1
            activeBackground += 1
            bgQueue.removeFirst().resume()
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
        // Background QoS: the warm-up does heavy bulk `.bi5` LZMA decoding. Running it at low
        // priority lets the scheduler favour foreground (visible-chart) loads, so the prefetch
        // can't peg every core and leave the user staring at empty charts. The whole fetch
        // chain (coalescer task → bulk download → decode) inherits this priority.
        task = Task(priority: .background) { [self] in await runLoop() }
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

        // After the depth pass we have the full target window on disk for every pair —
        // now scan for mid-series holes (left behind by transient bulk timeouts or by
        // older runs without the non-positive-price filter) and refill them. Aggregated
        // periods (4H/Daily/3m/5m/15m/30m) rebuild from these, so fixing 1H + 1m fixes
        // every visible timeframe.
        if Task.isCancelled { return }
        await gapScan()
    }

    /// Scan every (instrument, basic period) for missing-bar runs and refill them.
    /// Same pacing as the depth pass: one request at a time, gated on foreground idle
    /// so user-driven loads always win. Logs at every boundary so the run is traceable
    /// in `log stream --predicate 'subsystem == "com.swifttrader" AND category == "native"'`.
    private func gapScan() async {
        nativeLog.info("gap-scan: beginning sweep of \(self.instruments.count) instruments × [ONE_HOUR, ONE_MIN]")
        let t0 = Date()
        var seriesScanned = 0
        var seriesWithGaps = 0
        var totalGapsFound = 0
        var totalGapsFilled = 0
        var totalBarsPulled = 0

        for period in Self.gapScanPeriods {
            for instrument in instruments {
                if Task.isCancelled {
                    nativeLog.info("gap-scan: cancelled mid-sweep — \(totalGapsFilled)/\(totalGapsFound) gaps filled so far")
                    return
                }
                seriesScanned += 1
                let gaps = await cache.findGaps(instrument: instrument, period: period)
                if gaps.isEmpty { continue }
                seriesWithGaps += 1
                totalGapsFound += gaps.count
                let missingTotal = gaps.reduce(0) { $0 + $1.missingBars }
                nativeLog.info(
                    "gap-scan \(instrument, privacy: .public) \(period, privacy: .public): found \(gaps.count) gap(s) totalling \(missingTotal) bar(s)"
                )

                // Cap per-series work — a runaway cache (e.g. years of 1m with a hole every
                // hour) shouldn't pin the prefetcher forever. Per-period cap is roomy enough
                // that real-world gap counts (single digits per pair) never trip it.
                let toFix = gaps.prefix(Self.maxGapsPerSeries)
                for (idx, gap) in toFix.enumerated() {
                    if Task.isCancelled {
                        nativeLog.info("gap-scan: cancelled mid-sweep — \(totalGapsFilled)/\(totalGapsFound) gaps filled so far")
                        return
                    }
                    await awaitIdle()
                    if Task.isCancelled { return }
                    nativeLog.debug(
                        "gap-fill \(instrument, privacy: .public) \(period, privacy: .public) [\(idx + 1)/\(toFix.count)]: window [\(gap.fromMs), \(gap.toMs)] = \(gap.missingBars) bar(s)"
                    )
                    let cadenceMs = Self.cadenceMs(period)
                    // Anchor the fetch at the right edge of the gap; count = missing + slop
                    // so the underlying server window covers the full gap.
                    let beforeMs = gap.toMs + cadenceMs
                    let count = gap.missingBars + 2
                    let bars = await fetchPage(instrument, period, beforeMs, count)
                    if bars.isEmpty {
                        nativeLog.warning(
                            "gap-fill \(instrument, privacy: .public) \(period, privacy: .public) [\(gap.fromMs), \(gap.toMs)]: fetch returned 0 bars (CDN may still be missing this chunk)"
                        )
                    } else {
                        totalGapsFilled += 1
                        totalBarsPulled += bars.count
                        nativeLog.info(
                            "gap-fill \(instrument, privacy: .public) \(period, privacy: .public) [\(gap.fromMs), \(gap.toMs)]: pulled \(bars.count) bars"
                        )
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }

        let elapsed = Int(Date().timeIntervalSince(t0))
        nativeLog.info(
            "gap-scan complete: scanned \(seriesScanned) series, \(seriesWithGaps) had gaps, filled \(totalGapsFilled)/\(totalGapsFound) gaps (pulled \(totalBarsPulled) bars) in \(elapsed)s"
        )
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

    /// Basic stored periods the gap-scan walks. Aggregated periods rebuild from these.
    private static let gapScanPeriods: [String] = ["ONE_HOUR", "ONE_MIN"]
    /// Bound per-series gap-fill so a pathological cache (e.g. every other bar missing)
    /// can't pin the prefetcher. Real-world gap counts on the affected pairs are single
    /// digits, so this is a generous safety cap, not a tuning knob.
    private static let maxGapsPerSeries = 32

    private static func cadenceMs(_ period: String) -> Int64 {
        switch period {
        case "ONE_MIN": return 60_000
        case "ONE_HOUR": return 3_600_000
        case "DAILY": return 86_400_000
        default: return 60_000
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

/// Snapshot of the server's in-progress candle set for one instrument. Only the source
/// periods we use are kept: 1H drives 4H/Daily/1H-raw seeds, 1m drives 3m/5m/15m/30m
/// and 1m-raw seeds. Monthly/Weekly/4H/Daily/30m/15m/10m/5m/10s entries in the wire
/// response are dropped — our chart bucketing is NY-session-aligned for 4H/Daily and
/// epoch-grid for the fixed-grid intraday periods, but the server's in-progress 4H
/// uses pure UTC alignment (verified 2026-05-29: server 4H @ 20:00 UTC ≠ NY 4H bucket
/// which spans 17:00 ET → 21:00 ET). Aggregating from 1H/1m via `BarAggregator` keeps
/// bucket alignment in our hands.
struct InProgressSnapshot: Sendable {
    let oneHour: SwiftTrader.CandleBar?
    let oneMin: SwiftTrader.CandleBar?
    // Epoch-grid intraday partials (same alignment as the chart's fixed-grid buckets), so a
    // mid-bucket chart open seeds the live bar with the full OHLC the server has accumulated
    // since the bucket opened — not a fresh candle starting at the current tick.
    let fiveMin: SwiftTrader.CandleBar?
    let fifteenMin: SwiftTrader.CandleBar?
    let thirtyMin: SwiftTrader.CandleBar?
    let fetchedAt: Date
}

actor InProgressStore {
    private var byInstrument: [String: InProgressSnapshot] = [:]
    private var inFlight: [String: Task<InProgressSnapshot?, Never>] = [:]

    /// Returns the cached snapshot only if it's still within `ttl`; otherwise nil.
    func freshSnapshot(_ instrument: String, ttl: TimeInterval) -> InProgressSnapshot? {
        guard let s = byInstrument[instrument],
              Date().timeIntervalSince(s.fetchedAt) < ttl else { return nil }
        return s
    }

    /// Drop the cached snapshot for one instrument so the next live-bar seed
    /// re-fetches from the server. Used by hard refresh to ensure a wiped chart
    /// doesn't immediately repopulate the just-cleared 4H/Daily live bar from a
    /// stale in-progress snapshot.
    func clear(_ instrument: String) {
        byInstrument.removeValue(forKey: instrument)
    }

    /// Run `work` once per instrument even under burst arrival: concurrent callers
    /// for the same instrument share the in-flight task instead of stampeding the
    /// server (verified 2026-05-29: pre-dedup, the first ticks of a session triggered
    /// 4 parallel in-progress fetches per pair).
    func awaitOrLaunch(
        _ instrument: String,
        work: @Sendable @escaping () async -> InProgressSnapshot?
    ) async -> InProgressSnapshot? {
        if let pending = inFlight[instrument] {
            return await pending.value
        }
        let task = Task<InProgressSnapshot?, Never> { await work() }
        inFlight[instrument] = task
        let result = await task.value
        inFlight[instrument] = nil
        if let r = result { byInstrument[instrument] = r }
        return result
    }
}
