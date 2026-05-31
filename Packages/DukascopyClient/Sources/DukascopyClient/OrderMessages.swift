import Foundation

// Wire codec for positions & orders. Field IDs and enum values per PROTOCOL.md §9/§12.

public extension WireClass {
    static let orderGroupMessage = "com.dukascopy.dds3.transport.msg.ord.OrderGroupMessage"
    static let orderMessage      = "com.dukascopy.dds3.transport.msg.ord.OrderMessage"
    static let orderMessageExt   = "com.dukascopy.dds3.transport.msg.ord.OrderMessageExt"
    static let submitMarketOrder      = "com.dukascopy.dds3.transport.msg.extapi.SubmitMarketOrderRequest"
    static let submitConditionalOrder = "com.dukascopy.dds3.transport.msg.extapi.SubmitConditionalOrderRequest"
    static let submitPositionClose    = "com.dukascopy.dds3.transport.msg.extapi.SubmitPositionCloseRequest"
    static let submitOrderCancel      = "com.dukascopy.dds3.transport.msg.extapi.SubmitOrderCancelRequest"
    static let submitModifyStopLoss   = "com.dukascopy.dds3.transport.msg.extapi.SubmitModifyStopLossRequest"
    static let submitModifyTakeProfit = "com.dukascopy.dds3.transport.msg.extapi.SubmitModifyTakeProfitRequest"
    static let extApiOrderResponse    = "com.dukascopy.dds3.transport.msg.extapi.ExtApiOrderResponse"
}

// MARK: - ProtocolMessage envelope (shared by every order request)

/// The request-correlation + identity fields every order request carries.
/// `requestId` is the key we await `ExtApiOrderResponse` on.
struct OrderEnvelope: Sendable {
    var requestId: String
    var accountLoginId: String?
    var timestamp: Int64?

    func write(into w: inout BinaryWriter) {
        writeField(&w, fieldId: 17261) { $0.writeString(requestId) }
        if let accountLoginId { writeField(&w, fieldId: 9208) { $0.writeString(accountLoginId) } }
        if let timestamp { writeField(&w, fieldId: -28332) { $0.writeInt64BE(timestamp) } }
    }
}

// MARK: - Order request encoders

public struct SubmitMarketOrderRequest: Sendable {
    public var instrument: String       // "EUR/USD"
    public var side: String             // "BUY" / "SELL"
    public var label: String
    public var amount: BigDecimalValue
    public var comments: String?
    var envelope: OrderEnvelope

    public func encode() -> Data {
        var w = BinaryWriter()
        w.writeInt32BE(javaStringHashCode(WireClass.submitMarketOrder))
        writeField(&w, fieldId: 12424) { $0.writeString(instrument) }
        writeField(&w, fieldId: 6236)  { $0.writeString(side) }
        writeField(&w, fieldId: -14442) { $0.writeString(label) }
        if let comments { writeField(&w, fieldId: 3213) { $0.writeString(comments) } }
        writeField(&w, fieldId: -5158) { $0.writeBigDecimal(amount) }
        envelope.write(into: &w)
        return w.data
    }
}

public struct SubmitConditionalOrderRequest: Sendable {
    public var instrument: String
    public var side: String             // "BUY" / "SELL"
    public var label: String
    public var amount: BigDecimalValue
    public var price: BigDecimalValue        // trigger price
    public var stopDirection: String         // GREATER_BID / LESS_ASK / …
    public var slippage: BigDecimalValue?
    public var goodTillTime: String?
    public var stopLossPrice: BigDecimalValue?
    public var stopLossDirection: String?
    public var takeProfitPrice: BigDecimalValue?
    public var takeProfitDirection: String?
    public var comments: String?
    var envelope: OrderEnvelope

    public func encode() -> Data {
        var w = BinaryWriter()
        w.writeInt32BE(javaStringHashCode(WireClass.submitConditionalOrder))
        writeField(&w, fieldId: 12424) { $0.writeString(instrument) }
        writeField(&w, fieldId: 6236)  { $0.writeString(side) }
        writeField(&w, fieldId: -14442) { $0.writeString(label) }
        if let comments { writeField(&w, fieldId: 3213) { $0.writeString(comments) } }
        writeField(&w, fieldId: -5158) { $0.writeBigDecimal(amount) }
        writeField(&w, fieldId: 4726)  { $0.writeBigDecimal(price) }
        if let slippage { writeField(&w, fieldId: 22597) { $0.writeBigDecimal(slippage) } }
        writeField(&w, fieldId: -19375) { $0.writeString(stopDirection) }
        if let goodTillTime { writeField(&w, fieldId: -15959) { $0.writeString(goodTillTime) } }
        if let stopLossPrice { writeField(&w, fieldId: -9154) { $0.writeBigDecimal(stopLossPrice) } }
        if let stopLossDirection { writeField(&w, fieldId: 27268) { $0.writeString(stopLossDirection) } }
        if let takeProfitPrice { writeField(&w, fieldId: 24693) { $0.writeBigDecimal(takeProfitPrice) } }
        if let takeProfitDirection { writeField(&w, fieldId: -20837) { $0.writeString(takeProfitDirection) } }
        envelope.write(into: &w)
        return w.data
    }
}

public struct SubmitPositionCloseRequest: Sendable {
    public var positionId: String
    var envelope: OrderEnvelope

    public func encode() -> Data {
        var w = BinaryWriter()
        w.writeInt32BE(javaStringHashCode(WireClass.submitPositionClose))
        writeField(&w, fieldId: 24683) { $0.writeString(positionId) }
        envelope.write(into: &w)
        return w.data
    }
}

public struct SubmitOrderCancelRequest: Sendable {
    public var orderId: String
    var envelope: OrderEnvelope

    public func encode() -> Data {
        var w = BinaryWriter()
        w.writeInt32BE(javaStringHashCode(WireClass.submitOrderCancel))
        writeField(&w, fieldId: -12183) { $0.writeString(orderId) }
        envelope.write(into: &w)
        return w.data
    }
}

public struct SubmitModifyStopLossRequest: Sendable {
    public var orderId: String
    public var offerSide: String        // "BID" / "ASK"
    public var price: BigDecimalValue
    public var slippage: BigDecimalValue?
    var envelope: OrderEnvelope

    public func encode() -> Data {
        var w = BinaryWriter()
        w.writeInt32BE(javaStringHashCode(WireClass.submitModifyStopLoss))
        writeField(&w, fieldId: -12183) { $0.writeString(orderId) }
        writeField(&w, fieldId: 24910) { $0.writeString(offerSide) }
        writeField(&w, fieldId: 4726)  { $0.writeBigDecimal(price) }
        if let slippage { writeField(&w, fieldId: 22597) { $0.writeBigDecimal(slippage) } }
        envelope.write(into: &w)
        return w.data
    }
}

public struct SubmitModifyTakeProfitRequest: Sendable {
    public var orderId: String
    public var price: BigDecimalValue
    var envelope: OrderEnvelope

    public func encode() -> Data {
        var w = BinaryWriter()
        w.writeInt32BE(javaStringHashCode(WireClass.submitModifyTakeProfit))
        writeField(&w, fieldId: -12183) { $0.writeString(orderId) }
        writeField(&w, fieldId: 4726)  { $0.writeBigDecimal(price) }
        envelope.write(into: &w)
        return w.data
    }
}

// MARK: - ExtApiOrderResponse (server → client, order ack/state)

public struct ExtApiOrderResponse: Sendable {
    public var orderId: String?
    public var instrument: String?
    public var positionId: String?
    public var parentOrderId: String?
    public var side: String?
    public var state: String?          // "CREATED"/"FILLED"/"REJECTED"/… (plain String here)
    public var direction: String?      // "OPEN"/"CLOSE"
    public var orderType: String?
    public var label: String?
    public var price: BigDecimalValue?
    public var priceStop: BigDecimalValue?
    public var priceLimit: BigDecimalValue?
    public var amount: BigDecimalValue?
    public var notes: String?
    public var comments: String?
    public var requestId: String?

    /// True for a terminal failure the caller should surface as an error.
    public var isRejected: Bool { state == "REJECTED" || state == "ERROR" || state == "REVOKED" }

    public static func decode(from reader: inout BinaryReader) throws -> ExtApiOrderResponse {
        var m = ExtApiOrderResponse()
        while let field = try readField(from: &reader) {
            var v = field.value
            switch field.fieldId {
            case -12183: m.orderId = try v.readString()
            case 12424:  m.instrument = try v.readString()
            case 24683:  m.positionId = try v.readString()
            case 27532:  m.parentOrderId = try v.readString()
            case 6236:   m.side = try v.readString()
            case -6389:  m.state = try v.readString()
            case 5312:   m.direction = try v.readString()
            case 3793:   m.orderType = try v.readString()
            case -14442: m.label = try v.readString()
            case 4726:   m.price = try BigDecimalCodec.decode(from: &v)
            case -30914: m.priceStop = try BigDecimalCodec.decode(from: &v)
            case 8993:   m.priceLimit = try BigDecimalCodec.decode(from: &v)
            case -5158:  m.amount = try BigDecimalCodec.decode(from: &v)
            case -20818: m.notes = try v.readString()
            case 3213:   m.comments = try v.readString()
            case 17261:  m.requestId = try v.readString()
            default:     break
            }
        }
        return m
    }
}

// MARK: - Enum value tables (wire int32 → canonical string)

enum OrderEnums {
    /// `PositionSide`: a position's net direction. Mapped to the app's BUY/SELL vocab.
    static func positionSide(_ v: Int32) -> String {
        switch v {
        case 2342524:  return "BUY"   // LONG
        case 78875740: return "SELL"  // SHORT
        default:       return "UNKNOWN(\(v))"
        }
    }
    /// `PositionStatus` / `OrderDirection` (same ints): OPEN(2432586) / CLOSE(64218584).
    static func openClose(_ v: Int32) -> String {
        switch v {
        case 2432586:  return "OPEN"
        case 64218584: return "CLOSE"
        default:       return "UNKNOWN(\(v))"
        }
    }
    /// `OrderSide`: an individual order's direction.
    static func orderSide(_ v: Int32) -> String {
        switch v {
        case 66150:   return "BUY"
        case 2541394: return "SELL"
        default:      return "UNKNOWN(\(v))"
        }
    }
    /// `OrderState` lifecycle.
    static func orderState(_ v: Int32) -> String {
        switch v {
        case 1746537160: return "CREATED"
        case 35394935:   return "PENDING"
        case 907287315:  return "PROCESSING"
        case 1695619794: return "EXECUTING"
        case 2073796962: return "FILLED"
        case 174130302:  return "REJECTED"
        case -1031784143: return "CANCELLED"
        case 1818119806: return "REVOKED"
        case 66247144:   return "ERROR"
        default:         return "UNKNOWN(\(v))"
        }
    }
}

/// Enum field value = `classId(int32) + value(int32)`; returns the raw value int.
func decodeEnumInt(from reader: inout BinaryReader) throws -> Int32 {
    _ = try reader.readInt32BE()   // enum class id (ignored)
    return try reader.readInt32BE()
}

/// Decodes a `List<Message>` field value. Wire form (per `CollectionCodec` +
/// `ProtocolMessageCodec`): `collectionClassId(int32) + varLen(size) +
/// size × [ elementClassId(int32) + varLen(len) + messageClassId(int32) + fields ]`.
func decodeMessageList<T>(
    from v: inout BinaryReader,
    element: (inout BinaryReader) throws -> T
) throws -> [T] {
    _ = try v.readInt32BE()            // declared collection type (List/ArrayList)
    let size = try v.readVarLen()
    var out: [T] = []
    out.reserveCapacity(size)
    for _ in 0..<size {
        _ = try v.readInt32BE()        // element class id
        let len = try v.readVarLen()   // message byte length
        let bytes = try v.readBytes(len)
        var mr = BinaryReader(bytes)
        _ = try mr.readInt32BE()       // message class id (inside the buffer)
        out.append(try element(&mr))
    }
    return out
}

// MARK: - OrderGroupMessage (a position)

public struct OrderGroup: Sendable {
    public var orderGroupId: String?       // position id (used to close)
    public var instrument: String?         // "EUR/USD"
    public var amount: BigDecimalValue?     // net size
    public var pricePosOpen: BigDecimalValue?  // average open price
    public var side: String?               // "BUY"/"SELL" (from PositionSide)
    public var status: String?             // "OPEN"/"CLOSE"
    public var bestBid: BigDecimalValue?
    public var bestAsk: BigDecimalValue?
    public var pricePl: BigDecimalValue?    // current P/L mark price
    public var orders: [OrderMsg] = []      // constituent orders (SL/TP, ids)

    public var isOpen: Bool { status == "OPEN" }

    public static func decode(from reader: inout BinaryReader) throws -> OrderGroup {
        var m = OrderGroup()
        while let field = try readField(from: &reader) {
            var v = field.value
            switch field.fieldId {
            case 29772:  m.orderGroupId = try v.readString()
            case 12424:  m.instrument = try v.readString()
            case -5158:  m.amount = try BigDecimalCodec.decode(from: &v)
            case -27533: m.pricePosOpen = try BigDecimalCodec.decode(from: &v)
            case -25925: m.side = OrderEnums.positionSide(try decodeEnumInt(from: &v))
            case -16069: m.status = OrderEnums.openClose(try decodeEnumInt(from: &v))
            case -7721:  m.bestBid = try BigDecimalCodec.decode(from: &v)
            case -31475: m.bestAsk = try BigDecimalCodec.decode(from: &v)
            case 5455:   m.pricePl = try BigDecimalCodec.decode(from: &v)
            case -23746: m.orders = try decodeMessageList(from: &v) { try OrderMsg.decode(from: &$0) }
            default:     break
            }
        }
        return m
    }
}

// MARK: - OrderMessage / OrderMessageExt (a single order)

public struct OrderMsg: Sendable {
    public var orderId: String?
    public var orderGroupId: String?
    public var instrument: String?
    public var amount: BigDecimalValue?
    public var side: String?          // "BUY"/"SELL"
    public var direction: String?     // "OPEN"/"CLOSE"
    public var state: String?         // OrderState
    public var priceLimit: BigDecimalValue?   // take-profit
    public var priceStop: BigDecimalValue?    // stop-loss
    public var priceClient: BigDecimalValue?  // client-requested (pending entry)
    public var pricePosOpen: BigDecimalValue?

    public static func decode(from reader: inout BinaryReader) throws -> OrderMsg {
        var m = OrderMsg()
        while let field = try readField(from: &reader) {
            var v = field.value
            switch field.fieldId {
            case -12183: m.orderId = try v.readString()
            case 29772:  m.orderGroupId = try v.readString()
            case 12424:  m.instrument = try v.readString()
            case -5158:  m.amount = try BigDecimalCodec.decode(from: &v)
            case -7924:  m.side = OrderEnums.orderSide(try decodeEnumInt(from: &v))
            case -19551: m.direction = OrderEnums.openClose(try decodeEnumInt(from: &v))
            case 32505:  m.state = OrderEnums.orderState(try decodeEnumInt(from: &v))
            case 8993:   m.priceLimit = try BigDecimalCodec.decode(from: &v)
            case -30914: m.priceStop = try BigDecimalCodec.decode(from: &v)
            case 14767:  m.priceClient = try BigDecimalCodec.decode(from: &v)
            case -27533: m.pricePosOpen = try BigDecimalCodec.decode(from: &v)
            default:     break
            }
        }
        return m
    }
}
