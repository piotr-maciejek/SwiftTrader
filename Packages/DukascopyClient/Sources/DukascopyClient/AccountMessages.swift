import Foundation

public extension WireClass {
    static let accountInfoMessage     = "com.dukascopy.dds3.transport.msg.acc.AccountInfoMessage"
    static let accountInfoMessageInit = "com.dukascopy.dds3.transport.msg.acc.AccountInfoMessageInit"
    static let accountInfoMessageLoad = "com.dukascopy.dds3.transport.msg.acc.AccountInfoMessageLoad"
    static let packedAccountInfo      = "com.dukascopy.dds3.transport.msg.acc.PackedAccountInfoMessage"
}

public enum AccountState: String, Sendable {
    case ok = "OK"
    case marginCall = "MARGIN_CALL"
    case marginClosing = "MARGIN_CLOSING"
    case okNoMarginCall = "OK_NO_MARGIN_CALL"
    case disabled = "DISABLED"
    case blocked = "BLOCKED"
}

public struct AccountInfo: Sendable {
    public var balance: BigDecimalValue?
    public var currency: String?
    public var equity: BigDecimalValue?
    public var baseEquity: BigDecimalValue?
    public var usableMargin: BigDecimalValue?
    public var leverage: Int32?
    public var accountHash: Int32?
    public var state: String?  // enum encoded as its `toString()` name
    public var accountLoginId: String?
    public var userId: String?
    /// `equity − usableMargin`; the server doesn't transmit it directly.
    public var usedMargin: BigDecimalValue? {
        guard let equity, let usableMargin else { return nil }
        return BigDecimalCodec.subtract(equity, usableMargin)
    }

    public init() {}

    /// Decodes the field stream of an AccountInfoMessage / AccountInfoMessageInit
    /// / AccountInfoMessageLoad. Unknown field IDs are skipped (they carry the
    /// extra Init/Load-only configuration we don't use).
    public static func decode(from reader: inout BinaryReader) throws -> AccountInfo {
        var msg = AccountInfo()
        while let field = try readField(from: &reader) {
            var v = field.value
            switch field.fieldId {
            case -26894: msg.balance = try BigDecimalCodec.decode(from: &v)
            case -14690: msg.currency = try v.readString()
            case -498:   msg.equity = try BigDecimalCodec.decode(from: &v)
            case -4245:  msg.baseEquity = try BigDecimalCodec.decode(from: &v)
            case -5160:  msg.usableMargin = try BigDecimalCodec.decode(from: &v)
            case -8756:  msg.leverage = try v.readInt32BE()
            case -17381: msg.accountHash = try v.readInt32BE()
            case 24446:  msg.state = try decodeAccountState(from: &v)
            case 9208:   msg.accountLoginId = try v.readString()
            case -31160: msg.userId = try v.readString()
            default:     break  // skip unknown field's prepacked bytes
            }
        }
        return msg
    }

    /// Enum codec wire format: `classId(int32) + value(int32)`.
    private static func decodeAccountState(from reader: inout BinaryReader) throws -> String {
        _ = try reader.readInt32BE()  // enum class id
        let value = try reader.readInt32BE()
        // The mapping below is the JForex `AccountState.getValue()` table.
        switch value {
        case 2524:        return "OK"
        case 35355396:    return "MARGIN_CLOSING"
        case -1125544369: return "MARGIN_CALL"
        case 1449938324:  return "OK_NO_MARGIN_CALL"
        case 1053567612:  return "DISABLED"
        case 696544716:   return "BLOCKED"
        default:          return "UNKNOWN(\(value))"
        }
    }
}

public struct PackedAccountInfo: Sendable {
    public let account: AccountInfo
    /// Open position groups present at connect.
    public var groups: [OrderGroup] = []
    /// Individual orders present at connect (incl. pending limit/stop orders).
    public var orders: [OrderMsg] = []

    public init(account: AccountInfo, groups: [OrderGroup] = [], orders: [OrderMsg] = []) {
        self.account = account
        self.groups = groups
        self.orders = orders
    }

    /// Decodes the field stream of a PackedAccountInfoMessage. The `account`
    /// field is a nested protocol message — value bytes are
    /// `varLen(nestedLen) + classId + nested fields`. `groups`/`orders` are
    /// `List<Message>` (see `decodeMessageList`).
    public static func decode(from reader: inout BinaryReader) throws -> PackedAccountInfo {
        var account = AccountInfo()
        var groups: [OrderGroup] = []
        var orders: [OrderMsg] = []
        while let field = try readField(from: &reader) {
            var v = field.value
            switch field.fieldId {
            case -2970:
                // Nested message: skip the inner varint length prefix and the classId,
                // then decode the field stream.
                _ = try v.readVarLen()
                _ = try v.readInt32BE()  // nested classId (AccountInfoMessageInit)
                account = try AccountInfo.decode(from: &v)
            case -17942:
                groups = try decodeMessageList(from: &v) { try OrderGroup.decode(from: &$0) }
            case -23746:
                orders = try decodeMessageList(from: &v) { try OrderMsg.decode(from: &$0) }
            default:
                break
            }
        }
        return PackedAccountInfo(account: account, groups: groups, orders: orders)
    }

    /// Reconstruct an `OrderGroup` for each resting pending (limit/stop) entry. At connect these
    /// arrive as loose `orders` (grouped by `orderGroupId`), NOT as `groups` — so without this they'd
    /// be invisible until the next live order event (which never comes for an unchanged resting
    /// order). Each rebuilt group is the PENDING opening order plus its protective SL/TP CLOSE legs,
    /// matching the shape delivered incrementally when an order is placed live, so the same
    /// pending-order/SL-TP extraction works unchanged.
    public func pendingOrderGroups() -> [OrderGroup] {
        Dictionary(grouping: orders.filter { $0.orderGroupId != nil }, by: { $0.orderGroupId! })
            .compactMap { gid, os in
                guard let opening = os.first(where: { $0.direction == "OPEN" }),
                      opening.state == "PENDING" else { return nil }
                return OrderGroup(orderGroupId: gid, instrument: opening.instrument,
                                  amount: opening.amount, side: opening.side,
                                  status: "OPEN", orders: os)
            }
    }
}
