import Foundation
import os
import SWCompression

private let log = Logger(subsystem: "com.swifttrader", category: "native")

/// Downloads deep historical candles from Dukascopy's bulk history server (the `.bi5`
/// files). Only the BASIC stored periods are downloadable — `ONE_MIN` (per-day files),
/// `ONE_HOUR` (per-month files), and `DAILY` (per-year files); every other timeframe is
/// built from these by the caller. Each chunk is an LZMA-"alone" stream of 24-byte
/// big-endian candle records.
public struct BulkHistoryClient: Sendable {
    public enum BulkError: Error, CustomStringConvertible {
        case unsupportedPeriod(Int64)
        case badURL(String)
        case decodeFailed(String)

        public var description: String {
            switch self {
            case .unsupportedPeriod(let s): "bulk history only serves 1m/1H/Daily, not period \(s)s"
            case .badURL(let s): "bad history URL: \(s)"
            case .decodeFailed(let s): "bulk chunk decode failed: \(s)"
            }
        }
    }

    private let urlSession: URLSession
    private let maxConcurrent: Int

    public init(urlSession: URLSession = .shared, maxConcurrent: Int = 6) {
        self.urlSession = urlSession
        self.maxConcurrent = maxConcurrent
    }

    /// A fetch's outcome including any chunks that failed transiently. The session
    /// retries `failedChunks` once more before surfacing them as `HistoryResult.missingWindows`.
    public struct BulkResult: Sendable {
        public let bars: [CandleBar]
        public let failedChunks: [ChunkDescriptor]
    }

    /// Fetches candles for a basic `period` over `[fromMs, toMs]` by downloading every
    /// chunk file spanning the range. Chunks that 404 or return empty data are treated
    /// as "no data" (weekends, before listing, future). Chunks that fail transiently
    /// (network/timeout, 5xx after retries) are reported in `failedChunks` so the caller
    /// can retry them or surface the gap — rather than silently returning a partial result.
    public func fetchCandles(
        instrument: String,
        side: OfferSide,
        period: CandlePeriod,
        fromMs: Int64,
        toMs: Int64,
        historyServerURL: String,
        pipValue: Double
    ) async throws -> BulkResult {
        guard fromMs < toMs else { return BulkResult(bars: [], failedChunks: []) }
        let base = historyServerURL.hasSuffix("/") ? String(historyServerURL.dropLast()) : historyServerURL
        let descriptors = try Self.chunkDescriptors(
            instrument: instrument, side: side, period: period, fromMs: fromMs, toMs: toMs
        )
        guard !descriptors.isEmpty else { return BulkResult(bars: [], failedChunks: []) }
        return try await fetchChunks(
            descriptors: descriptors, base: base, pipValue: pipValue, fromMs: fromMs, toMs: toMs
        )
    }

    /// Re-attempts a list of previously-failed chunks. Used by the session as a single
    /// inner retry pass before surfacing remaining failures via `missingWindows`. Same
    /// concurrency cap and per-chunk retry budget as the initial pass.
    public func retryChunks(
        _ failed: [ChunkDescriptor],
        historyServerURL: String,
        pipValue: Double
    ) async throws -> BulkResult {
        guard !failed.isEmpty else { return BulkResult(bars: [], failedChunks: []) }
        let base = historyServerURL.hasSuffix("/") ? String(historyServerURL.dropLast()) : historyServerURL
        return try await fetchChunks(
            descriptors: failed, base: base, pipValue: pipValue,
            fromMs: failed.map(\.chunkStartMs).min() ?? Int64.min,
            toMs: failed.map(\.chunkEndMs).max() ?? Int64.max
        )
    }

    private func fetchChunks(
        descriptors: [ChunkDescriptor], base: String, pipValue: Double,
        fromMs: Int64, toMs: Int64
    ) async throws -> BulkResult {
        // Download chunks with a bounded number of concurrent requests, preserving order.
        var perChunk = [ChunkOutcome](repeating: .bars([]), count: descriptors.count)
        try await withThrowingTaskGroup(of: (Int, ChunkOutcome).self) { group in
            var next = 0
            func schedule(_ i: Int) {
                let d = descriptors[i]
                let urlString = "\(base)/\(d.relativePath)"
                group.addTask {
                    let outcome = try await Self.fetchOne(
                        urlString: urlString, chunkStartMs: d.chunkStartMs,
                        pipValue: pipValue, session: urlSession
                    )
                    return (i, outcome)
                }
            }
            for _ in 0..<min(maxConcurrent, descriptors.count) { schedule(next); next += 1 }
            while let (idx, outcome) = try await group.next() {
                perChunk[idx] = outcome
                if next < descriptors.count { schedule(next); next += 1 }
            }
        }

        var bars: [CandleBar] = []
        var failedChunks: [ChunkDescriptor] = []
        for (i, outcome) in perChunk.enumerated() {
            switch outcome {
            case .bars(let chunkBars): bars.append(contentsOf: chunkBars)
            case .failed: failedChunks.append(descriptors[i])
            }
        }
        // Already in chunk order; clip to the window, ensure ascending.
        bars = bars
            .filter { $0.timeMillis >= fromMs && $0.timeMillis <= toMs }
            .sorted { $0.timeMillis < $1.timeMillis }
        return BulkResult(bars: bars, failedChunks: failedChunks)
    }

    /// Per-chunk result. `.bars([])` means "this chunk genuinely has no data" (404,
    /// empty response, weekend); `.failed` means "we couldn't determine — try again."
    private enum ChunkOutcome {
        case bars([CandleBar])
        case failed(String)
    }

    // MARK: - One chunk

    private static func fetchOne(
        urlString: String, chunkStartMs: Int64, pipValue: Double, session: URLSession,
        maxAttempts: Int = 3
    ) async throws -> ChunkOutcome {
        guard let url = URL(string: urlString) else { throw BulkError.badURL(urlString) }
        var attempt = 1
        while true {
            if Task.isCancelled { return .bars([]) }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                // Transient network error (usually a timeout during a cold-start grid
                // fetching many chunks at once). Retry a few times; if it still fails,
                // surface the chunk as `.failed` so the caller can refetch or flag the
                // gap — rather than silently dropping it.
                if attempt < maxAttempts, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(400 * attempt))
                    attempt += 1
                    continue
                }
                log.error("bulk chunk fetch error \(urlString, privacy: .public) after \(attempt) attempts: \(error.localizedDescription, privacy: .public)")
                return .failed("network: \(error.localizedDescription)")
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                guard !data.isEmpty else { return .bars([]) }   // empty = no data for this chunk
                let raw: Data
                do {
                    raw = try LZMA.decompress(data: data)
                } catch {
                    throw BulkError.decodeFailed("LZMA \(urlString): \(error)")
                }
                guard raw.count % 24 == 0 else {
                    throw BulkError.decodeFailed("\(urlString): \(raw.count) bytes not a multiple of 24")
                }
                return .bars(decodeCandles(raw, chunkStartMs: chunkStartMs, pipValue: pipValue))
            }
            // 5xx / 429 are transient (server busy under load) — retry, then surface as
            // .failed if we still can't get through. 404 / other non-200 mean the chunk
            // genuinely isn't there (weekend, before listing, future) — treat as no data.
            if (status >= 500 || status == 429) {
                if attempt < maxAttempts {
                    try? await Task.sleep(for: .milliseconds(400 * attempt))
                    attempt += 1
                    continue
                }
                log.error("bulk chunk \(urlString, privacy: .public) status=\(status) after \(attempt) attempts")
                return .failed("status \(status)")
            }
            return .bars([])
        }
    }

    /// Decodes v5 candle records (24 bytes, big-endian): int32 secOffset, int32 open,
    /// int32 close, int32 low, int32 high, float32 volume. `time = chunkStart + secOffset*1000`,
    /// `price = round(raw/10 * pipValue, 5dp)`.
    static func decodeCandles(_ data: Data, chunkStartMs: Int64, pipValue: Double) -> [CandleBar] {
        var reader = BinaryReader(data)
        let count = data.count / 24
        var bars: [CandleBar] = []
        bars.reserveCapacity(count)
        func price(_ raw: Int32) -> Double {
            Double(Int64(Double(raw) / 10.0 * pipValue * 100_000.0 + 0.5)) / 100_000.0
        }
        for _ in 0..<count {
            guard let secOffset = try? reader.readInt32BE(),
                  let open = try? reader.readInt32BE(),
                  let close = try? reader.readInt32BE(),
                  let low = try? reader.readInt32BE(),
                  let high = try? reader.readInt32BE(),
                  let volBits = try? reader.readInt32BE() else { break }
            bars.append(CandleBar(
                timeMillis: chunkStartMs + Int64(secOffset) * 1000,
                open: price(open), high: price(high), low: price(low), close: price(close),
                volume: Double(Float(bitPattern: UInt32(bitPattern: volBits)))
            ))
        }
        return bars
    }

    // MARK: - Chunk enumeration

    public struct ChunkDescriptor: Sendable, Equatable {
        public let relativePath: String
        public let chunkStartMs: Int64
        public let chunkEndMs: Int64

        public init(relativePath: String, chunkStartMs: Int64, chunkEndMs: Int64) {
            self.relativePath = relativePath
            self.chunkStartMs = chunkStartMs
            self.chunkEndMs = chunkEndMs
        }
    }

    private static let gmt = TimeZone(identifier: "GMT")!

    private static func calendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = gmt
        return c
    }

    /// Enumerates every chunk file covering `[fromMs, toMs]` for a basic period: daily
    /// files for 1m, monthly for 1H, yearly for Daily. `month` in the path is 0-based,
    /// zero-padded; instrument is slashless; side is uppercased (BID/ASK).
    static func chunkDescriptors(
        instrument: String, side: OfferSide, period: CandlePeriod, fromMs: Int64, toMs: Int64
    ) throws -> [ChunkDescriptor] {
        let instr = instrument.replacingOccurrences(of: "/", with: "").uppercased()
        let sideStr = side.rawValue.uppercased()   // "BID" / "ASK"
        let token: String
        let unit: Calendar.Component
        switch period.seconds {
        case 60:    token = "min_1";  unit = .day
        case 3600:  token = "hour_1"; unit = .month
        case 86400: token = "day_1";  unit = .year
        default:    throw BulkError.unsupportedPeriod(period.seconds)
        }

        let cal = calendar()
        let from = Date(timeIntervalSince1970: Double(fromMs) / 1000)
        let to = Date(timeIntervalSince1970: Double(toMs) / 1000)
        // Align to the start of the chunk that contains `from`.
        var cursor = cal.dateInterval(of: unit, for: from)?.start ?? from
        let endChunkStart = cal.dateInterval(of: unit, for: to)?.start ?? to

        var out: [ChunkDescriptor] = []
        while cursor <= endChunkStart {
            let comps = cal.dateComponents([.year, .month, .day], from: cursor)
            let year = comps.year ?? 0
            let mm0 = String(format: "%02d", (comps.month ?? 1) - 1)   // 0-based
            let dd = String(format: "%02d", comps.day ?? 1)
            let path: String
            switch unit {
            case .day:   path = "\(instr)/\(year)/\(mm0)/\(dd)/\(sideStr)_candles_\(token).bi5"
            case .month: path = "\(instr)/\(year)/\(mm0)/\(sideStr)_candles_\(token).bi5"
            default:     path = "\(instr)/\(year)/\(sideStr)_candles_\(token).bi5"
            }
            guard let advanced = cal.date(byAdding: unit, value: 1, to: cursor) else { break }
            out.append(ChunkDescriptor(
                relativePath: path,
                chunkStartMs: Int64(cursor.timeIntervalSince1970 * 1000),
                chunkEndMs: Int64(advanced.timeIntervalSince1970 * 1000)
            ))
            cursor = advanced
        }
        return out
    }
}
