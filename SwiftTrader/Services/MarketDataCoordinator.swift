import Foundation

final class MarketDataCoordinator: MarketDataProviding, Sendable {
    /// Per-request bar limit when gap-filling. Matches the server's MAX_FORWARD_GAP_BARS.
    static let gapBarLimit = 5000
    /// Max gap-fill iterations to bound runaway pagination on years-stale caches.
    static let maxGapFillIterations = 4

    private let apiService: ForexAPIService
    private let host: String
    private let port: Int
    let cache: CandleCache
    /// Injectable wall clock — lets tests pin "now" for weekend/staleness logic.
    private let now: @Sendable () -> Date

    init(host: String = "localhost", port: Int = 8080, cache: CandleCache = CandleCache(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.apiService = ForexAPIService(baseURL: URL(string: "http://\(host):\(port)")!)
        self.host = host
        self.port = port
        self.cache = cache
        self.now = now
    }

    func fetchInstruments() async throws -> [String] {
        try await apiService.fetchInstruments()
    }

    func fetchCandles(
        instrument: String = "EURUSD",
        period: String = "ONE_MIN",
        count: Int = 200,
        rebucketing: Bool = false,
        side: ChartSide = .bid   // server mode (jforex-server) is bid-only; side ignored
    ) async throws -> [CandleBar] {
        if let target = AggregatedPeriod(period), rebucketing || target.alwaysAggregated {
            return try await fetchAggregated(instrument: instrument, target: target, count: count)
        }

        let key = CandleCache.CacheKey(instrument: instrument, period: period, source: .server)
        if let latest = await cache.latestTime(for: key),
           !isStale(latest: latest, period: period) {
            // Warm cache: fetch only the gap. The live partial bar will arrive shortly
            // via the WebSocket — no need for a separate tail request here.
            try await gapFill(serverKey: key, instrument: instrument, period: period, latest: latest)
            return await cache.getBars(for: key)
        }

        let fetched = try await apiService.fetchHistory(instrument: instrument, period: period, count: count)
        let cached = await cache.merge(fetched, for: key)

        if let last = fetched.last, last.partial {
            return cached + [last]
        }
        return cached
    }

    /// Loop fetching forward from `latest` until the server stops returning full pages
    /// or we hit `maxGapFillIterations`. Each iteration merges into `serverKey`.
    private func gapFill(
        serverKey: CandleCache.CacheKey, instrument: String, period: String, latest initialLatest: Int64
    ) async throws {
        // Weekend storm-stopper: on the Fri 17:00 ET → Sun 17:00 ET closure the
        // newest bar that can exist is the Friday close. Once the cache holds it,
        // issue ZERO requests no matter how many reconnects / tab-switches /
        // WS-drops re-trigger this. The one legitimate fill (cold/behind cache)
        // still runs because then `initialLatest < lastSessionClose`.
        if initialLatest >= NYTradingCalendar.lastSessionCloseMs(at: now()) { return }

        var latest = initialLatest
        for _ in 0..<Self.maxGapFillIterations {
            // Subtract 1 ms so the boundary bar is re-emitted; merge dedupes by timestamp
            // and lets server-side bar corrections propagate.
            let fetched = try await apiService.fetchHistory(
                instrument: instrument, period: period, count: Self.gapBarLimit, after: latest - 1
            )
            if fetched.isEmpty { return }
            await cache.merge(fetched, for: serverKey)
            if fetched.count < Self.gapBarLimit { return }
            guard let newLatest = await cache.latestTime(for: serverKey), newLatest > latest else { return }
            latest = newLatest
        }
    }

    /// Period-aware staleness threshold. If the cache's latest bar is older than this,
    /// fall back to a fresh full-N fetch instead of a (potentially huge) gap-fill loop.
    private func isStale(latest: Int64, period: String) -> Bool {
        let t = now()
        let nowMs = Int64(t.timeIntervalSince1970 * 1000)
        // Clamp the reference to the newest bar that can exist: over the weekend
        // closure that's the Friday close, not "now" — so a cache already at the
        // Friday close is NOT considered stale (no needless full refetch).
        let expectedNewestMs = min(nowMs, NYTradingCalendar.lastSessionCloseMs(at: t))
        let ageMs = expectedNewestMs - latest
        if ageMs <= 0 { return false }
        let thresholdMs: Int64 = switch period {
        case "FOUR_HOURS", "DAILY", "WEEKLY", "MONTHLY":
            365 * 24 * 60 * 60 * 1000
        case "ONE_MIN":
            // Must stay well under the gap-fill reach (maxGapFillIterations ×
            // gapBarLimit ≈ ~14 days of 1-min) so a stale 1m cache forces a clean
            // full refetch instead of an incomplete gap-fill that leaves a hole.
            3 * 24 * 60 * 60 * 1000
        default:
            30 * 24 * 60 * 60 * 1000
        }
        return ageMs > thresholdMs
    }

    /// Fetch bars older than the earliest cached bar for this key.
    func fetchEarlierCandles(
        instrument: String,
        period: String,
        count: Int = 1000,
        rebucketing: Bool = false,
        side: ChartSide = .bid
    ) async throws -> [CandleBar] {
        if let target = AggregatedPeriod(period), rebucketing || target.alwaysAggregated {
            return try await fetchEarlierAggregated(
                instrument: instrument, target: target, count: count
            )
        }

        let key = CandleCache.CacheKey(instrument: instrument, period: period, source: .server)
        guard let before = await cache.earliestTime(for: key) else {
            return await cache.getBars(for: key)
        }
        let fetched = try await apiService.fetchHistory(
            instrument: instrument, period: period, count: count, before: before
        )
        return await cache.merge(fetched, for: key)
    }

    /// Write a completed WebSocket bar into the shared cache.
    /// For the aggregated path, `period` is the source period (`ONE_HOUR` for
    /// 4H/Daily, `ONE_MIN` for 3m) — derived bars are rebuilt on the fly and
    /// cached separately in `streamCandles`.
    func cacheBar(
        _ bar: CandleBar, instrument: String, period: String, rebucketing: Bool = false, side: ChartSide = .bid
    ) async {
        let key = CandleCache.CacheKey(instrument: instrument, period: period, source: .server)
        await cache.appendBar(bar, for: key)
    }

    func streamCandles(
        instrument: String = "EURUSD",
        period: String = "ONE_MIN",
        rebucketing: Bool = false,
        side: ChartSide = .bid
    ) -> AsyncThrowingStream<CandleBar, Error> {
        if let target = AggregatedPeriod(period), rebucketing || target.alwaysAggregated {
            return aggregatedStream(instrument: instrument, target: target)
        }
        return ForexWebSocketService(
            instrument: instrument, period: period, host: host, port: port
        ).bars()
    }

    func clearServerCache(instrument: String) async throws -> Int {
        try await apiService.clearCache(instrument: instrument)
    }

    func forceReconnect() async throws {
        try await apiService.forceReconnect()
    }

    // MARK: - Aggregation helpers

    private func fetchAggregated(
        instrument: String, target: AggregatedPeriod, count: Int
    ) async throws -> [CandleBar] {
        let source = target.sourcePeriod
        let hourlyKey = CandleCache.CacheKey(instrument: instrument, period: source, source: .server)

        // Warm-cache path: gap-fill the underlying source cache instead of re-fetching
        // `count * sourceSpan` bars. Re-aggregate the full merged source array as before
        // so the .aggregated cache stays consistent.
        if let latest = await cache.latestTime(for: hourlyKey),
           !isStale(latest: latest, period: source) {
            try await gapFill(
                serverKey: hourlyKey, instrument: instrument, period: source, latest: latest
            )
            let merged = await cache.getBars(for: hourlyKey)
            let aggregated = BarAggregator.aggregate(
                hourly: merged, openPartial: nil, target: target
            )
            let aggKey = CandleCache.CacheKey(
                instrument: instrument, period: target.periodCode, source: .aggregated
            )
            return await cache.merge(aggregated, for: aggKey)
        }

        let hourlyCount = count * target.sourceSpan
        let fetched = try await apiService.fetchHistory(
            instrument: instrument, period: source, count: hourlyCount
        )
        let merged = await cache.merge(fetched, for: hourlyKey)
        let partial = fetched.last.flatMap { $0.partial ? $0 : nil }

        let aggregated = BarAggregator.aggregate(
            hourly: merged, openPartial: partial, target: target
        )
        let aggKey = CandleCache.CacheKey(
            instrument: instrument, period: target.periodCode, source: .aggregated
        )
        let cached = await cache.merge(aggregated, for: aggKey)
        if let last = aggregated.last, last.partial {
            return cached + [last]
        }
        return cached
    }

    private func fetchEarlierAggregated(
        instrument: String, target: AggregatedPeriod, count: Int
    ) async throws -> [CandleBar] {
        let source = target.sourcePeriod
        let hourlyKey = CandleCache.CacheKey(instrument: instrument, period: source, source: .server)
        guard let before = await cache.earliestTime(for: hourlyKey) else {
            let key = CandleCache.CacheKey(
                instrument: instrument, period: target.periodCode, source: .aggregated
            )
            return await cache.getBars(for: key)
        }
        let hourlyCount = count * target.sourceSpan
        let fetched = try await apiService.fetchHistory(
            instrument: instrument, period: source, count: hourlyCount, before: before
        )
        let merged = await cache.merge(fetched, for: hourlyKey)
        let aggregated = BarAggregator.aggregate(
            hourly: merged, openPartial: nil, target: target
        )
        let aggKey = CandleCache.CacheKey(
            instrument: instrument, period: target.periodCode, source: .aggregated
        )
        return await cache.merge(aggregated, for: aggKey)
    }

    private func aggregatedStream(
        instrument: String, target: AggregatedPeriod
    ) -> AsyncThrowingStream<CandleBar, Error> {
        let cache = self.cache
        let host = self.host
        let port = self.port

        let source = target.sourcePeriod

        return AsyncThrowingStream { continuation in
            let task = Task {
                let hourly = ForexWebSocketService(
                    instrument: instrument, period: source, host: host, port: port
                ).bars()
                do {
                    for try await hourBar in hourly {
                        if Task.isCancelled { break }
                        let hourlyKey = CandleCache.CacheKey(
                            instrument: instrument, period: source, source: .server
                        )
                        if !hourBar.partial {
                            await cache.appendBar(hourBar, for: hourlyKey)
                        }
                        let cachedHourly = await cache.getBars(for: hourlyKey)
                        // Partial bars fire at tick rate; re-aggregating the entire source
                        // history per tick pegs the ICU timezone lock (session-aligned only;
                        // 3m's fixed grid has no ICU cost). Only the tail can affect the live
                        // bucket — take a window large enough to cover it. Completed source
                        // bars still get a full aggregation so the aggregated cache stays
                        // complete.
                        let inputs: [CandleBar]
                        if hourBar.partial {
                            let tail: Int
                            switch target {
                            case .daily: tail = 30
                            case .fourHours: tail = 6
                            case .threeMinutes: tail = 10
                            }
                            inputs = Array(cachedHourly.suffix(tail))
                        } else {
                            inputs = cachedHourly
                        }
                        let partial = hourBar.partial ? hourBar : nil
                        let aggregated = BarAggregator.aggregate(
                            hourly: inputs, openPartial: partial, target: target
                        )
                        let aggKey = CandleCache.CacheKey(
                            instrument: instrument, period: target.periodCode, source: .aggregated
                        )
                        let completedAgg = aggregated.filter { !$0.partial }
                        await cache.merge(completedAgg, for: aggKey)
                        if let lastAgg = aggregated.last {
                            continuation.yield(lastAgg)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension AggregatedPeriod {
    init?(_ periodCode: String) {
        switch periodCode {
        case "FOUR_HOURS": self = .fourHours
        case "DAILY": self = .daily
        case "THREE_MINS": self = .threeMinutes
        default: return nil
        }
    }

    var periodCode: String {
        switch self {
        case .fourHours: return "FOUR_HOURS"
        case .daily: return "DAILY"
        case .threeMinutes: return "THREE_MINS"
        }
    }

    /// Raw server period this timeframe is aggregated from.
    var sourcePeriod: String {
        switch self {
        case .fourHours, .daily: return "ONE_HOUR"
        case .threeMinutes: return "ONE_MIN"
        }
    }

    /// Nominal number of source bars per bucket (used to size REST fetches).
    /// DAILY intentionally uses 24 to include weekend filler hours the server returns,
    /// even though the aggregator drops them.
    var sourceSpan: Int {
        switch self {
        case .fourHours: return 4
        case .daily: return 24
        case .threeMinutes: return 3
        }
    }

    /// True when bucketing follows NY-session rules (and weekend fillers are dropped).
    /// False for fixed-grid intraday periods like 3m (pure epoch grid, weekends kept).
    var isSessionAligned: Bool {
        switch self {
        case .fourHours, .daily: return true
        case .threeMinutes: return false
        }
    }

    /// Periods with no native server equivalent must always aggregate, regardless
    /// of the client-side rebucketing toggle (there is no raw server fallback).
    var alwaysAggregated: Bool {
        self == .threeMinutes
    }
}
