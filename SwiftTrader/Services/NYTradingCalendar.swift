import Foundation

enum AggregatedPeriod: String, Codable, Sendable {
    case fourHours
    case daily
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
    static func sameBucket(_ a: Date, _ b: Date, period: AggregatedPeriod) -> Bool {
        switch period {
        case .fourHours: return fourHourBucketStart(at: a) == fourHourBucketStart(at: b)
        case .daily: return tradingDayStart(at: a) == tradingDayStart(at: b)
        }
    }

    /// Start of the bucket containing `at` for the given aggregated period.
    /// DAILY buckets are labeled by the session's CLOSING calendar day in NY:
    /// a session running Sun 17 ET → Mon 17 ET is labeled Monday (midnight ET).
    static func bucketStart(at: Date, period: AggregatedPeriod) -> Date {
        switch period {
        case .fourHours: return fourHourBucketStart(at: at)
        case .daily:
            let cal = calendar
            let sessionStart = tradingDayStart(at: at)
            return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: sessionStart))!
        }
    }
}
