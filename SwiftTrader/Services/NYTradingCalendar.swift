import Foundation

enum AggregatedPeriod: String, Codable, Sendable {
    case fourHours
    case daily
    /// Client-derived 3-minute candles bucketed from raw ONE_MIN bars on a fixed
    /// epoch grid (NOT NY-session-aligned — Dukascopy has no native 3m period).
    case threeMinutes
}

enum NYTradingCalendar {
    static let nyTZ = TimeZone(identifier: "America/New_York")!

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = nyTZ
        return c
    }()

    /// Start of the forex trading day containing `at`.
    /// Trading day runs 17:00 ET → 17:00 ET next day. A date exactly at 17:00 ET
    /// belongs to the NEW day that opens at 17:00.
    static func tradingDayStart(at: Date) -> Date {
        let cal = calendar
        let comps = cal.dateComponents([.hour], from: at)
        let hour = comps.hour ?? 0
        var dayStart = cal.startOfDay(for: at)
        if hour < 17 {
            dayStart = cal.date(byAdding: .day, value: -1, to: dayStart)!
        }
        return cal.date(bySettingHour: 17, minute: 0, second: 0, of: dayStart)!
    }

    /// Whether the FX market is closed at `at` — the Fri 17:00 ET → Sun 17:00 ET
    /// weekend closure. Mirrors `BarAggregator.isWeekendFiller` (same gregorian
    /// weekday numbering: 1=Sun … 6=Fri … 7=Sat), DST-correct via the NY calendar.
    static func isMarketClosed(at: Date) -> Bool {
        let comps = calendar.dateComponents([.weekday, .hour], from: at)
        guard let wd = comps.weekday, let hr = comps.hour else { return false }
        if wd == 7 { return true }              // Saturday — all day
        if wd == 6 && hr >= 17 { return true }  // Friday from 17:00 ET
        if wd == 1 && hr < 17 { return true }   // Sunday before 17:00 ET
        return false
    }

    /// Whether `at` falls inside one of the two truly global FX-wide closures —
    /// Christmas Day and New Year's Day. Every other "holiday" (Good Friday,
    /// Independence Day, Thanksgiving, etc.) only closes one venue while London/
    /// Tokyo/Sydney keep trading, so Dukascopy still publishes bars and we don't
    /// want to call those slots a gap. NY-calendar-relative so a Christmas window
    /// is the full local 24h regardless of DST.
    static func isFXHoliday(at: Date) -> Bool {
        let comps = calendar.dateComponents([.month, .day], from: at)
        guard let m = comps.month, let d = comps.day else { return false }
        if m == 12 && d == 25 { return true }   // Christmas Day
        if m == 1  && d == 1  { return true }   // New Year's Day
        return false
    }

    /// True iff every slot in `[fromMs, toMs]` (stepped hour-by-hour) is either a
    /// weekend closure or a global FX holiday — i.e. no real trading window exists
    /// inside the range. Used by gap detection to discard "gaps" that are nothing
    /// but a Fri 17 ET → Sun 17 ET weekend, or a weekend extended by Dec 25 / Jan 1.
    /// Early-exits on the first trading slot, so an unrelated 60-day gap takes ~hours
    /// to first Monday morning, not 1440 iterations.
    static func isClosedThroughout(fromMs: Int64, toMs: Int64) -> Bool {
        guard fromMs <= toMs else { return true }
        var t = fromMs
        while t <= toMs {
            let d = Date(timeIntervalSince1970: Double(t) / 1000)
            if !isMarketClosed(at: d) && !isFXHoliday(at: d) { return false }
            t += 3_600_000
        }
        return true
    }

    /// Epoch ms of the newest bar that can possibly exist as of `at`: if the
    /// market is open, `at` itself; if closed, the Friday 17:00 ET that began
    /// the current weekend closure. Used to clamp the gap-fill target so the
    /// client doesn't chase candles that don't exist over the weekend.
    static func lastSessionCloseMs(at: Date) -> Int64 {
        guard isMarketClosed(at: at) else { return ms(at) }
        let cal = calendar
        let wd = cal.dateComponents([.weekday], from: at).weekday ?? 6
        let back = wd == 7 ? 1 : (wd == 1 ? 2 : 0)  // Sat→Fri, Sun→Fri, Fri→same day
        let friday = cal.date(byAdding: .day, value: -back, to: at)!
        let close = cal.date(bySettingHour: 17, minute: 0, second: 0,
                             of: cal.startOfDay(for: friday))!
        return ms(close)
    }

    /// Start of the 4H bucket containing `at`. Buckets open at 17, 21, 01, 05, 09, 13 ET.
    static func fourHourBucketStart(at: Date) -> Date {
        let cal = calendar
        let dayStart = tradingDayStart(at: at)
        let nextDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: dayStart))!

        var buckets: [Date] = []
        buckets.append(dayStart)
        buckets.append(cal.date(bySettingHour: 21, minute: 0, second: 0, of: dayStart)!)
        buckets.append(cal.date(bySettingHour: 1, minute: 0, second: 0, of: nextDay)!)
        buckets.append(cal.date(bySettingHour: 5, minute: 0, second: 0, of: nextDay)!)
        buckets.append(cal.date(bySettingHour: 9, minute: 0, second: 0, of: nextDay)!)
        buckets.append(cal.date(bySettingHour: 13, minute: 0, second: 0, of: nextDay)!)

        return buckets.last { $0 <= at } ?? dayStart
    }

    /// Whether two dates fall in the same bucket for the given aggregated period.
    /// Fixed-grid periods (e.g. `.threeMinutes`) ignore NY-session rules entirely —
    /// the canonical computation lives in `BarAggregator.fixedGridBucketStartMs`.
    static func sameBucket(_ a: Date, _ b: Date, period: AggregatedPeriod) -> Bool {
        switch period {
        case .fourHours: return fourHourBucketStart(at: a) == fourHourBucketStart(at: b)
        case .daily: return tradingDayStart(at: a) == tradingDayStart(at: b)
        case .threeMinutes:
            return BarAggregator.fixedGridBucketStartMs(ms(a), 180_000)
                == BarAggregator.fixedGridBucketStartMs(ms(b), 180_000)
        }
    }

    /// Start of the bucket containing `at` for the given aggregated period.
    /// DAILY buckets are labeled by the session's CLOSING calendar day in NY:
    /// a session running Sun 17 ET → Mon 17 ET is labeled Monday (midnight ET).
    /// Fixed-grid periods (e.g. `.threeMinutes`) ignore NY-session rules entirely —
    /// the canonical computation lives in `BarAggregator.fixedGridBucketStartMs`.
    static func bucketStart(at: Date, period: AggregatedPeriod) -> Date {
        switch period {
        case .fourHours: return fourHourBucketStart(at: at)
        case .daily:
            let cal = calendar
            let sessionStart = tradingDayStart(at: at)
            return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: sessionStart))!
        case .threeMinutes:
            let startMs = BarAggregator.fixedGridBucketStartMs(ms(at), 180_000)
            return Date(timeIntervalSince1970: Double(startMs) / 1000.0)
        }
    }

    private static func ms(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
