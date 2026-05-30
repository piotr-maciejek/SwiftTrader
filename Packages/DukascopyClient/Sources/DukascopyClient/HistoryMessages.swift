import Compression
import Foundation

public extension WireClass {
    static let candleSubscribe = "com.dukascopy.dds3.transport.msg.dfs.CandleSubscribeRequestMessage"
    static let candleHistoryGroup = "com.dukascopy.dds3.transport.msg.dfs.CandleHistoryGroupMessage"
}

public enum OfferSide: String, Sendable {
    case bid = "Bid"
    case ask = "Ask"
}

public struct CandlePeriod: Sendable, Equatable {
    public let seconds: Int64
    public static let oneMinute    = CandlePeriod(seconds: 60)
    public static let fiveMinutes  = CandlePeriod(seconds: 300)
    public static let fifteenMinutes = CandlePeriod(seconds: 900)
    public static let thirtyMinutes = CandlePeriod(seconds: 1800)
    public static let oneHour      = CandlePeriod(seconds: 3600)
    public static let fourHours    = CandlePeriod(seconds: 14400)
    public static let oneDay       = CandlePeriod(seconds: 86400)
    public static let oneWeek      = CandlePeriod(seconds: 604800)

    public static func parse(_ name: String) -> CandlePeriod? {
        switch name.uppercased() {
        case "ONE_MIN", "1M":       return .oneMinute
        case "FIVE_MINS", "5M":     return .fiveMinutes
        case "FIFTEEN_MINS", "15M": return .fifteenMinutes
        case "THIRTY_MINS", "30M":  return .thirtyMinutes
        case "ONE_HOUR", "1H":      return .oneHour
        case "FOUR_HOURS", "4H":    return .fourHours
        case "DAILY", "1D":         return .oneDay
        case "WEEKLY", "1W":        return .oneWeek
        default: return nil
        }
    }
}

public struct CandleBar: Sendable {
    public let timeMillis: Int64
    public let open: Double
    public let high: Double
    public let low: Double
    public let close: Double
    public let volume: Double

    public init(timeMillis: Int64, open: Double, high: Double, low: Double, close: Double, volume: Double) {
        self.timeMillis = timeMillis
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
    }
}

/// Half-open epoch-ms window `[fromMs, toMs)`. Used to describe a bulk-history chunk
/// that could not be downloaded after all retries, so the caller can decide whether
/// to accept the partial result, refetch later, or flag the cache as incomplete.
public struct HistoryWindow: Sendable, Equatable {
    public let fromMs: Int64
    public let toMs: Int64

    public init(fromMs: Int64, toMs: Int64) {
        self.fromMs = fromMs
        self.toMs = toMs
    }
}

/// Result of a `DukascopySession.fetchHistory` call. `bars` is what we got;
/// `missingWindows` is non-empty when bulk chunks failed transiently and couldn't be
/// recovered — the caller should treat `bars` as partial and schedule a refetch for
/// those windows rather than caching the response as complete.
public struct HistoryResult: Sendable {
    public let bars: [CandleBar]
    public let missingWindows: [HistoryWindow]

    public init(bars: [CandleBar], missingWindows: [HistoryWindow] = []) {
        self.bars = bars
        self.missingWindows = missingWindows
    }

    public var isComplete: Bool { missingWindows.isEmpty }
}

// MARK: - Request

public struct CandleSubscribeRequest: Sendable {
    public var instrument: String        // e.g. "*EURUSD_Bid"
    public var startTimeSeconds: Int64
    public var endTimeSeconds: Int64
    public var periodSeconds: Int64
    public var lastCandleRequest: Bool = false
    public var volumesInDouble: Bool = true
    public var silenceOnDataNotInCacheError: Bool = false
    public var userName: String?
    public var sessionId: String?
    public var requestId: String?
    public var timestamp: Int64?

    public init(
        instrument: String, side: OfferSide,
        period: CandlePeriod,
        startTimeSeconds: Int64, endTimeSeconds: Int64
    ) {
        // Wire form for candles: leading "*" + instrument as-is (slashed) + "_Bid"/"_Ask".
        self.instrument = "*\(instrument)_\(side.rawValue)"
        self.periodSeconds = period.seconds
        self.startTimeSeconds = startTimeSeconds
        self.endTimeSeconds = endTimeSeconds
    }

    /// "In-progress candles" form — matches `CurvesJsonProtocolHandler.loadDataFromDFS`
    /// (decompiled SDK) when called with `inProgress=true`. Server returns the live
    /// in-progress candle for every supported period in one positional response.
    /// `untilMillis` IS in MILLIS, not seconds (the SDK passes `System.currentTimeMillis()`).
    public static func inProgress(
        instrument: String, side: OfferSide, untilMillis: Int64
    ) -> CandleSubscribeRequest {
        var r = CandleSubscribeRequest(
            instrument: instrument, side: side, period: .oneMinute,
            startTimeSeconds: 0, endTimeSeconds: untilMillis
        )
        r.lastCandleRequest = true
        return r
    }

    public func encode() -> Data {
        var w = BinaryWriter()
        w.writeInt32BE(javaStringHashCode(WireClass.candleSubscribe))
        writeField(&w, fieldId: 12424) { sub in sub.writeString(instrument) }
        writeField(&w, fieldId: -28971) { sub in sub.writeInt64BE(startTimeSeconds) }
        writeField(&w, fieldId: 26733)  { sub in sub.writeInt64BE(endTimeSeconds) }
        writeField(&w, fieldId: -3783)  { sub in sub.writeInt64BE(periodSeconds) }
        writeField(&w, fieldId: -23305) { sub in sub.writeBoolean(lastCandleRequest) }
        writeField(&w, fieldId: -3181)  { sub in sub.writeBoolean(volumesInDouble) }
        writeField(&w, fieldId: 25587)  { sub in sub.writeBoolean(silenceOnDataNotInCacheError) }
        if let userName  { writeField(&w, fieldId: 14530) { sub in sub.writeString(userName) } }
        if let sessionId { writeField(&w, fieldId: 28132) { sub in sub.writeString(sessionId) } }
        if let requestId { writeField(&w, fieldId: 17261) { sub in sub.writeString(requestId) } }
        if let timestamp { writeField(&w, fieldId: -28332) { sub in sub.writeInt64BE(timestamp) } }
        return w.data
    }
}

// MARK: - Response

public struct CandleHistoryGroup: Sendable {
    public var periodSeconds: Int64?
    public var candles: String?
    public var historyFinished: Bool?
    public var messageOrder: Int32?
    public var instrument: String?
    public var requestId: String?

    public init() {}

    public static func decode(from reader: inout BinaryReader) throws -> CandleHistoryGroup {
        var msg = CandleHistoryGroup()
        while let field = try readField(from: &reader) {
            var v = field.value
            switch field.fieldId {
            case -3783:  msg.periodSeconds = try v.readInt64BE()
            case -3845:  msg.candles = try v.readString()
            case -28247:
                // historyFinished is Boolean (wrapper) — value is just 1 byte.
                msg.historyFinished = try v.readBoolean()
            case -18886: msg.messageOrder = try v.readInt32BE()
            case 12424:  msg.instrument = try v.readString()
            case 17261:  msg.requestId = try v.readString()
            default: break
            }
        }
        return msg
    }
}

// MARK: - Streaming reassembly

public enum HistoryDecodeError: Error, CustomStringConvertible {
    case invalidBase64
    case zipHeaderMissing
    case zipDecompressFailed
    case malformedRecord(String)

    public var description: String {
        switch self {
        case .invalidBase64: "history: candles string is not valid Base64"
        case .zipHeaderMissing: "history: ZIP local file header signature not found"
        case .zipDecompressFailed: "history: ZIP decompression failed"
        case .malformedRecord(let s): "history: malformed CSV record \"\(s)\""
        }
    }
}

public enum HistoryDecoder {
    /// Decodes the `candles` string of a single CandleHistoryGroup into bars.
    /// Pipeline: Base64 → ZIP local-file-header → DEFLATE inflate → CSV split.
    public static func decodeCandles(_ encoded: String) throws -> [CandleBar] {
        // Strict mode first; fall back to ignoring whitespace / URL-safe variants.
        let zipped: Data
        if let d = Data(base64Encoded: encoded) {
            zipped = d
        } else if let d = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) {
            zipped = d
        } else {
            // URL-safe Base64 (replace _ → /, - → +) with padding restoration.
            var s = encoded
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            while s.count % 4 != 0 { s.append("=") }
            guard let d = Data(base64Encoded: s, options: .ignoreUnknownCharacters) else {
                throw HistoryDecodeError.invalidBase64
            }
            zipped = d
        }
        let csvBytes = try unzipSingleEntry(zipped)
        guard let csv = String(data: csvBytes, encoding: .utf8) else {
            throw HistoryDecodeError.malformedRecord("non-UTF8 ZIP entry")
        }
        return try parseCandleCSV(csv)
    }

    private static func parseCandleCSV(_ csv: String) throws -> [CandleBar] {
        var out: [CandleBar] = []
        for record in csv.split(separator: ";", omittingEmptySubsequences: true) {
            // Candle records: time,vol,low,high,open,close — time in SECONDS.
            let fields = record.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 6,
                  let timeSec = Int64(fields[0]),
                  let vol  = Double(fields[1]),
                  let low  = Double(fields[2]),
                  let high = Double(fields[3]),
                  let open = Double(fields[4]),
                  let close = Double(fields[5]) else {
                throw HistoryDecodeError.malformedRecord(String(record))
            }
            out.append(CandleBar(
                timeMillis: timeSec * 1000,
                open: open, high: high, low: low, close: close, volume: vol
            ))
        }
        return out
    }

    /// Extracts the first entry of a ZIP archive. Supports stored (no compression)
    /// and deflate compression methods — the latter via `Compression.zlib`.
    private static func unzipSingleEntry(_ data: Data) throws -> Data {
        var reader = BinaryReader(data)
        let signature = try reader.readUInt32LE()
        // Local file header signature = 0x04034b50.
        guard signature == 0x04034b50 else {
            throw HistoryDecodeError.zipHeaderMissing
        }
        _ = try reader.readUInt16LE()  // version
        let flags = try reader.readUInt16LE()
        let method = try reader.readUInt16LE()
        _ = try reader.readUInt16LE()  // mod time
        _ = try reader.readUInt16LE()  // mod date
        _ = try reader.readUInt32LE()  // crc32
        var compressedSize = Int(try reader.readUInt32LE())
        let uncompressedSize = Int(try reader.readUInt32LE())
        let fileNameLen = Int(try reader.readUInt16LE())
        let extraLen = Int(try reader.readUInt16LE())
        _ = try reader.readBytes(fileNameLen)
        _ = try reader.readBytes(extraLen)

        // Bit 3 (0x08) of the general-purpose flag means the sizes in the local
        // header are zero and the actual sizes follow the data as a "data
        // descriptor". Treat everything after the header (up to a trailing data
        // descriptor or the central-directory signature) as the compressed payload.
        if compressedSize == 0 && (flags & 0x08) != 0 {
            compressedSize = data.count - reader.offset
            // Trim the data descriptor (12 or 16 bytes ending before the central
            // directory signature 0x02014b50) if present.
            let signatureDD: UInt32 = 0x08074b50
            let signatureCD: UInt32 = 0x02014b50
            if compressedSize >= 16 {
                // Search backwards for a data-descriptor signature.
                for offset in stride(from: data.count - 12, through: reader.offset, by: -1) {
                    var probe = BinaryReader(data, offset: offset)
                    if let sig = try? probe.readUInt32LE(), sig == signatureDD || sig == signatureCD {
                        compressedSize = offset - reader.offset
                        break
                    }
                }
            }
        }
        let payload = try reader.readBytes(compressedSize)

        if method == 0 {
            return payload
        }
        if method == 8 {
            let target = max(uncompressedSize, payload.count * 4, 64 * 1024)
            return try inflateDeflate(payload, expectedSize: target)
        }
        throw HistoryDecodeError.zipDecompressFailed
    }

    private static func inflateDeflate(_ input: Data, expectedSize: Int) throws -> Data {
        let bufferSize = max(expectedSize, 64 * 1024)
        return try input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data in
            let srcPtr = src.bindMemory(to: UInt8.self).baseAddress!
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { dst.deallocate() }
            let written = compression_decode_buffer(
                dst, bufferSize, srcPtr, input.count, nil, COMPRESSION_ZLIB
            )
            guard written > 0 else { throw HistoryDecodeError.zipDecompressFailed }
            return Data(bytes: dst, count: written)
        }
    }
}

// MARK: - Little-endian helpers

extension BinaryReader {
    mutating func readUInt16LE() throws -> UInt16 {
        let lo = UInt16(try readByte())
        let hi = UInt16(try readByte())
        return (hi << 8) | lo
    }
    mutating func readUInt32LE() throws -> UInt32 {
        let b0 = UInt32(try readByte())
        let b1 = UInt32(try readByte())
        let b2 = UInt32(try readByte())
        let b3 = UInt32(try readByte())
        return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
    }
}
