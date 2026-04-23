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

struct TradingSnapshot: Codable {
    let positions: [Position]
    let account: Account
}
