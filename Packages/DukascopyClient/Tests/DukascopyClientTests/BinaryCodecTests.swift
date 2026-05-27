import XCTest
@testable import DukascopyClient

final class BinaryCodecTests: XCTestCase {
    func testJavaHashCodeKnownValues() {
        // SHA reference values for Java's `String.hashCode()`:
        XCTAssertEqual(javaStringHashCode(""), 0)
        XCTAssertEqual(javaStringHashCode("a"), 97)
        XCTAssertEqual(javaStringHashCode("abc"), 96354)
        XCTAssertEqual(javaStringHashCode("Hello, World!"), 1498789909)
        // Large strings hash with 32-bit wrap-around.
        XCTAssertEqual(
            javaStringHashCode("com.dukascopy.dds4.transport.msg.system.HaloRequestMessage"),
            javaStringHashCode("com.dukascopy.dds4.transport.msg.system.HaloRequestMessage")
        )
    }

    func testVarLenSingleByte() {
        var w = BinaryWriter()
        w.writeVarLen(0)
        XCTAssertEqual(w.data, Data([0xC0]))
        w = BinaryWriter()
        w.writeVarLen(63)
        XCTAssertEqual(w.data, Data([0xFF]))
    }

    func testVarLenTwoByteBoundary() {
        var w = BinaryWriter()
        w.writeVarLen(64)
        XCTAssertEqual(w.data, Data([0x80, 0x40]))
        w = BinaryWriter()
        w.writeVarLen(16383)
        XCTAssertEqual(w.data, Data([0xBF, 0xFF]))
    }

    func testVarLenRoundTrip() throws {
        for value in [0, 1, 63, 64, 1000, 16383, 16384, 0x3F_FFFF, 0x40_0000, 1_000_000, 0x3FFF_FFFF] {
            var w = BinaryWriter()
            w.writeVarLen(value)
            var r = BinaryReader(w.data)
            XCTAssertEqual(try r.readVarLen(), value)
            XCTAssertEqual(r.remaining, 0)
        }
    }

    func testStringRoundTrip() throws {
        for s in ["", "a", "EUR/USD", "héllo", String(repeating: "x", count: 1000)] {
            var w = BinaryWriter()
            w.writeString(s)
            var r = BinaryReader(w.data)
            XCTAssertEqual(try r.readString(), s)
            XCTAssertEqual(r.remaining, 0)
        }
    }

    func testInt64RoundTrip() throws {
        for v: Int64 in [0, 1, -1, Int64.min, Int64.max, 1234567890123] {
            var w = BinaryWriter()
            w.writeInt64BE(v)
            var r = BinaryReader(w.data)
            XCTAssertEqual(try r.readInt64BE(), v)
        }
    }

    func testInt16RoundTripCoversFieldIdRange() throws {
        for v: Int16 in [Int16.min, -1, 0, 1, Int16.max, -16397, 28132, -29489] {
            var w = BinaryWriter()
            w.writeInt16BE(v)
            var r = BinaryReader(w.data)
            XCTAssertEqual(try r.readInt16BE(), v)
        }
    }

    func testFieldRecordRoundTrip() throws {
        var msgWriter = BinaryWriter()
        writeField(&msgWriter, fieldId: 17261) { sub in sub.writeString("req-1") }
        writeField(&msgWriter, fieldId: -28332) { sub in sub.writeInt64BE(1_700_000_000_000) }

        var reader = BinaryReader(msgWriter.data)
        let first = try readField(from: &reader)
        XCTAssertEqual(first?.fieldId, 17261)
        var firstValue = first!.value
        XCTAssertEqual(try firstValue.readString(), "req-1")

        let second = try readField(from: &reader)
        XCTAssertEqual(second?.fieldId, -28332)
        var secondValue = second!.value
        XCTAssertEqual(try secondValue.readInt64BE(), 1_700_000_000_000)

        XCTAssertNil(try readField(from: &reader))
    }
}

final class MessageEncodingTests: XCTestCase {
    func testHaloRequestEncodesClassIdFirst() {
        var halo = HaloRequest()
        halo.useragent = "ua"
        halo.pingable = true
        let encoded = halo.encode()
        var reader = BinaryReader(encoded)
        XCTAssertEqual(try reader.readInt32BE(), javaStringHashCode(WireClass.haloRequest))
        XCTAssertGreaterThan(reader.remaining, 0)
    }

    func testHaloResponseDecodesBackToFields() throws {
        // Round-trip via a synthetic encoder: write classId + 3 fields, then decode.
        var w = BinaryWriter()
        w.writeInt32BE(javaStringHashCode(WireClass.haloResponse))
        writeField(&w, fieldId: -3004)  { sub in sub.writeString("xyz") }
        writeField(&w, fieldId: 28132)  { sub in sub.writeString("sess-123") }
        writeField(&w, fieldId: -11686) { sub in sub.writeBoolean(true) }

        let msg = try MessageDecoder.decode(w.data)
        guard case .halo(let halo) = msg else { return XCTFail("expected halo, got \(msg)") }
        XCTAssertEqual(halo.challenge, "xyz")
        XCTAssertEqual(halo.sessionId, "sess-123")
        XCTAssertEqual(halo.udpSupportedByServer, true)
    }

    func testOkResponseEmpty() throws {
        var w = BinaryWriter()
        w.writeInt32BE(javaStringHashCode(WireClass.okResponse))
        let msg = try MessageDecoder.decode(w.data)
        guard case .ok = msg else { return XCTFail("expected ok") }
    }

    func testErrorResponseDecodes() throws {
        var w = BinaryWriter()
        w.writeInt32BE(javaStringHashCode(WireClass.errorResponse))
        writeField(&w, fieldId: -19257) { sub in sub.writeString("bad creds") }
        writeField(&w, fieldId: 31707)  { sub in sub.writeBoolean(true) }

        let msg = try MessageDecoder.decode(w.data)
        guard case .error(let err) = msg else { return XCTFail("expected error") }
        XCTAssertEqual(err.reason, "bad creds")
        XCTAssertEqual(err.fatal, true)
    }

    func testUnknownClassIsPreserved() throws {
        var w = BinaryWriter()
        w.writeInt32BE(12345)
        let msg = try MessageDecoder.decode(w.data)
        guard case .unknown(let classId, _) = msg else { return XCTFail("expected unknown") }
        XCTAssertEqual(classId, 12345)
    }
}
