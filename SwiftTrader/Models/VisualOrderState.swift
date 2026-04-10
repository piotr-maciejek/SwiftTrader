struct VisualOrderState: Equatable {
    let direction: String       // "BUY" or "SELL"
    let instrument: String
    let entryPrice: Double      // market price at activation
    var stopLoss: Double        // draggable
    var takeProfit: Double      // draggable
    let startBarIndex: Int      // left edge (current candle)
    let endBarIndex: Int        // right edge (~10 candles ahead)

    var riskPips: Double {
        abs(entryPrice - stopLoss) * TradingDayATR.pipFactor(for: instrument)
    }

    var rewardPips: Double {
        abs(takeProfit - entryPrice) * TradingDayATR.pipFactor(for: instrument)
    }

    var riskRewardRatio: Double {
        guard riskPips > 0 else { return 0 }
        return rewardPips / riskPips
    }
}
