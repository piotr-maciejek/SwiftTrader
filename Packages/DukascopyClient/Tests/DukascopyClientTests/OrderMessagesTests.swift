import Foundation
import Testing
@testable import DukascopyClient

@Suite("Order/position decoding")
struct OrderMessagesTests {

    /// Writes an enum field value: `classId(int32) + value(int32)`.
    private func writeEnum(_ w: inout BinaryWriter, _ value: Int32) {
        w.writeInt32BE(0x0BAD_F00D)   // enum class id — ignored on decode
        w.writeInt32BE(value)
    }

    /// Wraps a message field-stream `body` as a single-element `List<Message>` field
    /// value: `listClassId + varLen(1) + elemClassId + varLen(len) + classId + body`.
    private func listFieldValue(messageClassId: Int32, body: Data) -> (inout BinaryWriter) -> Void {
        return { sub in
            sub.writeInt32BE(javaStringHashCode(WireType.arrayListClass))
            sub.writeVarLen(1)
            sub.writeInt32BE(messageClassId)        // element class id
            var msg = BinaryWriter()
            msg.writeInt32BE(messageClassId)        // message class id (inside buffer)
            msg.writeBytes(body)
            sub.writeVarLen(msg.data.count)
            sub.writeBytes(msg.data)
        }
    }

    @Test("PackedAccountInfo decodes a position group with a nested filled order")
    func decodesGroupWithOrder() throws {
        let groupClassId = javaStringHashCode(WireClass.orderGroupMessage)
        let orderClassId = javaStringHashCode(WireClass.orderMessage)

        // --- build the nested order field-stream ---
        var ord = BinaryWriter()
        writeField(&ord, fieldId: -12183) { $0.writeString("ORD-1") }                              // orderId
        writeField(&ord, fieldId: -7924)  { self.writeEnum(&$0, 66150) }                            // side BUY
        writeField(&ord, fieldId: 32505)  { self.writeEnum(&$0, 2073796962) }                       // state FILLED
        writeField(&ord, fieldId: -30914) { BigDecimalCodec.encode(BigDecimalValue(1.09, scale: 5), into: &$0) }   // SL
        writeField(&ord, fieldId: 8993)   { BigDecimalCodec.encode(BigDecimalValue(1.12, scale: 5), into: &$0) }   // TP

        // --- build the group field-stream ---
        var grp = BinaryWriter()
        writeField(&grp, fieldId: 29772)  { $0.writeString("POS-1") }                               // orderGroupId
        writeField(&grp, fieldId: 12424)  { $0.writeString("EUR/USD") }                             // instrument
        writeField(&grp, fieldId: -5158)  { BigDecimalCodec.encode(BigDecimalValue(0.01, scale: 5), into: &$0) }   // amount
        writeField(&grp, fieldId: -27533) { BigDecimalCodec.encode(BigDecimalValue(1.10, scale: 5), into: &$0) }   // pricePosOpen
        writeField(&grp, fieldId: -25925) { self.writeEnum(&$0, 2342524) }                          // side LONG
        writeField(&grp, fieldId: -16069) { self.writeEnum(&$0, 2432586) }                          // status OPEN
        writeField(&grp, fieldId: 5455)   { BigDecimalCodec.encode(BigDecimalValue(1.1005, scale: 5), into: &$0) } // pricePl
        writeField(&grp, fieldId: -23746, encode: listFieldValue(messageClassId: orderClassId, body: ord.data))

        // --- build the PackedAccountInfo field-stream (groups list only) ---
        var packed = BinaryWriter()
        writeField(&packed, fieldId: -17942, encode: listFieldValue(messageClassId: groupClassId, body: grp.data))

        var r = BinaryReader(packed.data)
        let info = try PackedAccountInfo.decode(from: &r)

        #expect(info.groups.count == 1)
        let g = info.groups[0]
        #expect(g.orderGroupId == "POS-1")
        #expect(g.instrument == "EUR/USD")
        #expect(g.side == "BUY")
        #expect(g.status == "OPEN")
        #expect(g.isOpen)
        #expect(abs((g.pricePosOpen?.doubleValue ?? 0) - 1.10) < 1e-9)
        #expect(abs((g.pricePl?.doubleValue ?? 0) - 1.1005) < 1e-9)
        #expect(g.orders.count == 1)
        let o = g.orders[0]
        #expect(o.orderId == "ORD-1")
        #expect(o.side == "BUY")
        #expect(o.state == "FILLED")
        #expect(abs((o.priceStop?.doubleValue ?? 0) - 1.09) < 1e-9)
        #expect(abs((o.priceLimit?.doubleValue ?? 0) - 1.12) < 1e-9)
    }

    @Test("MessageDecoder dispatches a live OrderGroupMessage")
    func dispatchesLiveOrderGroup() throws {
        var frame = BinaryWriter()
        frame.writeInt32BE(javaStringHashCode(WireClass.orderGroupMessage))
        writeField(&frame, fieldId: 29772) { $0.writeString("POS-9") }
        writeField(&frame, fieldId: -16069) { self.writeEnum(&$0, 64218584) }  // CLOSE
        let msg = try MessageDecoder.decode(frame.data)
        guard case .orderGroup(let g) = msg else {
            Issue.record("expected .orderGroup, got \(msg)"); return
        }
        #expect(g.orderGroupId == "POS-9")
        #expect(g.status == "CLOSE")
        #expect(!g.isOpen)
    }

    @Test("Order request class IDs match the decompiled values")
    func classIds() {
        #expect(javaStringHashCode(WireClass.submitMarketOrder) == -1750786620)
        #expect(javaStringHashCode(WireClass.submitConditionalOrder) == 1969632608)
        #expect(javaStringHashCode(WireClass.submitPositionClose) == 182515591)
        #expect(javaStringHashCode(WireClass.submitOrderCancel) == -1350871538)
        #expect(javaStringHashCode(WireClass.submitModifyStopLoss) == -1268600055)
        #expect(javaStringHashCode(WireClass.submitModifyTakeProfit) == -1727437533)
        #expect(javaStringHashCode(WireClass.extApiOrderResponse) == 1522519751)
    }

    @Test("Market order encodes classId + fields and round-trips its key fields")
    func marketOrderEncode() throws {
        let req = SubmitMarketOrderRequest(
            instrument: "EUR/USD", side: "BUY", label: "ST_1",
            amount: BigDecimalValue(0.01, scale: 5), comments: nil,
            envelope: OrderEnvelope(requestId: "REQ-1", accountLoginId: "123", timestamp: 42)
        )
        var r = BinaryReader(req.encode())
        #expect(try r.readInt32BE() == javaStringHashCode(WireClass.submitMarketOrder))
        var fields: [Int16: BinaryReader] = [:]
        while let f = try readField(from: &r) { fields[f.fieldId] = f.value }
        var inst = fields[12424]!; #expect(try inst.readString() == "EUR/USD")
        var side = fields[6236]!;  #expect(try side.readString() == "BUY")
        var label = fields[-14442]!; #expect(try label.readString() == "ST_1")
        var amt = fields[-5158]!
        #expect(abs(try BigDecimalCodec.decode(from: &amt).doubleValue - 0.01) < 1e-9)
        var rid = fields[17261]!; #expect(try rid.readString() == "REQ-1")
        #expect(fields[3213] == nil)   // no comments field when nil
    }

    @Test("Conditional order carries trigger price + SL/TP + directions")
    func conditionalOrderEncode() throws {
        let req = SubmitConditionalOrderRequest(
            instrument: "EUR/USD", side: "BUY", label: "L1",
            amount: BigDecimalValue(0.02, scale: 5),
            price: BigDecimalValue(1.05, scale: 5), stopDirection: "LESS_ASK",
            slippage: nil, goodTillTime: nil,
            stopLossPrice: BigDecimalValue(1.04, scale: 5), stopLossDirection: "LESS_BID",
            takeProfitPrice: BigDecimalValue(1.08, scale: 5), takeProfitDirection: "GREATER_BID",
            comments: nil,
            envelope: OrderEnvelope(requestId: "REQ-2", accountLoginId: nil, timestamp: nil)
        )
        var r = BinaryReader(req.encode())
        #expect(try r.readInt32BE() == javaStringHashCode(WireClass.submitConditionalOrder))
        var fields: [Int16: BinaryReader] = [:]
        while let f = try readField(from: &r) { fields[f.fieldId] = f.value }
        var price = fields[4726]!
        #expect(abs(try BigDecimalCodec.decode(from: &price).doubleValue - 1.05) < 1e-9)
        var sd = fields[-19375]!; #expect(try sd.readString() == "LESS_ASK")
        var slDir = fields[27268]!; #expect(try slDir.readString() == "LESS_BID")
        var tp = fields[24693]!
        #expect(abs(try BigDecimalCodec.decode(from: &tp).doubleValue - 1.08) < 1e-9)
    }

    @Test("ExtApiOrderResponse decodes id/state and flags rejection")
    func responseDecode() throws {
        var frame = BinaryWriter()
        frame.writeInt32BE(javaStringHashCode(WireClass.extApiOrderResponse))
        writeField(&frame, fieldId: -12183) { $0.writeString("ORD-7") }
        writeField(&frame, fieldId: 24683)  { $0.writeString("POS-7") }
        writeField(&frame, fieldId: -6389)  { $0.writeString("FILLED") }
        writeField(&frame, fieldId: 17261)  { $0.writeString("REQ-9") }
        guard case .orderResponse(let resp) = try MessageDecoder.decode(frame.data) else {
            Issue.record("expected .orderResponse"); return
        }
        #expect(resp.orderId == "ORD-7")
        #expect(resp.positionId == "POS-7")
        #expect(resp.state == "FILLED")
        #expect(resp.requestId == "REQ-9")
        #expect(!resp.isRejected)

        var rej = BinaryWriter()
        rej.writeInt32BE(javaStringHashCode(WireClass.extApiOrderResponse))
        writeField(&rej, fieldId: -6389) { $0.writeString("REJECTED") }
        guard case .orderResponse(let r2) = try MessageDecoder.decode(rej.data) else {
            Issue.record("expected .orderResponse"); return
        }
        #expect(r2.isRejected)
    }

    // MARK: - ord.* order encoders (the live path) round-trip through the decoders

    @Test("Market order group encodes to a decodable OrderGroup with an OPEN/BUY order")
    func marketGroupRoundTrip() throws {
        let frame = encodeMarketOrderGroup(
            instrument: "EUR/USD", side: "BUY", amount: BigDecimalValue(1000, scale: 0),
            priceClient: BigDecimalValue(1.16, scale: 5), label: "L1",
            userId: "3602594", accountLoginId: nil, sessionId: "SID", requestId: "R1", timestamp: 1
        )
        guard case .orderGroup(let g) = try MessageDecoder.decode(frame) else {
            Issue.record("expected .orderGroup"); return
        }
        #expect(g.instrument == "EUR/USD")
        #expect(g.orders.count == 1)
        let o = g.orders[0]
        #expect(o.side == "BUY")
        #expect(o.direction == "OPEN")
        #expect(abs((o.priceClient?.doubleValue ?? 0) - 1.16) < 1e-9)
        #expect(abs((o.amount?.doubleValue ?? 0) - 1000) < 1e-6)
    }

    @Test("Pending order puts the trigger in priceStop and opens with OPEN direction")
    func pendingGroupRoundTrip() throws {
        let frame = encodePendingOrderGroup(
            instrument: "EUR/USD", side: "BUY", kind: .limit, amount: BigDecimalValue(1000, scale: 0),
            triggerPrice: BigDecimalValue(1.10, scale: 5), priceClient: BigDecimalValue(1.16, scale: 5),
            label: "L2", userId: "u", sessionId: "s", requestId: "R2", timestamp: 2
        )
        guard case .orderGroup(let g) = try MessageDecoder.decode(frame) else {
            Issue.record("expected .orderGroup"); return
        }
        let o = g.orders[0]
        #expect(o.direction == "OPEN")
        #expect(abs((o.priceStop?.doubleValue ?? 0) - 1.10) < 1e-9)   // trigger
        #expect(abs((o.priceClient?.doubleValue ?? 0) - 1.16) < 1e-9) // market
    }

    @Test("Close group carries a CLOSE order on the opposite side")
    func closeGroupRoundTrip() throws {
        let frame = encodeCloseOrderGroup(
            orderGroupId: "POS-1", instrument: "EUR/USD", positionSide: "BUY",
            amount: BigDecimalValue(1000, scale: 0), pricePosOpen: BigDecimalValue(1.15, scale: 5),
            priceClient: BigDecimalValue(1.16, scale: 5), userId: "u", sessionId: "s",
            requestId: "R3", timestamp: 3
        )
        guard case .orderGroup(let g) = try MessageDecoder.decode(frame) else {
            Issue.record("expected .orderGroup"); return
        }
        #expect(g.orderGroupId == "POS-1")
        let o = g.orders[0]
        #expect(o.direction == "CLOSE")
        #expect(o.side == "SELL")          // closing a BUY/LONG
        #expect(o.state == "CREATED")
    }

    @Test("Cancel encodes a top-level OrderMessage with state CANCELLED")
    func cancelRoundTrip() throws {
        var order = OrderMsg()
        order.orderId = "ORD-9"
        order.orderGroupId = "POS-9"
        order.instrument = "EUR/USD"
        order.side = "BUY"
        order.amount = BigDecimalValue(1000, scale: 0)
        order.priceStop = BigDecimalValue(1.10, scale: 5)
        let frame = encodeCancelOrder(order: order, userId: "u", sessionId: "s", requestId: "R4", timestamp: 4)
        guard case .order(let o) = try MessageDecoder.decode(frame) else {
            Issue.record("expected .order"); return
        }
        #expect(o.orderId == "ORD-9")
        #expect(o.state == "CANCELLED")
    }

    @Test("Enum value tables map known wire ints")
    func enumTables() {
        #expect(OrderEnums.positionSide(2342524) == "BUY")
        #expect(OrderEnums.positionSide(78875740) == "SELL")
        #expect(OrderEnums.openClose(2432586) == "OPEN")
        #expect(OrderEnums.openClose(64218584) == "CLOSE")
        #expect(OrderEnums.orderSide(66150) == "BUY")
        #expect(OrderEnums.orderState(2073796962) == "FILLED")
        #expect(OrderEnums.orderState(-1031784143) == "CANCELLED")
    }
}
