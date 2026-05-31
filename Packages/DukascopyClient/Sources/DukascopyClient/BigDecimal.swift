import BigInt
import Foundation

/// Decoded big-decimal value. The price feed only ever sends a fixed-precision
/// decimal, so we store the unscaled mantissa plus the negative power of ten.
public struct BigDecimalValue: Sendable, Equatable, CustomStringConvertible {
    public let unscaled: BigInt
    public let scale: Int

    public init(unscaled: BigInt, scale: Int) {
        self.unscaled = unscaled
        self.scale = scale
    }

    public static let zero = BigDecimalValue(unscaled: 0, scale: 0)

    /// Build from a `Double` at a fixed decimal `scale` — `unscaled = round(value · 10^scale)`.
    /// Used to encode order amounts/prices (e.g. price 1.23456 at scale 5 → unscaled 123456).
    public init(_ value: Double, scale: Int) {
        let factor = pow(10.0, Double(scale))
        let scaled = (value * factor).rounded()
        self.init(unscaled: BigInt(scaled), scale: scale)
    }

    public var doubleValue: Double {
        let raw = Double(unscaled.description) ?? 0
        if scale == 0 { return raw }
        return raw / pow(10, Double(scale))
    }

    public var description: String {
        if unscaled == 0 { return "0" }
        let s = String(unscaled.magnitude, radix: 10)
        let neg = unscaled.sign == .minus ? "-" : ""
        if scale <= 0 {
            return neg + s + String(repeating: "0", count: -scale)
        }
        if s.count > scale {
            let split = s.index(s.endIndex, offsetBy: -scale)
            return neg + s[..<split] + "." + s[split...]
        }
        let pad = String(repeating: "0", count: scale - s.count)
        return neg + "0." + pad + s
    }
}

public enum BigDecimalCodec {
    public static func decode(from reader: inout BinaryReader) throws -> BigDecimalValue {
        let b = Int(try reader.readByte())
        let kind = b & 7
        switch kind {
        case 0:
            return .zero
        case 1:
            let len = b >> 3
            let data = try reader.readBytes(len)
            return BigDecimalValue(unscaled: signedBigInt(from: data), scale: 0)
        case 2:
            let scale = b >> 5
            let len = (b >> 3) & 3
            let data = try reader.readBytes(len)
            return BigDecimalValue(unscaled: signedBigInt(from: data), scale: scale)
        case 3:
            let scale = -(b >> 5)
            let len = (b >> 3) & 3
            let data = try reader.readBytes(len)
            return BigDecimalValue(unscaled: signedBigInt(from: data), scale: scale)
        case 4:
            let scale = Int(try reader.readByte())
            let len = Int(try reader.readByte())
            let data = try reader.readBytes(len)
            return BigDecimalValue(unscaled: signedBigInt(from: data), scale: scale)
        case 5:
            let scale = -Int(try reader.readByte())
            let len = Int(try reader.readByte())
            let data = try reader.readBytes(len)
            return BigDecimalValue(unscaled: signedBigInt(from: data), scale: scale)
        case 6:
            let scale = Int(try reader.readInt16BE())
            let lenHi = UInt16(try reader.readByte())
            let lenLo = UInt16(try reader.readByte())
            let len = Int((lenHi << 8) | lenLo)
            let data = try reader.readBytes(len)
            return BigDecimalValue(unscaled: signedBigInt(from: data), scale: scale)
        case 7:
            let scale = Int(try reader.readInt32BE())
            let len = Int(try reader.readInt32BE())
            let data = try reader.readBytes(len)
            return BigDecimalValue(unscaled: signedBigInt(from: data), scale: scale)
        default:
            return .zero
        }
    }

    /// Encodes a `BigDecimalValue` in the DDS tagged format (inverse of `decode`).
    /// Emits kind 4 (non-negative scale ≤ 255), kind 5 (negative scale ≥ -255), or
    /// kind 7 (int32 scale + length) — all forms the server's decoder accepts. FX
    /// amounts/prices always fall in the kind-4 range.
    public static func encode(_ value: BigDecimalValue, into w: inout BinaryWriter) {
        if value.unscaled == 0 {
            w.writeByte(0)   // kind 0 = zero
            return
        }
        let bytes = twosComplementBE(value.unscaled)
        let len = bytes.count
        let scale = value.scale
        if scale >= 0 && scale <= 0xFF && len <= 0xFF {
            w.writeByte(4)
            w.writeByte(UInt8(scale))
            w.writeByte(UInt8(len))
            w.writeBytes(bytes)
        } else if scale < 0 && -scale <= 0xFF && len <= 0xFF {
            w.writeByte(5)
            w.writeByte(UInt8(-scale))
            w.writeByte(UInt8(len))
            w.writeBytes(bytes)
        } else {
            w.writeByte(7)
            w.writeInt32BE(Int32(scale))
            w.writeInt32BE(Int32(len))
            w.writeBytes(bytes)
        }
    }

    /// Minimal-length two's-complement big-endian bytes for a non-zero `BigInt`
    /// (inverse of `signedBigInt`). Positive values get a leading 0x00 when their
    /// top bit would otherwise read as negative.
    static func twosComplementBE(_ value: BigInt) -> Data {
        if value > 0 {
            var bytes = [UInt8](value.magnitude.serialize())
            if bytes.isEmpty { bytes = [0] }
            if (bytes[0] & 0x80) != 0 { bytes.insert(0, at: 0) }
            return Data(bytes)
        }
        // value < 0 (zero is handled by the caller).
        let mag = value.magnitude
        var n = max(1, (mag.bitWidth + 7) / 8)
        while true {
            let modulus = BigUInt(1) << (8 * n)
            let tc = modulus - mag                 // 2^(8n) − |value|
            let signBit = BigUInt(1) << (8 * n - 1)
            if tc >= signBit {                     // top bit set → reads as negative
                var bytes = [UInt8](tc.serialize())
                while bytes.count < n { bytes.insert(0, at: 0) }
                return Data(bytes)
            }
            n += 1
        }
    }

    /// Two's-complement big-endian bytes → signed BigInt.
    private static func signedBigInt(from data: Data) -> BigInt {
        if data.isEmpty { return 0 }
        let isNegative = (data[data.startIndex] & 0x80) != 0
        if isNegative {
            // value = -((~data) + 1) interpreted as unsigned
            let inverted = Data(data.map { ~$0 })
            let unsigned = BigUInt(inverted) + 1
            return -BigInt(unsigned)
        }
        return BigInt(BigUInt(data))
    }

    /// Scale-aware subtraction: returns `a - b` as a `BigDecimalValue`.
    public static func subtract(_ a: BigDecimalValue, _ b: BigDecimalValue) -> BigDecimalValue {
        let (l, r) = alignScales(a, b)
        return BigDecimalValue(unscaled: l.unscaled - r.unscaled, scale: l.scale)
    }

    public static func operatorAddDelta(
        first: BigDecimalValue,
        delta: BigDecimalValue,
        asks: Bool
    ) -> BigDecimalValue {
        // decoded delta is in units of 0.01 of the first price; multiply by 100 to
        // recover the original delta value, then add (asks) or subtract (bids).
        let multiplied = BigDecimalValue(
            unscaled: delta.unscaled * 100,
            scale: delta.scale
        )
        // Align scales between first and multiplied.
        let (a, b) = alignScales(first, multiplied)
        let sum = asks ? a.unscaled + b.unscaled : a.unscaled - b.unscaled
        return BigDecimalValue(unscaled: sum, scale: a.scale)
    }

    static func alignScales(_ x: BigDecimalValue, _ y: BigDecimalValue) -> (BigDecimalValue, BigDecimalValue) {
        if x.scale == y.scale { return (x, y) }
        if x.scale < y.scale {
            let factor = BigInt(10).power(y.scale - x.scale)
            return (BigDecimalValue(unscaled: x.unscaled * factor, scale: y.scale), y)
        } else {
            let factor = BigInt(10).power(x.scale - y.scale)
            return (x, BigDecimalValue(unscaled: y.unscaled * factor, scale: x.scale))
        }
    }
}
