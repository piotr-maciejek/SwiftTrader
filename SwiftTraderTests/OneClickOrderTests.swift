import Testing
@testable import SwiftTrader

private func makeBar(time: Int64, open: Double = 1.0, high: Double = 1.2, low: Double = 0.9, close: Double = 1.1, volume: Double = 100, partial: Bool = false) -> CandleBar {
    CandleBar(time: time, open: open, high: high, low: low, close: close, volume: volume, partial: partial)
}

@Suite("OneClickOrder")
struct OneClickOrderTests {

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
