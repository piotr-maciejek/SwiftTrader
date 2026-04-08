import Testing
import Foundation
@testable import SwiftTrader

private let nyTZ = TimeZone(identifier: "America/New_York")!

/// Create a date at a specific hour in NY timezone.
private func nyDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = nyTZ
    return calendar.date(from: DateComponents(
        timeZone: nyTZ, year: year, month: month, day: day, hour: hour, minute: minute
    ))!
}

/// Create a CandleBar at a specific NY time.
private func makeBar(
    year: Int = 2025, month: Int = 1, day: Int = 6, hour: Int,
    open: Double = 1.10, high: Double = 1.12, low: Double = 1.08, close: Double = 1.11,
    volume: Double = 100
) -> CandleBar {
    let date = nyDate(year, month, day, hour)
    return CandleBar(
        time: Int64(date.timeIntervalSince1970 * 1000),
        open: open, high: high, low: low, close: close,
        volume: volume, partial: false
    )
}

@Suite("TradingDayATR")
struct TradingDayATRTests {

    // MARK: - Trading day boundary

    @Test("Bar at 16:59 ET belongs to previous day's session")
    func barBefore17BelongsToPreviousDay() {
        // 16:59 on Monday Jan 6 → trading day started Sunday Jan 5 at 17:00
        let bar = makeBar(year: 2025, month: 1, day: 6, hour: 16)
        let ranges = TradingDayATR.tradingDayRanges(from: [bar])
        #expect(ranges.count == 1)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = nyTZ
        let components = cal.dateComponents([.month, .day, .hour], from: ranges[0].start)
        #expect(components.month == 1)
        #expect(components.day == 5)  // Sunday
        #expect(components.hour == 17)
    }

    @Test("Bar at 17:00 ET belongs to new day's session")
    func barAt17BelongsToNewDay() {
        // 17:00 on Monday Jan 6 → new trading day starts Monday Jan 6 at 17:00
        let date = nyDate(2025, 1, 6, 17, 0)
        let bar = CandleBar(
            time: Int64(date.timeIntervalSince1970 * 1000),
            open: 1.10, high: 1.12, low: 1.08, close: 1.11,
            volume: 100, partial: false
        )
        let ranges = TradingDayATR.tradingDayRanges(from: [bar])
        #expect(ranges.count == 1)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = nyTZ
        let components = cal.dateComponents([.month, .day, .hour], from: ranges[0].start)
        #expect(components.day == 6)  // Monday
        #expect(components.hour == 17)
    }

    // MARK: - Day grouping

    @Test("Bars spanning two trading days produce two ranges")
    func twoTradingDays() {
        // Day 1: Monday 10:00 and 14:00
        // Day 2: Tuesday 10:00 (trading day started Monday 17:00)
        let bars = [
            makeBar(day: 6, hour: 10, high: 1.15, low: 1.05, close: 1.10),
            makeBar(day: 6, hour: 14, high: 1.18, low: 1.06, close: 1.12),
            makeBar(day: 7, hour: 10, high: 1.20, low: 1.08, close: 1.15),
        ]
        let ranges = TradingDayATR.tradingDayRanges(from: bars)
        #expect(ranges.count == 2)
        // First day: high = max(1.15, 1.18) = 1.18, low = min(1.05, 1.06) = 1.05
        #expect(ranges[0].high == 1.18)
        #expect(ranges[0].low == 1.05)
        #expect(ranges[0].close == 1.12)
        // Second day
        #expect(ranges[1].high == 1.20)
        #expect(ranges[1].low == 1.08)
    }

    @Test("Empty bars produce no ranges")
    func emptyBars() {
        let ranges = TradingDayATR.tradingDayRanges(from: [])
        #expect(ranges.isEmpty)
    }

    // MARK: - True Range

    @Test("True Range with no gap equals high minus low")
    func trueRangeNoGap() {
        // Previous close within current range → TR = H - L
        let tr = TradingDayATR.trueRange(high: 1.20, low: 1.10, previousClose: 1.15)
        #expect(abs(tr - 0.10) < 0.0001)
    }

    @Test("True Range with gap up uses high minus previous close")
    func trueRangeGapUp() {
        // Gap up: previous close below current low
        let tr = TradingDayATR.trueRange(high: 1.30, low: 1.25, previousClose: 1.10)
        // max(0.05, |1.30-1.10|, |1.25-1.10|) = max(0.05, 0.20, 0.15) = 0.20
        #expect(abs(tr - 0.20) < 0.0001)
    }

    @Test("True Range with gap down uses previous close minus low")
    func trueRangeGapDown() {
        // Gap down: previous close above current high
        let tr = TradingDayATR.trueRange(high: 1.05, low: 1.00, previousClose: 1.20)
        // max(0.05, |1.05-1.20|, |1.00-1.20|) = max(0.05, 0.15, 0.20) = 0.20
        #expect(abs(tr - 0.20) < 0.0001)
    }

    // MARK: - ATR calculation

    @Test("ATR is simple average of True Ranges over period")
    func atrCalculation() {
        // Create 4 day ranges (need period+1=3+1 for period=3)
        let ranges: [TradingDayATR.DayRange] = [
            .init(start: nyDate(2025, 1, 5, 17), high: 1.20, low: 1.10, close: 1.15),
            .init(start: nyDate(2025, 1, 6, 17), high: 1.22, low: 1.12, close: 1.18),
            .init(start: nyDate(2025, 1, 7, 17), high: 1.25, low: 1.15, close: 1.20),
            .init(start: nyDate(2025, 1, 8, 17), high: 1.28, low: 1.16, close: 1.22),
        ]

        let atr = TradingDayATR.atr(from: ranges, period: 3)
        #expect(atr != nil)

        // TR1: max(1.22-1.12, |1.22-1.15|, |1.12-1.15|) = max(0.10, 0.07, 0.03) = 0.10
        // TR2: max(1.25-1.15, |1.25-1.18|, |1.15-1.18|) = max(0.10, 0.07, 0.03) = 0.10
        // TR3: max(1.28-1.16, |1.28-1.20|, |1.16-1.20|) = max(0.12, 0.08, 0.04) = 0.12
        // ATR = (0.10 + 0.10 + 0.12) / 3 = 0.1067
        let expected = (0.10 + 0.10 + 0.12) / 3.0
        #expect(abs(atr! - expected) < 0.0001)
    }

    @Test("ATR returns nil when insufficient data")
    func atrInsufficientData() {
        let ranges: [TradingDayATR.DayRange] = [
            .init(start: nyDate(2025, 1, 5, 17), high: 1.20, low: 1.10, close: 1.15),
        ]
        // Need > period ranges, so period=14 with 1 range → nil
        #expect(TradingDayATR.atr(from: ranges, period: 14) == nil)
    }

    // MARK: - Today's progress

    @Test("Today progress is range over ATR as percentage")
    func todayProgress() {
        let today = TradingDayATR.DayRange(
            start: nyDate(2025, 1, 6, 17), high: 1.15, low: 1.10, close: 1.12
        )
        // range = 0.05, ATR = 0.10 → 50%
        let progress = TradingDayATR.todayProgress(currentDayRange: today, atr: 0.10)
        #expect(abs(progress - 50.0) < 0.01)
    }

    @Test("Today progress can exceed 100%")
    func todayProgressExceeds100() {
        let today = TradingDayATR.DayRange(
            start: nyDate(2025, 1, 6, 17), high: 1.20, low: 1.05, close: 1.15
        )
        // range = 0.15, ATR = 0.10 → 150%
        let progress = TradingDayATR.todayProgress(currentDayRange: today, atr: 0.10)
        #expect(abs(progress - 150.0) < 0.01)
    }

    // MARK: - Pip factor

    @Test("JPY pairs use 100 pip factor")
    func jpyPipFactor() {
        #expect(TradingDayATR.pipFactor(for: "USDJPY") == 100)
        #expect(TradingDayATR.pipFactor(for: "EURJPY") == 100)
    }

    @Test("Non-JPY pairs use 10000 pip factor")
    func nonJpyPipFactor() {
        #expect(TradingDayATR.pipFactor(for: "EURUSD") == 10_000)
        #expect(TradingDayATR.pipFactor(for: "GBPCHF") == 10_000)
    }

    // MARK: - Compute convenience

    @Test("Compute returns nil for insufficient bars")
    func computeInsufficientBars() {
        let bars = [makeBar(hour: 10)]
        #expect(TradingDayATR.compute(from: bars, instrument: "EURUSD") == nil)
    }
}
