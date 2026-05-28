import DukascopyClient
import Foundation

/// Standalone market-data provider: talks the Dukascopy protocol directly via the
/// `DukascopyClient` package (no jforex-server). Conforms to `MarketDataProviding`
/// so the view-model layer is identical to server mode.
///
/// 4H/Daily/3m are ALWAYS aggregated client-side here (the `rebucketing` flag is
/// ignored) — see `fetchAggregated`. Skeleton stage: `fetchRawCandles` (the one leaf
/// that hits the native client) and the live stream are stubbed until the session
/// lifecycle and credential handling land.
final class NativeMarketDataCoordinator: MarketDataProviding, Sendable {
    let cache: CandleCache
    /// Connected session, supplied once standalone auth reaches `.ready`. Nil before
    /// connect — data calls then fail with `.notImplemented`/`.notConnected`.
    private let session: DukascopySession?

    init(session: DukascopySession? = nil, cache: CandleCache = CandleCache()) {
        self.session = session
        self.cache = cache
    }

    func fetchInstruments() async throws -> [String] {
        Self.defaultInstruments
    }

    func fetchCandles(
        instrument: String, period: String, count: Int, rebucketing: Bool
    ) async throws -> [SwiftTrader.CandleBar] {
        // Native mode ALWAYS aggregates 4H/Daily/3m client-side from raw 1H/1M using the
        // shared BarAggregator (the `rebucketing` flag is ignored). This keeps aggregated
        // bars byte-identical regardless of provider and means the only thing native ever
        // caches as `.server` is raw 1H/1M — the single surface that must match server mode.
        if let target = AggregatedPeriod(period) {
            return try await fetchAggregated(instrument: instrument, target: target, count: count)
        }
        let key = CandleCache.CacheKey(instrument: instrument, period: period, source: .server)
        let fetched = try await fetchRawCandles(instrument: instrument, period: period, count: count)
        let cached = await cache.merge(fetched, for: key)
        if let last = fetched.last, last.partial { return cached + [last] }
        return cached
    }

    func fetchEarlierCandles(
        instrument: String, period: String, count: Int, rebucketing: Bool
    ) async throws -> [SwiftTrader.CandleBar] {
        if let target = AggregatedPeriod(period) {
            return try await fetchEarlierAggregated(instrument: instrument, target: target, count: count)
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
        // Live path lands with the native session. It will mirror the fetch policy:
        // 4H/Daily/3m aggregated client-side from a raw 1H/1M bar stream.
        AsyncThrowingStream { $0.finish(throwing: NativeProviderError.notImplemented("live bar stream")) }
    }

    func clearServerCache(instrument: String) async throws -> Int {
        await cache.clear(instrument: instrument)
        return 0
    }

    func forceReconnect() async throws {
        throw NativeProviderError.notImplemented("reconnect")
    }

    // MARK: - Client-side aggregation (always on for 4H/Daily/3m)

    private func fetchAggregated(
        instrument: String, target: AggregatedPeriod, count: Int
    ) async throws -> [SwiftTrader.CandleBar] {
        let source = target.sourcePeriod  // ONE_HOUR (4H/Daily) or ONE_MIN (3m)
        let sourceKey = CandleCache.CacheKey(instrument: instrument, period: source, source: .server)
        let fetched = try await fetchRawCandles(
            instrument: instrument, period: source, count: count * target.sourceSpan
        )
        let merged = await cache.merge(fetched, for: sourceKey)
        let partial = fetched.last.flatMap { $0.partial ? $0 : nil }

        let aggregated = BarAggregator.aggregate(hourly: merged, openPartial: partial, target: target)
        let aggKey = CandleCache.CacheKey(
            instrument: instrument, period: target.periodCode, source: .aggregated
        )
        let cached = await cache.merge(aggregated, for: aggKey)
        if let last = aggregated.last, last.partial { return cached + [last] }
        return cached
    }

    private func fetchEarlierAggregated(
        instrument: String, target: AggregatedPeriod, count: Int
    ) async throws -> [SwiftTrader.CandleBar] {
        let source = target.sourcePeriod
        let sourceKey = CandleCache.CacheKey(instrument: instrument, period: source, source: .server)
        guard let before = await cache.earliestTime(for: sourceKey) else {
            let aggKey = CandleCache.CacheKey(
                instrument: instrument, period: target.periodCode, source: .aggregated
            )
            return await cache.getBars(for: aggKey)
        }
        let fetched = try await fetchRawCandles(
            instrument: instrument, period: source, count: count * target.sourceSpan, before: before
        )
        let merged = await cache.merge(fetched, for: sourceKey)
        let aggregated = BarAggregator.aggregate(hourly: merged, openPartial: nil, target: target)
        let aggKey = CandleCache.CacheKey(
            instrument: instrument, period: target.periodCode, source: .aggregated
        )
        return await cache.merge(aggregated, for: aggKey)
    }

    /// The single leaf that talks to the native Dukascopy client. Everything else
    /// (raw caching + 4H/Daily/3m aggregation) is built on top of this one call.
    /// Stubbed until the native session lands.
    private func fetchRawCandles(
        instrument: String, period: String, count: Int, before: Int64? = nil
    ) async throws -> [SwiftTrader.CandleBar] {
        throw NativeProviderError.notImplemented("history fetch")
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
