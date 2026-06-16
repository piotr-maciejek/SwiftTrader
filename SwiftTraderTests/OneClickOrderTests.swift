import Foundation
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
            direction: "BUY", instrument: "EURUSD", entryPrice: 1.1000, marketPrice: 1.1000, amount: 0.001,
            stopLoss: 1.0980, takeProfit: 1.1060,
            startBarIndex: 100, endBarIndex: 110
        )
        // Risk = 0.0020 = 20 pips, Reward = 0.0060 = 60 pips, R:R = 3.0
        #expect(abs(order.riskPips - 20.0) < 0.01)
        #expect(abs(order.rewardPips - 60.0) < 0.01)
        #expect(abs(order.riskRewardRatio(spread: 0) - 3.0) < 0.01)
    }

    @Test("R:R ratio computed correctly for JPY pair")
    func rrRatioJPY() {
        let order = VisualOrderState(
            direction: "SELL", instrument: "USDJPY", entryPrice: 150.00, marketPrice: 150.00, amount: 0.001,
            stopLoss: 150.30, takeProfit: 149.10,
            startBarIndex: 50, endBarIndex: 60
        )
        // Risk = 0.30 = 30 pips, Reward = 0.90 = 90 pips, R:R = 3.0
        #expect(abs(order.riskPips - 30.0) < 0.01)
        #expect(abs(order.rewardPips - 90.0) < 0.01)
        #expect(abs(order.riskRewardRatio(spread: 0) - 3.0) < 0.01)
    }

    @Test("R:R is zero when SL equals entry")
    func rrZeroWhenNoRisk() {
        let order = VisualOrderState(
            direction: "BUY", instrument: "EURUSD", entryPrice: 1.1000, marketPrice: 1.1000, amount: 0.001,
            stopLoss: 1.1000, takeProfit: 1.1060,
            startBarIndex: 0, endBarIndex: 10
        )
        #expect(order.riskRewardRatio(spread: 0) == 0)
    }

    @Test("R:R shrinks once the spread is accounted for (BUY)")
    func rrSpreadAwareBuy() {
        // 20 pip risk / 60 pip reward / 1 pip spread → (60-1)/(20+1) = 59/21 ≈ 2.81
        let order = VisualOrderState(
            direction: "BUY", instrument: "EURUSD", entryPrice: 1.1000, marketPrice: 1.1000, amount: 0.001,
            stopLoss: 1.0980, takeProfit: 1.1060,
            startBarIndex: 0, endBarIndex: 10
        )
        #expect(abs(order.riskRewardRatio(spread: 0.0001) - (59.0 / 21.0)) < 0.001)
    }

    @Test("R:R shrinks once the spread is accounted for (SELL)")
    func rrSpreadAwareSell() {
        // Same math, opposite direction — abs() makes the formula symmetric.
        let order = VisualOrderState(
            direction: "SELL", instrument: "USDJPY", entryPrice: 150.00, marketPrice: 150.00, amount: 0.001,
            stopLoss: 150.30, takeProfit: 149.10,
            startBarIndex: 0, endBarIndex: 10
        )
        // 30 pip risk / 90 pip reward / 2 pip spread → (90-2)/(30+2) = 88/32 = 2.75
        #expect(abs(order.riskRewardRatio(spread: 0.02) - (88.0 / 32.0)) < 0.001)
    }

    @Test("R:R clamps to 0 when spread eats the entire reward")
    func rrSpreadEatsReward() {
        let order = VisualOrderState(
            direction: "BUY", instrument: "EURUSD", entryPrice: 1.1000, marketPrice: 1.1000, amount: 0.001,
            stopLoss: 1.0990, takeProfit: 1.1005,
            startBarIndex: 0, endBarIndex: 10
        )
        // Reward = 5 pips, spread = 10 pips → reward clamps to 0, R:R = 0
        #expect(order.riskRewardRatio(spread: 0.0010) == 0)
    }
}

@Suite("Visual Order Management")
struct VisualOrderManagementTests {

    private func makeBars(count: Int, close: Double = 1.1000) -> [CandleBar] {
        (0..<count).map { i in
            makeBar(time: Int64(i), open: 1.0990, high: 1.1010, low: 1.0980, close: close)
        }
    }

    @Test("Per-instrument isolation — different instruments stored separately")
    @MainActor func perInstrumentIsolation() {
        let vm = TradingViewModel()
        let bars = makeBars(count: 50)
        vm.beginVisualOrder(direction: "BUY", instrument: "EURUSD", bars: bars)
        vm.beginVisualOrder(direction: "SELL", instrument: "GBPUSD", bars: bars)

        #expect(vm.visualOrders.count == 2)
        #expect(vm.visualOrder(for: "EURUSD")?.direction == "BUY")
        #expect(vm.visualOrder(for: "GBPUSD")?.direction == "SELL")
    }

    @Test("Per-instrument isolation — same instrument overwrites")
    @MainActor func sameInstrumentOverwrites() {
        let vm = TradingViewModel()
        let bars = makeBars(count: 50)
        vm.beginVisualOrder(direction: "BUY", instrument: "EURUSD", bars: bars)
        vm.beginVisualOrder(direction: "SELL", instrument: "EURUSD", bars: bars)

        #expect(vm.visualOrders.count == 1)
        #expect(vm.visualOrder(for: "EURUSD")?.direction == "SELL")
    }

    @Test("Cancel removes only the target instrument")
    @MainActor func cancelRemovesTarget() {
        let vm = TradingViewModel()
        let bars = makeBars(count: 50)
        vm.beginVisualOrder(direction: "BUY", instrument: "EURUSD", bars: bars)
        vm.beginVisualOrder(direction: "SELL", instrument: "GBPUSD", bars: bars)
        vm.cancelVisualOrder(instrument: "EURUSD")

        #expect(vm.visualOrder(for: "EURUSD") == nil)
        #expect(vm.visualOrder(for: "GBPUSD") != nil)
    }

    @Test("Amount defaults to vm.amount")
    @MainActor func amountDefault() {
        let vm = TradingViewModel()
        let bars = makeBars(count: 50)
        vm.beginVisualOrder(direction: "BUY", instrument: "EURUSD", bars: bars)

        #expect(vm.visualOrder(for: "EURUSD")?.amount == vm.amount)
    }

    @Test("Adjust amount increases and clamps at minimum")
    @MainActor func adjustAmountClamping() {
        let vm = TradingViewModel()
        let bars = makeBars(count: 50)
        vm.beginVisualOrder(direction: "BUY", instrument: "EURUSD", bars: bars)

        vm.adjustVisualOrderAmount(instrument: "EURUSD", by: 0.001)
        #expect(vm.visualOrder(for: "EURUSD")?.amount == 0.011)

        // Try to go below minimum
        vm.adjustVisualOrderAmount(instrument: "EURUSD", by: -0.1)
        #expect(vm.visualOrder(for: "EURUSD")?.amount == 0.001)
    }

    @Test("Live price update refreshes entry price and bar indices")
    @MainActor func livePriceUpdate() {
        let vm = TradingViewModel()
        let bars = makeBars(count: 50, close: 1.1000)
        vm.beginVisualOrder(direction: "BUY", instrument: "EURUSD", bars: bars)

        let updated = vm.visualOrderWithLivePrice(for: "EURUSD", currentPrice: 1.1050, barCount: 55)
        #expect(updated?.entryPrice == 1.1050)
        #expect(updated?.startBarIndex == 56)
        #expect(updated?.endBarIndex == 66)
    }

    @Test("Live price update preserves box width")
    @MainActor func livePricePreservesBoxWidth() {
        let vm = TradingViewModel()
        let bars = makeBars(count: 50)
        vm.beginVisualOrder(direction: "BUY", instrument: "EURUSD", bars: bars)
        let original = vm.visualOrder(for: "EURUSD")!
        let originalWidth = original.endBarIndex - original.startBarIndex

        let updated = vm.visualOrderWithLivePrice(for: "EURUSD", currentPrice: 1.1050, barCount: 60)!
        let updatedWidth = updated.endBarIndex - updated.startBarIndex
        #expect(updatedWidth == originalWidth)
    }
}

@Suite("Visual order panel placement")
@MainActor
struct VisualOrderPanelPlacementTests {
    @Test("Default: panel sits to the right of the box, centred on entry")
    func placesRightWhenRoom() {
        let r = ChartView.visualOrderPanelRect(
            boxLeft: 100, boxRight: 300, entryY: 400, boxTopY: 350, boxBottomY: 450,
            isBuy: true, chartWidth: 1000, chartHeight: 800)
        #expect(r.minX >= 300)               // entirely right of the box
        #expect(abs(r.minX - 308) < 0.001)   // boxRight + gap(8)
        #expect(r.maxX <= 1000 - 4)
        #expect(abs(r.midY - 400) < 0.001)   // centred on entry
    }

    @Test("No room right → BUY drops the panel BELOW the box (risk side), off the candles")
    func buyFallsBelowWhenNoRoomRight() {
        let r = ChartView.visualOrderPanelRect(
            boxLeft: 750, boxRight: 970, entryY: 400, boxTopY: 350, boxBottomY: 450,
            isBuy: true, chartWidth: 1000, chartHeight: 800)
        #expect(r.minY >= 450)               // entirely below the box
        #expect(abs(r.minY - 458) < 0.001)   // boxBottomY + gap(8)
        #expect(r.maxX <= 1000 - 4)          // within bounds
    }

    @Test("No room right → SELL drops the panel ABOVE the box")
    func sellFallsAboveWhenNoRoomRight() {
        let r = ChartView.visualOrderPanelRect(
            boxLeft: 750, boxRight: 970, entryY: 400, boxTopY: 350, boxBottomY: 450,
            isBuy: false, chartWidth: 1000, chartHeight: 800)
        #expect(r.maxY <= 350)               // entirely above the box
        #expect(abs(r.maxY - 342) < 0.001)   // boxTopY - gap(8)
    }

    @Test("BUY flips above when there's no room below")
    func buyFlipsAboveWhenNoRoomBelow() {
        // No room right; box bottom near the chart floor so below doesn't fit → flip above.
        let r = ChartView.visualOrderPanelRect(
            boxLeft: 750, boxRight: 970, entryY: 400, boxTopY: 300, boxBottomY: 700,
            isBuy: true, chartWidth: 1000, chartHeight: 800)
        #expect(r.maxY <= 300)               // flipped above the box
    }

    @Test("Always stays on-screen, even in a too-narrow/short cell")
    func clampsOnScreen() {
        let r = ChartView.visualOrderPanelRect(
            boxLeft: 120, boxRight: 320, entryY: 200, boxTopY: 150, boxBottomY: 260,
            isBuy: true, chartWidth: 400, chartHeight: 500)
        #expect(r.minX >= 4)
        #expect(r.maxX <= 400 - 4)
        #expect(r.minY >= 4)
        #expect(r.maxY <= 500 - 4)
    }
}

@Suite("Visual order risk money (account-currency conversion)")
struct VisualOrderRiskMoneyTests {

    @Test("Same-currency quote (rate 1): risk is amount × distance × 1e6")
    func sameCurrencyRisk() {
        // EURUSD on a USD account: 0.018M units, 50-pip stop (0.0050), no spread.
        let order = VisualOrderState(direction: "BUY", instrument: "EURUSD", entryPrice: 1.1000,
                                     marketPrice: 1.1000, amount: 0.018, stopLoss: 1.0950,
                                     takeProfit: 1.1150, startBarIndex: 1, endBarIndex: 11)
        let risk = order.riskMoney(spread: 0, quoteToAccountRate: 1)
        #expect(abs(risk - 0.018 * 0.0050 * 1_000_000) < 1e-6)   // = 90 USD
    }

    @Test("JPY quote on EUR account: converted by the JPY→EUR rate (the bug)")
    func jpyQuoteConverted() {
        // EURJPY, 0.018M units, ~7.1-pip stop (0.071), EUR account. Quote (JPY) risk must be
        // multiplied by ~1/185 to land in EUR — matching the live diagnostic (≈€7.8, not ≈1440).
        let order = VisualOrderState(direction: "BUY", instrument: "EURJPY", entryPrice: 185.521,
                                     marketPrice: 185.521, amount: 0.018, stopLoss: 185.450,
                                     takeProfit: 185.734, startBarIndex: 1, endBarIndex: 11)
        let rate = 0.005390   // JPY→EUR
        let quoteRisk = order.riskMoney(spread: 0.009, quoteToAccountRate: 1)
        let acctRisk = order.riskMoney(spread: 0.009, quoteToAccountRate: rate)
        #expect(abs(quoteRisk - acctRisk / rate) < 1e-3)        // conversion is the only difference
        #expect(acctRisk > 5 && acctRisk < 10)                  // ≈ €7.8, not ≈ 1440
        #expect(quoteRisk > 1000)                               // the un-converted (buggy) figure
    }

    @Test("Spread widens the realized risk")
    func spreadPadsRisk() {
        let order = VisualOrderState(direction: "SELL", instrument: "EURUSD", entryPrice: 1.1000,
                                     marketPrice: 1.1000, amount: 0.01, stopLoss: 1.1050,
                                     takeProfit: 1.0900, startBarIndex: 1, endBarIndex: 11)
        let noSpread = order.riskMoney(spread: 0, quoteToAccountRate: 1)
        let withSpread = order.riskMoney(spread: 0.0002, quoteToAccountRate: 1)
        #expect(withSpread > noSpread)
    }
}
