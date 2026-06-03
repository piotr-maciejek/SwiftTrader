import Foundation

/// Per-position trading metadata captured at order-submit time, which the broker/wire does
/// NOT record: the market price at the instant the user pressed the confirm button (for
/// slippage), and the INITIAL stop-loss (for R-multiple — `Position.stopLoss` is mutable once
/// the position is open, so the original risk would otherwise be lost).
///
/// Only raw inputs are stored; R-multiple and slippage are derived on demand (see the extension)
/// so the formulas can change without a stored-data migration. The join key is `positionId`
/// (= open `Position.label` = closed `TradeRecord.positionId` = the wire `orderGroupId`).
struct PositionMetadata: Codable, Equatable, Identifiable {
    let positionId: String        // = Position.label = orderGroupId (join key)
    let instrument: String        // slashless, e.g. "EURUSD"
    let direction: String         // "BUY" / "SELL"
    let pressPrice: Double         // market tick at the confirm-button press
    let initialStopLoss: Double    // price units; 0 = none
    let initialTakeProfit: Double  // price units; 0 = none
    let fillPrice: Double          // actual fill = Position.openPrice
    let submitTimeMs: Int64        // press time (matching window + pruning fallback)
    let openTimeMs: Int64          // fill time (pruning); 0 until known

    var id: String { positionId }
}

extension PositionMetadata {
    /// +1 for a long, -1 for a short — so "favourable" price moves and "worse" fills are positive.
    var dir: Double { direction == "BUY" ? 1 : -1 }

    private var pipFactor: Double { PnLConverter.pipFactor(for: instrument) }

    /// 1R, in pips: the distance from the actual fill to the initial stop. `nil` (→ "—") when
    /// there was no stop or the stop sat on the fill — both make R undefined (this is the
    /// riskPips > 0 guard the R helpers rely on).
    var riskPips: Double? {
        guard initialStopLoss != 0 else { return nil }
        let r = abs(fillPrice - initialStopLoss) * pipFactor
        return r > 0 ? r : nil
    }

    /// Execution slippage in pips: how far the fill landed from the price when the button was
    /// pressed, signed so POSITIVE = a worse fill (bought higher / sold lower than intended).
    var slippagePips: Double {
        (fillPrice - pressPrice) * dir * pipFactor
    }

    /// Direction-aware pips from the fill to an arbitrary price (mark for open, close for closed).
    func realizedPips(at price: Double) -> Double {
        (price - fillPrice) * dir * pipFactor
    }

    /// Current R-multiple for an OPEN position given a live mark price.
    func currentR(markPrice: Double) -> Double? {
        riskPips.map { realizedPips(at: markPrice) / $0 }
    }

    /// Realized R-multiple for a CLOSED trade given its close price.
    func realizedR(closePrice: Double) -> Double? {
        riskPips.map { realizedPips(at: closePrice) / $0 }
    }

    /// Convenience for open positions: `Position.profitLossPips` is already direction-aware
    /// fill-vs-mark pips, so divide it straight through without threading a separate mark price.
    func currentR(fromPositionPips pips: Double) -> Double? {
        riskPips.map { pips / $0 }
    }

    /// Portfolio total of current R across OPEN positions that have metadata (joined by label).
    /// `nil` when none do — so the UI shows "—" rather than a misleading 0.00R.
    static func totalOpenR(positions: [Position], metadata: [String: PositionMetadata]) -> Double? {
        let rs = positions.compactMap { metadata[$0.label]?.currentR(fromPositionPips: $0.profitLossPips) }
        return rs.isEmpty ? nil : rs.reduce(0, +)
    }

    /// Total realized R across CLOSED trades that have metadata (joined by positionId). `nil` when none.
    static func totalRealizedR(trades: [TradeRecord], metadata: [String: PositionMetadata]) -> Double? {
        let rs = trades.compactMap { metadata[$0.positionId]?.realizedR(closePrice: $0.closePrice) }
        return rs.isEmpty ? nil : rs.reduce(0, +)
    }
}
