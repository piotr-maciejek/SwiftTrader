import Foundation

/// Shared in-memory cache for completed candle bars, keyed by (instrument, period).
/// Thread-safe via actor isolation. Used across all tabs to avoid redundant REST fetches.
///
/// Optionally backed by `DiskCandleCache`: on `hydrate()`, every on-disk key is loaded
/// into memory; every `merge` / `appendBar` schedules a debounced write-back.
actor CandleCache {
    struct CacheKey: Hashable {
        let instrument: String
        let period: String  // timeframe, e.g. "ONE_MIN", "FOUR_HOURS"
        let source: BarSource

        init(instrument: String, period: String, source: BarSource = .server) {
            self.instrument = instrument
            self.period = period
            self.source = source
        }

        /// Resolve the source for the currently-displayed chart given the rebucketing toggle.
        /// Raw periods always map to `.server`; only FOUR_HOURS/DAILY can switch.
        static func forDisplay(
            instrument: String, period: String, clientSideRebucketing: Bool
        ) -> CacheKey {
            let source: BarSource =
                (period == "FOUR_HOURS" || period == "DAILY") && clientSideRebucketing
                    ? .aggregated : .server
            return CacheKey(instrument: instrument, period: period, source: source)
        }
    }

    private struct CacheEntry {
        var bars: [CandleBar]  // sorted by time ascending, all partial == false
        var lastAccess: ContinuousClock.Instant
    }

    private var store: [CacheKey: CacheEntry] = [:]
    private let maxBarsPerKey = 5000
    private let maxKeys = 50
    private let diskCache: DiskCandleCache?
    private var hydrated = false

    init(diskCache: DiskCandleCache? = nil) {
        self.diskCache = diskCache
    }

    /// Load every persisted key from disk into memory. Safe to call multiple times —
    /// subsequent calls are no-ops.
    func hydrate() async {
        guard !hydrated, let diskCache else {
            hydrated = true
            return
        }
        hydrated = true
        let keys = await diskCache.allKeys()
        for diskKey in keys {
            let bars = await diskCache.load(diskKey)
            guard !bars.isEmpty else { continue }
            let key = CacheKey(instrument: diskKey.instrument, period: diskKey.period, source: diskKey.source)
            store[key] = CacheEntry(bars: bars, lastAccess: .now)
        }
    }

    /// Returns cached completed bars for this key, or empty array.
    func getBars(for key: CacheKey) -> [CandleBar] {
        guard var entry = store[key] else { return [] }
        entry.lastAccess = .now
        store[key] = entry
        return entry.bars
    }

    /// Returns the earliest cached timestamp for the key, used to build `before` parameter.
    func earliestTime(for key: CacheKey) -> Int64? {
        store[key]?.bars.first?.time
    }

    /// Merge fetched bars into cache. Only stores bars where partial == false.
    /// Returns the full merged array (cached + new).
    @discardableResult
    func merge(_ fetchedBars: [CandleBar], for key: CacheKey) -> [CandleBar] {
        let completed = fetchedBars.filter { !$0.partial }
        guard !completed.isEmpty else {
            return store[key]?.bars ?? []
        }

        var existing = store[key]?.bars ?? []

        if existing.isEmpty {
            existing = completed.sorted { $0.time < $1.time }
        } else {
            // Replace existing bars when timestamps match (server may have corrected values),
            // and append truly new bars.
            let newByTime = Dictionary(completed.map { ($0.time, $0) }, uniquingKeysWith: { _, new in new })
            existing = existing.map { bar in newByTime[bar.time] ?? bar }
            let existingTimes = Set(existing.map(\.time))
            let additions = completed.filter { !existingTimes.contains($0.time) }
            if !additions.isEmpty {
                existing.append(contentsOf: additions)
                existing.sort { $0.time < $1.time }
            }
        }

        // Per-key eviction: trim oldest if over limit
        if existing.count > maxBarsPerKey {
            existing = Array(existing.suffix(maxBarsPerKey))
        }

        store[key] = CacheEntry(bars: existing, lastAccess: .now)
        evictIfNeeded()
        scheduleDiskWrite(key: key, bars: existing)
        return existing
    }

    /// Append a single completed bar from WebSocket. Ignores partial bars.
    func appendBar(_ bar: CandleBar, for key: CacheKey) {
        guard !bar.partial else { return }

        var existing = store[key]?.bars ?? []

        if let last = existing.last {
            if bar.time > last.time {
                existing.append(bar)
            } else if bar.time == last.time {
                existing[existing.count - 1] = bar
            }
        } else {
            existing.append(bar)
        }

        if existing.count > maxBarsPerKey {
            existing = Array(existing.suffix(maxBarsPerKey))
        }

        store[key] = CacheEntry(bars: existing, lastAccess: .now)
        scheduleDiskWrite(key: key, bars: existing)
    }

    /// Wipe all entries (e.g. on full reconnect with different server config).
    func clear() {
        store.removeAll()
        if let diskCache {
            Task { await diskCache.clearAll() }
        }
    }

    /// Wipe all cached periods for one instrument. Used by the Refresh Cache button.
    func clear(instrument: String) {
        store = store.filter { $0.key.instrument != instrument }
        if let diskCache {
            Task { await diskCache.clear(instrument: instrument) }
        }
    }

    private func evictIfNeeded() {
        while store.count > maxKeys {
            if let lruKey = store.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
                store.removeValue(forKey: lruKey)
            }
        }
    }

    private func scheduleDiskWrite(key: CacheKey, bars: [CandleBar]) {
        guard let diskCache else { return }
        let diskKey = DiskCacheKey(instrument: key.instrument, period: key.period, source: key.source)
        Task { await diskCache.scheduleSave(bars, for: diskKey) }
    }
}
