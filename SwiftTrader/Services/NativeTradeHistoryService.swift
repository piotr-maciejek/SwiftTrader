import Foundation
import DukascopyClient

/// Standalone `TradeHistoryFetching` backed by a native `DukascopySession`. Fetches closed
/// positions over the wire (`dfs.PositionDataRequestMessage`) and maps each `ClosedPosition`
/// to the app's `TradeRecord`, so the History tab works without jforex-server. Returns an
/// empty list when there's no session (the History VM is built before connect in native mode).
final class NativeTradeHistoryService: TradeHistoryFetching, Sendable {
    private let session: DukascopySession?

    init(session: DukascopySession?) {
        self.session = session
    }

    func fetchClosedTrades(from: Date, to: Date) async throws -> [TradeRecord] {
        guard let session else { return [] }
        let fromMs = Int64(from.timeIntervalSince1970 * 1000)
        let toMs = Int64(to.timeIntervalSince1970 * 1000)
        let positions = try await session.fetchClosedPositions(fromMillis: fromMs, toMillis: toMs)
        return positions.map(Self.map)
    }

    /// Map a decoded `ClosedPosition` to a `TradeRecord`. `TradeRecord`'s money/price fields
    /// are non-optional, so a missing decimal (only `currentPrice` is ever null for a closed
    /// trade, and that field isn't carried) defaults to 0; dates are already epoch-ms.
    static func map(_ p: ClosedPosition) -> TradeRecord {
        TradeRecord(
            positionId: p.positionId,
            instrument: p.instrument,
            direction: p.isLong ? "BUY" : "SELL",
            amount: p.amount ?? 0,
            openPrice: p.openPrice ?? 0,
            closePrice: p.closePrice ?? 0,
            profitLoss: p.profitLoss ?? 0,
            grossProfitLoss: p.grossProfitLoss ?? 0,
            swaps: p.swaps ?? 0,
            commission: p.commission ?? 0,
            openTime: p.openDateMillis ?? 0,
            closeTime: p.closeDateMillis ?? 0,
            positionType: p.isMerged ? "MERGED" : "REGULAR"
        )
    }
}
