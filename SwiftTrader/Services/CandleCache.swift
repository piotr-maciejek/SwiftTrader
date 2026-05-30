import Foundation

/// Shared in-memory cache for completed candle bars, keyed by (instrument, period).
/// Thread-safe via actor isolation. Used across all tabs to avoid redundant REST fetches.
///
/// Optionally backed by `DiskCandleCache`: each key is loaded from disk **lazily on first
/// access** (never all upfront — the on-disk cache can be hundreds of MB across all pairs),
/// and every `merge` / `appendBar` schedules a debounced write-back.
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
        /// Raw periods map to `.server`; FOUR_HOURS/DAILY switch with the toggle.
        /// THREE_MINS has no native server period, so it is ALWAYS `.aggregated`.
        static func forDisplay(
            instrument: String, period: String, clientSideRebucketing: Bool
        ) -> CacheKey {
            let source: BarSource =
                period == "THREE_MINS"
                    || ((period == "FOUR_HOURS" || period == "DAILY") && clientSideRebucketing)
                    ? .aggregated : .server
            return CacheKey(instrument: instrument, period: period, source: source)
        }
    }

    private struct CacheEntry {
        var bars: [CandleBar]  // sorted by time ascending, all partial == false
        var lastAccess: ContinuousClock.Instant
    }

    private var store: [CacheKey: CacheEntry] = [:]
    /// Keys already pulled from disk (or confirmed absent on disk), so we touch disk at most
    /// once per key. Cleared for a key when it's evicted or wiped, so it can reload later.
    private var diskLoaded: Set<CacheKey> = []
    // Scroll-back pagination adds bars to the OLD end; `suffix(maxBarsPerKey)` keeps
    // newest, so a too-small cap silently discards every newly-fetched earlier page
    // once the cap is hit. Sized for deep history: 200k ONE_MIN bars ≈ 139 days,
    // ONE_HOUR ≈ 22 years, FIFTEEN_MINS ≈ 5.7 years. ~200k × ~80B ≈ 16MB/key (only
    // actively-scrolled series approach the cap).
    private let maxBarsPerKey = 200_000
    // One key per (instrument, period, source). Standalone mode's background prefetcher
    // warms all ~28 pairs across 1H/1m raw + 4H/Daily/3m/5m/15m/30m aggregated (~8 periods),
    // i.e. ~220 keys. A smaller cap evicts deep loads mid-warm-up, so reads miss and the
    // whole range re-fetches (cache thrash). Sized to hold the full working set.
    private let maxKeys = 300
    private let diskCache: DiskCandleCache?

    init(diskCache: DiskCandleCache? = nil) {
        self.diskCache = diskCache
    }

    /// Retained for callers, but a no-op: keys load lazily from disk on first access (see
    /// `ensureLoaded`), so startup never blocks loading the entire on-disk cache into memory.
    func hydrate() async {}

    /// Pull this key from disk into memory the first time it's touched. Loads at most one
    /// file per key; subsequent accesses hit memory directly. Bars with non-positive OHLC
    /// (a transient Dukascopy boundary-filler bug we now filter at fetch time) are
    /// dropped here and the cleaned set written back, so corrupted bars from a previous
    /// run self-heal on next load instead of needing a manual hard refresh.
    private func ensureLoaded(_ key: CacheKey) async {
        guard let diskCache, store[key] == nil, !diskLoaded.contains(key) else { return }
        // Mark before the await so concurrent callers for the same key don't double-load.
        diskLoaded.insert(key)
        let diskKey = DiskCacheKey(instrument: key.instrument, period: key.period, source: key.source)
        let bars = await diskCache.load(diskKey)
        let valid = bars.filter { $0.low > 0 && $0.high > 0 && $0.open > 0 && $0.close > 0 }
        // A merge may have populated the key while we were awaiting — don't clobber it.
        if !valid.isEmpty, store[key] == nil {
            store[key] = CacheEntry(bars: valid, lastAccess: .now)
            // Persist the cleanup so subsequent launches don't re-filter the same bars.
            if valid.count != bars.count {
                scheduleDiskWrite(key: key, bars: valid)
            }
        }
    }

    /// Returns cached completed bars for this key, or empty array.
    func getBars(for key: CacheKey) async -> [CandleBar] {
        await ensureLoaded(key)
        guard var entry = store[key] else { return [] }
        entry.lastAccess = .now
        store[key] = entry
        return entry.bars
    }

    /// Returns the earliest cached timestamp for the key, used to build `before` parameter.
    func earliestTime(for key: CacheKey) async -> Int64? {
        await ensureLoaded(key)
        return store[key]?.bars.first?.time
    }

    /// Returns the latest cached timestamp for the key, used to build `after` parameter for gap-fill.
    func latestTime(for key: CacheKey) async -> Int64? {
        await ensureLoaded(key)
        return store[key]?.bars.last?.time
    }

    /// Merge fetched bars into cache. Only stores bars where partial == false.
    /// Returns the full merged array (cached + new).
    @discardableResult
    func merge(_ fetchedBars: [CandleBar], for key: CacheKey) async -> [CandleBar] {
        await ensureLoaded(key)
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
    func appendBar(_ bar: CandleBar, for key: CacheKey) async {
        guard !bar.partial else { return }
        await ensureLoaded(key)

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
    /// Awaits the disk wipe so the caller's next merge/scheduleDiskWrite can't
    /// race ahead and have its freshly-written data deleted by a delayed wipe.
    func clear() async {
        store.removeAll()
        diskLoaded.removeAll()
        if let diskCache {
            await diskCache.clearAll()
        }
    }

    /// Wipe all cached periods for one instrument. Used by the Refresh Cache
    /// button. Awaits the disk wipe — see `clear()` above for the race rationale.
    func clear(instrument: String) async {
        store = store.filter { $0.key.instrument != instrument }
        diskLoaded = diskLoaded.filter { $0.instrument != instrument }
        if let diskCache {
            await diskCache.clear(instrument: instrument)
        }
    }

    private func evictIfNeeded() {
        while store.count > maxKeys {
            if let lruKey = store.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
                store.removeValue(forKey: lruKey)
                // Allow a future access to reload it from disk instead of re-fetching.
                diskLoaded.remove(lruKey)
            }
        }
    }

    private func scheduleDiskWrite(key: CacheKey, bars: [CandleBar]) {
        guard let diskCache else { return }
        let diskKey = DiskCacheKey(instrument: key.instrument, period: key.period, source: key.source)
        Task { await diskCache.scheduleSave(bars, for: diskKey) }
    }
}
