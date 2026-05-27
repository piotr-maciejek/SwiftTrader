import BigInt
import Foundation

enum Hex {
    static func encode(_ data: Data) -> String {
        var out = String()
        out.reserveCapacity(data.count * 2)
        for byte in data {
            out.append(hexChar(byte >> 4))
            out.append(hexChar(byte & 0x0F))
        }
        return out
    }

    static func decode(_ s: String) -> Data? {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append((hi << 4) | lo)
            i += 2
        }
        return out
    }

    private static func hexChar(_ nibble: UInt8) -> Character {
        let n = nibble & 0x0F
        return Character(UnicodeScalar(n < 10 ? (0x30 + n) : (0x61 + n - 10)))
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }
}

extension BigUInt {
    init?(hex: String) {
        self.init(hex, radix: 16)
    }

    var lowercaseHex: String {
        if self == 0 { return "0" }
        return String(self, radix: 16, uppercase: false)
    }

    func bytes(paddedTo length: Int) -> Data {
        let raw = self.serialize()
        if raw.count < length {
            var padded = Data(repeating: 0, count: length - raw.count)
            padded.append(raw)
            return padded
        }
        return raw
    }
}
