struct VisualOrderState: Equatable {
    let direction: String       // "BUY" or "SELL"
    let instrument: String
    var entryPrice: Double       // tracks current market price
    var amount: Double          // position size in lots
    var stopLoss: Double        // draggable
    var takeProfit: Double      // draggable
    var startBarIndex: Int      // left edge (ahead of current candle)
    var endBarIndex: Int        // right edge (~10 candles ahead)

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
