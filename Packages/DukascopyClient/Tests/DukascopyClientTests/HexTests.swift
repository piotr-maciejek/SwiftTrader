import XCTest
@testable import DukascopyClient

final class HexTests: XCTestCase {
    func testRoundTripAllByteValues() {
        var bytes = Data()
        for i in 0..<256 { bytes.append(UInt8(i)) }
        let hex = Hex.encode(bytes)
        XCTAssertEqual(hex.count, 512)
        XCTAssertEqual(hex.prefix(6), "000102")
        XCTAssertEqual(hex.suffix(6), "fdfeff")
        XCTAssertEqual(Hex.decode(hex), bytes)
    }

    func testDecodeAcceptsUppercase() {
        XCTAssertEqual(Hex.decode("DEADBEEF"), Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    func testDecodeRejectsOddLength() {
        XCTAssertNil(Hex.decode("abc"))
    }

    func testDecodeRejectsNonHex() {
        XCTAssertNil(Hex.decode("zz"))
    }

    func testDecodeEmpty() {
        XCTAssertEqual(Hex.decode(""), Data())
    }
}
