import Foundation

public enum CodecError: Error, CustomStringConvertible {
    case truncated(needed: Int, available: Int)
    case invalidVarLen(firstByte: UInt8)
    case invalidString
    case unexpectedClassId(Int32)
    case negativeLength(Int)

    public var description: String {
        switch self {
        case .truncated(let n, let a): "codec: needed \(n) bytes, have \(a)"
        case .invalidVarLen(let b): String(format: "codec: invalid var-length first byte 0x%02x", b)
        case .invalidString: "codec: invalid UTF-8 string"
        case .unexpectedClassId(let id): "codec: unexpected classId \(id)"
        case .negativeLength(let n): "codec: negative field/byte length \(n)"
        }
    }
}

/// Mutable big-endian byte writer.
public struct BinaryWriter {
    public private(set) var data: Data

    public init(capacity: Int = 64) {
        var d = Data()
        d.reserveCapacity(capacity)
        self.data = d
    }

    public mutating func writeByte(_ b: UInt8) {
        data.append(b)
    }

    public mutating func writeBytes(_ bytes: Data) {
        data.append(bytes)
    }

    public mutating func writeInt16BE(_ v: Int16) {
        let u = UInt16(bitPattern: v)
        data.append(UInt8(u >> 8))
        data.append(UInt8(u & 0xFF))
    }

    public mutating func writeInt32BE(_ v: Int32) {
        data.appendInt32BE(v)
    }

    public mutating func writeInt64BE(_ v: Int64) {
        let u = UInt64(bitPattern: v)
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((u >> shift) & 0xFF))
        }
    }

    public mutating func writeBoolean(_ b: Bool) {
        data.append(b ? 1 : 0)
    }

    /// Variable-length count as used by the binary protocol (v >= 2).
    public mutating func writeVarLen(_ length: Int) {
        precondition(length >= 0 && length <= 0x3FFF_FFFF)
        if length <= 63 {
            data.append(UInt8(0xC0 | length))
        } else if length <= 16383 {
            data.append(UInt8(0x80 | (length >> 8)))
            data.append(UInt8(length & 0xFF))
        } else if length <= 0x3F_FFFF {
            data.append(UInt8(0x40 | (length >> 16)))
            data.append(UInt8((length >> 8) & 0xFF))
            data.append(UInt8(length & 0xFF))
        } else {
            data.append(UInt8((length >> 24) & 0xFF))
            data.append(UInt8((length >> 16) & 0xFF))
            data.append(UInt8((length >> 8) & 0xFF))
            data.append(UInt8(length & 0xFF))
        }
    }

    /// String = var-length byte count + UTF-8 bytes.
    public mutating func writeString(_ s: String) {
        let bytes = Data(s.utf8)
        writeVarLen(bytes.count)
        data.append(bytes)
    }

    /// BigDecimal in the DDS tagged format (see `BigDecimalCodec.encode`).
    public mutating func writeBigDecimal(_ value: BigDecimalValue) {
        BigDecimalCodec.encode(value, into: &self)
    }
}

/// Cursor-style big-endian reader.
public struct BinaryReader {
    public let data: Data
    public private(set) var offset: Int

    public init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    public var remaining: Int { data.count - offset }

    private mutating func require(_ n: Int) throws {
        // Lengths come off the wire as SIGNED Int32 (field lengths, BigDecimal byte
        // counts, …). A negative n passes the bounds check below (`offset + n` only
        // shrinks) and then traps in `readBytes` building a backwards Range — a fatal
        // crash on one malformed frame. Throw instead so the read loop's per-message
        // decode failure handling skips the frame like every other corruption.
        if n < 0 {
            throw CodecError.negativeLength(n)
        }
        if offset + n > data.count {
            throw CodecError.truncated(needed: n, available: remaining)
        }
    }

    public mutating func readByte() throws -> UInt8 {
        try require(1)
        let b = data[data.startIndex + offset]
        offset += 1
        return b
    }

    public mutating func readBytes(_ n: Int) throws -> Data {
        try require(n)
        let start = data.startIndex + offset
        let chunk = data.subdata(in: start..<(start + n))
        offset += n
        return chunk
    }

    public mutating func readInt16BE() throws -> Int16 {
        try require(2)
        let i = data.startIndex + offset
        let u = (UInt16(data[i]) << 8) | UInt16(data[i + 1])
        offset += 2
        return Int16(bitPattern: u)
    }

    public mutating func readInt32BE() throws -> Int32 {
        try require(4)
        let v = data.readInt32BE(at: offset)
        offset += 4
        return v
    }

    public mutating func readInt64BE() throws -> Int64 {
        try require(8)
        let i = data.startIndex + offset
        var u: UInt64 = 0
        for k in 0..<8 {
            u = (u << 8) | UInt64(data[i + k])
        }
        offset += 8
        return Int64(bitPattern: u)
    }

    public mutating func readBoolean() throws -> Bool {
        try readByte() != 0
    }

    public mutating func readVarLen() throws -> Int {
        let first = try readByte()
        if (first & 0xC0) == 0xC0 {
            return Int(first & 0x3F)
        } else if (first & 0x80) == 0x80 {
            let second = try readByte()
            return (Int(first & 0x3F) << 8) | Int(second)
        } else if (first & 0x40) == 0x40 {
            let b1 = try readByte()
            let b2 = try readByte()
            return (Int(first & 0x3F) << 16) | (Int(b1) << 8) | Int(b2)
        } else {
            let b1 = try readByte()
            let b2 = try readByte()
            let b3 = try readByte()
            return (Int(first & 0x3F) << 24) | (Int(b1) << 16) | (Int(b2) << 8) | Int(b3)
        }
    }

    public mutating func readString() throws -> String {
        let n = try readVarLen()
        let bytes = try readBytes(n)
        guard let s = String(data: bytes, encoding: .utf8) else {
            throw CodecError.invalidString
        }
        return s
    }
}

// MARK: - Java String.hashCode

/// Java's `String.hashCode()` on the UTF-16 code units of the string. Used to
/// derive the wire class ID from a fully qualified class name.
public func javaStringHashCode(_ s: String) -> Int32 {
    var h: Int32 = 0
    for unit in s.utf16 {
        h = h &* 31 &+ Int32(unit)
    }
    return h
}

// MARK: - Message framing

/// Writes a field record: `int16 fieldId + int32 valueLen + value bytes`.
/// Skips entirely if the encoder returns no bytes (caller handles null/empty).
public func writeField(
    _ writer: inout BinaryWriter,
    fieldId: Int16,
    encode: (inout BinaryWriter) -> Void
) {
    var sub = BinaryWriter()
    encode(&sub)
    writer.writeInt16BE(fieldId)
    writer.writeInt32BE(Int32(sub.data.count))
    writer.writeBytes(sub.data)
}

public struct FieldRecord {
    public let fieldId: Int16
    public let value: BinaryReader

    public init(fieldId: Int16, value: BinaryReader) {
        self.fieldId = fieldId
        self.value = value
    }
}

/// Reads the next field record (`int16 fieldId + int32 valueLen + bytes`) or
/// returns `nil` if the message body is exhausted.
public func readField(from reader: inout BinaryReader) throws -> FieldRecord? {
    if reader.remaining == 0 { return nil }
    let fieldId = try reader.readInt16BE()
    let len = try reader.readInt32BE()
    let bytes = try reader.readBytes(Int(len))
    return FieldRecord(fieldId: fieldId, value: BinaryReader(bytes))
}
