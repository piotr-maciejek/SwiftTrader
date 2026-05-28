import Foundation
import Testing
@testable import DukascopyClient

@Suite("Hex")
struct HexTests {
    @Test("Round-trips all 256 byte values")
    func roundTripAllByteValues() {
        var bytes = Data()
        for i in 0..<256 { bytes.append(UInt8(i)) }
        let hex = Hex.encode(bytes)
        #expect(hex.count == 512)
        #expect(hex.prefix(6) == "000102")
        #expect(hex.suffix(6) == "fdfeff")
        #expect(Hex.decode(hex) == bytes)
    }

    @Test("Decode accepts uppercase")
    func decodeAcceptsUppercase() {
        #expect(Hex.decode("DEADBEEF") == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test("Decode rejects odd length")
    func decodeRejectsOddLength() {
        #expect(Hex.decode("abc") == nil)
    }

    @Test("Decode rejects non-hex")
    func decodeRejectsNonHex() {
        #expect(Hex.decode("zz") == nil)
    }

    @Test("Decode empty string")
    func decodeEmpty() {
        #expect(Hex.decode("") == Data())
    }
}
