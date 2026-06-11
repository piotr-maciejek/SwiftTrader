import Foundation

enum PositionSizing {
    struct Result: Equatable {
        let lots: Double
        let isMarginCapped: Bool
        /// True when no quote→account conversion rate was available; `lots` is the
        /// floor value and must not overwrite a user-chosen amount.
        var conversionUnavailable: Bool = false
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
    ///   - marginBuffer: Fraction of free margin to use (0.80 = 20% safety cushion)
    ///   - spread: Bid-ask spread (in price units) at entry. Padded onto stopDistance for
    ///     the risk calc because realized loss = entry-side - exit-side ≈ displayedDistance + spread.
    ///   - quoteToAccountRate: Conversion rate from the pair's quote currency to the
    ///     account currency (1 when they're the same). The stop distance and notional are
    ///     in quote currency while equity/freeMargin are in account currency, so sizing
    ///     without this rate is wrong by up to ~170× (JPY quotes). Pass nil when no rate
    ///     is available — the result is then flagged `conversionUnavailable` and must not
    ///     be applied as an auto-size.
    static func calculate(
        equity: Double,
        freeMargin: Double,
        riskFraction: Double,
        entryPrice: Double,
        stopLoss: Double,
        leverage: Double = 30,
        minLot: Double = 0.001,
        lotStep: Double = 0.001,
        marginBuffer: Double = 0.80,
        spread: Double = 0,
        quoteToAccountRate: Double?
    ) -> Result {
        let stopDistance = abs(entryPrice - stopLoss)
        guard stopDistance > 0, equity > 0, entryPrice > 0 else {
            return Result(lots: minLot, isMarginCapped: false)
        }
        guard let rate = quoteToAccountRate, rate > 0 else {
            return Result(lots: minLot, isMarginCapped: false, conversionUnavailable: true)
        }

        // JForex amounts are in millions of base currency (0.01 = 10,000 units)
        let unitsPerLot: Double = 1_000_000

        // Risk constraint: loss at SL ≤ riskFraction * equity. The realized loss for a
        // BUY is open_ask − close_bid, so add the spread to the chart-mid-based stopDistance.
        // The loss per lot is in quote currency; × rate converts it to account currency.
        let realizedDistance = stopDistance + max(0, spread)
        let riskAmount = equity * riskFraction
        let riskLots = riskAmount / (realizedDistance * unitsPerLot * rate)

        // Margin constraint: required margin ≤ free margin (with safety buffer).
        // Notional per lot (unitsPerLot × entryPrice) is quote currency; × rate converts.
        let marginLots = (freeMargin * marginBuffer * leverage) / (unitsPerLot * entryPrice * rate)

        let isMarginCapped = marginLots < riskLots && marginLots > 0
        let rawLots = isMarginCapped ? marginLots : riskLots

        // Floor to nearest lotStep (round to avoid floating-point drift before flooring)
        let steps = (rawLots / lotStep * 1e9).rounded() / 1e9
        let floored = steps.rounded(.down) * lotStep
        let finalLots = max(minLot, floored)

        return Result(lots: finalLots, isMarginCapped: isMarginCapped)
    }
}
