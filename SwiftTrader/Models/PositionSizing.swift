import Foundation

enum PositionSizing {
    struct Result: Equatable {
        let lots: Double
        let isMarginCapped: Bool
    }

    /// Calculate position size based on risk and margin constraints.
    ///
    /// - Parameters:
    ///   - equity: Current account equity in account currency
    ///   - freeMargin: Available margin in account currency
    ///   - riskFraction: Max loss as fraction of equity (e.g. 0.05 for 5%)
    ///   - entryPrice: Expected entry price
    ///   - stopLoss: Stop-loss price level
    ///   - leverage: Account leverage (default 30 for EU retail)
    ///   - minLot: Minimum tradeable lot size
    ///   - lotStep: Lot size granularity
    ///   - marginBuffer: Fraction of free margin to use (0.90 = 10% safety cushion)
    static func calculate(
        equity: Double,
        freeMargin: Double,
        riskFraction: Double,
        entryPrice: Double,
        stopLoss: Double,
        leverage: Double = 30,
        minLot: Double = 0.001,
        lotStep: Double = 0.001,
        marginBuffer: Double = 0.90
    ) -> Result {
        let stopDistance = abs(entryPrice - stopLoss)
        guard stopDistance > 0, equity > 0, entryPrice > 0 else {
            return Result(lots: minLot, isMarginCapped: false)
        }

        // JForex amounts are in millions of base currency (0.01 = 10,000 units)
        let unitsPerLot: Double = 1_000_000

        // Risk constraint: loss at SL ≤ riskFraction * equity
        let riskAmount = equity * riskFraction
        let riskLots = riskAmount / (stopDistance * unitsPerLot)

        // Margin constraint: required margin ≤ free margin (with safety buffer)
        let marginLots = (freeMargin * marginBuffer * leverage) / (unitsPerLot * entryPrice)

        let isMarginCapped = marginLots < riskLots && marginLots > 0
        let rawLots = isMarginCapped ? marginLots : riskLots

        // Floor to nearest lotStep (round to avoid floating-point drift before flooring)
        let steps = (rawLots / lotStep * 1e9).rounded() / 1e9
        let floored = steps.rounded(.down) * lotStep
        let finalLots = max(minLot, floored)

        return Result(lots: finalLots, isMarginCapped: isMarginCapped)
    }
}
