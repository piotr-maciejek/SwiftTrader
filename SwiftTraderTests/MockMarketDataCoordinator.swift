import Foundation
@testable import SwiftTrader

final class MockMarketDataCoordinator: MarketDataProviding, @unchecked Sendable {
    let cache = CandleCache()

    // Controllable return values
    var instrumentsResult: Result<[String], Error> = .success(["EURUSD", "GBPUSD"])
    var fetchCandlesResult: Result<[CandleBar], Error> = .success([])
    var fetchEarlierResult: Result<[CandleBar], Error> = .success([])

    // Call tracking. ChartViewModel can fan-out multiple fetchCandles
    // concurrently (history + loadATR) which lands on the cooperative
    // thread pool, so the call-log arrays need a lock to avoid Array
    // realloc races during `append`.
    private let lock = NSLock()
    var fetchInstrumentsCalled = false
    var fetchCandlesCalls: [(instrument: String, period: String, count: Int)] = []
    var cachedBars: [(bar: CandleBar, instrument: String, period: String)] = []

    func fetchInstruments() async throws -> [String] {
        lock.withLock { fetchInstrumentsCalled = true }
        return try instrumentsResult.get()
    }

    func fetchCandles(instrument: String, period: String, count: Int, rebucketing: Bool, side: ChartSide) async throws -> [CandleBar] {
        lock.withLock { fetchCandlesCalls.append((instrument, period, count)) }
        return try fetchCandlesResult.get()
    }

    func fetchEarlierCandles(instrument: String, period: String, count: Int, rebucketing: Bool, side: ChartSide) async throws -> [CandleBar] {
        return try fetchEarlierResult.get()
    }

    func cacheBar(_ bar: CandleBar, instrument: String, period: String, rebucketing: Bool, side: ChartSide) async {
        lock.withLock { cachedBars.append((bar, instrument, period)) }
    }

    func streamCandles(instrument: String, period: String, rebucketing: Bool, side: ChartSide) -> AsyncThrowingStream<CandleBar, Error> {
        // Return a stream that never yields — tests call handleBar directly
        AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in }
        }
    }

    func clearServerCache(instrument: String) async throws -> Int { 0 }

    var forceReconnectCalled = false
    var forceReconnectResult: Result<Void, Error> = .success(())
    func forceReconnect() async throws {
        lock.withLock { forceReconnectCalled = true }
        try forceReconnectResult.get()
    }
}
