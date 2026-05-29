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
    /// Per-instrument cache of the server's in-progress candle set (the wire path the
    /// JForex SDK uses internally for `getHistory().getBar(period, BID, 0)`). Re-fetched
    /// every `inProgressTtl` so the seed for a forming bucket reflects the server's
    /// authoritative OHLC instead of being derived from our cached 1m bars.
    private let inProgressStore = InProgressStore()
    private let inProgressTtl: TimeInterval = 30
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
        guard let session else {
            return AsyncThrowingStream { $0.finish(throwing: NativeProviderError.missingCredentials) }
        }
        let wireInstrument = Self.toSlashedPair(instrument)
        return AsyncThrowingStream<SwiftTrader.CandleBar, Error> { continuation in
            let task = Task {
                // Subscribe to quotes for THIS instrument only. The session unions
                // additions across all open streams, so opening AUD/CAD multi-tf
                // doesn't pull ticks for the other 27 default pairs.
                try? await session.ensureSubscribedQuotes([wireInstrument])
                var current: SwiftTrader.CandleBar?
                for await tick in await session.tickStream() {
                    if Task.isCancelled { break }
                    guard tick.instrument == wireInstrument else { continue }
                    guard let bid = tick.bestBid?.doubleValue else { continue }
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
            guard let b = bar else {
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
            return extend(snap?.oneHour)
        case "ONE_MIN":
            return extend(snap?.oneMin)
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
            let granularityMs: Int64 = period == "THREE_MINS" ? 180_000
                : period == "FIVE_MINS" ? 300_000
                : period == "FIFTEEN_MINS" ? 900_000
                : 1_800_000
            // Tail = a few buckets' worth of 1m so re-aggregation is O(constant) not O(cache).
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
                    return SwiftTrader.CandleBar(
                        time: b.timeMillis, open: b.open, high: b.high, low: b.low,
                        close: b.close, volume: b.volume, partial: true
                    )
                }
                return InProgressSnapshot(
                    oneHour: bid(at: 9), oneMin: bid(at: 19), fetchedAt: Date()
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
        default:             return (tickMs / 60_000) * 60_000
        }
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
        let aggKey = CandleCache.CacheKey(instrument: instrument, period: spec.periodCode, source: .aggregated)
        let neededSource = count * spec.sourceSpan
        let sourceSeconds = CandlePeriod.parse(source)?.seconds ?? (source == "ONE_HOUR" ? 3600 : 60)
        let targetSeconds = sourceSeconds * Int64(spec.sourceSpan)

        // Is the raw source already fresh AND deep enough (so we wouldn't refetch it)?
        var sourceFresh = false
        if let srcLatest = await cache.latestTime(for: sourceKey),
           Self.isCacheFresh(latestMs: srcLatest, period: source),
           await cacheCoversWindow(key: sourceKey, periodSeconds: sourceSeconds, count: neededSource) {
            sourceFresh = true
        }

        // Aggregated-cache-first: the derived series (4H/Daily/3m/5m/15m/30m) is itself cached
        // and persisted to disk. When the source is already up-to-date, a fresh, deep-enough
        // cached aggregation is authoritative — serve it directly instead of re-running the
        // per-bar NY-calendar bucketing over the deep source on every launch (the dominant
        // startup CPU cost). Gating on `sourceFresh` keeps the derived series consistent with
        // the raw series: if the source is stale and about to be refetched, we re-aggregate.
        if sourceFresh,
           let aggLatest = await cache.latestTime(for: aggKey),
           Self.isCacheFresh(latestMs: aggLatest, period: spec.periodCode),
           await cacheCoversWindow(key: aggKey, periodSeconds: targetSeconds, count: count) {
            return await cache.getBars(for: aggKey)
        }

        let merged: [SwiftTrader.CandleBar]
        var partial: SwiftTrader.CandleBar?
        if sourceFresh {
            merged = await cache.getBars(for: sourceKey)
        } else {
            let fetched = try await fetchRawCandles(
                instrument: instrument, period: source, count: neededSource
            )
            merged = await cache.merge(fetched, for: sourceKey)
            partial = fetched.last.flatMap { $0.partial ? $0 : nil }
        }

        // Aggregate only the recent `neededSource` bars, not the entire (possibly years-deep,
        // prefetched) source cache. Otherwise every chart re-runs per-bar NY-calendar bucket
        // math over ~12k source bars at startup — the dominant CPU cost. Scroll-back fills
        // older buckets on demand via fetchEarlierAggregated.
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
