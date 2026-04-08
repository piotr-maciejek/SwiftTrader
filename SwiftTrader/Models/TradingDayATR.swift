import Foundation

enum TradingDayATR {
    struct DayRange {
        let start: Date      // trading day start (17:00 ET)
        let high: Double
        let low: Double
        let close: Double    // last bar's close in this trading day
        var range: Double { high - low }
    }

    // MARK: - Trading day grouping

    /// Groups hourly (or any timeframe) bars into trading days.
    /// A forex trading day runs from 17:00 ET to 17:00 ET the next day.
    /// Bars exactly at 17:00 ET belong to the NEW trading day.
    static func tradingDayRanges(from bars: [CandleBar]) -> [DayRange] {
        guard !bars.isEmpty else { return [] }

        let nyTZ = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = nyTZ

        // Group bars by their trading day start
        var dayBuckets: [(start: Date, bars: [CandleBar])] = []

        for bar in bars {
            let barDate = bar.date
            let dayStart = tradingDayStart(for: barDate, calendar: calendar)

            if let lastIndex = dayBuckets.indices.last, dayBuckets[lastIndex].start == dayStart {
                dayBuckets[lastIndex].bars.append(bar)
            } else {
                dayBuckets.append((start: dayStart, bars: [bar]))
            }
        }

        return dayBuckets.map { bucket in
            let high = bucket.bars.map(\.high).max()!
            let low = bucket.bars.map(\.low).min()!
            let close = bucket.bars.last!.close
            return DayRange(start: bucket.start, high: high, low: low, close: close)
        }
    }

    /// Returns the trading day start (17:00 ET) for a given date.
    /// If the date is before 17:00 ET, it belongs to the previous day's session
    /// (which started at 17:00 ET the day before).
    static func tradingDayStart(for date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let hour = components.hour!

        var dayStart = calendar.startOfDay(for: date)
        if hour < 17 {
            // Before 17:00 ET — belongs to previous day's session
            dayStart = calendar.date(byAdding: .day, value: -1, to: dayStart)!
        }
        // Set to 17:00 ET
        return calendar.date(bySettingHour: 17, minute: 0, second: 0, of: dayStart)!
    }

    // MARK: - ATR calculation

    /// Computes ATR using True Range over the last `period` completed trading days.
    /// Returns nil if fewer than `period + 1` day ranges are available
    /// (we need the previous day's close for True Range).
    static func atr(from dayRanges: [DayRange], period: Int = 14) -> Double? {
        // Need at least period+1 ranges: 1 for previous close reference + period for averaging
        guard dayRanges.count > period else { return nil }

        // Use the last `period` completed days (exclude the very last if it's "today")
        // Caller should pass only completed days for pure ATR.
        let ranges = Array(dayRanges.suffix(period + 1))

        var trSum = 0.0
        for i in 1...period {
            let current = ranges[i]
            let prevClose = ranges[i - 1].close
            let tr = trueRange(high: current.high, low: current.low, previousClose: prevClose)
            trSum += tr
        }

        return trSum / Double(period)
    }

    /// True Range: max(H-L, |H-prevClose|, |L-prevClose|)
    static func trueRange(high: Double, low: Double, previousClose: Double) -> Double {
        max(high - low, abs(high - previousClose), abs(low - previousClose))
    }

    // MARK: - Today's progress

    /// Returns how much of the ATR has been covered in the current trading day (0-100+).
    static func todayProgress(currentDayRange: DayRange, atr: Double) -> Double {
        guard atr > 0 else { return 0 }
        return (currentDayRange.range / atr) * 100
    }

    // MARK: - Pip conversion

    /// Returns the multiplier to convert price difference to pips.
    /// JPY pairs use 0.01 per pip, all others use 0.0001.
    static func pipFactor(for instrument: String) -> Double {
        instrument.contains("JPY") ? 100 : 10_000
    }

    /// Convenience: compute ATR value, pips, and today's progress from hourly bars.
    static func compute(from bars: [CandleBar], instrument: String, period: Int = 14) -> (atr: Double, pips: Double, todayPercent: Double)? {
        let allDays = tradingDayRanges(from: bars)
        guard allDays.count > 1 else { return nil }

        // Separate completed days from the current (possibly incomplete) day
        let completedDays = Array(allDays.dropLast())
        let today = allDays.last!

        guard let atrValue = atr(from: completedDays, period: period) else { return nil }

        let pips = atrValue * pipFactor(for: instrument)
        let percent = todayProgress(currentDayRange: today, atr: atrValue)

        return (atr: atrValue, pips: pips, todayPercent: percent)
    }
}
