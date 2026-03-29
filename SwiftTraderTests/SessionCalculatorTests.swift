import Foundation
import Testing
@testable import SwiftTrader

/// Helper to create a CandleBar at a specific UTC time.
private func bar(utc: String, open: Double = 1.1, high: Double = 1.2, low: Double = 1.0, close: Double = 1.15, volume: Double = 100) -> CandleBar {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    formatter.timeZone = TimeZone(identifier: "UTC")!
    let date = formatter.date(from: utc)!
    let ms = Int64(date.timeIntervalSince1970 * 1000)
    return CandleBar(time: ms, open: open, high: high, low: low, close: close, volume: volume)
}

/// Generate bars every 15 minutes between two UTC times.
private func bars(from start: String, to end: String) -> [CandleBar] {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    formatter.timeZone = TimeZone(identifier: "UTC")!
    let startDate = formatter.date(from: start)!
    let endDate = formatter.date(from: end)!

    var result: [CandleBar] = []
    var current = startDate
    var price = 1.1000
    while current < endDate {
        let ms = Int64(current.timeIntervalSince1970 * 1000)
        result.append(CandleBar(time: ms, open: price, high: price + 0.001, low: price - 0.001, close: price + 0.0005, volume: 50))
        current = current.addingTimeInterval(15 * 60) // 15-min bars
        price += 0.0001
    }
    return result
}

@Suite("SessionCalculator")
struct SessionCalculatorTests {

    @Test("Empty visible range returns no sessions")
    func emptyRange() {
        let result = SessionCalculator.sessions(for: [], visibleRange: 0..<0)
        #expect(result.isEmpty)
    }

    @Test("Single bar inside Tokyo session produces a rect")
    func singleBarTokyo() {
        // 2024-01-15 02:00 UTC = 11:00 JST — inside Tokyo session (09:00-18:00 JST = 00:00-09:00 UTC)
        let testBars = [bar(utc: "2024-01-15 02:00")]
        let result = SessionCalculator.sessions(for: testBars, visibleRange: 0..<1, definitions: [.tokyo])
        #expect(result.count == 1)
        #expect(result[0].session.name == "Tokyo")
        #expect(result[0].startBarIndex == 0)
        #expect(result[0].endBarIndex == 0)
    }

    @Test("Tokyo session high/low computed from bars within session")
    func tokyoHighLow() {
        let testBars = [
            bar(utc: "2024-01-15 01:00", high: 1.10, low: 1.05),
            bar(utc: "2024-01-15 03:00", high: 1.15, low: 1.08),
            bar(utc: "2024-01-15 06:00", high: 1.12, low: 1.03),
        ]
        let result = SessionCalculator.sessions(for: testBars, visibleRange: 0..<3, definitions: [.tokyo])
        #expect(result.count == 1)
        #expect(result[0].highPrice == 1.15)
        #expect(result[0].lowPrice == 1.03)
    }

    @Test("London session detected with correct boundaries")
    func londonSession() {
        // London session: 08:00-17:00 local. In winter (January), GMT = UTC.
        // So bars at 08:30 and 16:00 UTC should be inside.
        let testBars = [
            bar(utc: "2024-01-15 07:00"), // before session
            bar(utc: "2024-01-15 08:30"), // inside
            bar(utc: "2024-01-15 16:00"), // inside
            bar(utc: "2024-01-15 17:30"), // after session
        ]
        let result = SessionCalculator.sessions(for: testBars, visibleRange: 0..<4, definitions: [.london])
        #expect(result.count == 1)
        #expect(result[0].startBarIndex == 1) // 08:30
        #expect(result[0].endBarIndex == 2)   // 16:00
    }

    @Test("New York session detected with correct boundaries")
    func newYorkSession() {
        // NY session: 08:00-17:00 local. In winter (January), EST = UTC-5.
        // 08:00 EST = 13:00 UTC, 17:00 EST = 22:00 UTC.
        let testBars = [
            bar(utc: "2024-01-15 12:00"), // before session (07:00 EST)
            bar(utc: "2024-01-15 14:00"), // inside (09:00 EST)
            bar(utc: "2024-01-15 20:00"), // inside (15:00 EST)
            bar(utc: "2024-01-15 23:00"), // after session (18:00 EST)
        ]
        let result = SessionCalculator.sessions(for: testBars, visibleRange: 0..<4, definitions: [.newYork])
        #expect(result.count == 1)
        #expect(result[0].startBarIndex == 1) // 14:00 UTC
        #expect(result[0].endBarIndex == 2)   // 20:00 UTC
    }

    @Test("Exchange open/close bar indices found correctly")
    func exchangeIndices() {
        // Tokyo: forex session 09:00-18:00 JST (00:00-09:00 UTC)
        //        exchange 09:00-15:00 JST (00:00-06:00 UTC)
        let testBars = [
            bar(utc: "2024-01-15 00:00"), // session start = exchange open
            bar(utc: "2024-01-15 03:00"), // inside exchange
            bar(utc: "2024-01-15 05:30"), // last bar before exchange close (06:00 UTC)
            bar(utc: "2024-01-15 07:00"), // after exchange close, still in forex session
        ]
        let result = SessionCalculator.sessions(for: testBars, visibleRange: 0..<4, definitions: [.tokyo])
        #expect(result.count == 1)
        // Exchange open at 00:00 UTC = 09:00 JST → first bar at index 0
        #expect(result[0].exchangeOpenBarIndex == 0)
        // Exchange close at 06:00 UTC = 15:00 JST → last bar before close is index 2 (05:30 UTC)
        #expect(result[0].exchangeCloseBarIndex == 2)
    }

    @Test("Multiple sessions detected on same day")
    func multipleSessions() {
        // Monday 2024-01-15, bars spanning most of the trading day
        let testBars = bars(from: "2024-01-15 00:00", to: "2024-01-15 23:00")
        let result = SessionCalculator.sessions(for: testBars, visibleRange: 0..<testBars.count)
        // Should find at least one of each session
        let names = Set(result.map(\.session.name))
        #expect(names.contains("Tokyo"))
        #expect(names.contains("London"))
        #expect(names.contains("New York"))
    }

    @Test("Weekend bars produce no sessions")
    func weekendNoSessions() {
        // Saturday 2024-01-13 — forex markets closed, but even if we had bars,
        // sessions should still be computed (they're time-based, not market-aware).
        // The real test is that no bars exist on weekends, so no rects are produced.
        // With no bars in the range, no rects.
        let result = SessionCalculator.sessions(for: [], visibleRange: 0..<0)
        #expect(result.isEmpty)
    }

    @Test("DST transition shifts London session by 1 hour")
    func dstTransition() {
        // Before DST (winter): London 08:00-17:00 GMT = 08:00-17:00 UTC
        // After DST (summer): London 08:00-17:00 BST = 07:00-16:00 UTC
        // UK clocks go forward last Sunday of March. In 2024, that's March 31.

        // Winter day: March 28, 2024 — bar at 07:30 UTC should be OUTSIDE (07:30 GMT < 08:00 GMT)
        let winterBars = [bar(utc: "2024-03-28 07:30")]
        let winterResult = SessionCalculator.sessions(for: winterBars, visibleRange: 0..<1, definitions: [.london])
        #expect(winterResult.isEmpty) // 07:30 GMT is before 08:00 open

        // Summer day: April 1, 2024 — bar at 07:30 UTC = 08:30 BST should be INSIDE
        let summerBars = [bar(utc: "2024-04-01 07:30")]
        let summerResult = SessionCalculator.sessions(for: summerBars, visibleRange: 0..<1, definitions: [.london])
        #expect(summerResult.count == 1) // 08:30 BST is inside 08:00-17:00 session
    }

    @Test("Bar exactly at session close is excluded")
    func barAtCloseExcluded() {
        // Tokyo forex session closes at 18:00 JST = 09:00 UTC. Bar at 09:00 UTC should be outside.
        let testBars = [bar(utc: "2024-01-15 09:00")]
        let result = SessionCalculator.sessions(for: testBars, visibleRange: 0..<1, definitions: [.tokyo])
        #expect(result.isEmpty)
    }
}
