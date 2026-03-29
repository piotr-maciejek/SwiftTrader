import Testing
@testable import SwiftTrader

private func makeBar(time: Int64, close: Double = 1.1, partial: Bool = false) -> CandleBar {
    CandleBar(time: time, open: 1.0, high: 1.2, low: 0.9, close: close, volume: 100, partial: partial)
}

private let testKey = CandleCache.CacheKey(instrument: "EURUSD", period: "ONE_MIN")

@Suite("CandleCache")
struct CandleCacheTests {

    @Test("Merge into empty cache stores bars sorted by time")
    func mergeEmpty() async {
        let cache = CandleCache()
        let bars = [makeBar(time: 300), makeBar(time: 100), makeBar(time: 200)]
        let result = await cache.merge(bars, for: testKey)
        #expect(result.count == 3)
        #expect(result[0].time == 100)
        #expect(result[1].time == 200)
        #expect(result[2].time == 300)
    }

    @Test("Merge deduplicates by timestamp")
    func mergeDedup() async {
        let cache = CandleCache()
        _ = await cache.merge([makeBar(time: 100), makeBar(time: 200)], for: testKey)
        let result = await cache.merge([makeBar(time: 200), makeBar(time: 300)], for: testKey)
        #expect(result.count == 3)
        #expect(result.map(\.time) == [100, 200, 300])
    }

    @Test("Merge filters out partial bars")
    func mergeFiltersPartial() async {
        let cache = CandleCache()
        let bars = [makeBar(time: 100), makeBar(time: 200, partial: true), makeBar(time: 300)]
        let result = await cache.merge(bars, for: testKey)
        #expect(result.count == 2)
        #expect(result.map(\.time) == [100, 300])
    }

    @Test("Merge with only partial bars returns existing cache")
    func mergeAllPartial() async {
        let cache = CandleCache()
        _ = await cache.merge([makeBar(time: 100)], for: testKey)
        let result = await cache.merge([makeBar(time: 200, partial: true)], for: testKey)
        #expect(result.count == 1)
        #expect(result[0].time == 100)
    }

    @Test("appendBar with newer timestamp appends")
    func appendNewer() async {
        let cache = CandleCache()
        _ = await cache.merge([makeBar(time: 100)], for: testKey)
        await cache.appendBar(makeBar(time: 200), for: testKey)
        let result = await cache.getBars(for: testKey)
        #expect(result.count == 2)
        #expect(result[1].time == 200)
    }

    @Test("appendBar with same timestamp replaces last bar")
    func appendReplace() async {
        let cache = CandleCache()
        _ = await cache.merge([makeBar(time: 100, close: 1.0)], for: testKey)
        await cache.appendBar(makeBar(time: 100, close: 2.0), for: testKey)
        let result = await cache.getBars(for: testKey)
        #expect(result.count == 1)
        #expect(result[0].close == 2.0)
    }

    @Test("appendBar ignores partial bars")
    func appendIgnoresPartial() async {
        let cache = CandleCache()
        _ = await cache.merge([makeBar(time: 100)], for: testKey)
        await cache.appendBar(makeBar(time: 200, partial: true), for: testKey)
        let result = await cache.getBars(for: testKey)
        #expect(result.count == 1)
    }

    @Test("appendBar into empty cache works")
    func appendEmpty() async {
        let cache = CandleCache()
        await cache.appendBar(makeBar(time: 100), for: testKey)
        let result = await cache.getBars(for: testKey)
        #expect(result.count == 1)
        #expect(result[0].time == 100)
    }

    @Test("getBars returns empty for unknown key")
    func getBarsUnknown() async {
        let cache = CandleCache()
        let result = await cache.getBars(for: testKey)
        #expect(result.isEmpty)
    }

    @Test("earliestTime returns nil for unknown key")
    func earliestTimeUnknown() async {
        let cache = CandleCache()
        let result = await cache.earliestTime(for: testKey)
        #expect(result == nil)
    }

    @Test("earliestTime returns correct value")
    func earliestTimeCorrect() async {
        let cache = CandleCache()
        _ = await cache.merge([makeBar(time: 200), makeBar(time: 100), makeBar(time: 300)], for: testKey)
        let result = await cache.earliestTime(for: testKey)
        #expect(result == 100)
    }

    @Test("Multiple keys stored independently")
    func multipleKeys() async {
        let cache = CandleCache()
        let key1 = CandleCache.CacheKey(instrument: "EURUSD", period: "ONE_MIN")
        let key2 = CandleCache.CacheKey(instrument: "GBPUSD", period: "ONE_MIN")
        _ = await cache.merge([makeBar(time: 100)], for: key1)
        _ = await cache.merge([makeBar(time: 200), makeBar(time: 300)], for: key2)
        let r1 = await cache.getBars(for: key1)
        let r2 = await cache.getBars(for: key2)
        #expect(r1.count == 1)
        #expect(r2.count == 2)
    }

    @Test("appendBar with older timestamp is ignored")
    func appendOlderIgnored() async {
        let cache = CandleCache()
        _ = await cache.merge([makeBar(time: 200)], for: testKey)
        await cache.appendBar(makeBar(time: 100), for: testKey)
        let result = await cache.getBars(for: testKey)
        #expect(result.count == 1)
        #expect(result[0].time == 200)
    }

    @Test("Clear removes all entries")
    func clearCache() async {
        let cache = CandleCache()
        _ = await cache.merge([makeBar(time: 100)], for: testKey)
        await cache.clear()
        let result = await cache.getBars(for: testKey)
        #expect(result.isEmpty)
    }
}
