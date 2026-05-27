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

    private static func alignScales(_ x: BigDecimalValue, _ y: BigDecimalValue) -> (BigDecimalValue, BigDecimalValue) {
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
