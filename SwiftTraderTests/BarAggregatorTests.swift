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
}
