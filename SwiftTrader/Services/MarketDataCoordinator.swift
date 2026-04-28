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

    init(host: String = "localhost", port: Int = 8080, cache: CandleCache = CandleCache()) {
        self.apiService = ForexAPIService(baseURL: URL(string: "http://\(host):\(port)")!)
        self.host = host
        self.port = port
        self.cache = cache
    }

    func fetchInstruments() async throws -> [String] {
        try await apiService.fetchInstruments()
    }

    func fetchCandles(
        instrument: String = "EURUSD",
        period: String = "ONE_MIN",
        count: Int = 200,
        rebucketing: Bool = false
    ) async throws -> [CandleBar] {
        if rebucketing, let target = AggregatedPeriod(period) {
            return try await fetchAggregated(instrument: instrument, target: target, count: count)
        }

        let key = CandleCache.CacheKey(instrument: instrument, period: period, source: .server)
        if let latest = await cache.latestTime(for: key),
           !Self.isStale(latest: latest, period: period) {
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
    private static func isStale(latest: Int64, period: String) -> Bool {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let ageMs = nowMs - latest
        let thresholdMs: Int64 = switch period {
        case "FOUR_HOURS", "DAILY", "WEEKLY", "MONTHLY":
            365 * 24 * 60 * 60 * 1000
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
        rebucketing: Bool = false
    ) async throws -> [CandleBar] {
        if rebucketing, let target = AggregatedPeriod(period) {
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
    /// For the aggregated path, `period` is always `ONE_HOUR` — derived bars are
    /// rebuilt on the fly and cached separately in `streamCandles`.
    func cacheBar(
        _ bar: CandleBar, instrument: String, period: String, rebucketing: Bool = false
    ) async {
        let key = CandleCache.CacheKey(instrument: instrument, period: period, source: .server)
        await cache.appendBar(bar, for: key)
    }

    func streamCandles(
        instrument: String = "EURUSD",
        period: String = "ONE_MIN",
        rebucketing: Bool = false
    ) -> AsyncThrowingStream<CandleBar, Error> {
        if rebucketing, let target = AggregatedPeriod(period) {
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
        let hourlyKey = CandleCache.CacheKey(instrument: instrument, period: "ONE_HOUR", source: .server)

        // Warm-cache path: gap-fill the underlying ONE_HOUR cache instead of re-fetching
        // `count * hourlySpan` bars. Re-aggregate the full merged hourly array as before
        // so the .aggregated cache stays consistent.
        if let latest = await cache.latestTime(for: hourlyKey),
           !Self.isStale(latest: latest, period: "ONE_HOUR") {
            try await gapFill(
                serverKey: hourlyKey, instrument: instrument, period: "ONE_HOUR", latest: latest
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

        let hourlyCount = count * target.hourlySpan
        let fetched = try await apiService.fetchHistory(
            instrument: instrument, period: "ONE_HOUR", count: hourlyCount
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
        let hourlyKey = CandleCache.CacheKey(instrument: instrument, period: "ONE_HOUR", source: .server)
        guard let before = await cache.earliestTime(for: hourlyKey) else {
            let key = CandleCache.CacheKey(
                instrument: instrument, period: target.periodCode, source: .aggregated
            )
            return await cache.getBars(for: key)
        }
        let hourlyCount = count * target.hourlySpan
        let fetched = try await apiService.fetchHistory(
            instrument: instrument, period: "ONE_HOUR", count: hourlyCount, before: before
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

        return AsyncThrowingStream { continuation in
            let task = Task {
                let hourly = ForexWebSocketService(
                    instrument: instrument, period: "ONE_HOUR", host: host, port: port
                ).bars()
                do {
                    for try await hourBar in hourly {
                        if Task.isCancelled { break }
                        let hourlyKey = CandleCache.CacheKey(
                            instrument: instrument, period: "ONE_HOUR", source: .server
                        )
                        if !hourBar.partial {
                            await cache.appendBar(hourBar, for: hourlyKey)
                        }
                        let cachedHourly = await cache.getBars(for: hourlyKey)
                        // Partial bars fire at tick rate; re-aggregating the entire hourly
                        // history per tick pegs the ICU timezone lock. Only the tail can
                        // affect the live bucket — take a window large enough to cover it.
                        // Completed hourly bars (≤1/hr) still get a full aggregation so the
                        // aggregated cache stays complete.
                        let inputs: [CandleBar]
                        if hourBar.partial {
                            let tail = target == .daily ? 30 : 6
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

private extension AggregatedPeriod {
    init?(_ periodCode: String) {
        switch periodCode {
        case "FOUR_HOURS": self = .fourHours
        case "DAILY": self = .daily
        default: return nil
        }
    }

    var periodCode: String {
        switch self {
        case .fourHours: return "FOUR_HOURS"
        case .daily: return "DAILY"
        }
    }

    /// Nominal number of 1H bars per bucket (used to size REST fetches).
    /// DAILY intentionally uses 24 to include weekend filler hours the server returns,
    /// even though the aggregator drops them.
    var hourlySpan: Int {
        switch self {
        case .fourHours: return 4
        case .daily: return 24
        }
    }
}
