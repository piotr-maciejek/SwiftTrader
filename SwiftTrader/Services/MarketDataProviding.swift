import Foundation

protocol MarketDataProviding: Sendable {
    var cache: CandleCache { get }
    /// How many chart cells a correlation / multi-timeframe grid may cold-load concurrently.
    /// Native mode throttles this to protect its single socket + bulk CDN; server mode keeps
    /// the effectively-unbounded default (its own cache absorbs the burst).
    var maxConcurrentColdLoads: Int { get }
    /// Seconds the chart should wait after a hard refresh (cache wipe + reconnect) before
    /// reloading. Server mode needs ~12s for JForex to restart; native mode does no
    /// reconnect, so the chart can reload immediately.
    var hardRefreshGraceSeconds: TimeInterval { get }
    func fetchInstruments() async throws -> [String]
    func fetchCandles(instrument: String, period: String, count: Int, rebucketing: Bool, side: ChartSide) async throws -> [CandleBar]
    func fetchEarlierCandles(instrument: String, period: String, count: Int, rebucketing: Bool, side: ChartSide) async throws -> [CandleBar]
    func cacheBar(_ bar: CandleBar, instrument: String, period: String, rebucketing: Bool, side: ChartSide) async
    func streamCandles(instrument: String, period: String, rebucketing: Bool, side: ChartSide) -> AsyncThrowingStream<CandleBar, Error>
    func clearServerCache(instrument: String) async throws -> Int
    func forceReconnect() async throws
    /// Re-assert live-data subscriptions to recover a feed that's silent despite an open
    /// connection (e.g. a dropped quote subscription). Default no-op for providers that
    /// manage their own subscriptions server-side.
    func resubscribeLiveData() async
}

extension MarketDataProviding {
    /// Server mode (and any provider that doesn't opt in) loads grid cells unthrottled.
    var maxConcurrentColdLoads: Int { .max }
    /// Server mode defaults — overridden by native (instant) and any provider with
    /// a different reconnect cycle.
    var hardRefreshGraceSeconds: TimeInterval { 12 }

    /// No-op by default: server mode resubscribes through its own WebSocket layer.
    func resubscribeLiveData() async {}

    // Convenience defaults so existing callers/tests keep working: `side` defaults to `.bid`, and the
    // `rebucketing`-only / `count`-only overloads chain down to the full requirement.
    func fetchCandles(instrument: String, period: String, count: Int, rebucketing: Bool) async throws -> [CandleBar] {
        try await fetchCandles(instrument: instrument, period: period, count: count, rebucketing: rebucketing, side: .bid)
    }
    func fetchCandles(instrument: String, period: String, count: Int) async throws -> [CandleBar] {
        try await fetchCandles(instrument: instrument, period: period, count: count, rebucketing: false, side: .bid)
    }
    func fetchEarlierCandles(instrument: String, period: String, count: Int, rebucketing: Bool) async throws -> [CandleBar] {
        try await fetchEarlierCandles(instrument: instrument, period: period, count: count, rebucketing: rebucketing, side: .bid)
    }
    func fetchEarlierCandles(instrument: String, period: String, count: Int) async throws -> [CandleBar] {
        try await fetchEarlierCandles(instrument: instrument, period: period, count: count, rebucketing: false, side: .bid)
    }
    func cacheBar(_ bar: CandleBar, instrument: String, period: String, rebucketing: Bool) async {
        await cacheBar(bar, instrument: instrument, period: period, rebucketing: rebucketing, side: .bid)
    }
    func cacheBar(_ bar: CandleBar, instrument: String, period: String) async {
        await cacheBar(bar, instrument: instrument, period: period, rebucketing: false, side: .bid)
    }
    func streamCandles(instrument: String, period: String, rebucketing: Bool) -> AsyncThrowingStream<CandleBar, Error> {
        streamCandles(instrument: instrument, period: period, rebucketing: rebucketing, side: .bid)
    }
    func streamCandles(instrument: String, period: String) -> AsyncThrowingStream<CandleBar, Error> {
        streamCandles(instrument: instrument, period: period, rebucketing: false, side: .bid)
    }
}
