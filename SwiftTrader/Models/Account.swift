import DukascopyClient
import Foundation

struct Account: Codable, Equatable {
    let balance: Double
    let equity: Double
    let usedMargin: Double
    let freeMargin: Double
    let currency: String
    let leverage: Double
    let connected: Bool
    let lastTickAgeMs: Int64

    /// Red when the upstream transport is down, or when no tick has arrived in 10 s.
    /// Callers should consider positions, P&L and prices stale while this is true.
    var isHealthStale: Bool { !connected || lastTickAgeMs > 10_000 }
}

extension Account {
    /// Builds the app account model from a native Dukascopy snapshot. `usedMargin`
    /// is `equity − usableMargin` (the server doesn't transmit it directly); the app's
    /// `freeMargin` is the native `usableMargin`. `connected` reflects the live session
    /// state and `lastTickAgeMs` the age of the last tick, so `isHealthStale` drives the
    /// connection banner in standalone mode (the trading coordinator supplies both).
    init(native: DukascopyClient.AccountInfo, connected: Bool, lastTickAgeMs: Int64 = 0) {
        self.init(
            balance: native.balance?.doubleValue ?? 0,
            equity: native.equity?.doubleValue ?? 0,
            usedMargin: native.usedMargin?.doubleValue ?? 0,
            freeMargin: native.usableMargin?.doubleValue ?? 0,
            currency: native.currency ?? "USD",
            leverage: Double(native.leverage ?? 30),
            connected: connected,
            lastTickAgeMs: lastTickAgeMs
        )
    }
}

struct TradingSnapshot: Codable {
    let positions: [Position]
    let account: Account
    let spreads: [String: Double]?
}
