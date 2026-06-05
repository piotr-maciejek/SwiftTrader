import Foundation
import Testing
@testable import SwiftTrader

private func makeBar(time: Int64, close: Double = 1.1, partial: Bool = false) -> CandleBar {
    CandleBar(time: time, open: 1.0, high: 1.2, low: 0.9, close: close, volume: 100, partial: partial)
}

private func makeTempDir() -> URL {
    let base = FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent("DiskCandleCacheTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func cleanUp(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}

@Suite("DiskCandleCache")
struct DiskCandleCacheTests {

    @Test("Save then load roundtrip preserves bars and order")
    func roundtrip() async throws {
        let dir = makeTempDir()
        defer { cleanUp(dir) }
        let cache = DiskCandleCache(directory: dir)
        let key = DiskCacheKey(instrument: "EURUSD", period: "ONE_HOUR", source: .server)
        let bars = [makeBar(time: 100), makeBar(time: 200, close: 1.2), makeBar(time: 300, close: 1.3)]

        try await cache.save(bars, for: key)
        let loaded = await cache.load(key)

        #expect(loaded.count == 3)
        #expect(loaded.map(\.time) == [100, 200, 300])
        #expect(loaded[1].close == 1.2)
    }

    @Test("Bid and ask are stored in separate files (no collision); BID keeps the legacy filename")
    func bidAskIsolation() async throws {
        let dir = makeTempDir()
        defer { cleanUp(dir) }
        let cache = DiskCandleCache(directory: dir)
        let bidKey = DiskCacheKey(instrument: "EURUSD", period: "ONE_HOUR", source: .server, side: .bid)
        let askKey = DiskCacheKey(instrument: "EURUSD", period: "ONE_HOUR", source: .server, side: .ask)

        // Distinct files; BID unchanged from the historical name so old caches still load.
        #expect(cache.fileURL(for: bidKey).lastPathComponent == "EURUSD-ONE_HOUR.server.plist")
        #expect(cache.fileURL(for: askKey).lastPathComponent == "EURUSD-ONE_HOUR.server.ASK.plist")

        try await cache.save([makeBar(time: 100, close: 1.1000)], for: bidKey)
        try await cache.save([makeBar(time: 100, close: 1.1002)], for: askKey)
        // Each side reads back its own value — no overwrite.
        #expect(await cache.load(bidKey).first?.close == 1.1000)
        #expect(await cache.load(askKey).first?.close == 1.1002)
    }

    @Test("parseStem round-trips the side suffix")
    func parseStemSide() {
        #expect(DiskCandleCache.parseStem("EURUSD-ONE_HOUR.server")?.side == .bid)
        #expect(DiskCandleCache.parseStem("EURUSD-ONE_HOUR.server.ASK")?.side == .ask)
        #expect(DiskCandleCache.parseStem("EURUSD-ONE_MIN.aggregated.ASK")?.source == .aggregated)
    }

    @Test("Binary roundtrip preserves every OHLCV field exactly")
    func roundtripAllFields() async throws {
        let dir = makeTempDir()
        defer { cleanUp(dir) }
        let cache = DiskCandleCache(directory: dir)
        let key = DiskCacheKey(instrument: "USDJPY", period: "ONE_MIN", source: .server)
        let bar = CandleBar(time: 1_780_000_000_000, open: 152.123, high: 152.987,
                            low: 151.001, close: 152.456, volume: 12_345.5)
        try await cache.save([bar], for: key)
        let loaded = await cache.load(key)
        #expect(loaded.count == 1)
        let r = try #require(loaded.first)
        #expect(r.time == bar.time)
        #expect(r.open == bar.open)
        #expect(r.high == bar.high)
        #expect(r.low == bar.low)
        #expect(r.close == bar.close)
        #expect(r.volume == bar.volume)
    }

    @Test("Large series roundtrips without loss")
    func roundtripLarge() async throws {
        let dir = makeTempDir()
        defer { cleanUp(dir) }
        let cache = DiskCandleCache(directory: dir)
        let key = DiskCacheKey(instrument: "EURUSD", period: "ONE_MIN", source: .server)
        let bars = (0..<20_000).map { i in makeBar(time: Int64(i) * 60_000, close: 1.0 + Double(i) * 1e-6) }
        try await cache.save(bars, for: key)
        let loaded = await cache.load(key)
        #expect(loaded.count == 20_000)
        #expect(loaded.first?.time == 0)
        #expect(loaded.last?.time == Int64(19_999) * 60_000)
    }

    @Test("Load on missing file returns empty array")
    func loadMissing() async {
        let dir = makeTempDir()
        defer { cleanUp(dir) }
        let cache = DiskCandleCache(directory: dir)
        let key = DiskCacheKey(instrument: "EURUSD", period: "FOUR_HOURS", source: .aggregated)
        let loaded = await cache.load(key)
        #expect(loaded.isEmpty)
    }

    @Test("Partial bars are dropped on save")
    func dropPartials() async throws {
        let dir = makeTempDir()
        defer { cleanUp(dir) }
        let cache = DiskCandleCache(directory: dir)
        let key = DiskCacheKey(instrument: "EURUSD", period: "ONE_MIN", source: .server)
        let bars = [makeBar(time: 100), makeBar(time: 200, partial: true), makeBar(time: 300)]

        try await cache.save(bars, for: key)
        let loaded = await cache.load(key)
        #expect(loaded.count == 2)
        #expect(loaded.allSatisfy { !$0.partial })
    }

    @Test("Corrupted file decodes as empty")
    func corruptedFile() async throws {
        let dir = makeTempDir()
        defer { cleanUp(dir) }
        let cache = DiskCandleCache(directory: dir)
        let key = DiskCacheKey(instrument: "EURUSD", period: "ONE_MIN", source: .server)
        let url = await cache.fileURL(for: key)
        try Data("not a plist".utf8).write(to: url)

        let loaded = await cache.load(key)
        #expect(loaded.isEmpty)
    }

    @Test("Clear by instrument removes all its files")
    func clearInstrument() async throws {
        let dir = makeTempDir()
        defer { cleanUp(dir) }
        let cache = DiskCandleCache(directory: dir)
        let eurusdHour = DiskCacheKey(instrument: "EURUSD", period: "ONE_HOUR", source: .server)
        let eurusdMin = DiskCacheKey(instrument: "EURUSD", period: "ONE_MIN", source: .server)
        let usdjpyHour = DiskCacheKey(instrument: "USDJPY", period: "ONE_HOUR", source: .server)

        try await cache.save([makeBar(time: 1)], for: eurusdHour)
        try await cache.save([makeBar(time: 2)], for: eurusdMin)
        try await cache.save([makeBar(time: 3)], for: usdjpyHour)

        await cache.clear(instrument: "EURUSD")

        #expect(await cache.load(eurusdHour).isEmpty)
        #expect(await cache.load(eurusdMin).isEmpty)
        #expect(await cache.load(usdjpyHour).count == 1)
    }

    @Test("allKeys enumerates every file")
    func enumerate() async throws {
        let dir = makeTempDir()
        defer { cleanUp(dir) }
        let cache = DiskCandleCache(directory: dir)
        let k1 = DiskCacheKey(instrument: "EURUSD", period: "ONE_HOUR", source: .server)
        let k2 = DiskCacheKey(instrument: "EURUSD", period: "FOUR_HOURS", source: .aggregated)
        let k3 = DiskCacheKey(instrument: "USDJPY", period: "DAILY", source: .server)
        try await cache.save([makeBar(time: 1)], for: k1)
        try await cache.save([makeBar(time: 2)], for: k2)
        try await cache.save([makeBar(time: 3)], for: k3)

        let keys = await cache.allKeys()
        #expect(Set(keys) == Set([k1, k2, k3]))
    }

    @Test("Debounced save coalesces multiple writes into one")
    func debouncedSave() async throws {
        let dir = makeTempDir()
        defer { cleanUp(dir) }
        let cache = DiskCandleCache(directory: dir, debounceInterval: 0.2)
        let key = DiskCacheKey(instrument: "EURUSD", period: "ONE_MIN", source: .server)

        await cache.scheduleSave([makeBar(time: 1)], for: key)
        await cache.scheduleSave([makeBar(time: 1), makeBar(time: 2)], for: key)
        await cache.scheduleSave([makeBar(time: 1), makeBar(time: 2), makeBar(time: 3)], for: key)

        try await Task.sleep(nanoseconds: 500_000_000) // > debounce

        let loaded = await cache.load(key)
        #expect(loaded.count == 3)
    }

    @Test("flushAll writes pending bars immediately")
    func flushPending() async {
        let dir = makeTempDir()
        defer { cleanUp(dir) }
        let cache = DiskCandleCache(directory: dir, debounceInterval: 60.0)
        let key = DiskCacheKey(instrument: "EURUSD", period: "ONE_MIN", source: .server)
        await cache.scheduleSave([makeBar(time: 1)], for: key)

        await cache.flushAll()

        let loaded = await cache.load(key)
        #expect(loaded.count == 1)
    }

    @Test("Filename round-trips via parseStem")
    func parseStemRoundtrip() {
        let key = DiskCacheKey(instrument: "EURUSD", period: "FOUR_HOURS", source: .aggregated)
        let stem = "EURUSD-FOUR_HOURS.aggregated"
        let parsed = DiskCandleCache.parseStem(stem)
        #expect(parsed == key)
    }

    @Test("Slash in instrument name is stripped from file path")
    func sanitizesSlash() async throws {
        let dir = makeTempDir()
        defer { cleanUp(dir) }
        let cache = DiskCandleCache(directory: dir)
        let key = DiskCacheKey(instrument: "EUR/USD", period: "ONE_HOUR", source: .server)

        try await cache.save([makeBar(time: 1)], for: key)
        let loaded = await cache.load(key)
        #expect(loaded.count == 1)
    }
}
