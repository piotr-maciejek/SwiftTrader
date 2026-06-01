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

    @Test("connect enforces the timeout instead of hanging on an unreachable host")
    func connectEnforcesTimeout() async {
        // 10.255.255.1 is a reserved address that typically blackholes packets, so the
        // TLS connection neither completes nor resets — exactly the hang the timeout guards.
        let transport = Transport(address: ServerAddress(host: "10.255.255.1", port: 443))
        let clock = ContinuousClock()
        let start = clock.now
        var threw = false
        do {
            try await transport.connect(timeout: 1.0)
        } catch {
            threw = true
        }
        let elapsed = start.duration(to: clock.now)
        #expect(threw)
        // Without the timeout this would never return; allow generous slack for CI.
        #expect(elapsed < .seconds(6))
        await transport.close()
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
