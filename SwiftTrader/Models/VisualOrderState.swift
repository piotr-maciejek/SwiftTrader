struct VisualOrderState: Equatable {
    let direction: String       // "BUY" or "SELL"
    let instrument: String
    var entryPrice: Double       // tracks current market price until user drags
    var marketPrice: Double      // last known market price; used to infer order type
    var amount: Double          // position size in lots
    var stopLoss: Double        // draggable
    var takeProfit: Double      // draggable
    var startBarIndex: Int      // left edge (ahead of current candle)
    var endBarIndex: Int        // right edge (~10 candles ahead)
    var isAmountOverridden: Bool = false
    var isMarginCapped: Bool = false
    var isEntryOverridden: Bool = false  // true once user drags the entry line off market

    var riskPips: Double {
        abs(entryPrice - stopLoss) * TradingDayATR.pipFactor(for: instrument)
    }

    var rewardPips: Double {
        abs(takeProfit - entryPrice) * TradingDayATR.pipFactor(for: instrument)
    }

    /// Spread-aware R:R. Risk widens by the spread (open at ask, exit SL at bid for
    /// BUY — and the mirror for SELL); reward narrows by it. `spread` is in price units
    /// (same as `entryPrice`), matching `TradingViewModel.spreads[instrument]`. abs() makes
    /// the formula direction-agnostic. Passing 0 yields the legacy raw ratio.
    func riskRewardRatio(spread: Double) -> Double {
        let s = max(0, spread)
        let risk = abs(entryPrice - stopLoss) + s
        let reward = max(0, abs(takeProfit - entryPrice) - s)
        guard risk > 0 else { return 0 }
        return reward / risk
    }

    /// Distance of entry from market, in pips (signed: positive = above market).
    var entryOffsetPips: Double {
        (entryPrice - marketPrice) * TradingDayATR.pipFactor(for: instrument)
    }

    /// MARKET / BUY_LIMIT / BUY_STOP / SELL_LIMIT / SELL_STOP, inferred from
    /// entry vs market. Within 0.5 pip of market counts as MARKET.
    var orderType: String {
        guard isEntryOverridden else { return "MARKET" }
        let offset = entryOffsetPips
        if abs(offset) < 0.5 { return "MARKET" }
        if direction == "BUY" {
            return offset < 0 ? "BUY_LIMIT" : "BUY_STOP"
        } else {
            return offset > 0 ? "SELL_LIMIT" : "SELL_STOP"
        }
    }
}
