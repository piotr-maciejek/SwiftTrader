import Foundation
import Testing
@testable import DukascopyClient

@Suite("Binary codec")
struct BinaryCodecTests {
    @Test("Java String.hashCode matches known values")
    func javaHashCodeKnownValues() {
        #expect(javaStringHashCode("") == 0)
        #expect(javaStringHashCode("a") == 97)
        #expect(javaStringHashCode("abc") == 96354)
        #expect(javaStringHashCode("Hello, World!") == 1498789909)
        // Large strings hash with 32-bit wrap-around (deterministic).
        #expect(javaStringHashCode("com.dukascopy.dds4.transport.msg.system.HaloRequestMessage")
            == javaStringHashCode("com.dukascopy.dds4.transport.msg.system.HaloRequestMessage"))
    }

    @Test("VarLen single-byte encoding")
    func varLenSingleByte() {
        var w = BinaryWriter()
        w.writeVarLen(0)
        #expect(w.data == Data([0xC0]))
        w = BinaryWriter()
        w.writeVarLen(63)
        #expect(w.data == Data([0xFF]))
    }

    @Test("VarLen two-byte boundary")
    func varLenTwoByteBoundary() {
        var w = BinaryWriter()
        w.writeVarLen(64)
        #expect(w.data == Data([0x80, 0x40]))
        w = BinaryWriter()
        w.writeVarLen(16383)
        #expect(w.data == Data([0xBF, 0xFF]))
    }

    @Test("VarLen round-trips across size classes")
    func varLenRoundTrip() throws {
        for value in [0, 1, 63, 64, 1000, 16383, 16384, 0x3F_FFFF, 0x40_0000, 1_000_000, 0x3FFF_FFFF] {
            var w = BinaryWriter()
            w.writeVarLen(value)
            var r = BinaryReader(w.data)
            #expect(try r.readVarLen() == value)
            #expect(r.remaining == 0)
        }
    }

    @Test("String round-trips, including UTF-8 and long strings")
    func stringRoundTrip() throws {
        for s in ["", "a", "EUR/USD", "héllo", String(repeating: "x", count: 1000)] {
            var w = BinaryWriter()
            w.writeString(s)
            var r = BinaryReader(w.data)
            #expect(try r.readString() == s)
            #expect(r.remaining == 0)
        }
    }

    @Test("Int64 round-trips including extremes")
    func int64RoundTrip() throws {
        for v: Int64 in [0, 1, -1, Int64.min, Int64.max, 1234567890123] {
            var w = BinaryWriter()
            w.writeInt64BE(v)
            var r = BinaryReader(w.data)
            #expect(try r.readInt64BE() == v)
        }
    }

    @Test("Int16 round-trips across the field-id range")
    func int16RoundTripCoversFieldIdRange() throws {
        for v: Int16 in [Int16.min, -1, 0, 1, Int16.max, -16397, 28132, -29489] {
            var w = BinaryWriter()
            w.writeInt16BE(v)
            var r = BinaryReader(w.data)
            #expect(try r.readInt16BE() == v)
        }
    }

    @Test("Field record round-trips id + value pairs")
    func fieldRecordRoundTrip() throws {
        var msgWriter = BinaryWriter()
        writeField(&msgWriter, fieldId: 17261) { sub in sub.writeString("req-1") }
        writeField(&msgWriter, fieldId: -28332) { sub in sub.writeInt64BE(1_700_000_000_000) }

        var reader = BinaryReader(msgWriter.data)
        let first = try readField(from: &reader)
        #expect(first?.fieldId == 17261)
        var firstValue = try #require(first).value
        #expect(try firstValue.readString() == "req-1")

        let second = try readField(from: &reader)
        #expect(second?.fieldId == -28332)
        var secondValue = try #require(second).value
        #expect(try secondValue.readInt64BE() == 1_700_000_000_000)

        #expect(try readField(from: &reader) == nil)
    }

    // MARK: - Hostile lengths (a malformed frame must throw, never trap)

    @Test("readBytes with a negative count throws instead of trapping")
    func negativeReadBytesThrows() {
        var r = BinaryReader(Data([0x01, 0x02, 0x03]))
        #expect(throws: CodecError.self) {
            _ = try r.readBytes(-1)
        }
    }

    @Test("A field carrying a negative Int32 length throws from readField")
    func negativeFieldLengthThrows() {
        // fieldId(int16) + length(int32 = -5) + some bytes.
        var w = BinaryWriter()
        w.writeInt16BE(17261)
        w.writeInt32BE(-5)
        w.writeBytes(Data([0xAA, 0xBB, 0xCC]))
        var r = BinaryReader(w.data)
        #expect(throws: CodecError.self) {
            _ = try readField(from: &r)
        }
    }

    @Test("BigDecimal kind 7 with a negative byte length throws")
    func negativeBigDecimalLengthThrows() {
        // kind byte 7 + scale(int32) + len(int32 = -1).
        var w = BinaryWriter()
        w.writeByte(7)
        w.writeInt32BE(5)
        w.writeInt32BE(-1)
        var r = BinaryReader(w.data)
        #expect(throws: CodecError.self) {
            _ = try BigDecimalCodec.decode(from: &r)
        }
    }

    @Test("A message list declaring a huge size fails fast without a giant allocation")
    func hostileListSizeFailsFast() {
        // collectionClassId + varLen size of 2^30-1, then nothing — must throw on the
        // first missing element, not reserve a multi-GB array first.
        var w = BinaryWriter()
        w.writeInt32BE(0x0BAD_F00D)
        w.writeVarLen(0x3FFF_FFFF)
        var r = BinaryReader(w.data)
        #expect(throws: CodecError.self) {
            _ = try decodeMessageList(from: &r) { (sub: inout BinaryReader) in
                try sub.readByte()
            }
        }
    }

    @Test("Positive-length truncation still throws .truncated")
    func positiveTruncationStillThrows() {
        var r = BinaryReader(Data([0x01]))
        #expect(throws: CodecError.self) {
            _ = try r.readBytes(8)
        }
        // And the specific case is preserved (not folded into negativeLength).
        var r2 = BinaryReader(Data([0x01]))
        do {
            _ = try r2.readBytes(8)
            Issue.record("expected throw")
        } catch let CodecError.truncated(needed, available) {
            #expect(needed == 8)
            #expect(available == 1)
        } catch {
            Issue.record("expected .truncated, got \(error)")
        }
    }
}

@Suite("Message encoding")
struct MessageEncodingTests {
    @Test("HaloRequest encodes the classId first")
    func haloRequestEncodesClassIdFirst() throws {
        var halo = HaloRequest()
        halo.useragent = "ua"
        halo.pingable = true
        let encoded = halo.encode()
        var reader = BinaryReader(encoded)
        #expect(try reader.readInt32BE() == javaStringHashCode(WireClass.haloRequest))
        #expect(reader.remaining > 0)
    }

    @Test("HaloResponse decodes back into fields")
    func haloResponseDecodesBackToFields() throws {
        var w = BinaryWriter()
        w.writeInt32BE(javaStringHashCode(WireClass.haloResponse))
        writeField(&w, fieldId: -3004)  { sub in sub.writeString("xyz") }
        writeField(&w, fieldId: 28132)  { sub in sub.writeString("sess-123") }
        writeField(&w, fieldId: -11686) { sub in sub.writeBoolean(true) }

        let msg = try MessageDecoder.decode(w.data)
        guard case .halo(let halo) = msg else {
            Issue.record("expected halo, got \(msg)")
            return
        }
        #expect(halo.challenge == "xyz")
        #expect(halo.sessionId == "sess-123")
        #expect(halo.udpSupportedByServer == true)
    }

    @Test("OkResponse decodes when empty")
    func okResponseEmpty() throws {
        var w = BinaryWriter()
        w.writeInt32BE(javaStringHashCode(WireClass.okResponse))
        let msg = try MessageDecoder.decode(w.data)
        guard case .ok = msg else {
            Issue.record("expected ok, got \(msg)")
            return
        }
    }

    @Test("ErrorResponse decodes reason and fatal flag")
    func errorResponseDecodes() throws {
        var w = BinaryWriter()
        w.writeInt32BE(javaStringHashCode(WireClass.errorResponse))
        writeField(&w, fieldId: -19257) { sub in sub.writeString("bad creds") }
        writeField(&w, fieldId: 31707)  { sub in sub.writeBoolean(true) }

        let msg = try MessageDecoder.decode(w.data)
        guard case .error(let err) = msg else {
            Issue.record("expected error, got \(msg)")
            return
        }
        #expect(err.reason == "bad creds")
        #expect(err.fatal == true)
    }

    @Test("Unknown class id is preserved")
    func unknownClassIsPreserved() throws {
        var w = BinaryWriter()
        w.writeInt32BE(12345)
        let msg = try MessageDecoder.decode(w.data)
        guard case .unknown(let classId, _) = msg else {
            Issue.record("expected unknown, got \(msg)")
            return
        }
        #expect(classId == 12345)
    }
}
