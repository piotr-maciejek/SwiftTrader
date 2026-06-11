import Testing
@testable import SwiftTrader

@Suite("Position Sizing")
struct PositionSizingTests {

    @Test("Standard case — 20 pip stop, 10k equity")
    func standardCase() {
        // equity=10000, 5% risk = 500, stop distance=0.0020
        // riskLots = 500 / (0.0020 * 1_000_000) = 500 / 2000 = 0.25
        let result = PositionSizing.calculate(
            equity: 10_000, freeMargin: 100_000, riskFraction: 0.05,
            entryPrice: 1.1000, stopLoss: 1.0980, quoteToAccountRate: 1)
        #expect(result.lots == 0.25)
        #expect(result.isMarginCapped == false)
    }

    @Test("Small account — 1k equity")
    func smallAccount() {
        // 1000 * 0.05 = 50, stop distance = 0.0020
        // riskLots = 50 / 2000 = 0.025
        let result = PositionSizing.calculate(
            equity: 1_000, freeMargin: 100_000, riskFraction: 0.05,
            entryPrice: 1.1000, stopLoss: 1.0980, quoteToAccountRate: 1)
        #expect(result.lots == 0.025)
        #expect(result.isMarginCapped == false)
    }

    @Test("Wide stop — 100 pip stop")
    func wideStop() {
        // 10000 * 0.05 = 500, stop distance = 0.0100
        // riskLots = 500 / 10000 = 0.05
        let result = PositionSizing.calculate(
            equity: 10_000, freeMargin: 100_000, riskFraction: 0.05,
            entryPrice: 1.1000, stopLoss: 1.0900, quoteToAccountRate: 1)
        #expect(result.lots == 0.05)
        #expect(result.isMarginCapped == false)
    }

    @Test("JPY pair — entry 150.00, SL 149.50")
    func jpyPair() {
        // 10000 * 0.05 = 500, stop distance = 0.50
        // riskLots = 500 / (0.50 * 1_000_000) = 500 / 500000 = 0.001
        let result = PositionSizing.calculate(
            equity: 10_000, freeMargin: 100_000, riskFraction: 0.05,
            entryPrice: 150.00, stopLoss: 149.50, quoteToAccountRate: 1)
        #expect(result.lots == 0.001)
        #expect(result.isMarginCapped == false)
    }

    @Test("Zero stop distance returns minLot")
    func zeroStopDistance() {
        let result = PositionSizing.calculate(
            equity: 10_000, freeMargin: 100_000, riskFraction: 0.05,
            entryPrice: 1.1000, stopLoss: 1.1000, quoteToAccountRate: 1)
        #expect(result.lots == 0.001)
        #expect(result.isMarginCapped == false)
    }

    @Test("Rounds down to lotStep")
    func roundsDown() {
        // 10000 * 0.05 = 500, stop distance = 0.0023
        // riskLots = 500 / 2300 = 0.21739... → floor to 0.217
        let result = PositionSizing.calculate(
            equity: 10_000, freeMargin: 100_000, riskFraction: 0.05,
            entryPrice: 1.1000, stopLoss: 1.0977, quoteToAccountRate: 1)
        #expect(result.lots == 0.217)
        #expect(result.isMarginCapped == false)
    }

    @Test("Below minLot clamps")
    func belowMinLotClamps() {
        // Very wide stop: equity=100, 5% risk = 5, stop distance = 1.0
        // riskLots = 5 / 1_000_000 = 0.000005 → clamp to 0.001
        let result = PositionSizing.calculate(
            equity: 100, freeMargin: 100_000, riskFraction: 0.05,
            entryPrice: 1.1000, stopLoss: 0.1000, quoteToAccountRate: 1)
        #expect(result.lots == 0.001)
        #expect(result.isMarginCapped == false)
    }

    @Test("Margin cap — freeMargin constrains position size")
    func marginCapped() {
        // Risk allows: 10000 * 0.05 = 500, stop = 0.0020, riskLots = 500/2000 = 0.25
        // Margin allows: (200 * 0.80 * 30) / (1_000_000 * 1.1) = 4800 / 1_100_000 = 0.0043636... → 0.004
        // marginLots < riskLots → margin-capped
        let result = PositionSizing.calculate(
            equity: 10_000, freeMargin: 200, riskFraction: 0.05,
            entryPrice: 1.1000, stopLoss: 1.0980, quoteToAccountRate: 1)
        #expect(result.lots == 0.004)
        #expect(result.isMarginCapped == true)
    }

    @Test("Risk is binding — margin allows more than risk")
    func riskIsBinding() {
        // Risk: 10000 * 0.05 = 500, stop = 0.0020, riskLots = 0.25
        // Margin (with buffer): (50000 * 0.90 * 30) / (1_000_000 * 1.1) = 1350000/1100000 ≈ 1.227
        // riskLots < marginLots → risk is binding
        let result = PositionSizing.calculate(
            equity: 10_000, freeMargin: 50_000, riskFraction: 0.05,
            entryPrice: 1.1000, stopLoss: 1.0980, quoteToAccountRate: 1)
        #expect(result.lots == 0.25)
        #expect(result.isMarginCapped == false)
    }

    @Test("SELL direction — SL above entry")
    func sellDirection() {
        // Same math as buy — abs(entryPrice - stopLoss) = 0.0020
        let result = PositionSizing.calculate(
            equity: 10_000, freeMargin: 100_000, riskFraction: 0.05,
            entryPrice: 1.1000, stopLoss: 1.1020, quoteToAccountRate: 1)
        #expect(result.lots == 0.25)
        #expect(result.isMarginCapped == false)
    }

    @Test("Zero equity returns minLot")
    func zeroEquity() {
        let result = PositionSizing.calculate(
            equity: 0, freeMargin: 0, riskFraction: 0.05,
            entryPrice: 1.1000, stopLoss: 1.0980, quoteToAccountRate: 1)
        #expect(result.lots == 0.001)
    }

    @Test("Spread inflates stopDistance for risk calc")
    func spreadInflatesStop() {
        // 5% of 10k = 500 risk. stop=20 pips, spread=5 pips → realized=25 pips.
        // riskLots = 500 / (0.0025 * 1_000_000) = 0.20
        let result = PositionSizing.calculate(
            equity: 10_000, freeMargin: 100_000, riskFraction: 0.05,
            entryPrice: 1.1000, stopLoss: 1.0980,
            spread: 0.0005, quoteToAccountRate: 1)
        #expect(result.lots == 0.20)
        #expect(result.isMarginCapped == false)
    }

    @Test("Spread of zero matches no-spread call")
    func spreadZeroIsTransparent() {
        let withZero = PositionSizing.calculate(
            equity: 10_000, freeMargin: 100_000, riskFraction: 0.05,
            entryPrice: 1.1000, stopLoss: 1.0980, spread: 0, quoteToAccountRate: 1)
        let baseline = PositionSizing.calculate(
            equity: 10_000, freeMargin: 100_000, riskFraction: 0.05,
            entryPrice: 1.1000, stopLoss: 1.0980, quoteToAccountRate: 1)
        #expect(withZero == baseline)
    }

    @Test("Margin buffer reduces available lots by 20%")
    func marginBufferReducesLots() {
        // Without buffer: marginLots = (1000 * 30) / (1_000_000 * 1.0) = 0.03
        // With 80% buffer: marginLots = (1000 * 0.80 * 30) / (1_000_000 * 1.0) = 0.024
        let result = PositionSizing.calculate(
            equity: 100_000, freeMargin: 1_000, riskFraction: 0.05,
            entryPrice: 1.0000, stopLoss: 0.9990, quoteToAccountRate: 1)
        #expect(result.lots == 0.024)
        #expect(result.isMarginCapped == true)

        // Same scenario with no buffer
        let unbuffered = PositionSizing.calculate(
            equity: 100_000, freeMargin: 1_000, riskFraction: 0.05,
            entryPrice: 1.0000, stopLoss: 0.9990, marginBuffer: 1.0,
            quoteToAccountRate: 1)
        #expect(unbuffered.lots == 0.03)
        #expect(unbuffered.isMarginCapped == true)
    }

    // MARK: - Quote→account currency conversion

    @Test("PLN account, USD-quote pair — rate 4 quarters the size")
    func plnAccountConversion() {
        // Account currency PLN, EURUSD: 1 USD = 4 PLN → quoteToAccountRate = 4.
        // Loss per lot in PLN is 4× the USD figure, so lots are ¼ of the rate-1 result.
        // baseline (rate 1): 500 / 2000 = 0.25 → with rate 4: 500 / 8000 = 0.0625 → floor 0.062
        let result = PositionSizing.calculate(
            equity: 10_000, freeMargin: 100_000, riskFraction: 0.05,
            entryPrice: 1.1000, stopLoss: 1.0980, quoteToAccountRate: 4)
        #expect(result.lots == 0.062)
        #expect(result.isMarginCapped == false)
        #expect(result.conversionUnavailable == false)
    }

    @Test("EUR account, JPY-quote pair — fractional rate scales size up")
    func jpyQuoteConversion() {
        // 1 JPY ≈ 1/171 EUR → quoteToAccountRate = 1/171. EUR risk buys ~171× the
        // JPY-denominated loss the currency-blind formula assumed.
        // riskLots = 500 / (0.50 * 1_000_000 * (1/171)) = 500 / 2923.97... = 0.171
        let result = PositionSizing.calculate(
            equity: 10_000, freeMargin: 1_000_000, riskFraction: 0.05,
            entryPrice: 150.00, stopLoss: 149.50, quoteToAccountRate: 1.0 / 171.0)
        #expect(result.lots == 0.171)
        #expect(result.isMarginCapped == false)
    }

    @Test("Margin cap respects the conversion rate")
    func marginCapWithConversion() {
        // Margin in account ccy must cover notional × rate. With rate 4:
        // marginLots = (200 * 0.80 * 30) / (1_000_000 * 1.1 * 4) = 4800 / 4_400_000 ≈ 0.00109 → 0.001
        // riskLots = 500 / (0.0020 * 1_000_000 * 4) = 0.0625 → margin caps.
        let result = PositionSizing.calculate(
            equity: 10_000, freeMargin: 200, riskFraction: 0.05,
            entryPrice: 1.1000, stopLoss: 1.0980, quoteToAccountRate: 4)
        #expect(result.lots == 0.001)
        #expect(result.isMarginCapped == true)
    }

    @Test("Missing conversion rate refuses to auto-size")
    func missingRateRefusesToSize() {
        let result = PositionSizing.calculate(
            equity: 10_000, freeMargin: 100_000, riskFraction: 0.05,
            entryPrice: 1.1000, stopLoss: 1.0980, quoteToAccountRate: nil)
        #expect(result.conversionUnavailable == true)
        #expect(result.lots == 0.001)
        #expect(result.isMarginCapped == false)
    }

    @Test("Non-positive conversion rate treated as unavailable")
    func nonPositiveRateUnavailable() {
        let result = PositionSizing.calculate(
            equity: 10_000, freeMargin: 100_000, riskFraction: 0.05,
            entryPrice: 1.1000, stopLoss: 1.0980, quoteToAccountRate: 0)
        #expect(result.conversionUnavailable == true)
        #expect(result.lots == 0.001)
    }

    @Test("Rate 1 result is not flagged unavailable")
    func rateOneNotFlagged() {
        let result = PositionSizing.calculate(
            equity: 10_000, freeMargin: 100_000, riskFraction: 0.05,
            entryPrice: 1.1000, stopLoss: 1.0980, quoteToAccountRate: 1)
        #expect(result.conversionUnavailable == false)
    }
}
