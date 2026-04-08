import Foundation

final class MarketDataCoordinator: Sendable {
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
        count: Int = 200
    ) async throws -> [CandleBar] {
        let fetched = try await apiService.fetchHistory(instrument: instrument, period: period, count: count)
        let key = CandleCache.CacheKey(instrument: instrument, period: period)
        let cached = await cache.merge(fetched, for: key)

        // Append trailing partial bar from the fetch if present
        if let last = fetched.last, last.partial {
            return cached + [last]
        }
        return cached
    }

    /// Fetch bars older than the earliest cached bar for this key.
    func fetchEarlierCandles(
        instrument: String,
        period: String,
        count: Int = 1000
    ) async throws -> [CandleBar] {
        let key = CandleCache.CacheKey(instrument: instrument, period: period)
        guard let before = await cache.earliestTime(for: key) else {
            // Cache is empty — nothing to paginate from; return what we have
            return await cache.getBars(for: key)
        }
        let fetched = try await apiService.fetchHistory(
            instrument: instrument, period: period, count: count, before: before
        )
        return await cache.merge(fetched, for: key)
    }

    /// Write a completed WebSocket bar into the shared cache.
    func cacheBar(_ bar: CandleBar, instrument: String, period: String) async {
        let key = CandleCache.CacheKey(instrument: instrument, period: period)
        await cache.appendBar(bar, for: key)
    }

    func streamCandles(
        instrument: String = "EURUSD",
        period: String = "ONE_MIN"
    ) -> AsyncThrowingStream<CandleBar, Error> {
        ForexWebSocketService(instrument: instrument, period: period, host: host, port: port).bars()
    }
}
