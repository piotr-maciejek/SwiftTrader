import Foundation

final class MarketDataCoordinator: MarketDataProviding, Sendable {
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

        let fetched = try await apiService.fetchHistory(instrument: instrument, period: period, count: count)
        let key = CandleCache.CacheKey(instrument: instrument, period: period, source: .server)
        let cached = await cache.merge(fetched, for: key)

        if let last = fetched.last, last.partial {
            return cached + [last]
        }
        return cached
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

    // MARK: - Aggregation helpers

    private func fetchAggregated(
        instrument: String, target: AggregatedPeriod, count: Int
    ) async throws -> [CandleBar] {
        let hourlyCount = count * target.hourlySpan
        let fetched = try await apiService.fetchHistory(
            instrument: instrument, period: "ONE_HOUR", count: hourlyCount
        )
        let hourlyKey = CandleCache.CacheKey(instrument: instrument, period: "ONE_HOUR", source: .server)
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
                        let partial = hourBar.partial ? hourBar : nil
                        let aggregated = BarAggregator.aggregate(
                            hourly: cachedHourly, openPartial: partial, target: target
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
