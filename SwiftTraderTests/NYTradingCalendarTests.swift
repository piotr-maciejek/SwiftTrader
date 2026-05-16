import Foundation
import Testing
@testable import SwiftTrader

private let nyTZ = TimeZone(identifier: "America/New_York")!

private func nyDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    var comps = DateComponents()
    comps.timeZone = nyTZ
    comps.year = year
    comps.month = month
    comps.day = day
    comps.hour = hour
    comps.minute = minute
    return Calendar(identifier: .gregorian).date(from: comps)!
}

@Suite("NYTradingCalendar")
struct NYTradingCalendarTests {

    // MARK: tradingDayStart

    @Test("Before 17:00 ET belongs to previous session")
    func beforeClose() {
        let at = nyDate(2024, 3, 5, 12, 0) // Tue 12:00 ET
        let start = NYTradingCalendar.tradingDayStart(at: at)
        #expect(start == nyDate(2024, 3, 4, 17, 0)) // Mon 17:00 ET
    }

    @Test("After 17:00 ET belongs to new session")
    func afterClose() {
        let at = nyDate(2024, 3, 5, 18, 0)
        let start = NYTradingCalendar.tradingDayStart(at: at)
        #expect(start == nyDate(2024, 3, 5, 17, 0))
    }

    @Test("Exactly 17:00 ET starts new session")
    func exactClose() {
        let at = nyDate(2024, 3, 5, 17, 0)
        let start = NYTradingCalendar.tradingDayStart(at: at)
        #expect(start == nyDate(2024, 3, 5, 17, 0))
    }

    // MARK: DST edges

    @Test("US DST start (spring forward) 2024-03-10")
    func usDstStart() {
        // 05:00 EDT on Sun Mar 10 = 09:00 UTC. Trading day started 17:00 EST Sat Mar 9 (22:00 UTC).
        let at = nyDate(2024, 3, 10, 5, 0)
        let start = NYTradingCalendar.tradingDayStart(at: at)
        #expect(start == nyDate(2024, 3, 9, 17, 0))
    }

    @Test("US DST end (fall back) 2024-11-03")
    func usDstEnd() {
        // 09:00 EST on Sun Nov 3 (= 14:00 UTC). Trading day started 17:00 EDT Sat Nov 2 (21:00 UTC).
        let at = nyDate(2024, 11, 3, 9, 0)
        let start = NYTradingCalendar.tradingDayStart(at: at)
        #expect(start == nyDate(2024, 11, 2, 17, 0))
    }

    @Test("EU DST start (NY already on DST) — 2024-03-31")
    func euDstStart() {
        let at = nyDate(2024, 3, 31, 12, 0)
        let start = NYTradingCalendar.tradingDayStart(at: at)
        #expect(start == nyDate(2024, 3, 30, 17, 0))
    }

    @Test("EU DST end (NY still on DST) — 2024-10-27")
    func euDstEnd() {
        let at = nyDate(2024, 10, 27, 12, 0)
        let start = NYTradingCalendar.tradingDayStart(at: at)
        #expect(start == nyDate(2024, 10, 26, 17, 0))
    }

    // MARK: 4H bucket

    @Test("4H bucket at 20:00 ET → 17:00 ET")
    func bucket20() {
        let at = nyDate(2024, 4, 15, 20, 0)
        let bucket = NYTradingCalendar.fourHourBucketStart(at: at)
        #expect(bucket == nyDate(2024, 4, 15, 17, 0))
    }

    @Test("4H bucket at exactly 21:00 ET → 21:00 ET")
    func bucket21() {
        let at = nyDate(2024, 4, 15, 21, 0)
        let bucket = NYTradingCalendar.fourHourBucketStart(at: at)
        #expect(bucket == nyDate(2024, 4, 15, 21, 0))
    }

    @Test("4H bucket at 00:30 ET rolls into same trading-day 21:00 ET bucket")
    func bucketMidnight() {
        let at = nyDate(2024, 4, 16, 0, 30) // after midnight local
        let bucket = NYTradingCalendar.fourHourBucketStart(at: at)
        #expect(bucket == nyDate(2024, 4, 15, 21, 0))
    }

    @Test("4H bucket at 05:30 ET → 05:00 ET")
    func bucket0530() {
        let at = nyDate(2024, 4, 16, 5, 30)
        let bucket = NYTradingCalendar.fourHourBucketStart(at: at)
        #expect(bucket == nyDate(2024, 4, 16, 5, 0))
    }

    @Test("4H bucket at 16:59 ET → 13:00 ET (still previous trading day)")
    func bucketBeforeClose() {
        let at = nyDate(2024, 4, 16, 16, 59)
        let bucket = NYTradingCalendar.fourHourBucketStart(at: at)
        #expect(bucket == nyDate(2024, 4, 16, 13, 0))
    }

    @Test("4H bucket at 17:00 ET → 17:00 ET (start of new trading day)")
    func bucketExactClose() {
        let at = nyDate(2024, 4, 16, 17, 0)
        let bucket = NYTradingCalendar.fourHourBucketStart(at: at)
        #expect(bucket == nyDate(2024, 4, 16, 17, 0))
    }

    @Test("4H bucket across DST spring forward: 04:00 EDT Mar 10 → 01:00 EDT Mar 10")
    func bucketSpringForward() {
        let at = nyDate(2024, 3, 10, 4, 0)
        let bucket = NYTradingCalendar.fourHourBucketStart(at: at)
        #expect(bucket == nyDate(2024, 3, 10, 1, 0))
    }

    @Test("4H bucket across DST fall back: 04:00 EST Nov 3 → 01:00 EDT Nov 3")
    func bucketFallBack() {
        let at = nyDate(2024, 11, 3, 4, 0)
        let bucket = NYTradingCalendar.fourHourBucketStart(at: at)
        #expect(bucket == nyDate(2024, 11, 3, 1, 0))
    }

    // MARK: sameBucket

    @Test("sameBucket returns true for bars within same 4H bucket")
    func sameBucketFourHours() {
        let a = nyDate(2024, 4, 15, 17, 30)
        let b = nyDate(2024, 4, 15, 20, 59)
        #expect(NYTradingCalendar.sameBucket(a, b, period: .fourHours))
    }

    @Test("sameBucket returns false across 4H bucket boundary")
    func differentBucketFourHours() {
        let a = nyDate(2024, 4, 15, 20, 59)
        let b = nyDate(2024, 4, 15, 21, 0)
        #expect(!NYTradingCalendar.sameBucket(a, b, period: .fourHours))
    }

    @Test("sameBucket DAILY treats 16:59 ET and 17:01 ET as different days")
    func dailyBoundary() {
        let a = nyDate(2024, 4, 16, 16, 59)
        let b = nyDate(2024, 4, 16, 17, 1)
        #expect(!NYTradingCalendar.sameBucket(a, b, period: .daily))
    }

    // MARK: threeMinutes (fixed epoch grid — no NY-session rules)

    @Test("bucketStart THREE_MINS floors to the :03 grid cell")
    func threeMinBucketStart() {
        // :00,:01,:02 all floor to the 17:00 cell; :03 starts the next cell.
        #expect(NYTradingCalendar.bucketStart(at: nyDate(2024, 4, 16, 17, 1),
                                              period: .threeMinutes)
                == nyDate(2024, 4, 16, 17, 0))
        #expect(NYTradingCalendar.bucketStart(at: nyDate(2024, 4, 16, 17, 8),
                                              period: .threeMinutes)
                == nyDate(2024, 4, 16, 17, 6))
        #expect(NYTradingCalendar.bucketStart(at: nyDate(2024, 4, 16, 17, 3),
                                              period: .threeMinutes)
                == nyDate(2024, 4, 16, 17, 3))
    }

    @Test("sameBucket THREE_MINS groups :00–:02 and splits at :03")
    func threeMinSameBucket() {
        #expect(NYTradingCalendar.sameBucket(nyDate(2024, 4, 16, 17, 0),
                                             nyDate(2024, 4, 16, 17, 2),
                                             period: .threeMinutes))
        #expect(!NYTradingCalendar.sameBucket(nyDate(2024, 4, 16, 17, 2),
                                              nyDate(2024, 4, 16, 17, 3),
                                              period: .threeMinutes))
    }

    // MARK: market-closed / last session close

    @Test("isMarketClosed spans the Fri 17:00 → Sun 17:00 ET closure")
    func marketClosedWindow() {
        // 2024-04-16 Tue, 04-19 Fri, 04-20 Sat, 04-21 Sun.
        #expect(!NYTradingCalendar.isMarketClosed(at: nyDate(2024, 4, 16, 12, 0)))  // Tue — open
        #expect(!NYTradingCalendar.isMarketClosed(at: nyDate(2024, 4, 19, 16, 59))) // Fri 16:59 — open
        #expect(NYTradingCalendar.isMarketClosed(at: nyDate(2024, 4, 19, 17, 0)))   // Fri 17:00 — closed
        #expect(NYTradingCalendar.isMarketClosed(at: nyDate(2024, 4, 20, 3, 0)))    // Sat — closed
        #expect(NYTradingCalendar.isMarketClosed(at: nyDate(2024, 4, 21, 16, 59)))  // Sun 16:59 — closed
        #expect(!NYTradingCalendar.isMarketClosed(at: nyDate(2024, 4, 21, 17, 0)))  // Sun 17:00 — open
    }

    @Test("lastSessionCloseMs = now when open, Friday 17:00 ET when closed")
    func lastSessionClose() {
        func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
        let friClose = ms(nyDate(2024, 4, 19, 17, 0))

        let openInstant = nyDate(2024, 4, 16, 12, 0)
        #expect(NYTradingCalendar.lastSessionCloseMs(at: openInstant) == ms(openInstant))

        #expect(NYTradingCalendar.lastSessionCloseMs(at: nyDate(2024, 4, 19, 20, 0)) == friClose) // Fri eve
        #expect(NYTradingCalendar.lastSessionCloseMs(at: nyDate(2024, 4, 20, 11, 0)) == friClose) // Sat
        #expect(NYTradingCalendar.lastSessionCloseMs(at: nyDate(2024, 4, 21, 9, 0)) == friClose)  // Sun am
    }

    @Test("lastSessionCloseMs is DST-correct across the spring-forward weekend")
    func lastSessionCloseDST() {
        func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
        // DST spring-forward Sun 2024-03-10. Closure ran Fri 2024-03-08 17:00 EST
        // → Sun 2024-03-10 17:00 EDT; Sat/Sun must map to that Friday close.
        let friClose = ms(nyDate(2024, 3, 8, 17, 0))
        #expect(NYTradingCalendar.isMarketClosed(at: nyDate(2024, 3, 9, 12, 0)))
        #expect(NYTradingCalendar.lastSessionCloseMs(at: nyDate(2024, 3, 9, 12, 0)) == friClose)
        #expect(NYTradingCalendar.lastSessionCloseMs(at: nyDate(2024, 3, 10, 9, 0)) == friClose)
    }
}
