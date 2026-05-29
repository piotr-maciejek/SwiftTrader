import Foundation

protocol MarketDataProviding: Sendable {
    var cache: CandleCache { get }
    /// How many chart cells a correlation / multi-timeframe grid may cold-load concurrently.
    /// Native mode throttles this to protect its single socket + bulk CDN; server mode keeps
    /// the effectively-unbounded default (its own cache absorbs the burst).
    var maxConcurrentColdLoads: Int { get }
    func fetchInstruments() async throws -> [String]
    func fetchCandles(instrument: String, period: String, count: Int, rebucketing: Bool) async throws -> [CandleBar]
    func fetchEarlierCandles(instrument: String, period: String, count: Int, rebucketing: Bool) async throws -> [CandleBar]
    func cacheBar(_ bar: CandleBar, instrument: String, period: String, rebucketing: Bool) async
    func streamCandles(instrument: String, period: String, rebucketing: Bool) -> AsyncThrowingStream<CandleBar, Error>
    func clearServerCache(instrument: String) async throws -> Int
    func forceReconnect() async throws
}

extension MarketDataProviding {
    /// Server mode (and any provider that doesn't opt in) loads grid cells unthrottled.
    var maxConcurrentColdLoads: Int { .max }

    // Convenience defaults so existing tests that pass `rebucketing: false` implicitly keep working.
    func fetchCandles(instrument: String, period: String, count: Int) async throws -> [CandleBar] {
        try await fetchCandles(instrument: instrument, period: period, count: count, rebucketing: false)
    }
    func fetchEarlierCandles(instrument: String, period: String, count: Int) async throws -> [CandleBar] {
        try await fetchEarlierCandles(instrument: instrument, period: period, count: count, rebucketing: false)
    }
    func cacheBar(_ bar: CandleBar, instrument: String, period: String) async {
        await cacheBar(bar, instrument: instrument, period: period, rebucketing: false)
    }
    func streamCandles(instrument: String, period: String) -> AsyncThrowingStream<CandleBar, Error> {
        streamCandles(instrument: instrument, period: period, rebucketing: false)
    }
}
