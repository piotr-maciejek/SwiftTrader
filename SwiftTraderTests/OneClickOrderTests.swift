import Testing
@testable import SwiftTrader

private func makeBar(time: Int64, open: Double = 1.0, high: Double = 1.2, low: Double = 0.9, close: Double = 1.1, volume: Double = 100, partial: Bool = false) -> CandleBar {
    CandleBar(time: time, open: open, high: high, low: low, close: close, volume: volume, partial: partial)
}

@Suite("SL/TP Calculation")
struct SLTPCalculationTests {

    @Test("BUY stop loss at previous completed bar's low")
    func buyStopLossAtPreviousLow() {
        let bars = [
            makeBar(time: 1000, low: 1.05, close: 1.10),
            makeBar(time: 2000, close: 1.15),
        ]
        let result = TradingViewModel.calculateOneClick(direction: "BUY", bars: bars)
        if case .success(let params) = result {
            #expect(params.stopLoss == 1.05)
        } else {
            Issue.record("Expected success")
        }
    }

    @Test("BUY take profit at 3R")
    func buyTakeProfitThreeR() {
        let bars = [
            makeBar(time: 1000, low: 1.05, close: 1.10),
            makeBar(time: 2000, close: 1.15),
        ]
        let result = TradingViewModel.calculateOneClick(direction: "BUY", bars: bars)
        if case .success(let params) = result {
            let risk = 1.15 - 1.05
            let expectedTP = 1.15 + risk * 3
            #expect(abs(params.takeProfit - expectedTP) < 0.0001)
        } else {
            Issue.record("Expected success")
        }
    }

    @Test("SELL stop loss at previous completed bar's high")
    func sellStopLossAtPreviousHigh() {
        let bars = [
            makeBar(time: 1000, high: 1.20, close: 1.15),
            makeBar(time: 2000, close: 1.10),
        ]
        let result = TradingViewModel.calculateOneClick(direction: "SELL", bars: bars)
        if case .success(let params) = result {
            #expect(params.stopLoss == 1.20)
        } else {
            Issue.record("Expected success")
        }
    }

    @Test("SELL take profit at 3R")
    func sellTakeProfitThreeR() {
        let bars = [
            makeBar(time: 1000, high: 1.20, close: 1.15),
            makeBar(time: 2000, close: 1.10),
        ]
        let result = TradingViewModel.calculateOneClick(direction: "SELL", bars: bars)
        if case .success(let params) = result {
            let risk = 1.20 - 1.10
            let expectedTP = 1.10 - risk * 3
            #expect(abs(params.takeProfit - expectedTP) < 0.0001)
        } else {
            Issue.record("Expected success")
        }
    }

    @Test("BUY rejected when current price below previous low")
    func rejectsInvalidRiskBuy() {
        let bars = [
            makeBar(time: 1000, low: 1.20, close: 1.25),
            makeBar(time: 2000, close: 1.15), // close < previous low
        ]
        let result = TradingViewModel.calculateOneClick(direction: "BUY", bars: bars)
        if case .failure(let error) = result {
            #expect(error == .invalidRisk("current price below previous low"))
        } else {
            Issue.record("Expected failure")
        }
    }

    @Test("SELL rejected when current price above previous high")
    func rejectsInvalidRiskSell() {
        let bars = [
            makeBar(time: 1000, high: 1.10, close: 1.05),
            makeBar(time: 2000, close: 1.15), // close > previous high
        ]
        let result = TradingViewModel.calculateOneClick(direction: "SELL", bars: bars)
        if case .failure(let error) = result {
            #expect(error == .invalidRisk("current price above previous high"))
        } else {
            Issue.record("Expected failure")
        }
    }

    @Test("Needs at least 2 bars")
    func needsEnoughBars() {
        let bars = [makeBar(time: 1000)]
        let result = TradingViewModel.calculateOneClick(direction: "BUY", bars: bars)
        #expect(result == .failure(.insufficientData))
    }

    @Test("lastCompletedBar skips trailing partial bar")
    func lastCompletedBarSkipsPartial() {
        let bars = [
            makeBar(time: 1000, low: 0.90),
            makeBar(time: 2000, low: 0.95),
            makeBar(time: 3000, partial: true),
        ]
        let previous = TradingViewModel.lastCompletedBar(in: bars)
        #expect(previous?.time == 1000)
    }
}

@Suite("Visual Order SL/TP")
struct VisualOrderSLTPTests {

    @Test("BUY SL at lowest low of recent bars")
    func buySLAtLowestLow() {
        let bars = [
            makeBar(time: 1000, low: 1.05, close: 1.10),
            makeBar(time: 2000, low: 1.08, close: 1.12),
            makeBar(time: 3000, low: 1.06, close: 1.15),
        ]
        let (sl, _) = TradingViewModel.visualOrderSLTP(direction: "BUY", bars: bars, currentPrice: 1.15)
        #expect(sl == 1.05) // lowest low across recent bars
    }

    @Test("BUY works even when price is below previous low")
    func buyWorksWhenPriceBelowPrevLow() {
        let bars = [
            makeBar(time: 1000, low: 1.20, close: 1.25),
            makeBar(time: 2000, low: 1.18, close: 1.15), // close below prev low
        ]
        let (sl, tp) = TradingViewModel.visualOrderSLTP(direction: "BUY", bars: bars, currentPrice: 1.15)
        #expect(sl < 1.15) // SL always below entry
        #expect(tp > 1.15) // TP always above entry
    }

    @Test("SELL SL at highest high of recent bars")
    func sellSLAtHighestHigh() {
        let bars = [
            makeBar(time: 1000, high: 1.25, close: 1.20),
            makeBar(time: 2000, high: 1.22, close: 1.18),
            makeBar(time: 3000, high: 1.20, close: 1.10),
        ]
        let (sl, _) = TradingViewModel.visualOrderSLTP(direction: "SELL", bars: bars, currentPrice: 1.10)
        #expect(sl == 1.25) // highest high across recent bars
    }

    @Test("TP is always at 3:1 R:R")
    func tpAt3R() {
        let bars = [
            makeBar(time: 1000, high: 1.15, low: 1.05, close: 1.10),
            makeBar(time: 2000, close: 1.12),
        ]
        let (sl, tp) = TradingViewModel.visualOrderSLTP(direction: "BUY", bars: bars, currentPrice: 1.12)
        let risk = 1.12 - sl
        let expectedTP = 1.12 + risk * 3
        #expect(abs(tp - expectedTP) < 0.0001 as Double)
    }
}

@Suite("VisualOrderState")
struct VisualOrderStateTests {

    @Test("R:R ratio computed correctly for non-JPY pair")
    func rrRatio() {
        let order = VisualOrderState(
            direction: "BUY", instrument: "EURUSD", entryPrice: 1.1000,
            stopLoss: 1.0980, takeProfit: 1.1060,
            startBarIndex: 100, endBarIndex: 110
        )
        // Risk = 0.0020 = 20 pips, Reward = 0.0060 = 60 pips, R:R = 3.0
        #expect(abs(order.riskPips - 20.0) < 0.01)
        #expect(abs(order.rewardPips - 60.0) < 0.01)
        #expect(abs(order.riskRewardRatio - 3.0) < 0.01)
    }

    @Test("R:R ratio computed correctly for JPY pair")
    func rrRatioJPY() {
        let order = VisualOrderState(
            direction: "SELL", instrument: "USDJPY", entryPrice: 150.00,
            stopLoss: 150.30, takeProfit: 149.10,
            startBarIndex: 50, endBarIndex: 60
        )
        // Risk = 0.30 = 30 pips, Reward = 0.90 = 90 pips, R:R = 3.0
        #expect(abs(order.riskPips - 30.0) < 0.01)
        #expect(abs(order.rewardPips - 90.0) < 0.01)
        #expect(abs(order.riskRewardRatio - 3.0) < 0.01)
    }

    @Test("R:R is zero when SL equals entry")
    func rrZeroWhenNoRisk() {
        let order = VisualOrderState(
            direction: "BUY", instrument: "EURUSD", entryPrice: 1.1000,
            stopLoss: 1.1000, takeProfit: 1.1060,
            startBarIndex: 0, endBarIndex: 10
        )
        #expect(order.riskRewardRatio == 0)
    }
}
