import Foundation

protocol MarketDataProviding: Sendable {
    var cache: CandleCache { get }
    func fetchInstruments() async throws -> [String]
    func fetchCandles(instrument: String, period: String, count: Int, rebucketing: Bool) async throws -> [CandleBar]
    func fetchEarlierCandles(instrument: String, period: String, count: Int, rebucketing: Bool) async throws -> [CandleBar]
    func cacheBar(_ bar: CandleBar, instrument: String, period: String, rebucketing: Bool) async
    func streamCandles(instrument: String, period: String, rebucketing: Bool) -> AsyncThrowingStream<CandleBar, Error>
    func clearServerCache(instrument: String) async throws -> Int
    func forceReconnect() async throws
}

extension MarketDataProviding {
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
