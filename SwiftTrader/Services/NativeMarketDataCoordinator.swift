import DukascopyClient
import Foundation

/// Standalone market-data provider: talks the Dukascopy protocol directly via the
/// `DukascopyClient` package (no jforex-server). Conforms to `MarketDataProviding`
/// so the view-model layer is identical to server mode.
///
/// Skeleton stage: only the instrument roster is wired. History, live streaming,
/// and account snapshots come in the next slice once the session lifecycle and
/// credential handling are in place — until then those paths surface a clear error.
final class NativeMarketDataCoordinator: MarketDataProviding, Sendable {
    let cache: CandleCache
    private let environment: DukascopyEnvironment
    private let credentials: AuthCredentials?

    init(environment: DukascopyEnvironment = .demo,
         credentials: AuthCredentials? = nil,
         cache: CandleCache = CandleCache()) {
        self.environment = environment
        self.credentials = credentials
        self.cache = cache
    }

    func fetchInstruments() async throws -> [String] {
        Self.defaultInstruments
    }

    func fetchCandles(
        instrument: String, period: String, count: Int, rebucketing: Bool
    ) async throws -> [SwiftTrader.CandleBar] {
        throw NativeProviderError.notImplemented("history fetch")
    }

    func fetchEarlierCandles(
        instrument: String, period: String, count: Int, rebucketing: Bool
    ) async throws -> [SwiftTrader.CandleBar] {
        throw NativeProviderError.notImplemented("history fetch")
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
        AsyncThrowingStream { $0.finish(throwing: NativeProviderError.notImplemented("live bar stream")) }
    }

    func clearServerCache(instrument: String) async throws -> Int {
        await cache.clear(instrument: instrument)
        return 0
    }

    func forceReconnect() async throws {
        throw NativeProviderError.notImplemented("reconnect")
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
