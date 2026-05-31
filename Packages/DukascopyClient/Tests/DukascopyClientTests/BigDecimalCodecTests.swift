import BigInt
import Foundation
import Testing
@testable import DukascopyClient

@Suite("BigDecimal codec")
struct BigDecimalCodecTests {

    private func roundTrip(_ value: BigDecimalValue) throws -> BigDecimalValue {
        var w = BinaryWriter()
        BigDecimalCodec.encode(value, into: &w)
        var r = BinaryReader(w.data)
        return try BigDecimalCodec.decode(from: &r)
    }

    @Test("encode → decode round-trips across signs, scales, and magnitudes")
    func roundTrips() throws {
        let cases: [BigDecimalValue] = [
            .zero,
            BigDecimalValue(unscaled: 1, scale: 0),
            BigDecimalValue(unscaled: -1, scale: 0),
            BigDecimalValue(unscaled: 127, scale: 0),
            BigDecimalValue(unscaled: 128, scale: 0),
            BigDecimalValue(unscaled: -128, scale: 0),
            BigDecimalValue(unscaled: -129, scale: 0),
            BigDecimalValue(unscaled: 256, scale: 0),
            BigDecimalValue(unscaled: 123456, scale: 5),    // 1.23456 (EURUSD price)
            BigDecimalValue(unscaled: 15123, scale: 2),     // 151.23 (JPY price)
            BigDecimalValue(unscaled: -98765, scale: 4),
            BigDecimalValue(unscaled: 100000, scale: 0),    // 0.1 lots at amount-millions
            BigDecimalValue(unscaled: BigInt("123456789012345"), scale: 7),
            BigDecimalValue(unscaled: 5, scale: -3),        // negative scale → kind 5
        ]
        for c in cases {
            let back = try roundTrip(c)
            #expect(back == c, "round-trip mismatch for \(c) (scale \(c.scale))")
        }
    }

    @Test("zero encodes to a single 0 byte (kind 0)")
    func zeroIsOneByte() {
        var w = BinaryWriter()
        BigDecimalCodec.encode(.zero, into: &w)
        #expect(Array(w.data) == [0])
    }

    @Test("Double initializer rounds to the requested scale")
    func doubleInit() throws {
        // 0.07 * 1e5 = 6999.9999… must round to 7000, not 6999.
        let v = BigDecimalValue(0.07, scale: 5)
        #expect(v.unscaled == 7000)
        #expect(v.scale == 5)
        #expect(abs(v.doubleValue - 0.07) < 1e-9)

        let price = BigDecimalValue(1.23456, scale: 5)
        #expect(price.unscaled == 123456)
        #expect(try roundTrip(price) == price)

        let neg = BigDecimalValue(-1.5, scale: 1)
        #expect(neg.unscaled == -15)
        #expect(try roundTrip(neg) == neg)
    }

    @Test("positive value whose top bit is set gets a leading zero byte")
    func positiveSignByte() throws {
        // 0x80 (128) must serialize as [0x00, 0x80] so it doesn't read as negative.
        let v = BigDecimalValue(unscaled: 128, scale: 0)
        #expect(try roundTrip(v) == v)
        #expect(try roundTrip(v).unscaled > 0)
    }
}
