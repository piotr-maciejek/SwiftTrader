import Foundation

/// Fully-qualified class names whose hashCode is the wire `classId`.
public enum WireClass {
    public static let haloRequest    = "com.dukascopy.dds4.transport.msg.system.HaloRequestMessage"
    public static let haloResponse   = "com.dukascopy.dds4.transport.msg.system.HaloResponseMessage"
    public static let loginRequest   = "com.dukascopy.dds4.transport.msg.system.LoginRequestMessage"
    public static let okResponse     = "com.dukascopy.dds4.transport.msg.system.OkResponseMessage"
    public static let errorResponse  = "com.dukascopy.dds4.transport.msg.system.ErrorResponseMessage"
    public static let pingRequest    = "com.dukascopy.dds4.transport.msg.system.PingRequestMessage"
    public static let pingResponse   = "com.dukascopy.dds4.transport.msg.system.PingResponseMessage"
}

// MARK: - HaloRequest

public struct HaloRequest: Sendable {
    public var useragent: String?
    public var pingable: Bool = true
    public var secondaryConnectionDisabled: Bool? = true
    public var secondaryConnectionMessagesTTL: Int64? = 0
    public var sessionName: String?
    public var udpSupportedByClient: Bool = false

    // ProtocolMessage envelope fields (all nullable, all omitted by default)
    public var synchRequestId: Int64?
    public var userId: String?
    public var requestId: String?
    public var accountLoginId: String?
    public var sourceNode: String?
    public var sourceServiceType: String?
    public var timestamp: Int64?
    public var counter: Int64?

    public init() {}

    public func encode() -> Data {
        var w = BinaryWriter()
        w.writeInt32BE(javaStringHashCode(WireClass.haloRequest))

        if let useragent {
            writeField(&w, fieldId: -16397) { sub in sub.writeString(useragent) }
        }
        writeField(&w, fieldId: -31538) { sub in sub.writeBoolean(pingable) }
        if let secondaryConnectionDisabled {
            writeField(&w, fieldId: 13053) { sub in sub.writeBoolean(secondaryConnectionDisabled) }
        }
        if let secondaryConnectionMessagesTTL {
            writeField(&w, fieldId: -14514) { sub in sub.writeInt64BE(secondaryConnectionMessagesTTL) }
        }
        if let sessionName {
            writeField(&w, fieldId: 28903) { sub in sub.writeString(sessionName) }
        }
        writeField(&w, fieldId: 27324) { sub in sub.writeBoolean(udpSupportedByClient) }

        // Envelope
        if let synchRequestId  { writeField(&w, fieldId: -29489) { sub in sub.writeInt64BE(synchRequestId) } }
        if let userId          { writeField(&w, fieldId: -31160) { sub in sub.writeString(userId) } }
        if let requestId       { writeField(&w, fieldId:  17261) { sub in sub.writeString(requestId) } }
        if let accountLoginId  { writeField(&w, fieldId:   9208) { sub in sub.writeString(accountLoginId) } }
        if let sourceNode      { writeField(&w, fieldId:  15729) { sub in sub.writeString(sourceNode) } }
        if let sourceServiceType { writeField(&w, fieldId: -23478) { sub in sub.writeString(sourceServiceType) } }
        if let timestamp       { writeField(&w, fieldId: -28332) { sub in sub.writeInt64BE(timestamp) } }
        if let counter         { writeField(&w, fieldId: -23568) { sub in sub.writeInt64BE(counter) } }

        return w.data
    }
}

// MARK: - HaloResponse

public struct HaloResponse: Sendable {
    public var challenge: String?
    public var sessionId: String?
    public var udpSupportedByServer: Bool?

    public var synchRequestId: Int64?
    public var userId: String?
    public var requestId: String?
    public var accountLoginId: String?
    public var sourceNode: String?
    public var sourceServiceType: String?
    public var timestamp: Int64?
    public var counter: Int64?

    public init() {}

    public static func decode(from reader: inout BinaryReader) throws -> HaloResponse {
        var msg = HaloResponse()
        while let field = try readField(from: &reader) {
            var v = field.value
            switch field.fieldId {
            case -3004:  msg.challenge = try v.readString()
            case 28132:  msg.sessionId = try v.readString()
            case -11686: msg.udpSupportedByServer = try v.readBoolean()
            case -29489: msg.synchRequestId = try v.readInt64BE()
            case -31160: msg.userId = try v.readString()
            case 17261:  msg.requestId = try v.readString()
            case 9208:   msg.accountLoginId = try v.readString()
            case 15729:  msg.sourceNode = try v.readString()
            case -23478: msg.sourceServiceType = try v.readString()
            case -28332: msg.timestamp = try v.readInt64BE()
            case -23568: msg.counter = try v.readInt64BE()
            default: break  // unknown field — skip (length-prefixed, already consumed by readField)
            }
        }
        return msg
    }
}

// MARK: - LoginRequest

public struct LoginRequest: Sendable {
    public var mode: Int32?
    public var username: String
    public var ticket: String
    public var sessionId: String?

    public var synchRequestId: Int64?
    public var requestId: String?
    public var timestamp: Int64?

    public init(username: String, ticket: String, sessionId: String?) {
        self.username = username
        self.ticket = ticket
        self.sessionId = sessionId
    }

    public func encode() -> Data {
        var w = BinaryWriter()
        w.writeInt32BE(javaStringHashCode(WireClass.loginRequest))

        if let mode { writeField(&w, fieldId: 23971) { sub in sub.writeInt32BE(mode) } }
        writeField(&w, fieldId: -10988) { sub in sub.writeString(username) }
        writeField(&w, fieldId: -18036) { sub in sub.writeString(ticket) }
        if let sessionId { writeField(&w, fieldId: 28132) { sub in sub.writeString(sessionId) } }

        if let synchRequestId { writeField(&w, fieldId: -29489) { sub in sub.writeInt64BE(synchRequestId) } }
        if let requestId      { writeField(&w, fieldId:  17261) { sub in sub.writeString(requestId) } }
        if let timestamp      { writeField(&w, fieldId: -28332) { sub in sub.writeInt64BE(timestamp) } }

        return w.data
    }
}

// MARK: - OkResponse

public struct OkResponse: Sendable {
    public var synchRequestId: Int64?
    public var requestId: String?
    public var timestamp: Int64?
    public init() {}

    public static func decode(from reader: inout BinaryReader) throws -> OkResponse {
        var msg = OkResponse()
        while let field = try readField(from: &reader) {
            var v = field.value
            switch field.fieldId {
            case -29489: msg.synchRequestId = try v.readInt64BE()
            case 17261:  msg.requestId = try v.readString()
            case -28332: msg.timestamp = try v.readInt64BE()
            default: break
            }
        }
        return msg
    }
}

// MARK: - ErrorResponse

public struct ErrorResponse: Sendable, Error, CustomStringConvertible {
    public var reason: String?
    public var fatal: Bool?
    public var sessionId: String?

    public init() {}

    public static func decode(from reader: inout BinaryReader) throws -> ErrorResponse {
        var msg = ErrorResponse()
        while let field = try readField(from: &reader) {
            var v = field.value
            switch field.fieldId {
            case -19257: msg.reason = try v.readString()
            case 31707:  msg.fatal = try v.readBoolean()
            case 28132:  msg.sessionId = try v.readString()
            default: break
            }
        }
        return msg
    }

    public var description: String {
        "ErrorResponse(reason=\(reason ?? "nil"), fatal=\(fatal.map(String.init) ?? "nil"))"
    }
}

// MARK: - Dispatch

public enum InboundMessage: Sendable {
    case halo(HaloResponse)
    case ok(OkResponse)
    case error(ErrorResponse)
    case currencyMarket(CurrencyMarket)
    case heartbeatRequest(HeartbeatRequest)
    case packedAccountInfo(PackedAccountInfo)
    case candleHistoryGroup(CandleHistoryGroup)
    case unknown(classId: Int32, body: Data)
}

public enum MessageDecoder {
    /// Decodes the message header (classId) and dispatches to the matching type.
    public static func decode(_ payload: Data) throws -> InboundMessage {
        var reader = BinaryReader(payload)
        let classId = try reader.readInt32BE()
        var fields = reader
        switch classId {
        case javaStringHashCode(WireClass.haloResponse):
            return .halo(try HaloResponse.decode(from: &fields))
        case javaStringHashCode(WireClass.okResponse):
            return .ok(try OkResponse.decode(from: &fields))
        case javaStringHashCode(WireClass.errorResponse):
            return .error(try ErrorResponse.decode(from: &fields))
        case javaStringHashCode(WireClass.currencyMarket):
            return .currencyMarket(try CurrencyMarket.decode(from: &fields))
        case javaStringHashCode(WireClass.heartbeatRequest):
            return .heartbeatRequest(try HeartbeatRequest.decode(from: &fields))
        case javaStringHashCode(WireClass.packedAccountInfo):
            return .packedAccountInfo(try PackedAccountInfo.decode(from: &fields))
        case javaStringHashCode(WireClass.candleHistoryGroup):
            return .candleHistoryGroup(try CandleHistoryGroup.decode(from: &fields))
        default:
            let remaining = try fields.readBytes(fields.remaining)
            return .unknown(classId: classId, body: remaining)
        }
    }
}
