import Foundation

protocol MarketDataProviding: Sendable {
    var cache: CandleCache { get }
    func fetchInstruments() async throws -> [String]
    func fetchCandles(instrument: String, period: String, count: Int) async throws -> [CandleBar]
    func fetchEarlierCandles(instrument: String, period: String, count: Int) async throws -> [CandleBar]
    func cacheBar(_ bar: CandleBar, instrument: String, period: String) async
    func streamCandles(instrument: String, period: String) -> AsyncThrowingStream<CandleBar, Error>
}
