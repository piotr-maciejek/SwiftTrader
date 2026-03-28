import Foundation

/// Shared in-memory cache for completed candle bars, keyed by (instrument, period).
/// Thread-safe via actor isolation. Used across all tabs to avoid redundant REST fetches.
actor CandleCache {
    struct CacheKey: Hashable {
        let instrument: String
        let period: String  // timeframe, e.g. "ONE_MIN", "FOUR_HOURS"
    }

    private struct CacheEntry {
        var bars: [CandleBar]  // sorted by time ascending, all partial == false
        var lastAccess: ContinuousClock.Instant
    }

    private var store: [CacheKey: CacheEntry] = [:]
    private let maxBarsPerKey = 5000
    private let maxKeys = 50

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
            let existingTimes = Set(existing.map(\.time))
            let newBars = completed.filter { !existingTimes.contains($0.time) }
            if !newBars.isEmpty {
                existing.append(contentsOf: newBars)
                existing.sort { $0.time < $1.time }
            }
        }

        // Per-key eviction: trim oldest if over limit
        if existing.count > maxBarsPerKey {
            existing = Array(existing.suffix(maxBarsPerKey))
        }

        store[key] = CacheEntry(bars: existing, lastAccess: .now)
        evictIfNeeded()
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
    }

    /// Wipe all entries (e.g. on full reconnect with different server config).
    func clear() {
        store.removeAll()
    }

    private func evictIfNeeded() {
        while store.count > maxKeys {
            if let lruKey = store.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
                store.removeValue(forKey: lruKey)
            }
        }
    }
}
