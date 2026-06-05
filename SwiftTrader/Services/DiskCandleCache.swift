import Foundation

enum BarSource: String, Codable, Sendable, Hashable, CaseIterable {
    case server
    case aggregated
}

struct DiskCacheKey: Hashable, Sendable {
    let instrument: String
    let period: String
    let source: BarSource
    var side: ChartSide = .bid
}

/// On-disk layer for completed candle bars — one **packed-binary** file per
/// `(instrument, period, source)`. The format is a fixed-size record stream (no `Codable`
/// reflection), so decoding tens of thousands of bars is a tight `Data` loop. Writes are
/// atomic; repeated saves for the same key coalesce via a per-key debounce.
actor DiskCandleCache {
    // "SCB1" — SwiftTrader Candle Binary v1. A 4-byte magic, then N fixed records of
    // `recordSize` bytes: time(Int64) + open/high/low/close/volume(Double), little-endian.
    // Only non-partial bars are stored, so `partial` need not be persisted.
    private static let magic: [UInt8] = [0x53, 0x43, 0x42, 0x31]
    private static let recordSize = 48

    private let directory: URL
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

    /// Load bars for a key from disk. Returns empty on missing/corrupt files (anything
    /// whose header doesn't match the `SCB1` magic).
    func load(_ key: DiskCacheKey) -> [CandleBar] {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url),
              data.count >= Self.magic.count,
              data.prefix(Self.magic.count).elementsEqual(Self.magic) else {
            return []
        }
        return Self.decodePacked(data)
    }

    /// Save bars for a key to disk immediately. Drops any partial bars.
    func save(_ bars: [CandleBar], for key: DiskCacheKey) throws {
        let data = Self.encodePacked(bars.filter { !$0.partial })
        try data.write(to: fileURL(for: key), options: [.atomic])
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

    /// File URL used for a key; exposed for testing. The `.plist` extension is historical
    /// — existing on-disk caches use it, and the contents are the packed SCB1 binary format.
    nonisolated func fileURL(for key: DiskCacheKey) -> URL {
        // BID keeps the historical name so existing on-disk caches still load; ASK gets a distinct
        // suffix so the two sides never share a file.
        let sideSuffix = key.side == .bid ? "" : ".\(key.side.rawValue)"
        let name = "\(Self.sanitize(key.instrument))-\(key.period).\(key.source.rawValue)\(sideSuffix).plist"
        return directory.appendingPathComponent(name)
    }

    static func sanitize(_ instrument: String) -> String {
        instrument.replacingOccurrences(of: "/", with: "")
    }

    static func parseStem(_ stem: String) -> DiskCacheKey? {
        // Shape: "<instrumentSan>-<period>.<source>[.<SIDE>]" (no SIDE suffix ⇒ BID, legacy files).
        let dotParts = stem.split(separator: ".").map(String.init)
        guard dotParts.count == 2 || dotParts.count == 3 else { return nil }
        guard let source = BarSource(rawValue: dotParts[1]) else { return nil }
        let side: ChartSide = dotParts.count == 3 ? (ChartSide(rawValue: dotParts[2]) ?? .bid) : .bid
        let dashParts = dotParts[0].split(separator: "-", maxSplits: 1).map(String.init)
        guard dashParts.count == 2 else { return nil }
        return DiskCacheKey(instrument: dashParts[0], period: dashParts[1], source: source, side: side)
    }

    // MARK: - Packed binary codec (no Codable/reflection)

    /// Encode bars to `magic` + N × 48-byte little-endian records.
    static func encodePacked(_ bars: [CandleBar]) -> Data {
        var data = Data(capacity: magic.count + bars.count * recordSize)
        data.append(contentsOf: magic)
        for b in bars {
            appendLE(&data, UInt64(bitPattern: b.time))
            appendLE(&data, b.open.bitPattern)
            appendLE(&data, b.high.bitPattern)
            appendLE(&data, b.low.bitPattern)
            appendLE(&data, b.close.bitPattern)
            appendLE(&data, b.volume.bitPattern)
        }
        return data
    }

    /// Decode a packed file (`magic` + N × 48-byte records) with a tight `Data` loop.
    static func decodePacked(_ data: Data) -> [CandleBar] {
        let count = (data.count - magic.count) / recordSize
        guard count > 0 else { return [] }
        var bars = [CandleBar]()
        bars.reserveCapacity(count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = magic.count
            for _ in 0..<count {
                func field(_ delta: Int) -> UInt64 {
                    UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset + delta, as: UInt64.self))
                }
                let bar = CandleBar(
                    time: Int64(bitPattern: field(0)),
                    open: Double(bitPattern: field(8)),
                    high: Double(bitPattern: field(16)),
                    low: Double(bitPattern: field(24)),
                    close: Double(bitPattern: field(32)),
                    volume: Double(bitPattern: field(40))
                )
                bars.append(bar)
                offset += recordSize
            }
        }
        return bars
    }

    private static func appendLE(_ data: inout Data, _ value: UInt64) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
