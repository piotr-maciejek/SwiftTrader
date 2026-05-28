import Foundation
import Testing
@testable import DukascopyClient

@Suite("Transport")
struct TransportTests {
    @Test("ServerAddress parses host:port and defaults port to 443")
    func serverAddressParse() {
        #expect(ServerAddress.parse("api.example.com:10443") == ServerAddress(host: "api.example.com", port: 10443))
        #expect(ServerAddress.parse("api.example.com") == ServerAddress(host: "api.example.com", port: 443))
    }

    @Test("ServerAddress rejects bad ports")
    func serverAddressRejectsBadPort() {
        #expect(ServerAddress.parse("api.example.com:not-a-port") == nil)
        #expect(ServerAddress.parse("api.example.com:99999") == nil)
    }

    @Test("Big-endian read/write round-trips")
    func bigEndianRoundTrip() {
        var data = Data()
        data.appendUInt16BE(0xABCD)
        data.appendUInt32BE(0xDEADBEEF)
        data.appendInt32BE(-1)
        #expect(data == Data([0xAB, 0xCD, 0xDE, 0xAD, 0xBE, 0xEF, 0xFF, 0xFF, 0xFF, 0xFF]))
        #expect(data.readUInt16BE(at: 0) == 0xABCD)
        #expect(data.readUInt32BE(at: 2) == 0xDEADBEEF)
        #expect(data.readInt32BE(at: 6) == -1)
    }
}
