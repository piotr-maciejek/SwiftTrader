import Foundation
import SWCompression

public extension WireClass {
    static let positionDataRequest    = "com.dukascopy.dds3.transport.msg.dfs.PositionDataRequestMessage"
    static let positionBinaryResponse = "com.dukascopy.dds3.transport.msg.dfs.PositionBinaryResponseMessage"
}

// MARK: - Request

/// Encodes a `dfs.PositionDataRequestMessage` asking the server for the account's
/// position history in `[startMillis, endMillis]`. `getClosed == true` selects closed
/// positions (the trade history); `false` would select open ones. The response comes
/// back as one or more chunked `PositionBinaryResponse` frames correlated by `requestId`.
///
/// Times are epoch milliseconds (the wire field is a Java `Long`), matching how
/// `PositionData.openDate`/`closeDate` are carried.
public func encodePositionDataRequest(
    startMillis: Int64,
    endMillis: Int64,
    getClosed: Bool,
    userName: String?,
    sessionId: String?,
    userId: String?,
    accountLoginId: String?,
    requestId: String,
    timestamp: Int64
) -> Data {
    var w = BinaryWriter()
    w.writeInt32BE(javaStringHashCode(WireClass.positionDataRequest))
    writeField(&w, fieldId: -28971) { sub in sub.writeInt64BE(startMillis) }
    writeField(&w, fieldId: 26733)  { sub in sub.writeInt64BE(endMillis) }
    writeField(&w, fieldId: 21067)  { sub in sub.writeBoolean(getClosed) }
    if let userName       { writeField(&w, fieldId: 14530)  { sub in sub.writeString(userName) } }
    if let sessionId      { writeField(&w, fieldId: 28132)  { sub in sub.writeString(sessionId) } }
    if let userId         { writeField(&w, fieldId: -31160) { sub in sub.writeString(userId) } }
    if let accountLoginId { writeField(&w, fieldId: 9208)   { sub in sub.writeString(accountLoginId) } }
    writeField(&w, fieldId: 17261)  { sub in sub.writeString(requestId) }
    writeField(&w, fieldId: -28332) { sub in sub.writeInt64BE(timestamp) }
    return w.data
}

// MARK: - Response

/// One chunk of a `dfs.PositionBinaryResponseMessage`. The full history arrives as
/// `messageOrder`-ordered chunks terminated by `finished == true`. `positionsEncoded` is the
/// gzip blob decoded by `PositionDataBitsDecoder` once all chunks land. See PROTOCOL.md §15.2.
public struct PositionBinaryResponse: Sendable {
    public var positionsEncoded: Data?
    public var messageOrder: Int32?
    public var finished: Bool?
    public var requestId: String?

    public init() {}

    public static func decode(from reader: inout BinaryReader) throws -> PositionBinaryResponse {
        var msg = PositionBinaryResponse()
        while let field = try readField(from: &reader) {
            var v = field.value
            switch field.fieldId {
            case -22668:
                // byte[] field: a var-length count then the raw bytes (same scheme as a
                // String, minus the UTF-8 decode) — NOT the whole field value, which would
                // include the 2-byte length prefix and corrupt the GZIP stream.
                let n = try v.readVarLen()
                msg.positionsEncoded = try v.readBytes(n)
            case -18886: msg.messageOrder = try v.readInt32BE()
            case -28801: msg.finished = try v.readBoolean()
            case 17261:  msg.requestId = try v.readString()
            default: break
            }
        }
        return msg
    }
}

// MARK: - Decoded position

/// One closed trade, decoded from the `PositionData` Bits blob. `BigDecimal` money fields
/// become `Double`; epoch-ms dates become `Int64?` (the `Long.MIN_VALUE` sentinel → nil).
/// `currentPrice` is typically nil for a closed position (the server only fills it for open
/// ones), so it's optional like the rest.
public struct ClosedPosition: Sendable, Equatable {
    public var positionId: String
    /// `true` for a LONG (buy) position, `false` for SHORT (sell).
    public var isLong: Bool
    /// `true` if this is a MERGED position (combined fills), `false` for a REGULAR one.
    public var isMerged: Bool
    public var instrument: String
    public var amount: Double?
    public var openPrice: Double?
    public var currentPrice: Double?
    public var closePrice: Double?
    public var profitLoss: Double?
    public var swaps: Double?
    public var grossProfitLoss: Double?
    public var commission: Double?
    public var commissionCurrency: String?
    public var openDateMillis: Int64?
    public var closeDateMillis: Int64?

    public init(
        positionId: String, isLong: Bool, isMerged: Bool, instrument: String,
        amount: Double?, openPrice: Double?, currentPrice: Double?, closePrice: Double?,
        profitLoss: Double?, swaps: Double?, grossProfitLoss: Double?, commission: Double?,
        commissionCurrency: String?, openDateMillis: Int64?, closeDateMillis: Int64?
    ) {
        self.positionId = positionId
        self.isLong = isLong
        self.isMerged = isMerged
        self.instrument = instrument
        self.amount = amount
        self.openPrice = openPrice
        self.currentPrice = currentPrice
        self.closePrice = closePrice
        self.profitLoss = profitLoss
        self.swaps = swaps
        self.grossProfitLoss = grossProfitLoss
        self.commission = commission
        self.commissionCurrency = commissionCurrency
        self.openDateMillis = openDateMillis
        self.closeDateMillis = closeDateMillis
    }
}

// MARK: - Bits blob decode

public enum PositionDecodeError: Error, CustomStringConvertible {
    case gunzipFailed(String)
    case badHeader(String)

    public var description: String {
        switch self {
        case .gunzipFailed(let s): "closed positions: gunzip failed — \(s)"
        case .badHeader(let s): "closed positions: \(s)"
        }
    }
}

/// Decodes the `positionsEncoded` blob — `GZIP(Bits.writeObject(List<PositionData>))` — into
/// `[ClosedPosition]`. The `Bits` object serializer differs from the DDS field codec: every
/// object has a `01`/`00` null marker, strings/collections use a 4-byte int length, enums are
/// 4-byte ordinals, BigDecimals are strings, and primitive `long` dates are raw 8 bytes with no
/// marker. Each element is headed by `"PD"` + a version byte. See PROTOCOL.md §15.3.
public enum PositionDataBitsDecoder {
    /// Java `Long.MIN_VALUE`, the "no date" sentinel.
    private static let longMin: Int64 = Int64.min

    public static func decodeList(_ gzipped: Data) throws -> [ClosedPosition] {
        let raw: Data
        do {
            raw = try GzipArchive.unarchive(archive: gzipped)
        } catch {
            throw PositionDecodeError.gunzipFailed(String(describing: error))
        }
        var r = BinaryReader(raw)

        // List<PositionData>: null marker, then a 4-byte element count.
        let listMarker = try r.readByte()
        if listMarker == 0 { return [] }
        let count = try r.readInt32BE()
        guard count >= 0 else { throw PositionDecodeError.badHeader("negative list count \(count)") }

        var out: [ClosedPosition] = []
        // Wire-controlled count: clamp the upfront allocation to what the payload could
        // hold (each element costs ≥ 1 byte) — a hostile count then fails on the first
        // truncated element instead of allocating gigabytes here.
        out.reserveCapacity(min(Int(count), r.remaining))
        for _ in 0..<count {
            let elemMarker = try r.readByte()
            if elemMarker == 0 { continue }   // a null element — skip
            try out.append(decodePosition(&r))
        }
        return out
    }

    private static func decodePosition(_ r: inout BinaryReader) throws -> ClosedPosition {
        // "PD" header + version byte.
        let h0 = try r.readByte(), h1 = try r.readByte()
        guard h0 == 0x50, h1 == 0x44 else {
            throw PositionDecodeError.badHeader(String(format: "expected \"PD\", got %02x %02x", h0, h1))
        }
        _ = try r.readByte()  // version (== 1)

        let positionTypeOrdinal = try readEnumOrdinal(&r)
        let positionId = try readBitsString(&r) ?? ""
        let sideOrdinal = try readEnumOrdinal(&r)
        let instrument = try readBitsString(&r) ?? ""
        let amount = try readBitsDecimal(&r)
        let openPrice = try readBitsDecimal(&r)
        let currentPrice = try readBitsDecimal(&r)
        let closePrice = try readBitsDecimal(&r)
        let profitLoss = try readBitsDecimal(&r)
        let swaps = try readBitsDecimal(&r)
        let grossProfitLoss = try readBitsDecimal(&r)
        let commission = try readBitsDecimal(&r)
        let commissionCurrency = try readBitsString(&r)
        let openDate = try readBitsLong(&r)
        let closeDate = try readBitsLong(&r)

        return ClosedPosition(
            positionId: positionId,
            isLong: sideOrdinal == 0,        // PositionSide: LONG=0, SHORT=1
            isMerged: positionTypeOrdinal == 1,  // PositionType: REGULAR=0, MERGED=1
            instrument: instrument,
            amount: amount, openPrice: openPrice, currentPrice: currentPrice,
            closePrice: closePrice, profitLoss: profitLoss, swaps: swaps,
            grossProfitLoss: grossProfitLoss, commission: commission,
            commissionCurrency: commissionCurrency,
            openDateMillis: openDate, closeDateMillis: closeDate
        )
    }

    /// Enum: null marker, then a 4-byte ordinal. Returns -1 for a null enum.
    private static func readEnumOrdinal(_ r: inout BinaryReader) throws -> Int32 {
        if try r.readByte() == 0 { return -1 }
        return try r.readInt32BE()
    }

    /// String: null marker, then a 4-byte length + UTF-8 bytes. nil if the marker is null.
    private static func readBitsString(_ r: inout BinaryReader) throws -> String? {
        if try r.readByte() == 0 { return nil }
        let len = try r.readInt32BE()
        let bytes = try r.readBytes(Int(len))
        return String(data: bytes, encoding: .utf8)
    }

    /// BigDecimal: serialized as its `toString()` (a Bits string) → parsed to Double.
    private static func readBitsDecimal(_ r: inout BinaryReader) throws -> Double? {
        guard let s = try readBitsString(&r) else { return nil }
        return Double(s)
    }

    /// Primitive `long`: raw 8 big-endian bytes, no marker. `Long.MIN_VALUE` → nil.
    private static func readBitsLong(_ r: inout BinaryReader) throws -> Int64? {
        let v = try r.readInt64BE()
        return v == longMin ? nil : v
    }
}
