import BigInt
import DukascopyClient
import Foundation
import Testing
@testable import SwiftTrader

@Suite("NativeMarketDataCoordinator routing")
struct NativeMarketDataCoordinatorRoutingTests {
    /// Records every raw-fetch call so we can assert what period/count/before the
    /// coordinator routed to, without a live Dukascopy session.
    actor Spy {
        struct Call: Equatable, Sendable {
            let instrument: String
            let period: String
            let count: Int
            let before: Int64?
        }
        private(set) var calls: [Call] = []
        func record(_ c: Call) { calls.append(c) }
    }

    private func make(
        cache: CandleCache = CandleCache(),
        bars: @escaping @Sendable (_ period: String) -> [SwiftTrader.CandleBar]
    ) -> (NativeMarketDataCoordinator, Spy) {
        let spy = Spy()
        let coord = NativeMarketDataCoordinator(cache: cache, rawFetch: { instrument, period, count, before, _ in
            await spy.record(.init(instrument: instrument, period: period, count: count, before: before))
            return bars(period)
        })
        return (coord, spy)
    }

    @Test("Cold raw period fetches exactly `count` (no over-fetch), caches completed bars, appends the live partial")
    func rawFetchCachesAndAppendsPartial() async throws {
        let hourly: [SwiftTrader.CandleBar] = [
            SwiftTrader.CandleBar(time: 0, open: 1, high: 1, low: 1, close: 1, volume: 1),
            SwiftTrader.CandleBar(time: 3_600_000, open: 1, high: 1, low: 1, close: 1, volume: 1),
            SwiftTrader.CandleBar(time: 7_200_000, open: 1, high: 1, low: 1, close: 1, volume: 1, partial: true),
        ]
        let (coord, spy) = make { _ in hourly }
        let result = try await coord.fetchCandles(
            instrument: "EURUSD", period: "ONE_HOUR", count: 10, rebucketing: false
        )
        let calls = await spy.calls
        // Forward (before==nil) loads pull exactly the requested count — no minFetchCount
        // floor, so a 1H chart's window stays small instead of storming the socket+CDN.
        #expect(calls == [.init(instrument: "EURUSD", period: "ONE_HOUR", count: 10, before: nil)])
        // 2 completed bars are cached; the partial is appended (not cached).
        #expect(result.count == 3)
        #expect(result.last?.partial == true)
        #expect(result.dropLast().allSatisfy { !$0.partial })
    }

    @Test("A fresh, deep-enough cache is served without any network fetch (no startup storm)")
    func warmCacheSkipsFetch() async throws {
        let cache = CandleCache()
        let key = CandleCache.CacheKey(instrument: "EURUSD", period: "ONE_HOUR", source: .server)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // 600 hourly bars reach back further than a 500-bar request's window, so the
        // depth-aware cache-first check is satisfied and no fetch happens.
        let bars = (0..<600).map { i in
            SwiftTrader.CandleBar(
                time: nowMs - Int64(i) * 3_600_000, open: 1, high: 1, low: 1, close: 1, volume: 1
            )
        }.sorted { $0.time < $1.time }
        _ = await cache.merge(bars, for: key)
        let (coord, spy) = make(cache: cache) { _ in [] }
        let result = try await coord.fetchCandles(
            instrument: "EURUSD", period: "ONE_HOUR", count: 500, rebucketing: false
        )
        let calls = await spy.calls
        #expect(calls.isEmpty)         // cache-first: no network fetch
        #expect(result.count == 600)   // served straight from cache
    }

    @Test("A fresh but too-shallow cache triggers a refetch (depth-aware cache-first)")
    func shallowCacheTriggersRefetch() async throws {
        let cache = CandleCache()
        let key = CandleCache.CacheKey(instrument: "EURUSD", period: "ONE_HOUR", source: .server)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // 100 recent hourly bars (~4 days): fresh, but nowhere near a 500-bar window deep.
        let bars = (0..<100).map { i in
            SwiftTrader.CandleBar(
                time: nowMs - Int64(i) * 3_600_000, open: 1, high: 1, low: 1, close: 1, volume: 1
            )
        }.sorted { $0.time < $1.time }
        _ = await cache.merge(bars, for: key)
        let (coord, spy) = make(cache: cache) { _ in [] }
        _ = try await coord.fetchCandles(
            instrument: "EURUSD", period: "ONE_HOUR", count: 500, rebucketing: false
        )
        let calls = await spy.calls
        // Shallow cache can't satisfy 500 bars back → exactly one forward fetch for 500.
        #expect(calls == [.init(instrument: "EURUSD", period: "ONE_HOUR", count: 500, before: nil)])
    }

    @Test("Weekend filler bars are stripped from native raw fetches (server-mode parity)")
    func stripsWeekendFillers() async throws {
        func ts(_ iso: String) -> Int64 {
            Int64(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970 * 1000)
        }
        let wednesday = ts("2026-05-20T12:00:00Z")  // weekday → kept
        let saturday = ts("2026-05-23T12:00:00Z")   // Fri 17:00 ET → Sun 17:00 ET closure → dropped
        let raw = [
            SwiftTrader.CandleBar(time: wednesday, open: 1, high: 1, low: 1, close: 1, volume: 1),
            SwiftTrader.CandleBar(time: saturday, open: 1, high: 1, low: 1, close: 1, volume: 1),
        ]
        let (coord, _) = make { _ in raw }
        let result = try await coord.fetchCandles(
            instrument: "EURUSD", period: "ONE_HOUR", count: 2, rebucketing: false
        )
        #expect(result.map(\.time) == [wednesday])   // weekend filler removed, matching server mode
    }

    @Test("fetchEarlierCandles requests bars before the earliest cached timestamp")
    func earlierUsesBefore() async throws {
        let cache = CandleCache()
        let key = CandleCache.CacheKey(instrument: "EURUSD", period: "ONE_HOUR", source: .server)
        _ = await cache.merge(
            [SwiftTrader.CandleBar(time: 5_000_000, open: 1, high: 1, low: 1, close: 1, volume: 1)], for: key
        )
        let (coord, spy) = make(cache: cache) { _ in
            [SwiftTrader.CandleBar(time: 1_000_000, open: 1, high: 1, low: 1, close: 1, volume: 1)]
        }
        _ = try await coord.fetchEarlierCandles(
            instrument: "EURUSD", period: "ONE_HOUR", count: 100, rebucketing: false
        )
        let calls = await spy.calls
        #expect(calls.count == 1)
        #expect(calls.first?.before == 5_000_000)
    }

    @Test("4H/Daily aggregate from 1H; 3m/5m/15m/30m aggregate from 1m (native)")
    func aggregatedRoutesToSource() async throws {
        // Cold cache → one source fetch sized to exactly count × sourceSpan (no over-fetch).
        // The datafeed has no 5m/15m/30m files, so native builds them from ONE_MIN.
        let count = 5
        let cases: [(period: String, source: String, span: Int)] = [
            ("FOUR_HOURS", "ONE_HOUR", 4),
            ("DAILY", "ONE_HOUR", 24),
            ("THREE_MINS", "ONE_MIN", 3),
            ("FIVE_MINS", "ONE_MIN", 5),
            ("FIFTEEN_MINS", "ONE_MIN", 15),
            ("THIRTY_MINS", "ONE_MIN", 30),
        ]
        for c in cases {
            for rebucketing in [true, false] {
                let (coord, spy) = make { _ in [] }
                _ = try await coord.fetchCandles(
                    instrument: "EURUSD", period: c.period, count: count, rebucketing: rebucketing
                )
                let calls = await spy.calls
                let label = "\(c.period) rebucketing=\(rebucketing)"
                #expect(calls.count == 1, "\(label)")
                #expect(calls.first?.period == c.source, "\(label)")
                #expect(calls.first?.count == count * c.span, "\(label)")
            }
        }
    }

    @Test("A shallow source cache is deepened by fetching only the missing older bars")
    func shallowSourceCacheTriggersDeepFetch() async throws {
        let cache = CandleCache()
        let key = CandleCache.CacheKey(instrument: "EURUSD", period: "ONE_HOUR", source: .server)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // 100 recent 1H bars: enough for a small 1H window, far too shallow for Daily (250d).
        let bars = (0..<100).map { i in
            SwiftTrader.CandleBar(
                time: nowMs - Int64(i) * 3_600_000, open: 1, high: 1, low: 1, close: 1, volume: 1
            )
        }.sorted { $0.time < $1.time }
        let earliest = bars.first!.time
        _ = await cache.merge(bars, for: key)
        let (coord, spy) = make(cache: cache) { _ in [] }
        _ = try await coord.fetchCandles(
            instrument: "EURUSD", period: "DAILY", count: 250, rebucketing: false
        )
        let calls = await spy.calls
        // Daily needs 250×24 = 6000 source 1H bars; the 100-bar cache can't cover it. Rather than
        // refetching all 6000 from now, deepen by fetching ONLY the missing older slice — anchored
        // at the earliest cached bar (`before: earliest`), ~5900 bars (6000 window − 100 cached + slop).
        #expect(calls.count == 1)
        #expect(calls.first?.period == "ONE_HOUR")
        #expect(calls.first?.before == earliest)
        let missing = calls.first?.count ?? 0
        #expect((5895...5905).contains(missing), "expected ~5902 missing bars, got \(missing)")
    }

    @Test("Native mode throttles cold grid loads (server mode stays unbounded)")
    func nativeThrottlesColdLoads() {
        #expect(NativeMarketDataCoordinator().maxConcurrentColdLoads == 3)
    }

    @Test("A warm-source Daily rebuild never persists the forming bucket and displays it partial")
    func warmRebuildKeepsFormingBucketPartial() async throws {
        // The cached 1H source holds ONLY completed bars (the cache drops partials), so
        // the rebuild path can't learn the forming Daily bucket from its source — it
        // must derive it from the clock. Regression test for the frozen-Friday-close
        // cache poison: pre-fix, the forming bucket aggregated as complete and was
        // persisted to the .aggregated cache.
        let cache = CandleCache()
        let srcKey = CandleCache.CacheKey(instrument: "EURUSD", period: "ONE_HOUR", source: .server)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let hourMs: Int64 = 3_600_000
        let lastClosedHour = (nowMs / hourMs) * hourMs - hourMs
        // 240 completed hourly bars (10 days) cover a 5-day DAILY window, so the
        // covers-window (no source fetch) branch aggregates straight from cache.
        let bars = (0..<240).map { i in
            SwiftTrader.CandleBar(time: lastClosedHour - Int64(i) * hourMs,
                                  open: 1, high: 2, low: 0.5, close: 1.5, volume: 1)
        }.sorted { $0.time < $1.time }
        _ = await cache.merge(bars, for: srcKey)

        let (coord, _) = make(cache: cache) { _ in [] }
        let result = try await coord.fetchCandles(
            instrument: "EURUSD", period: "DAILY", count: 5, rebucketing: false)

        let formingStart = BarAggregator.formingBucketStartMs(target: .daily, now: Date())
        let aggKey = CandleCache.CacheKey(instrument: "EURUSD", period: "DAILY", source: .aggregated)
        let persisted = await cache.getBars(for: aggKey)
        // Closed buckets persist; the forming bucket (and any partial) never does.
        #expect(!persisted.isEmpty)
        #expect(persisted.allSatisfy { $0.time < formingStart })
        #expect(persisted.allSatisfy { !$0.partial })
        // Whatever the DISPLAY series shows at/after the forming start is flagged partial.
        #expect(result.contains { $0.time < formingStart })
        for bar in result where bar.time >= formingStart {
            #expect(bar.partial, "forming bucket at \(bar.time) must be partial")
        }
    }

    @Test("An aggregated cache missing the just-closed bucket is not served (rebuild)")
    func aggCacheStalenessGate() {
        // A fixed, market-open instant: Wed 2026-06-03 10:00:30 UTC.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 3
        comps.hour = 10; comps.minute = 0; comps.second = 30
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: comps)!
        let target: Int64 = 900   // 15m
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let currentBucketStart = (nowMs / (target * 1000)) * (target * 1000)  // 10:00:00
        let justClosed = currentBucketStart - target * 1000                   // 09:45:00

        // Reaching the just-closed bucket → fresh enough to serve.
        #expect(NativeMarketDataCoordinator.aggCacheReachesLatestClosedBucket(
            aggLatestMs: justClosed, period: "FIFTEEN_MINS", targetSeconds: target, now: now))
        // One bucket behind (09:30) is missing the just-closed bar → must rebuild.
        #expect(!NativeMarketDataCoordinator.aggCacheReachesLatestClosedBucket(
            aggLatestMs: justClosed - target * 1000, period: "FIFTEEN_MINS", targetSeconds: target, now: now))
        // Session-aligned periods keep prior behavior (gate is a no-op for them).
        #expect(NativeMarketDataCoordinator.aggCacheReachesLatestClosedBucket(
            aggLatestMs: 0, period: "DAILY", targetSeconds: 86_400, now: now))
    }
}

@Suite("Native instrument wire form")
struct NativeInstrumentWireFormTests {
    @Test("Slashless 6-char FX codes get a slash; other forms pass through unchanged")
    func slashedPairConversion() {
        // The candle subscribe needs the slashed pair, else history comes back empty.
        #expect(NativeMarketDataCoordinator.toSlashedPair("EURUSD") == "EUR/USD")
        #expect(NativeMarketDataCoordinator.toSlashedPair("GBPJPY") == "GBP/JPY")
        // Already slashed → unchanged.
        #expect(NativeMarketDataCoordinator.toSlashedPair("EUR/USD") == "EUR/USD")
        // Non-6-char (e.g. metals/indices) → left as-is, no guessing.
        #expect(NativeMarketDataCoordinator.toSlashedPair("XAUUSD") == "XAU/USD")
        #expect(NativeMarketDataCoordinator.toSlashedPair("US500") == "US500")
    }
}

@Suite("Account native mapping")
struct AccountNativeMappingTests {
    @Test("Maps native AccountInfo fields, deriving usedMargin and freeMargin")
    func mapsFields() {
        var info = AccountInfo()
        info.balance = BigDecimalValue(unscaled: BigInt(100_000), scale: 2)      // 1000.00
        info.equity = BigDecimalValue(unscaled: BigInt(99_500), scale: 2)        //  995.00
        info.usableMargin = BigDecimalValue(unscaled: BigInt(90_000), scale: 2)  //  900.00
        info.currency = "EUR"
        info.leverage = 30

        let acct = Account(native: info, connected: true)
        #expect(acct.balance == 1000)
        #expect(acct.equity == 995)
        #expect(acct.freeMargin == 900)
        #expect(abs(acct.usedMargin - 95) < 1e-9)  // equity − usableMargin
        #expect(acct.currency == "EUR")
        #expect(acct.leverage == 30)
        #expect(acct.connected)
        #expect(acct.lastTickAgeMs == 0)
    }

    @Test("Missing fields fall back to safe defaults")
    func defaults() {
        let acct = Account(native: AccountInfo(), connected: false)
        #expect(acct.balance == 0)
        #expect(acct.equity == 0)
        #expect(acct.currency == "USD")
        #expect(acct.leverage == 30)
        #expect(!acct.connected)
    }

    @Test("isHealthStale: healthy when connected with a fresh tick age")
    func healthyWhenConnectedAndFresh() {
        let acct = Account(native: AccountInfo(), connected: true, lastTickAgeMs: 1_000)
        #expect(!acct.isHealthStale)
    }

    @Test("isHealthStale: stale when the transport is disconnected")
    func staleWhenDisconnected() {
        let acct = Account(native: AccountInfo(), connected: false, lastTickAgeMs: 0)
        #expect(acct.isHealthStale)
    }

    @Test("isHealthStale: stale when no tick has arrived for over 10s")
    func staleWhenTickAged() {
        let acct = Account(native: AccountInfo(), connected: true, lastTickAgeMs: 10_001)
        #expect(acct.isHealthStale)
    }
}

@Suite("BarAggregator fixed grid")
struct BarAggregatorFixedGridTests {
    @Test("Builds 15m buckets from 1m bars on a fixed epoch grid")
    func fifteenMinFromOneMin() {
        // Five 1m bars: three in the [0, 900000) bucket, two in [900000, 1800000).
        func bar(_ tMin: Int64, o: Double, h: Double, l: Double, c: Double, v: Double) -> SwiftTrader.CandleBar {
            SwiftTrader.CandleBar(time: tMin * 60_000, open: o, high: h, low: l, close: c, volume: v)
        }
        let source = [
            bar(0,  o: 1.0, h: 1.2, l: 0.9, c: 1.1, v: 10),
            bar(1,  o: 1.1, h: 1.3, l: 1.0, c: 1.2, v: 20),
            bar(14, o: 1.2, h: 1.25, l: 1.15, c: 1.18, v: 5),
            bar(15, o: 1.18, h: 1.4, l: 1.18, c: 1.35, v: 8),
            bar(29, o: 1.35, h: 1.36, l: 1.30, c: 1.31, v: 3),
        ]
        let out = BarAggregator.aggregateFixedGrid(source, granularityMs: 900_000, openPartial: nil)
        #expect(out.count == 2)
        // Bucket 0 = first 3 bars.
        #expect(out[0].time == 0)
        #expect(out[0].open == 1.0)            // first bar's open
        #expect(out[0].close == 1.18)          // last bar's close
        #expect(out[0].high == 1.3)            // max high
        #expect(out[0].low == 0.9)             // min low
        #expect(out[0].volume == 35)           // 10+20+5
        // Bucket 1 = last 2 bars, starting at 900000ms.
        #expect(out[1].time == 900_000)
        #expect(out[1].open == 1.18)
        #expect(out[1].close == 1.31)
        #expect(out[1].high == 1.4)
        #expect(out[1].volume == 11)
    }

    @Test("5m and 30m use their own grid granularity")
    func fiveAndThirtyMinGranularity() {
        func bar(_ tMin: Int64) -> SwiftTrader.CandleBar {
            SwiftTrader.CandleBar(time: tMin * 60_000, open: 1, high: 1, low: 1, close: 1, volume: 1)
        }
        // Bars at 0,4 → one 5m bucket; at 5 → next 5m bucket.
        let fiveMin = BarAggregator.aggregateFixedGrid([bar(0), bar(4), bar(5)], granularityMs: 300_000, openPartial: nil)
        #expect(fiveMin.map(\.time) == [0, 300_000])
        // Bars at 0,29 → one 30m bucket; at 30 → next.
        let thirtyMin = BarAggregator.aggregateFixedGrid([bar(0), bar(29), bar(30)], granularityMs: 1_800_000, openPartial: nil)
        #expect(thirtyMin.map(\.time) == [0, 1_800_000])
    }
}

@Suite("Native news/calendar mapping")
struct NativeNewsMappingTests {
    @Test("Calendar event maps to a CALENDAR NewsItem with details + positive time")
    func calendarMapping() {
        let detail = CalendarEventDetailMsg(
            importance: "H", description: "GDP, Y/Y%", actual: nil, expected: "2.0%", previous: "1.8%")
        let cal = CalendarEventMsg(
            eventId: "EV1", country: "US", eventCategory: "GDP", period: "Q1",
            eventDate: Int64.min, eventTimestamp: Int64.min,   // unset → MIN_VALUE
            description: "Gross Domestic Product", details: [detail])
        let story = NewsStoryMsg(newsId: "N1", publishDate: 1_780_000_000_000, header: "", hot: false)

        let item = NativeNewsCoordinator.map(.calendar(cal, story: story))
        let r = try! #require(item)
        #expect(r.id == "N1")
        #expect(r.type == "CALENDAR")
        #expect(r.country == "US")
        #expect(r.eventCategory == "GDP")
        #expect(r.header == "Gross Domestic Product")   // empty story header → calendar description
        #expect(r.publishDate == 1_780_000_000_000)     // MIN_VALUE skipped, story publish used
        #expect(r.hot)                                  // importance H → hot
        #expect(r.details?.count == 1)
        #expect(r.details?.first?.expected == "2.0%")
    }

    @Test("Plain news story maps to a NEWS NewsItem")
    func storyMapping() {
        let story = NewsStoryMsg(newsId: "S1", publishDate: 1_780_000_000_000,
                                 header: "ECB speaks", hot: true, currencies: ["EUR"])
        let item = NativeNewsCoordinator.map(.story(story))
        let r = try! #require(item)
        #expect(r.id == "S1")
        #expect(r.type == "NEWS")
        #expect(r.header == "ECB speaks")
        #expect(r.hot)
        #expect(r.currencies == ["EUR"])
        #expect(r.isCalendar == false)
    }
}

@Suite("Aggregated cache gap detection")
struct AggregatedGapTests {
    private func ms(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Int64 {
        var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return Int64(cal.date(from: c)!.timeIntervalSince1970 * 1000)
    }
    private func bar(_ t: Int64) -> SwiftTrader.CandleBar {
        SwiftTrader.CandleBar(time: t, open: 1, high: 1, low: 1, close: 1, volume: 0)
    }

    @Test("a contiguous 15m series has no spurious gap")
    func contiguousIsClean() {
        let t0 = ms(2026, 6, 3, 10, 0)   // Wednesday, mid-session
        let bars = (0..<8).map { bar(t0 + Int64($0) * 900_000) }
        #expect(NativeMarketDataCoordinator.hasSpuriousGap(bars, periodSeconds: 900) == false)
    }

    @Test("a weekday hole IS a spurious gap (the AUD/CAD 15m bug)")
    func weekdayHoleIsSpurious() {
        let t0 = ms(2026, 6, 3, 10, 0)   // Wednesday
        // two contiguous bars, then a 14-hour hole — entirely within an open trading day
        let bars = [bar(t0), bar(t0 + 900_000), bar(t0 + 14 * 3_600_000)]
        #expect(NativeMarketDataCoordinator.hasSpuriousGap(bars, periodSeconds: 900) == true)
    }

    @Test("a weekend closure is NOT a spurious gap")
    func weekendIsNotSpurious() {
        // Last bar Fri 20:45 UTC (16:45 ET, open); first bar back Sun 21:00 UTC (17:00 ET reopen).
        let fri = ms(2026, 6, 5, 20, 45)   // Friday
        let sun = ms(2026, 6, 7, 21, 0)    // Sunday reopen
        #expect(NativeMarketDataCoordinator.hasSpuriousGap([bar(fri), bar(sun)], periodSeconds: 900) == false)
    }
}

@Suite("Raw live-bar seed bucket guard")
struct InProgressSeedTests {
    private func bar(_ t: Int64, high: Double) -> SwiftTrader.CandleBar {
        SwiftTrader.CandleBar(time: t, open: 1, high: high, low: 1, close: 1, volume: 0, partial: true)
    }

    @Test("seeds from an in-progress partial that matches the current bucket")
    func matchingBucketSeeds() {
        let bucket: Int64 = 11 * 3_600_000
        let seed = NativeMarketDataCoordinator.inProgressSeed(bar(bucket, high: 0.717), bucketMs: bucket)
        #expect(seed?.time == bucket)
        #expect(seed?.high == 0.717)
    }

    @Test("rejects a partial from the PREVIOUS bucket (the AUDUSD 1h stale-high bug)")
    func staleBucketRejected() {
        let prev: Int64 = 10 * 3_600_000     // 10:00 in-progress bar lingering at rollover
        let current: Int64 = 11 * 3_600_000  // the 11:00 bucket we're seeding
        // The stale 10:00 partial carries the prior hour's high — must NOT graft onto 11:00.
        #expect(NativeMarketDataCoordinator.inProgressSeed(bar(prev, high: 0.71659), bucketMs: current) == nil)
    }

    @Test("nil partial yields no seed")
    func nilPartial() {
        #expect(NativeMarketDataCoordinator.inProgressSeed(nil, bucketMs: 3_600_000) == nil)
    }
}

@Suite("Aggregated bucket completeness (never persist incomplete)")
struct AggregatedBucketCompleteTests {
    private func ms(_ y: Int, _ mo: Int, _ d: Int, _ h: Int) -> Int64 {
        var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = h
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return Int64(cal.date(from: c)!.timeIntervalSince1970 * 1000)
    }
    private let hour: Int64 = 3_600_000
    private let fourH: Int64 = 4 * 3_600_000

    @Test("A full mid-week 4H bucket (all four 1H bars) is complete")
    func fullBucketComplete() {
        let start = ms(2026, 6, 3, 13)   // Wednesday 13:00 UTC, mid-session
        let src = Set([0, 1, 2, 3].map { start + Int64($0) * hour })
        #expect(NativeMarketDataCoordinator.aggregatedBucketComplete(
            bucketStartMs: start, spanMs: fourH, sourceStepMs: hour, sourceTimes: src, nowMs: start + fourH + hour))
    }

    @Test("A 1-of-4 mid-week 4H bucket is INCOMPLETE (the cache-poisoning bug)")
    func incompleteBucketRejected() {
        let start = ms(2026, 6, 3, 13)
        let src: Set<Int64> = [start]   // only the first 1H bar arrived (history stall)
        #expect(!NativeMarketDataCoordinator.aggregatedBucketComplete(
            bucketStartMs: start, spanMs: fourH, sourceStepMs: hour, sourceTimes: src, nowMs: start + fourH + hour))
    }

    @Test("A weekend bucket counts complete even with no bars (slots are market-closed)")
    func weekendBucketComplete() {
        let start = ms(2026, 6, 6, 0)   // Saturday 00:00 UTC — market closed, no bars expected
        #expect(NativeMarketDataCoordinator.aggregatedBucketComplete(
            bucketStartMs: start, spanMs: fourH, sourceStepMs: hour, sourceTimes: Set(), nowMs: start + fourH + hour))
    }

    @Test("A still-forming bucket is withheld from persistence (fail-closed)")
    func formingBucketWithheld() {
        let start = ms(2026, 6, 3, 13)
        #expect(!NativeMarketDataCoordinator.aggregatedBucketComplete(
            bucketStartMs: start, spanMs: fourH, sourceStepMs: hour, sourceTimes: [start], nowMs: start + hour))
    }
}

@Suite("HistoryPrefetcher warm-up")
struct HistoryPrefetcherTests {
    /// Records every page request so the test can assert what the warm loop asked for.
    actor PageRecorder {
        struct Call: Equatable, Sendable {
            let period: String
            let side: ChartSide
        }
        private(set) var calls: [Call] = []
        func record(_ c: Call) { calls.append(c) }
    }

    @Test("Warm-up fetches BID fully first, then mirrors the plan on ASK")
    func warmsBothSides() async throws {
        let cache = CandleCache()
        let recorder = PageRecorder()
        // One page deep enough for every series target (2y for 1H), so each
        // (series, side) finishes in a single fetch and the gap-scan sees a
        // single-bar series (no gaps → no extra fetches).
        let deepMs = Int64(Date().timeIntervalSince1970 * 1000) - Int64(3 * 365) * 24 * 3_600_000
        let prefetcher = HistoryPrefetcher(
            instruments: ["EURUSD"],
            cache: cache,
            awaitIdle: {},
            fetchPage: { instrument, period, _, _, side in
                await recorder.record(.init(period: period, side: side))
                let bar = SwiftTrader.CandleBar(
                    time: deepMs, open: 1.0, high: 1.2, low: 0.9, close: 1.1, volume: 1
                )
                _ = await cache.merge(
                    [bar],
                    for: CandleCache.CacheKey(
                        instrument: instrument, period: period, source: .server, side: side
                    )
                )
                return [bar]
            },
            initialDelay: .zero
        )
        await prefetcher.ensureStarted()

        // 2 series × 1 instrument × 2 sides = 4 pages; each deepen paces 250ms.
        for _ in 0..<500 {
            if await recorder.calls.count >= 4 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        // Grace window: the gap-scan runs after the depth pass and must add nothing.
        try await Task.sleep(for: .milliseconds(100))
        await prefetcher.stop()

        let calls = await recorder.calls
        #expect(calls == [
            .init(period: "ONE_HOUR", side: .bid),
            .init(period: "ONE_MIN", side: .bid),
            .init(period: "ONE_HOUR", side: .ask),
            .init(period: "ONE_MIN", side: .ask),
        ])

        // Both sides landed under their own cache keys, no cross-side bleed.
        for period in ["ONE_HOUR", "ONE_MIN"] {
            for side in [ChartSide.bid, .ask] {
                let key = CandleCache.CacheKey(
                    instrument: "EURUSD", period: period, source: .server, side: side
                )
                let bars = await cache.getBars(for: key)
                #expect(bars.count == 1, "expected exactly one warmed bar for \(period) \(side.rawValue)")
            }
        }
    }
}
