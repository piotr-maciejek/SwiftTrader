import Foundation
import Testing
@testable import SwiftTrader

private let nyTZ = TimeZone(identifier: "America/New_York")!

private func nyDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    var comps = DateComponents()
    comps.timeZone = nyTZ
    comps.year = y; comps.month = m; comps.day = d; comps.hour = h; comps.minute = min
    return Calendar(identifier: .gregorian).date(from: comps)!
}

private func timeMs(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

private func hourly(
    _ y: Int, _ m: Int, _ d: Int, _ h: Int,
    open: Double, high: Double, low: Double, close: Double,
    volume: Double = 100, partial: Bool = false
) -> CandleBar {
    CandleBar(time: timeMs(nyDate(y, m, d, h, 0)),
              open: open, high: high, low: low, close: close,
              volume: volume, partial: partial)
}

private func minly(
    _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mn: Int,
    open: Double, high: Double, low: Double, close: Double,
    volume: Double = 100, partial: Bool = false
) -> CandleBar {
    CandleBar(time: timeMs(nyDate(y, m, d, h, mn)),
              open: open, high: high, low: low, close: close,
              volume: volume, partial: partial)
}

@Suite("BarAggregator")
struct BarAggregatorTests {

    // MARK: 4H aggregation

    @Test("4 consecutive 1H bars collapse into one FOUR_HOURS bucket")
    func fourHoursBasic() {
        let bars = [
            hourly(2024, 4, 16, 17, open: 1.0, high: 1.1, low: 0.9, close: 1.05, volume: 100),
            hourly(2024, 4, 16, 18, open: 1.05, high: 1.15, low: 1.0, close: 1.1, volume: 120),
            hourly(2024, 4, 16, 19, open: 1.1, high: 1.2, low: 1.05, close: 1.15, volume: 130),
            hourly(2024, 4, 16, 20, open: 1.15, high: 1.25, low: 1.1, close: 1.2, volume: 140),
        ]
        let out = BarAggregator.aggregate(hourly: bars, openPartial: nil, target: .fourHours)
        #expect(out.count == 1)
        let bar = out[0]
        #expect(bar.time == timeMs(nyDate(2024, 4, 16, 17, 0)))
        #expect(bar.open == 1.0)
        #expect(bar.close == 1.2)
        #expect(bar.high == 1.25)
        #expect(bar.low == 0.9)
        #expect(bar.volume == 490)
        #expect(bar.partial == false)
    }

    @Test("5 1H bars split across two FOUR_HOURS buckets at 21:00 ET")
    func fourHoursBoundary() {
        let bars = [
            hourly(2024, 4, 16, 17, open: 1.0, high: 1.1, low: 0.9, close: 1.05),
            hourly(2024, 4, 16, 18, open: 1.05, high: 1.1, low: 1.0, close: 1.08),
            hourly(2024, 4, 16, 19, open: 1.08, high: 1.12, low: 1.05, close: 1.1),
            hourly(2024, 4, 16, 20, open: 1.1, high: 1.15, low: 1.08, close: 1.12),
            hourly(2024, 4, 16, 21, open: 1.12, high: 1.2, low: 1.1, close: 1.18),
        ]
        let out = BarAggregator.aggregate(hourly: bars, openPartial: nil, target: .fourHours)
        #expect(out.count == 2)
        #expect(out[0].time == timeMs(nyDate(2024, 4, 16, 17, 0)))
        #expect(out[1].time == timeMs(nyDate(2024, 4, 16, 21, 0)))
        #expect(out[1].open == 1.12)
        #expect(out[1].close == 1.18)
    }

    @Test("Partial 1H bar marks last 4H bucket partial")
    func partialMerges() {
        let completed = [
            hourly(2024, 4, 16, 17, open: 1.0, high: 1.1, low: 0.9, close: 1.05),
            hourly(2024, 4, 16, 18, open: 1.05, high: 1.1, low: 1.0, close: 1.08),
        ]
        let forming = hourly(2024, 4, 16, 19, open: 1.08, high: 1.09, low: 1.07, close: 1.085, partial: true)
        let out = BarAggregator.aggregate(hourly: completed, openPartial: forming, target: .fourHours)
        #expect(out.count == 1)
        #expect(out[0].partial == true)
        #expect(out[0].close == 1.085)
        #expect(out[0].volume == 300)
    }

    @Test("Partial is ignored when a completed bar already exists at the same timestamp")
    func partialIgnoredIfCompletedExists() {
        let completed = [
            hourly(2024, 4, 16, 17, open: 1.0, high: 1.1, low: 0.9, close: 1.05),
            hourly(2024, 4, 16, 18, open: 1.05, high: 1.15, low: 1.03, close: 1.1),
        ]
        let partial = hourly(2024, 4, 16, 18, open: 9.9, high: 9.9, low: 9.9, close: 9.9, partial: true)
        let out = BarAggregator.aggregate(hourly: completed, openPartial: partial, target: .fourHours)
        #expect(out.count == 1)
        #expect(out[0].partial == false)
        #expect(out[0].close == 1.1)
    }

    // MARK: Forming-bucket marking

    @Test("formingBucketStartMs: 4H bucket containing a mid-session instant")
    func formingStartFourHours() {
        // Tue 2024-04-16 18:30 ET sits in the 17:00–21:00 ET bucket.
        let now = nyDate(2024, 4, 16, 18, 30)
        #expect(BarAggregator.formingBucketStartMs(target: .fourHours, now: now)
                == timeMs(nyDate(2024, 4, 16, 17, 0)))
    }

    @Test("formingBucketStartMs: 3m fixed grid floors to the grid cell")
    func formingStartFixedGrid() {
        let now = nyDate(2024, 4, 16, 18, 7)   // 18:07 → 18:06 cell on a 3m grid
        #expect(BarAggregator.formingBucketStartMs(target: .threeMinutes, now: now)
                == timeMs(nyDate(2024, 4, 16, 18, 6)))
    }

    @Test("weekStartMs anchors the forming weekly bucket to Sunday 00:00 ET")
    func formingStartWeekly() {
        let now = nyDate(2024, 4, 17, 11, 0)   // Wednesday
        #expect(BarAggregator.weekStartMs(now) == timeMs(nyDate(2024, 4, 14, 0, 0)))
    }

    @Test("markForming flags bars at/after the forming start, leaves earlier bars untouched")
    func markFormingFlags() {
        let closed = hourly(2024, 4, 16, 13, open: 1, high: 1, low: 1, close: 1)
        let atBoundary = hourly(2024, 4, 16, 17, open: 1, high: 1, low: 1, close: 1)
        let after = hourly(2024, 4, 16, 18, open: 1, high: 1, low: 1, close: 1)
        let out = BarAggregator.markForming([closed, atBoundary, after],
                                            formingStartMs: timeMs(nyDate(2024, 4, 16, 17, 0)))
        #expect(out[0].partial == false)
        #expect(out[1].partial == true)
        #expect(out[2].partial == true)
        // OHLCV pass through unchanged.
        #expect(out[1].time == atBoundary.time && out[1].close == atBoundary.close)
    }

    @Test("markForming keeps an already-partial bar partial")
    func markFormingIdempotent() {
        let bar = hourly(2024, 4, 16, 17, open: 1, high: 1, low: 1, close: 1, partial: true)
        let out = BarAggregator.markForming([bar], formingStartMs: bar.time)
        #expect(out[0].partial == true)
    }

    // MARK: DAILY aggregation

    @Test("DAILY bucket spans a full trading day of 24 wall-clock hours")
    func dailyFullDay() {
        var bars: [CandleBar] = []
        // Trading day starting 17:00 ET Mon Apr 15 → 17:00 ET Tue Apr 16
        // Hourly bars at 17, 18, ..., 23 Mon; 00..16 Tue
        for h in 17...23 {
            bars.append(hourly(2024, 4, 15, h, open: 1.0, high: 1.0, low: 1.0, close: 1.0, volume: 1))
        }
        for h in 0...16 {
            bars.append(hourly(2024, 4, 16, h, open: 1.0, high: 1.0, low: 1.0, close: 1.0, volume: 1))
        }
        let out = BarAggregator.aggregate(hourly: bars, openPartial: nil, target: .daily)
        #expect(out.count == 1)
        #expect(out[0].volume == 24)
        // DAILY bucket is labeled by the session's CLOSING calendar day.
        // Session Mon Apr 15 17 ET → Tue Apr 16 17 ET → label Tue Apr 16 00:00 ET.
        #expect(out[0].time == timeMs(nyDate(2024, 4, 16, 0, 0)))
    }

    @Test("Bar exactly at 17:00 ET starts a NEW daily bucket")
    func dailyBoundaryClose() {
        let bars = [
            hourly(2024, 4, 16, 16, open: 1.0, high: 1.0, low: 1.0, close: 1.0),
            hourly(2024, 4, 16, 17, open: 2.0, high: 2.0, low: 2.0, close: 2.0),
        ]
        let out = BarAggregator.aggregate(hourly: bars, openPartial: nil, target: .daily)
        #expect(out.count == 2)
        // First bar belongs to Mon→Tue session, labeled Tue (Apr 16 00:00 ET).
        // Second bar starts Tue→Wed session, labeled Wed (Apr 17 00:00 ET).
        #expect(out[0].time == timeMs(nyDate(2024, 4, 16, 0, 0)))
        #expect(out[1].time == timeMs(nyDate(2024, 4, 17, 0, 0)))
    }

    // MARK: Weekend filtering

    @Test("Weekend 1H bars (Sat, Sun before 17:00 ET) are dropped")
    func weekendFilter() {
        let bars = [
            hourly(2024, 4, 13, 12, open: 1.0, high: 1.0, low: 1.0, close: 1.0), // Sat
            hourly(2024, 4, 14, 10, open: 1.0, high: 1.0, low: 1.0, close: 1.0), // Sun before 17
            hourly(2024, 4, 14, 17, open: 2.0, high: 2.1, low: 2.0, close: 2.05), // Sun 17:00 — NEW trading day
            hourly(2024, 4, 14, 18, open: 2.05, high: 2.1, low: 2.03, close: 2.08),
        ]
        let out = BarAggregator.aggregate(hourly: bars, openPartial: nil, target: .fourHours)
        #expect(out.count == 1)
        #expect(out[0].time == timeMs(nyDate(2024, 4, 14, 17, 0)))
        #expect(out[0].open == 2.0)
        #expect(out[0].close == 2.08)
    }

    @Test("Friday 17:00+ bars are dropped as weekend fillers")
    func fridayAfterClose() {
        let bars = [
            hourly(2024, 4, 12, 16, open: 1.0, high: 1.0, low: 1.0, close: 1.0), // Fri 16:00 — valid
            hourly(2024, 4, 12, 17, open: 9.0, high: 9.0, low: 9.0, close: 9.0), // Fri 17:00 — filler
            hourly(2024, 4, 12, 20, open: 9.0, high: 9.0, low: 9.0, close: 9.0), // Fri 20:00 — filler
        ]
        let out = BarAggregator.aggregate(hourly: bars, openPartial: nil, target: .fourHours)
        #expect(out.count == 1)
        #expect(out[0].time == timeMs(nyDate(2024, 4, 12, 13, 0)))
        #expect(out[0].close == 1.0)
    }

    // MARK: Edge cases

    @Test("Empty input returns empty output")
    func emptyInput() {
        let out = BarAggregator.aggregate(hourly: [], openPartial: nil, target: .fourHours)
        #expect(out.isEmpty)
    }

    @Test("Only partial input produces a single partial bucket")
    func onlyPartial() {
        let partial = hourly(2024, 4, 16, 17, open: 1.0, high: 1.02, low: 0.99, close: 1.01, partial: true)
        let out = BarAggregator.aggregate(hourly: [], openPartial: partial, target: .fourHours)
        #expect(out.count == 1)
        #expect(out[0].partial == true)
        #expect(out[0].open == 1.0)
        #expect(out[0].close == 1.01)
    }

    // MARK: DST + weekend interaction
    // (US DST transitions happen Sunday 02:00 ET, during the Fri-17→Sun-17 market closure.
    // By the time trading resumes at 17:00 ET Sunday, DST is already in effect. So DST
    // transitions never intersect live market data — but we still verify the weekend
    // filter drops those hypothetical bars cleanly, and that the first 4H bucket of the
    // new trading week has the correct post-DST anchor.)

    @Test("Bars at wall-clock DST transition hours are dropped as weekend fillers")
    func dstTransitionBarsAreWeekend() {
        // Spring forward Sunday 2024-03-10: the 02:00 ET local hour is skipped.
        // Bars at 01:00, 03:00, 04:00 EDT on Sunday are all weekend fillers (Sun before 17:00).
        let bars = [
            hourly(2024, 3, 10, 1, open: 1.0, high: 1.0, low: 1.0, close: 1.0),
            hourly(2024, 3, 10, 3, open: 1.0, high: 1.0, low: 1.0, close: 1.0),
            hourly(2024, 3, 10, 4, open: 1.0, high: 1.0, low: 1.0, close: 1.0),
        ]
        let out = BarAggregator.aggregate(hourly: bars, openPartial: nil, target: .fourHours)
        #expect(out.isEmpty)
    }

    @Test("First 4H bucket of the trading week after DST fall-back opens at 17:00 EST Sunday")
    func firstBucketAfterFallBack() {
        // Sunday Nov 3, 2024, 17:00 EST = 22:00 UTC. Market re-opens here already on EST.
        // 1H bars at 17 and 18 ET belong to the first 4H bucket of the new trading week.
        let bars = [
            hourly(2024, 11, 3, 17, open: 1.0, high: 1.1, low: 1.0, close: 1.05),
            hourly(2024, 11, 3, 18, open: 1.05, high: 1.1, low: 1.0, close: 1.08),
        ]
        let out = BarAggregator.aggregate(hourly: bars, openPartial: nil, target: .fourHours)
        #expect(out.count == 1)
        #expect(out[0].time == timeMs(nyDate(2024, 11, 3, 17, 0)))
    }

    // MARK: 3m aggregation (fixed epoch grid from 1m — NOT NY-session-aligned)

    private let gridMs: Int64 = 180_000  // 3 minutes

    @Test("3 consecutive 1m bars collapse into one THREE_MINS bucket")
    func threeMinBasic() {
        let bars = [
            minly(2024, 4, 16, 17, 0, open: 1.0, high: 1.1, low: 0.9, close: 1.05, volume: 10),
            minly(2024, 4, 16, 17, 1, open: 1.05, high: 1.15, low: 1.0, close: 1.1, volume: 20),
            minly(2024, 4, 16, 17, 2, open: 1.1, high: 1.2, low: 1.05, close: 1.15, volume: 30),
        ]
        let out = BarAggregator.aggregate(hourly: bars, openPartial: nil, target: .threeMinutes)
        #expect(out.count == 1)
        let b = out[0]
        #expect(b.time == (bars[0].time / gridMs) * gridMs)
        #expect(b.time == timeMs(nyDate(2024, 4, 16, 17, 0)))
        #expect(b.open == 1.0)
        #expect(b.close == 1.15)
        #expect(b.high == 1.2)
        #expect(b.low == 0.9)
        #expect(b.volume == 60)
        #expect(b.partial == false)
    }

    @Test("1m bars at :02 and :03 fall in different 3m buckets")
    func threeMinBoundary() {
        let bars = [
            minly(2024, 4, 16, 17, 2, open: 1.0, high: 1.0, low: 1.0, close: 1.0),
            minly(2024, 4, 16, 17, 3, open: 2.0, high: 2.0, low: 2.0, close: 2.0),
        ]
        let out = BarAggregator.aggregate(hourly: bars, openPartial: nil, target: .threeMinutes)
        #expect(out.count == 2)
        #expect(out[0].time == timeMs(nyDate(2024, 4, 16, 17, 0)))
        #expect(out[1].time == timeMs(nyDate(2024, 4, 16, 17, 3)))
    }

    @Test("Non-:00 mid-hour 3m bucket starts on the :03 grid")
    func threeMinMidHour() {
        // :07,:08 → 17:06 bucket; :09 → 17:09 bucket.
        let bars = [
            minly(2024, 4, 16, 17, 7, open: 1.0, high: 1.0, low: 1.0, close: 1.0),
            minly(2024, 4, 16, 17, 8, open: 1.0, high: 1.0, low: 1.0, close: 1.0),
            minly(2024, 4, 16, 17, 9, open: 2.0, high: 2.0, low: 2.0, close: 2.0),
        ]
        let out = BarAggregator.aggregate(hourly: bars, openPartial: nil, target: .threeMinutes)
        #expect(out.count == 2)
        #expect(out[0].time == timeMs(nyDate(2024, 4, 16, 17, 6)))
        #expect(out[1].time == timeMs(nyDate(2024, 4, 16, 17, 9)))
    }

    @Test("3m buckets continue cleanly across the hour boundary (proves epoch grid)")
    func threeMinHourRollover() {
        // :57,:58,:59 → 17:57 bucket; next hour :00,:01 → 18:00 bucket.
        let bars = [
            minly(2024, 4, 16, 17, 57, open: 1.0, high: 1.0, low: 1.0, close: 1.0),
            minly(2024, 4, 16, 17, 58, open: 1.0, high: 1.0, low: 1.0, close: 1.0),
            minly(2024, 4, 16, 17, 59, open: 1.0, high: 1.0, low: 1.0, close: 1.0),
            minly(2024, 4, 16, 18, 0, open: 2.0, high: 2.0, low: 2.0, close: 2.0),
            minly(2024, 4, 16, 18, 1, open: 2.0, high: 2.0, low: 2.0, close: 2.0),
        ]
        let out = BarAggregator.aggregate(hourly: bars, openPartial: nil, target: .threeMinutes)
        #expect(out.count == 2)
        #expect(out[0].time == timeMs(nyDate(2024, 4, 16, 17, 57)))
        #expect(out[1].time == timeMs(nyDate(2024, 4, 16, 18, 0)))
    }

    @Test("Partial 1m tail marks the last 3m bucket partial")
    func threeMinPartialTail() {
        let completed = minly(2024, 4, 16, 17, 0, open: 1.0, high: 1.1, low: 1.0, close: 1.05, volume: 5)
        let partial = minly(2024, 4, 16, 17, 1, open: 1.05, high: 1.2, low: 1.0, close: 1.18,
                            volume: 7, partial: true)
        let out = BarAggregator.aggregate(hourly: [completed], openPartial: partial,
                                          target: .threeMinutes)
        #expect(out.count == 1)
        #expect(out[0].partial == true)
        #expect(out[0].close == 1.18)
        #expect(out[0].high == 1.2)
        #expect(out[0].volume == 12)
    }

    @Test("Weekend 1m bars are NOT dropped for THREE_MINS (server already filters them)")
    func threeMinKeepsWeekendEdgeBars() {
        // Sat 2024-04-20 12:00 and Fri 2024-04-19 17:00 would both be weekend
        // fillers for session-aligned aggregation. They must survive for 3m.
        let sat = minly(2024, 4, 20, 12, 0, open: 1.0, high: 1.0, low: 1.0, close: 1.0)
        let friClose = minly(2024, 4, 19, 17, 0, open: 2.0, high: 2.0, low: 2.0, close: 2.0)
        #expect(BarAggregator.isWeekendFiller(sat))       // sanity: session-aligned would drop it
        #expect(BarAggregator.isWeekendFiller(friClose))
        let out = BarAggregator.aggregate(hourly: [friClose, sat], openPartial: nil,
                                          target: .threeMinutes)
        #expect(out.count == 2)
        #expect(out.contains { $0.time == timeMs(nyDate(2024, 4, 19, 17, 0)) })
        #expect(out.contains { $0.time == timeMs(nyDate(2024, 4, 20, 12, 0)) })
        // And the same inputs ARE dropped for a session-aligned target:
        let session = BarAggregator.aggregate(hourly: [friClose, sat], openPartial: nil,
                                              target: .fourHours)
        #expect(session.isEmpty)
    }

    @Test("3m bucket starts stay on a clean 180000ms grid across a DST instant")
    func threeMinDSTIrrelevance() {
        // Spring-forward instant 2024-03-10 02:00 ET. Fixed grid is pure epoch ms,
        // so every bucket start must be a multiple of 180000 regardless of DST.
        let bars = (0..<10).map { i in
            minly(2024, 3, 10, 1, i, open: 1.0, high: 1.0, low: 1.0, close: 1.0)
        }
        let out = BarAggregator.aggregate(hourly: bars, openPartial: nil, target: .threeMinutes)
        #expect(!out.isEmpty)
        for b in out {
            #expect(b.time % gridMs == 0)
        }
        // Consecutive bucket starts differ by exactly one grid cell.
        for (a, c) in zip(out, out.dropFirst()) {
            #expect(c.time - a.time == gridMs)
        }
    }

    // MARK: AggregatedPeriod source/grid metadata

    @Test("THREE_MINS aggregated-period metadata")
    func threeMinEnumMetadata() {
        #expect(AggregatedPeriod("THREE_MINS") == .threeMinutes)
        #expect(AggregatedPeriod.threeMinutes.periodCode == "THREE_MINS")
        #expect(AggregatedPeriod.threeMinutes.sourcePeriod == "ONE_MIN")
        #expect(AggregatedPeriod.threeMinutes.sourceSpan == 3)
        #expect(AggregatedPeriod.threeMinutes.isSessionAligned == false)
        #expect(AggregatedPeriod.threeMinutes.alwaysAggregated == true)
    }

    @Test("4H/Daily metadata unchanged after the sourceSpan rename")
    func sessionAlignedEnumMetadataRegression() {
        #expect(AggregatedPeriod.fourHours.sourcePeriod == "ONE_HOUR")
        #expect(AggregatedPeriod.fourHours.sourceSpan == 4)
        #expect(AggregatedPeriod.fourHours.isSessionAligned == true)
        #expect(AggregatedPeriod.fourHours.alwaysAggregated == false)
        #expect(AggregatedPeriod.daily.sourcePeriod == "ONE_HOUR")
        #expect(AggregatedPeriod.daily.sourceSpan == 24)
        #expect(AggregatedPeriod.daily.isSessionAligned == true)
        #expect(AggregatedPeriod.daily.alwaysAggregated == false)
        #expect(AggregatedPeriod("FOUR_HOURS") == .fourHours)
        #expect(AggregatedPeriod("DAILY") == .daily)
        #expect(AggregatedPeriod("ONE_HOUR") == nil)
    }

    // MARK: Weekly aggregation (from 1H, FX-week boundaries)

    @Test("One FX trading week of 1H bars collapses into a single weekly candle")
    func weeklySingleWeek() {
        // FX week opening Sunday 2024-04-14 17:00 ET → Friday 2024-04-19.
        let bars = [
            hourly(2024, 4, 14, 17, open: 1.00, high: 1.02, low: 0.99, close: 1.01),  // Sun open
            hourly(2024, 4, 15, 10, open: 1.01, high: 1.08, low: 1.00, close: 1.05),  // Mon (week high 1.08)
            hourly(2024, 4, 17, 12, open: 1.05, high: 1.06, low: 0.95, close: 0.97),  // Wed (week low 0.95)
            hourly(2024, 4, 19, 16, open: 0.97, high: 1.00, low: 0.96, close: 0.98),  // Fri close
        ]
        let out = BarAggregator.aggregateWeekly(bars, openPartial: nil)
        #expect(out.count == 1)
        let w = out[0]
        // Labeled by the Sunday-first NY week start (Sunday 00:00 ET).
        #expect(w.time == timeMs(nyDate(2024, 4, 14, 0, 0)))
        #expect(w.open == 1.00)   // Sunday's open — the FX week open
        #expect(w.close == 0.98)  // Friday's close
        #expect(w.high == 1.08)
        #expect(w.low == 0.95)
        #expect(w.volume == 400)
        #expect(w.partial == false)
    }

    @Test("Bars across two FX weeks split into two weekly candles")
    func weeklyTwoWeeks() {
        let bars = [
            hourly(2024, 4, 15, 10, open: 1.00, high: 1.05, low: 0.99, close: 1.02),  // week of Apr 14
            hourly(2024, 4, 19, 16, open: 1.02, high: 1.03, low: 1.00, close: 1.01),  // week of Apr 14
            hourly(2024, 4, 21, 17, open: 1.01, high: 1.10, low: 1.01, close: 1.08),  // week of Apr 21 (Sun open)
            hourly(2024, 4, 25, 14, open: 1.08, high: 1.12, low: 1.07, close: 1.11),  // week of Apr 21
        ]
        let out = BarAggregator.aggregateWeekly(bars, openPartial: nil)
        #expect(out.count == 2)
        #expect(out[0].time == timeMs(nyDate(2024, 4, 14, 0, 0)))
        #expect(out[0].open == 1.00)
        #expect(out[0].close == 1.01)
        #expect(out[1].time == timeMs(nyDate(2024, 4, 21, 0, 0)))
        #expect(out[1].open == 1.01)   // Sunday open of the second week
        #expect(out[1].close == 1.11)
        #expect(out[1].high == 1.12)
    }

    @Test("A forming partial bar marks the current week's candle partial")
    func weeklyPartial() {
        let completed = hourly(2024, 4, 15, 10, open: 1.00, high: 1.05, low: 0.99, close: 1.02)
        let formingNow = hourly(2024, 4, 17, 12, open: 1.02, high: 1.07, low: 1.02, close: 1.06, partial: true)
        let out = BarAggregator.aggregateWeekly([completed], openPartial: formingNow)
        #expect(out.count == 1)
        #expect(out[0].partial == true)
        #expect(out[0].high == 1.07)   // forming bar's high folded in
        #expect(out[0].close == 1.06)
    }

    // MARK: Live-seed staleness premises (seedLiveBucket fallbacks)

    @Test("Stale previous-week partial forms its own earlier bucket; selecting by week start skips it")
    func weeklyStalePartialIsolatedToItsOwnWeek() {
        // New week opened Sun Apr 21 17:00 ET; the cached in-progress 1H partial is
        // still Friday Apr 19 (previous week).
        let stalePartial = hourly(2024, 4, 19, 16, open: 1.02, high: 1.03, low: 1.00, close: 1.01, partial: true)
        let currentWeekHour = hourly(2024, 4, 21, 17, open: 1.05, high: 1.10, low: 1.04, close: 1.08)
        let bucketMs = timeMs(nyDate(2024, 4, 21, 0, 0))

        let out = BarAggregator.aggregateWeekly([currentWeekHour], openPartial: stalePartial)
        #expect(out.count == 2)
        #expect(out.first?.time == timeMs(nyDate(2024, 4, 14, 0, 0)))  // .first is LAST week — must not seed from it
        let currentWeek = out.first { $0.time == bucketMs }
        #expect(currentWeek?.open == 1.05)
        #expect(currentWeek?.high == 1.10)

        // With ONLY the stale partial available, the new week has no bucket at all —
        // the seed must open fresh at the tick.
        let onlyStale = BarAggregator.aggregateWeekly([], openPartial: stalePartial)
        #expect(onlyStale.first { $0.time == bucketMs } == nil)
    }

    @Test("Fresh 1H partial always yields a 4H/Daily bucket at its own bucket start")
    func freshPartialProducesCurrentBucket() {
        // Premise the seedLiveBucket fallbacks rely on: if the partial belongs to the
        // forming bucket, aggregation produces that bucket — so a fallback firing
        // proves staleness and must open fresh instead of extending the partial.
        let partial = hourly(2024, 4, 16, 21, open: 1.12, high: 1.2, low: 1.1, close: 1.18, partial: true)
        let out = BarAggregator.aggregate(hourly: [], openPartial: partial, target: .fourHours)
        #expect(out.last?.time == timeMs(nyDate(2024, 4, 16, 21, 0)))
        #expect(out.last?.partial == true)
    }

    @Test("Cold-start under-seed heals: forming Daily opens on the session open once the source loads")
    func dailyColdStartUnderSeedHealsOnSourceLoad() {
        // Repro of the AUDUSD live-Daily gap: app launched at the session open (Mon 00:00 ET),
        // when the cached 1H only reached Friday. The forming Daily bucket (label Mon Apr 15) is
        // then built from ONLY the live partial — opening high off the prior close, a phantom gap.
        let dailyLabel = timeMs(nyDate(2024, 4, 15, 0, 0))   // session Sun 17 ET → Mon 17 ET
        let fridayBar  = hourly(2024, 4, 12, 16, open: 1.30, high: 1.31, low: 1.29, close: 1.30)
        // Current forming 1H at the moment of the cold-start seed (price already ran up).
        let formingNow = hourly(2024, 4, 15, 0, open: 1.40, high: 1.41, low: 1.39, close: 1.40, partial: true)

        // Cold start: cached source = Friday only. The Monday bucket comes from just the partial.
        let underSeeded = BarAggregator.aggregate(hourly: [fridayBar], openPartial: formingNow, target: .daily)
        let badMonday = underSeeded.first { $0.time == dailyLabel }
        #expect(badMonday?.open == 1.40)   // wrong: opened on the live partial, not the session

        // Source loads: the session's earlier 1H bars (Sun 17:00 ET reopen onward) are now cached.
        let sessionOpenBar = hourly(2024, 4, 14, 17, open: 1.305, high: 1.32, low: 1.30, close: 1.31)
        let sessionMidBar  = hourly(2024, 4, 14, 20, open: 1.31, high: 1.33, low: 1.305, close: 1.32)
        let healed = BarAggregator.aggregate(
            hourly: [fridayBar, sessionOpenBar, sessionMidBar], openPartial: formingNow, target: .daily
        )
        let goodMonday = healed.first { $0.time == dailyLabel }
        #expect(goodMonday?.open == 1.305)            // opens on the session's first 1H (≈ Friday close)
        #expect(goodMonday?.high == 1.41)             // widest extreme across the session + forming bar
        #expect(goodMonday?.low == 1.30)
        #expect(goodMonday?.partial == true)
    }

    @Test("All-stale inputs yield no bucket at the new bucket start")
    func stalePartialNeverReachesNewBucket() {
        // 4H bucket rolled at 21:00 ET; cached tail + partial all from the 17:00 bucket.
        let newBucketMs = timeMs(nyDate(2024, 4, 16, 21, 0))
        let staleTail = [
            hourly(2024, 4, 16, 17, open: 1.0, high: 1.1, low: 0.9, close: 1.05),
            hourly(2024, 4, 16, 18, open: 1.05, high: 1.15, low: 1.0, close: 1.1),
        ]
        let stalePartial = hourly(2024, 4, 16, 19, open: 1.1, high: 1.2, low: 1.05, close: 1.15, partial: true)
        let out = BarAggregator.aggregate(hourly: staleTail, openPartial: stalePartial, target: .fourHours)
        #expect(out.first { $0.time == newBucketMs } == nil)
        #expect(out.last?.time == timeMs(nyDate(2024, 4, 16, 17, 0)))
    }
}
