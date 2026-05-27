import XCTest
@testable import DukascopyClient

final class TransportTests: XCTestCase {
    func testServerAddressParse() {
        XCTAssertEqual(ServerAddress.parse("api.example.com:10443"),
                       ServerAddress(host: "api.example.com", port: 10443))
        XCTAssertEqual(ServerAddress.parse("api.example.com"),
                       ServerAddress(host: "api.example.com", port: 443))
    }

    func testServerAddressRejectsBadPort() {
        XCTAssertNil(ServerAddress.parse("api.example.com:not-a-port"))
        XCTAssertNil(ServerAddress.parse("api.example.com:99999"))
    }

    func testBigEndianRoundTrip() {
        var data = Data()
        data.appendUInt16BE(0xABCD)
        data.appendUInt32BE(0xDEADBEEF)
        data.appendInt32BE(-1)
        XCTAssertEqual(data, Data([0xAB, 0xCD, 0xDE, 0xAD, 0xBE, 0xEF, 0xFF, 0xFF, 0xFF, 0xFF]))
        XCTAssertEqual(data.readUInt16BE(at: 0), 0xABCD)
        XCTAssertEqual(data.readUInt32BE(at: 2), 0xDEADBEEF)
        XCTAssertEqual(data.readInt32BE(at: 6), -1)
    }
}
