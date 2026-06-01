import Foundation
import Testing
@testable import DukascopyClient

@Suite("ClosedPositionMessages")
struct ClosedPositionMessagesTests {

    /// The request carries the class id + the closed-trades window/flag/envelope fields.
    @Test("encodePositionDataRequest writes the class id and the window/getClosed fields")
    func requestEncodes() throws {
        let frame = encodePositionDataRequest(
            startMillis: 1_000, endMillis: 2_000, getClosed: true,
            userName: "u", sessionId: "s", userId: "uid", accountLoginId: "acc",
            requestId: "req-1", timestamp: 9_999
        )
        var r = BinaryReader(frame)
        #expect(try r.readInt32BE() == javaStringHashCode(WireClass.positionDataRequest))

        var fields: [Int16: BinaryReader] = [:]
        while let f = try readField(from: &r) { fields[f.fieldId] = f.value }
        var start = fields[-28971]; #expect(try start?.readInt64BE() == 1_000)
        var end = fields[26733];    #expect(try end?.readInt64BE() == 2_000)
        var closed = fields[21067]; #expect(try closed?.readBoolean() == true)
        var user = fields[14530];   #expect(try user?.readString() == "u")
        var req = fields[17261];    #expect(try req?.readString() == "req-1")
        var ts = fields[-28332];    #expect(try ts?.readInt64BE() == 9_999)
    }

    /// The response is a chunked binary group; positionsEncoded strips the byte[] var-len prefix.
    @Test("PositionBinaryResponse.decode reads order/finished/requestId and the unframed blob")
    func responseDecodes() throws {
        var w = BinaryWriter()
        w.writeInt32BE(javaStringHashCode(WireClass.positionBinaryResponse))
        let blob = Data([0x1f, 0x8b, 0xDE, 0xAD])
        writeField(&w, fieldId: -22668) { sub in
            sub.writeVarLen(blob.count)  // byte[] = var-len count + raw bytes
            sub.writeBytes(blob)
        }
        writeField(&w, fieldId: -18886) { sub in sub.writeInt32BE(0) }
        writeField(&w, fieldId: -28801) { sub in sub.writeBoolean(true) }
        writeField(&w, fieldId: 17261)  { sub in sub.writeString("req-1") }

        var r = BinaryReader(w.data)
        _ = try r.readInt32BE()
        let resp = try PositionBinaryResponse.decode(from: &r)
        #expect(resp.positionsEncoded == blob)
        #expect(resp.messageOrder == 0)
        #expect(resp.finished == true)
        #expect(resp.requestId == "req-1")
    }

    // A real GZIP(Bits.writeObject(List<PositionData>)) blob captured from the demo server
    // (CLI `closed-trades` probe). Pins the Bits decode against ground truth: 11 closed
    // EUR/USD positions. The first is LONG, REGULAR, amount 1000, openPrice 1.16448,
    // currentPrice null (closed), closePrice 1.1646, P/L 0.12, commission -0.22, PLN.
    static let blobHex =
        "1f8b08000000000000ff8d94b14a03411086f7d4a84104115b9f4072d9d9ececed61158d1254e450" +
        "5258586be723983462195289a868a18855f009f214368295a58520885888c96e72b7b7ece935f7c" +
        "fbf7730dfcdec8c470899f1a29ae7f50332781459c07905420ef1d1d45a63a7dcd8ad0de209a094" +
        "aa43f041702ed51793ca08f501f5810d028fa66ca1447da6a2f1686bbbfffaaab5f27ca6f4a0183" +
        "9101895611e04c949620231ca456502917807c5f1dba1d2e6cb999322a47f53e87f972604c649d1" +
        "82c00c8856b1adb55377414085e728050212c38cda4121d50e6d1d0ce7fbef4a2f0bd76e06a31dd" +
        "546adbc5ab518a81f868c33921808e35c957425b41f44c05314174f3d4d419ded00b42836a23d45" +
        "c1e24a00f7311c5d0a6554aeb192712d8746918854fedb6f7d29ef167bcefcc2ae427dddae020a1" +
        "600490c0fe25cdcaa02cfa8c2c39154da5d38755248968742a0418190ce95504016c5e35257ebb2" +
        "734091611e0a260d0a48fa6ecd066006c56b675aebcdbd8b420679d604a231a118c4abcad812b17" +
        "5ccc6c7ec9cd2cff9a683a1bf25f2f403c4705b6af3ffa6b20af1b3f9a5f5a4fd0b25e87dd6b8050000"

    @Test("decodeList against the real demo GZIP blob — pins the Bits format")
    func decodesRealBlob() throws {
        let gz = try #require(Hex.decode(Self.blobHex))
        let positions = try PositionDataBitsDecoder.decodeList(gz)

        #expect(positions.count == 11)
        let first = try #require(positions.first)
        #expect(first.positionId == "274431941")
        #expect(first.isLong == true)
        #expect(first.isMerged == false)
        #expect(first.instrument == "EUR/USD")
        #expect(first.amount == 1000)
        #expect(first.openPrice == 1.16448)
        #expect(first.currentPrice == nil)        // closed position → no current price
        #expect(first.closePrice == 1.1646)
        #expect(first.profitLoss == 0.12)
        #expect(first.swaps == 0)
        #expect(first.grossProfitLoss == 0.12)
        #expect(first.commission == -0.22)
        #expect(first.commissionCurrency == "PLN")
        // Raw 8-byte BE longs (epoch ms); open precedes close in time.
        let open = try #require(first.openDateMillis)
        let close = try #require(first.closeDateMillis)
        #expect(open > 1_600_000_000_000)         // after ~2020
        #expect(close >= open)
        // Every decoded position should carry an instrument and a position id.
        for p in positions {
            #expect(!p.positionId.isEmpty)
            #expect(!p.instrument.isEmpty)
        }
    }
}
