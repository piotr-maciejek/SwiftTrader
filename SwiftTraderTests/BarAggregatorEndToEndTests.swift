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

private func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }

private func bar(
    _ y: Int, _ m: Int, _ d: Int, _ h: Int,
    close: Double, volume: Double = 100, partial: Bool = false
) -> CandleBar {
    CandleBar(
        time: ms(nyDate(y, m, d, h, 0)),
        open: close, high: close, low: close, close: close,
        volume: volume, partial: partial
    )
}

@Suite("BarAggregator end-to-end parity")
struct BarAggregatorEndToEndTests {

    /// The one non-obvious behavior to guard: the client aggregator produces NY-close
    /// 4H bars that align on 17:00 ET — *not* the UTC anchor the raw server DAILY uses.
    /// This test fixture feeds 2 trading days of contiguous 1H bars through the
    /// aggregator and asserts both the bucket boundaries and volume sums.
    @Test("2 trading days of 1H bars → 12 FOUR_HOURS buckets aligned to NY close")
    func twoTradingDaysFourHour() {
        var bars: [CandleBar] = []
        // Mon Apr 15 17:00 ET → Tue Apr 16 17:00 ET (24 bars)
        for h in 17...23 {
            bars.append(bar(2024, 4, 15, h, close: Double(h), volume: Double(h)))
        }
        for h in 0...16 {
            bars.append(bar(2024, 4, 16, h, close: Double(h + 100), volume: Double(h + 100)))
        }
        // Tue Apr 16 17:00 ET → Wed Apr 17 17:00 ET (24 bars)
        for h in 17...23 {
            bars.append(bar(2024, 4, 16, h, close: Double(h), volume: Double(h)))
        }
        for h in 0...16 {
            bars.append(bar(2024, 4, 17, h, close: Double(h + 100), volume: Double(h + 100)))
        }
        let out = BarAggregator.aggregate(hourly: bars, openPartial: nil, target: .fourHours)
        #expect(out.count == 12)
        // First bucket anchors on Mon 17:00 ET
        #expect(out[0].time == ms(nyDate(2024, 4, 15, 17, 0)))
        // 7th bucket (index 6) anchors on Tue 17:00 ET — second trading day begins
        #expect(out[6].time == ms(nyDate(2024, 4, 16, 17, 0)))
    }

    @Test("DAILY on two trading days rolls over cleanly")
    func twoTradingDaysDaily() {
        var bars: [CandleBar] = []
        for h in 17...23 {
            bars.append(bar(2024, 4, 15, h, close: 1.0, volume: 1))
        }
        for h in 0...16 {
            bars.append(bar(2024, 4, 16, h, close: 1.0, volume: 1))
        }
        for h in 17...23 {
            bars.append(bar(2024, 4, 16, h, close: 2.0, volume: 2))
        }
        for h in 0...16 {
            bars.append(bar(2024, 4, 17, h, close: 2.0, volume: 2))
        }
        let out = BarAggregator.aggregate(hourly: bars, openPartial: nil, target: .daily)
        #expect(out.count == 2)
        // Sessions labeled by closing calendar day: Mon→Tue→label Tue 00:00, Tue→Wed→label Wed 00:00.
        #expect(out[0].time == ms(nyDate(2024, 4, 16, 0, 0)))
        #expect(out[1].time == ms(nyDate(2024, 4, 17, 0, 0)))
        #expect(out[0].volume == 24)
        #expect(out[1].volume == 48)
        #expect(out[0].close == 1.0)
        #expect(out[1].close == 2.0)
    }
}
