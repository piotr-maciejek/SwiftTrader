import Foundation

enum BarSource: String, Codable, Sendable, Hashable, CaseIterable {
    case server
    case aggregated
}

struct DiskCacheKey: Hashable, Sendable {
    let instrument: String
    let period: String
    let source: BarSource
}

/// On-disk layer for completed candle bars. Binary-plist per `(instrument, period, source)`.
/// Writes are atomic; repeated saves for the same key coalesce via a per-key debounce.
actor DiskCandleCache {
    private struct CacheFile: Codable {
        let version: Int
        let bars: [CandleBar]
    }

    private let directory: URL
    private let currentVersion = 1
    private let debounceInterval: TimeInterval
    private var pendingWrites: [DiskCacheKey: Task<Void, Never>] = [:]
    private var pendingBars: [DiskCacheKey: [CandleBar]] = [:]

    init(directory: URL? = nil, debounceInterval: TimeInterval = 2.0) {
        let resolved: URL = {
            if let directory { return directory }
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            return base.appendingPathComponent("SwiftTrader/bars", isDirectory: true)
        }()
        self.directory = resolved
        self.debounceInterval = debounceInterval
        try? FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
    }

    /// Load bars for a key from disk. Returns empty on missing/corrupt/version-mismatch.
    func load(_ key: DiskCacheKey) -> [CandleBar] {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = PropertyListDecoder()
        guard let file = try? decoder.decode(CacheFile.self, from: data) else { return [] }
        guard file.version == currentVersion else { return [] }
        return file.bars
    }

    /// Save bars for a key to disk immediately. Drops any partial bars.
    func save(_ bars: [CandleBar], for key: DiskCacheKey) throws {
        let file = CacheFile(version: currentVersion, bars: bars.filter { !$0.partial })
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(file)
        let url = fileURL(for: key)
        try data.write(to: url, options: [.atomic])
    }

    /// Schedule a debounced save. Successive calls for the same key within
    /// `debounceInterval` coalesce into a single disk write.
    func scheduleSave(_ bars: [CandleBar], for key: DiskCacheKey) {
        pendingBars[key] = bars
        pendingWrites[key]?.cancel()
        let delay = debounceInterval
        pendingWrites[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.flush(key: key)
        }
    }

    /// Flush pending write for a single key, synchronously.
    func flush(key: DiskCacheKey) {
        guard let bars = pendingBars.removeValue(forKey: key) else { return }
        pendingWrites.removeValue(forKey: key)
        try? save(bars, for: key)
    }

    /// Flush all pending writes. Useful from tests and graceful shutdown paths.
    func flushAll() {
        for key in Array(pendingBars.keys) {
            flush(key: key)
        }
    }

    /// List every key currently persisted to disk (by scanning file names).
    func allKeys() -> [DiskCacheKey] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        return contents.compactMap { url in
            guard url.pathExtension == "plist" else { return nil }
            let stem = url.deletingPathExtension().lastPathComponent
            return Self.parseStem(stem)
        }
    }

    /// Remove all disk files for a single instrument (every period × source).
    func clear(instrument: String) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        let prefix = Self.sanitize(instrument) + "-"
        for url in contents {
            if url.lastPathComponent.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        for key in Array(pendingBars.keys) where key.instrument == instrument {
            pendingBars.removeValue(forKey: key)
            pendingWrites.removeValue(forKey: key)?.cancel()
        }
    }

    /// Remove everything. Only used by explicit user-driven full reset.
    func clearAll() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
        pendingBars.removeAll()
        for (_, t) in pendingWrites { t.cancel() }
        pendingWrites.removeAll()
    }

    /// File URL used for a key; exposed for testing.
    nonisolated func fileURL(for key: DiskCacheKey) -> URL {
        let name = "\(Self.sanitize(key.instrument))-\(key.period).\(key.source.rawValue).plist"
        return directory.appendingPathComponent(name)
    }

    static func sanitize(_ instrument: String) -> String {
        instrument.replacingOccurrences(of: "/", with: "")
    }

    static func parseStem(_ stem: String) -> DiskCacheKey? {
        // Shape: "<instrumentSan>-<period>.<source>"
        let dotParts = stem.split(separator: ".", maxSplits: 1).map(String.init)
        guard dotParts.count == 2, let source = BarSource(rawValue: dotParts[1]) else { return nil }
        let instrumentPeriod = dotParts[0]
        let dashParts = instrumentPeriod.split(separator: "-", maxSplits: 1).map(String.init)
        guard dashParts.count == 2 else { return nil }
        return DiskCacheKey(instrument: dashParts[0], period: dashParts[1], source: source)
    }
}
