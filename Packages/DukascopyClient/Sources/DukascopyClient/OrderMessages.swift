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

public extension WireClass {
    static let orderDirectionEnum = "com.dukascopy.dds3.transport.msg.types.OrderDirection"
    static let orderSideEnum      = "com.dukascopy.dds3.transport.msg.types.OrderSide"
    static let positionSideEnum   = "com.dukascopy.dds3.transport.msg.types.PositionSide"
    static let orderStateEnum     = "com.dukascopy.dds3.transport.msg.types.OrderState"
    static let stopDirectionEnum  = "com.dukascopy.dds3.transport.msg.types.StopDirection"
}

/// Enum wire values used when ENCODING orders (inverse of the OrderEnums tables).
enum OrderEnumValue {
    static let directionOpen: Int32 = 2432586
    static let directionClose: Int32 = 64218584
    static let sideBuy: Int32 = 66150
    static let sideSell: Int32 = 2541394
    static let positionLong: Int32 = 2342524
    static let positionShort: Int32 = 78875740
    static let stateCreated: Int32 = 1746537160
    static let stateCancelled: Int32 = -1031784143
    static let statePending: Int32 = 35394935
    static let stopGreaterBid: Int32 = -1215583496
    static let stopGreaterAsk: Int32 = -1215584140
    static let stopLessBid: Int32 = -1421388489
    static let stopLessAsk: Int32 = -1421389133
}

/// Pending entry kind. The opening order's `stopDirection` is derived from side + kind:
/// BUY LIMIT → LESS_ASK, SELL LIMIT → GREATER_BID, BUY STOP → GREATER_ASK, SELL STOP → LESS_BID.
public enum PendingKind: Sendable { case limit, stop }

func entryStopDirection(side: String, kind: PendingKind) -> Int32 {
    switch (side, kind) {
    case ("BUY", .limit):  return OrderEnumValue.stopLessAsk
    case ("SELL", .limit): return OrderEnumValue.stopGreaterBid
    case ("BUY", .stop):   return OrderEnumValue.stopGreaterAsk
    default:               return OrderEnumValue.stopLessBid   // SELL stop
    }
}

/// Builds an `OrderGroupMessage` frame that places a pending LIMIT/STOP entry order:
/// the opening order carries the trigger price in `priceStop`, the current market in
/// `priceClient`, and a `stopDirection` selecting limit-vs-stop semantics.
public func encodePendingOrderGroup(
    instrument: String, side: String, kind: PendingKind, amount: BigDecimalValue,
    triggerPrice: BigDecimalValue, priceClient: BigDecimalValue, label: String,
    stopLoss: BigDecimalValue? = nil, takeProfit: BigDecimalValue? = nil,
    userId: String?, sessionId: String?, requestId: String, timestamp: Int64
) -> Data {
    var ord = BinaryWriter()
    ord.writeInt32BE(javaStringHashCode(WireClass.orderMessageExt))
    writeField(&ord, fieldId: 12424) { $0.writeString(instrument) }
    writeEnumField(&ord, fieldId: -19551, enumClass: WireClass.orderDirectionEnum, value: OrderEnumValue.directionOpen)
    writeEnumField(&ord, fieldId: -7924, enumClass: WireClass.orderSideEnum,
                   value: side == "BUY" ? OrderEnumValue.sideBuy : OrderEnumValue.sideSell)
    writeField(&ord, fieldId: -30914) { $0.writeBigDecimal(triggerPrice) }   // priceStop = trigger
    writeField(&ord, fieldId: 14767) { $0.writeBigDecimal(priceClient) }     // current market
    writeEnumField(&ord, fieldId: 19053, enumClass: WireClass.stopDirectionEnum,
                   value: entryStopDirection(side: side, kind: kind))
    if kind == .limit { writeField(&ord, fieldId: -3668) { $0.writeBigDecimal(.zero) } }  // priceTrailingLimit
    writeField(&ord, fieldId: -5158) { $0.writeBigDecimal(amount) }
    writeField(&ord, fieldId: -8548) { $0.writeString(label) }
    if let sessionId { writeField(&ord, fieldId: 28132) { $0.writeString(sessionId) } }

    var bodies = [ord.data]
    if let stopLoss {
        bodies.append(encodeProtectiveOrderBody(instrument: instrument, openingSide: side, amount: amount,
            stopPrice: stopLoss, isTakeProfit: false, label: label, sessionId: sessionId))
    }
    if let takeProfit {
        bodies.append(encodeProtectiveOrderBody(instrument: instrument, openingSide: side, amount: amount,
            stopPrice: takeProfit, isTakeProfit: true, label: label, sessionId: sessionId))
    }

    var w = BinaryWriter()
    w.writeInt32BE(javaStringHashCode(WireClass.orderGroupMessage))
    writeField(&w, fieldId: 12424) { $0.writeString(instrument) }
    if let userId { writeField(&w, fieldId: -31160) { $0.writeString(userId) } }
    writeField(&w, fieldId: 17261) { $0.writeString(requestId) }
    writeField(&w, fieldId: -28332) { $0.writeInt64BE(timestamp) }
    writeMessageListField(&w, fieldId: -23746, elementClass: WireClass.orderMessageExt, bodies: bodies)
    return w.data
}

/// Writes an enum field: `int16 fieldId + int32 len + [enumClassId(int32) + value(int32)]`.
func writeEnumField(_ w: inout BinaryWriter, fieldId: Int16, enumClass: String, value: Int32) {
    writeField(&w, fieldId: fieldId) { sub in
        sub.writeInt32BE(javaStringHashCode(enumClass))
        sub.writeInt32BE(value)
    }
}

/// Writes a `List<Message>` field value from N message `bodies` (each already
/// beginning with its classId), matching `decodeMessageList`.
func writeMessageListField(_ w: inout BinaryWriter, fieldId: Int16, elementClass: String, bodies: [Data]) {
    writeField(&w, fieldId: fieldId) { sub in
        sub.writeInt32BE(javaStringHashCode(WireType.arrayListClass))
        sub.writeVarLen(bodies.count)
        for body in bodies {
            sub.writeInt32BE(javaStringHashCode(elementClass))   // element class id
            sub.writeVarLen(body.count)
            sub.writeBytes(body)
        }
    }
}

/// Body of a protective SL/TP CLOSE order attached to a submit group
/// (per `OrderUtils.addDefaultStopLossAndTakeProfitToMarketGroup`). `openingSide`
/// is the entry order's side; the protective order takes the opposite side and a
/// `stopDirection` chosen so the stop triggers on the correct side of the market.
func encodeProtectiveOrderBody(
    instrument: String, openingSide: String, amount: BigDecimalValue,
    stopPrice: BigDecimalValue, isTakeProfit: Bool, label: String, sessionId: String?
) -> Data {
    let closeSideBuy = openingSide != "BUY"
    // SL: BUY→LESS_BID, SELL→GREATER_ASK.  TP: BUY→GREATER_BID, SELL→LESS_ASK.
    let stopDir: Int32
    if openingSide == "BUY" {
        stopDir = isTakeProfit ? OrderEnumValue.stopGreaterBid : OrderEnumValue.stopLessBid
    } else {
        stopDir = isTakeProfit ? OrderEnumValue.stopLessAsk : OrderEnumValue.stopGreaterAsk
    }
    var w = BinaryWriter()
    w.writeInt32BE(javaStringHashCode(WireClass.orderMessageExt))
    writeField(&w, fieldId: 12424) { $0.writeString(instrument) }
    writeEnumField(&w, fieldId: -19551, enumClass: WireClass.orderDirectionEnum, value: OrderEnumValue.directionClose)
    writeEnumField(&w, fieldId: -7924, enumClass: WireClass.orderSideEnum,
                   value: closeSideBuy ? OrderEnumValue.sideBuy : OrderEnumValue.sideSell)
    writeField(&w, fieldId: -5158) { $0.writeBigDecimal(amount) }       // same size as the entry
    writeField(&w, fieldId: -30914) { $0.writeBigDecimal(stopPrice) }   // priceStop = SL/TP level
    writeEnumField(&w, fieldId: 19053, enumClass: WireClass.stopDirectionEnum, value: stopDir)
    if isTakeProfit { writeField(&w, fieldId: -3668) { $0.writeBigDecimal(.zero) } }  // priceTrailingLimit
    writeField(&w, fieldId: -8548) { $0.writeString(label) }
    if let sessionId { writeField(&w, fieldId: 28132) { $0.writeString(sessionId) } }
    return w.data
}

/// Builds an `OrderGroupMessage` frame that submits a MARKET order — the path the
/// desktop client uses (`OrderEntryAction` → `controlRequest`): a group carrying one
/// opening `OrderMessageExt` (direction OPEN, side, client price, amount, label).
public func encodeMarketOrderGroup(
    instrument: String, side: String, amount: BigDecimalValue, priceClient: BigDecimalValue,
    label: String, stopLoss: BigDecimalValue? = nil, takeProfit: BigDecimalValue? = nil,
    userId: String?, accountLoginId: String?, sessionId: String?,
    requestId: String, timestamp: Int64
) -> Data {
    // Opening order body = classId + fields.
    var ord = BinaryWriter()
    ord.writeInt32BE(javaStringHashCode(WireClass.orderMessageExt))
    writeField(&ord, fieldId: 12424) { $0.writeString(instrument) }
    writeEnumField(&ord, fieldId: -19551, enumClass: WireClass.orderDirectionEnum, value: OrderEnumValue.directionOpen)
    writeEnumField(&ord, fieldId: -7924, enumClass: WireClass.orderSideEnum,
                   value: side == "BUY" ? OrderEnumValue.sideBuy : OrderEnumValue.sideSell)
    writeField(&ord, fieldId: 14767) { $0.writeBigDecimal(priceClient) }
    writeField(&ord, fieldId: -5158) { $0.writeBigDecimal(amount) }
    writeField(&ord, fieldId: -8548) { $0.writeString(label) }
    if let sessionId { writeField(&ord, fieldId: 28132) { $0.writeString(sessionId) } }   // security info

    var bodies = [ord.data]
    if let stopLoss {
        bodies.append(encodeProtectiveOrderBody(instrument: instrument, openingSide: side, amount: amount,
            stopPrice: stopLoss, isTakeProfit: false, label: label, sessionId: sessionId))
    }
    if let takeProfit {
        bodies.append(encodeProtectiveOrderBody(instrument: instrument, openingSide: side, amount: amount,
            stopPrice: takeProfit, isTakeProfit: true, label: label, sessionId: sessionId))
    }

    var w = BinaryWriter()
    w.writeInt32BE(javaStringHashCode(WireClass.orderGroupMessage))
    writeField(&w, fieldId: 12424) { $0.writeString(instrument) }
    if let userId { writeField(&w, fieldId: -31160) { $0.writeString(userId) } }
    if let accountLoginId, !accountLoginId.isEmpty { writeField(&w, fieldId: 9208) { $0.writeString(accountLoginId) } }
    writeField(&w, fieldId: 17261) { $0.writeString(requestId) }
    writeField(&w, fieldId: -28332) { $0.writeInt64BE(timestamp) }
    writeMessageListField(&w, fieldId: -23746, elementClass: WireClass.orderMessageExt, bodies: bodies)
    return w.data
}

/// Builds an `OrderGroupMessage` frame that CLOSES a position: the same group id with
/// `amount = 0` (per `OrderMessageUtils.prepareGroupForClose`).
/// Builds an `OrderGroupMessage` frame that CLOSES a position — the position group
/// carrying one nested CLOSE order (opposite side, state CREATED, current price),
/// per `OrderGroupCloseAction` + `ProtocolUtils.createPositionClosingOrder`.
/// `positionSide` is the open position's side ("BUY"/"SELL"); the closing order
/// takes the opposite side.
public func encodeCloseOrderGroup(
    orderGroupId: String, instrument: String, positionSide: String, amount: BigDecimalValue,
    pricePosOpen: BigDecimalValue?, priceClient: BigDecimalValue,
    userId: String?, sessionId: String?, requestId: String, timestamp: Int64
) -> Data {
    let closeSideBuy = positionSide != "BUY"   // close a LONG by SELL, a SHORT by BUY

    // Closing order body = classId + fields.
    var ord = BinaryWriter()
    ord.writeInt32BE(javaStringHashCode(WireClass.orderMessageExt))
    writeField(&ord, fieldId: 12424) { $0.writeString(instrument) }
    writeField(&ord, fieldId: 29772) { $0.writeString(orderGroupId) }
    writeEnumField(&ord, fieldId: -19551, enumClass: WireClass.orderDirectionEnum, value: OrderEnumValue.directionClose)
    writeEnumField(&ord, fieldId: -7924, enumClass: WireClass.orderSideEnum,
                   value: closeSideBuy ? OrderEnumValue.sideBuy : OrderEnumValue.sideSell)
    writeEnumField(&ord, fieldId: 32505, enumClass: WireClass.orderStateEnum, value: OrderEnumValue.stateCreated)
    writeField(&ord, fieldId: 14767) { $0.writeBigDecimal(priceClient) }
    writeField(&ord, fieldId: -5158) { $0.writeBigDecimal(amount) }
    if let sessionId { writeField(&ord, fieldId: 28132) { $0.writeString(sessionId) } }

    var w = BinaryWriter()
    w.writeInt32BE(javaStringHashCode(WireClass.orderGroupMessage))
    writeField(&w, fieldId: 29772) { $0.writeString(orderGroupId) }
    writeField(&w, fieldId: 12424) { $0.writeString(instrument) }
    writeEnumField(&w, fieldId: -25925, enumClass: WireClass.positionSideEnum,
                   value: positionSide == "BUY" ? OrderEnumValue.positionLong : OrderEnumValue.positionShort)
    writeField(&w, fieldId: -5158) { $0.writeBigDecimal(amount) }
    if let pricePosOpen { writeField(&w, fieldId: -27533) { $0.writeBigDecimal(pricePosOpen) } }
    if let userId { writeField(&w, fieldId: -31160) { $0.writeString(userId) } }
    writeField(&w, fieldId: 17261) { $0.writeString(requestId) }
    writeField(&w, fieldId: -28332) { $0.writeInt64BE(timestamp) }
    writeMessageListField(&w, fieldId: -23746, elementClass: WireClass.orderMessageExt, bodies: [ord.data])
    return w.data
}

/// Builds a top-level `OrderMessage` that CANCELS a pending order — a copy of the
/// pending order with `state = CANCELLED` (per `CancelOrderAction`). Sent directly,
/// not wrapped in a group.
public func encodeCancelOrder(
    order: OrderMsg, userId: String?, sessionId: String?, requestId: String, timestamp: Int64
) -> Data {
    var w = BinaryWriter()
    w.writeInt32BE(javaStringHashCode(WireClass.orderMessageExt))
    if let oid = order.orderId { writeField(&w, fieldId: -12183) { $0.writeString(oid) } }
    if let gid = order.orderGroupId { writeField(&w, fieldId: 29772) { $0.writeString(gid) } }
    if let inst = order.instrument { writeField(&w, fieldId: 12424) { $0.writeString(inst) } }
    if let side = order.side {
        writeEnumField(&w, fieldId: -7924, enumClass: WireClass.orderSideEnum,
                       value: side == "BUY" ? OrderEnumValue.sideBuy : OrderEnumValue.sideSell)
    }
    if let amt = order.amount { writeField(&w, fieldId: -5158) { $0.writeBigDecimal(amt) } }
    if let ps = order.priceStop { writeField(&w, fieldId: -30914) { $0.writeBigDecimal(ps) } }
    writeEnumField(&w, fieldId: 32505, enumClass: WireClass.orderStateEnum, value: OrderEnumValue.stateCancelled)
    if let sessionId { writeField(&w, fieldId: 28132) { $0.writeString(sessionId) } }
    if let userId { writeField(&w, fieldId: -31160) { $0.writeString(userId) } }
    writeField(&w, fieldId: 17261) { $0.writeString(requestId) }
    writeField(&w, fieldId: -28332) { $0.writeInt64BE(timestamp) }
    return w.data
}

/// Builds a top-level `OrderMessageExt` that CHANGES or ADDS a protective SL/TP order
/// on an existing position or pending entry — the desktop client's
/// `PlatformOrderImpl.setStopLossPrice` / `setTakeProfitPrice` path. Sent directly (not
/// wrapped in a group); the server amends/creates the protective CLOSE order inside the
/// group identified by `orderGroupId`.
///
/// `existingProtectiveOrderId` set → AMEND that protective order (`state = PENDING`).
/// `existingProtectiveOrderId` nil → CREATE a new one (`state = CREATED`).
/// To REMOVE a protective order, use `encodeCancelOrder` on it instead.
public func encodeModifyProtectiveOrder(
    existingProtectiveOrderId: String?, orderGroupId: String,
    instrument: String, positionSide: String, amount: BigDecimalValue,
    newPrice: BigDecimalValue, isTakeProfit: Bool,
    userId: String?, sessionId: String?, requestId: String, timestamp: Int64
) -> Data {
    // Protective order is the opposite side of the position, with a stopDirection chosen
    // so it triggers on the correct side of the market (same rules as the submit path).
    let closeSideBuy = positionSide != "BUY"
    let stopDir: Int32
    if positionSide == "BUY" {
        stopDir = isTakeProfit ? OrderEnumValue.stopGreaterBid : OrderEnumValue.stopLessBid
    } else {
        stopDir = isTakeProfit ? OrderEnumValue.stopLessAsk : OrderEnumValue.stopGreaterAsk
    }
    var w = BinaryWriter()
    w.writeInt32BE(javaStringHashCode(WireClass.orderMessageExt))
    if let existingProtectiveOrderId {
        writeField(&w, fieldId: -12183) { $0.writeString(existingProtectiveOrderId) }
    }
    writeField(&w, fieldId: 29772) { $0.writeString(orderGroupId) }
    writeField(&w, fieldId: 12424) { $0.writeString(instrument) }
    writeEnumField(&w, fieldId: -19551, enumClass: WireClass.orderDirectionEnum, value: OrderEnumValue.directionClose)
    writeEnumField(&w, fieldId: -7924, enumClass: WireClass.orderSideEnum,
                   value: closeSideBuy ? OrderEnumValue.sideBuy : OrderEnumValue.sideSell)
    writeField(&w, fieldId: -5158) { $0.writeBigDecimal(amount) }
    writeField(&w, fieldId: -30914) { $0.writeBigDecimal(newPrice) }   // priceStop = new SL/TP level
    writeEnumField(&w, fieldId: 19053, enumClass: WireClass.stopDirectionEnum, value: stopDir)
    if isTakeProfit { writeField(&w, fieldId: -3668) { $0.writeBigDecimal(.zero) } }  // priceTrailingLimit
    writeEnumField(&w, fieldId: 32505, enumClass: WireClass.orderStateEnum,
                   value: existingProtectiveOrderId != nil ? OrderEnumValue.statePending : OrderEnumValue.stateCreated)
    if let sessionId { writeField(&w, fieldId: 28132) { $0.writeString(sessionId) } }
    if let userId { writeField(&w, fieldId: -31160) { $0.writeString(userId) } }
    writeField(&w, fieldId: 17261) { $0.writeString(requestId) }
    writeField(&w, fieldId: -28332) { $0.writeInt64BE(timestamp) }
    return w.data
}

/// Amends the ENTRY/trigger price of a resting pending (limit/stop) entry order in place. Mirrors the
/// opening-order body of `encodePendingOrderGroup` (the same OPEN-direction fields), but as a top-level
/// `OrderMessageExt` carrying the existing `orderId` + `state = PENDING` — the amend marker, exactly as
/// `encodeModifyProtectiveOrder` distinguishes amend from create. Only the price moves; the order kind
/// (limit/stop) is preserved by recomputing `stopDirection` from side + kind.
public func encodeModifyPendingEntryOrder(
    orderId: String, orderGroupId: String, instrument: String, side: String, kind: PendingKind,
    amount: BigDecimalValue, newTriggerPrice: BigDecimalValue, priceClient: BigDecimalValue,
    userId: String?, sessionId: String?, requestId: String, timestamp: Int64
) -> Data {
    var w = BinaryWriter()
    w.writeInt32BE(javaStringHashCode(WireClass.orderMessageExt))
    writeField(&w, fieldId: -12183) { $0.writeString(orderId) }        // existing entry order → amend
    writeField(&w, fieldId: 29772) { $0.writeString(orderGroupId) }
    writeField(&w, fieldId: 12424) { $0.writeString(instrument) }
    writeEnumField(&w, fieldId: -19551, enumClass: WireClass.orderDirectionEnum, value: OrderEnumValue.directionOpen)
    writeEnumField(&w, fieldId: -7924, enumClass: WireClass.orderSideEnum,
                   value: side == "BUY" ? OrderEnumValue.sideBuy : OrderEnumValue.sideSell)
    writeField(&w, fieldId: -30914) { $0.writeBigDecimal(newTriggerPrice) }  // priceStop = new trigger
    writeField(&w, fieldId: 14767) { $0.writeBigDecimal(priceClient) }       // current market
    writeEnumField(&w, fieldId: 19053, enumClass: WireClass.stopDirectionEnum,
                   value: entryStopDirection(side: side, kind: kind))
    if kind == .limit { writeField(&w, fieldId: -3668) { $0.writeBigDecimal(.zero) } }  // priceTrailingLimit
    writeField(&w, fieldId: -5158) { $0.writeBigDecimal(amount) }
    writeEnumField(&w, fieldId: 32505, enumClass: WireClass.orderStateEnum, value: OrderEnumValue.statePending)
    if let sessionId { writeField(&w, fieldId: 28132) { $0.writeString(sessionId) } }
    if let userId { writeField(&w, fieldId: -31160) { $0.writeString(userId) } }
    writeField(&w, fieldId: 17261) { $0.writeString(requestId) }
    writeField(&w, fieldId: -28332) { $0.writeInt64BE(timestamp) }
    return w.data
}

/// Inbound order/position events surfaced by `DukascopySession.orderEvents()`.
public enum OrderEvent: Sendable {
    case response(ExtApiOrderResponse)   // submit/close/modify ack or state change
    case group(OrderGroup)               // live position update
    case order(OrderMsg)                 // live single-order update
}

// MARK: - extapi order requests (SUPERSEDED — not used by the live path)
//
// These `extapi.Submit*Request` messages are the external-API gateway's order
// protocol. The Dukascopy DESKTOP server silently ignores them; verified on demo
// (2026-06-01). The working order path is the `ord.OrderGroupMessage` one the
// desktop client uses — see `encodeMarketOrderGroup` / `encodePendingOrderGroup` /
// `encodeCloseOrderGroup` / `encodeCancelOrder` and the `DukascopySession.submit*`
// methods. These encoders are kept only as documented reference + their unit tests.

/// The request-correlation + identity fields every extapi order request carries.
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
    /// `StopDirection` — the side/direction a stop or limit triggers on.
    static func stopDirection(_ v: Int32) -> String {
        switch v {
        case -1215583496: return "GREATER_BID"
        case -1215584140: return "GREATER_ASK"
        case -1421388489: return "LESS_BID"
        case -1421389133: return "LESS_ASK"
        default:          return "UNKNOWN(\(v))"
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
    public var stopDirection: String?         // GREATER_BID/LESS_ASK/… (distinguishes SL/TP, limit/stop)

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
            case 19053:  m.stopDirection = OrderEnums.stopDirection(try decodeEnumInt(from: &v))
            default:     break
            }
        }
        return m
    }
}
