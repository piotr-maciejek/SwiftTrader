import Foundation

// Dukascopy news/calendar wire messages (the `…msg.news` package). Field ids and types are
// taken verbatim from the decompiled `DirectInvocationHandler*` `FieldInfo(name, id, type)`
// tables; enum wire values are `javaStringHashCode(constantName)` (same scheme as orders).
// We decode the inbound CalendarEvent / NewsStoryMessage and encode a NewsSubscribeRequest
// to start the feed — mirroring the desktop client's `NewsSubscribeManager`.

enum NewsWire {
    static let newsSubscribeRequest  = "com.dukascopy.dds3.transport.msg.news.NewsSubscribeRequest"
    static let newsSubscribeResponse = "com.dukascopy.dds3.transport.msg.news.NewsSubscribeResponse"
    static let calendarEvent         = "com.dukascopy.dds3.transport.msg.news.CalendarEvent"
    static let calendarEventDetail   = "com.dukascopy.dds3.transport.msg.news.CalendarEventDetail"
    static let newsStoryMessage      = "com.dukascopy.dds3.transport.msg.news.NewsStoryMessage"
    // Enum classes
    static let subscribeRequestType  = "com.dukascopy.dds3.transport.msg.news.SubscribeRequestType"
    static let newsSource            = "com.dukascopy.dds3.transport.msg.news.NewsSource"
    static let calendarType          = "com.dukascopy.dds3.transport.msg.news.CalendarType"
}

/// A decoded economic-calendar event. Maps to the app's `NewsItem` (type CALENDAR).
public struct CalendarEventMsg: Sendable {
    public var eventId: String?
    public var country: String?
    public var eventCategory: String?
    public var organisation: String?
    public var period: String?
    public var eventDate: Int64?         // calendar day (ms)
    public var eventTimestamp: Int64?    // scheduled release time (ms)
    public var description: String?
    public var longDescription: String?
    public var details: [CalendarEventDetailMsg] = []

    public static func decode(from reader: inout BinaryReader) throws -> CalendarEventMsg {
        var m = CalendarEventMsg()
        while let field = try readField(from: &reader) {
            var v = field.value
            switch field.fieldId {
            case 4728:    m.eventId = try v.readString()
            case -31140:  m.country = try v.readString()
            case 9059:    m.eventCategory = try v.readString()
            case 20944:   m.organisation = try v.readString()
            case 20662:   m.period = try v.readString()
            case 13051:   m.eventDate = try v.readInt64BE()
            case -6950:   m.eventTimestamp = try v.readInt64BE()
            case 30606:   m.description = try v.readString()
            case 4370:    m.longDescription = try v.readString()
            case -24362:
                m.details = try decodeMessageList(from: &v) { try CalendarEventDetailMsg.decode(from: &$0) }
            default: break
            }
        }
        return m
    }
}

/// One actual/expected/previous row inside a `CalendarEventMsg`.
public struct CalendarEventDetailMsg: Sendable {
    public var detailId: String?
    public var importance: String?
    public var description: String?
    public var actual: String?
    public var delta: String?
    public var expected: String?
    public var previous: String?
    public var tag: String?

    public static func decode(from reader: inout BinaryReader) throws -> CalendarEventDetailMsg {
        var m = CalendarEventDetailMsg()
        while let field = try readField(from: &reader) {
            var v = field.value
            switch field.fieldId {
            case -23643:  m.detailId = try v.readString()
            case -19567:  m.importance = try v.readString()
            case 30606:   m.description = try v.readString()
            case 10179:   m.actual = try v.readString()
            case -27324:  m.delta = try v.readString()
            case 20398:   m.expected = try v.readString()
            case 20181:   m.previous = try v.readString()
            case 6267:    m.tag = try v.readString()
            default: break
            }
        }
        return m
    }
}

/// A decoded news story. Carries an embedded `CalendarEvent` in its `content` for
/// economic-calendar entries (per `JForexTaskManager.onNewsMessage`: a story whose
/// `content` is a CalendarEvent IS a calendar item) — otherwise it's a plain news story.
public struct NewsStoryMsg: Sendable {
    public var newsId: String?
    public var publishDate: Int64?
    public var header: String?
    public var hot: Bool = false
    public var currencies: Set<String> = []
    public var language: String?
    public var content: CalendarEventMsg?   // present → this story is a calendar event

    public static func decode(from reader: inout BinaryReader) throws -> NewsStoryMsg {
        var m = NewsStoryMsg()
        while let field = try readField(from: &reader) {
            var v = field.value
            switch field.fieldId {
            case 22063:   m.newsId = try v.readString()
            case 8599:    m.publishDate = try v.readInt64BE()
            case 10098:   m.header = try v.readString()
            case 19038:   m.hot = try v.readBoolean()
            case -25008:  m.currencies = Set(try v.readStringList())
            case 3135:    m.language = try v.readString()
            case -19477:  // content: NewsContent or (for calendar items) CalendarEvent.
                // Nested-object field = varLen(byteLength) + classId + fields (ProtocolMessageCodec).
                _ = try v.readVarLen()
                let contentClassId = try v.readInt32BE()
                if contentClassId == javaStringHashCode(NewsWire.calendarEvent) {
                    m.content = try CalendarEventMsg.decode(from: &v)
                }
            default: break
            }
        }
        return m
    }
}

/// Inbound news/calendar event surfaced by `DukascopySession.newsEvents()`. A calendar
/// event carries both the `CalendarEventMsg` (country/category/details) and the wrapping
/// story (publishDate/currencies/hot).
public enum NewsEvent: Sendable {
    case calendar(CalendarEventMsg, story: NewsStoryMsg)
    case story(NewsStoryMsg)
}

public extension BinaryWriter {
    /// Encodes a `Set<enum>` the way the Java `CollectionCodec` + `EnumCodec` do:
    /// `classId(collectionType) + varLen(size) + size × [ classId(enumFQCN) ×2 + value(int32) ]`.
    /// The enum class id appears TWICE per element — once as the collection's element class
    /// (CollectionCodec) and once inside the enum's own value (EnumCodec writes classId+value).
    /// The wire `value` is the enum constant's `getValue()`, which equals its name's hashCode.
    mutating func writeEnumSet(_ values: [(enumClass: String, name: String)], declaredType: String = WireType.setClass) {
        writeInt32BE(javaStringHashCode(declaredType))
        writeVarLen(values.count)
        for v in values {
            let classId = javaStringHashCode(v.enumClass)
            writeInt32BE(classId)                       // CollectionCodec element class id
            writeInt32BE(classId)                       // EnumCodec's own class id
            writeInt32BE(javaStringHashCode(v.name))    // enum value (== name hashCode)
        }
    }
}

/// Builds a `NewsSubscribeRequest` (requestType SUBSCRIBE) that starts the calendar/news
/// feed — mirrors `NewsSubscribeManager.subscribe`. `sources` are `NewsSource` constant
/// names (e.g. "DJ_LIVE_CALENDAR" for the economic calendar, "FXSPIDER_NEWS" for headlines).
/// `from`/`to` bound the calendar window (ms); for FXSPIDER_NEWS the client uses Long.MIN_VALUE.
/// Empty currency/category/region sets mean "everything".
public func encodeNewsSubscribeRequest(
    sources: [String], from: Int64, to: Int64, calendarType: String?,
    userId: String?, accountLoginId: String?, sessionId: String?,
    requestId: String, timestamp: Int64
) -> Data {
    var w = BinaryWriter()
    w.writeInt32BE(javaStringHashCode(NewsWire.newsSubscribeRequest))
    // requestType = SUBSCRIBE
    writeField(&w, fieldId: -14236) {
        $0.writeInt32BE(javaStringHashCode(NewsWire.subscribeRequestType))
        $0.writeInt32BE(javaStringHashCode("SUBSCRIBE"))
    }
    // sources : Set<NewsSource>
    writeField(&w, fieldId: -12220) {
        $0.writeEnumSet(sources.map { (NewsWire.newsSource, $0) })
    }
    writeField(&w, fieldId: 19708) { $0.writeInt64BE(from) }   // from
    writeField(&w, fieldId: -11466) { $0.writeInt64BE(to) }    // to
    if let calendarType {
        writeField(&w, fieldId: -7057) {
            $0.writeInt32BE(javaStringHashCode(NewsWire.calendarType))
            $0.writeInt32BE(javaStringHashCode(calendarType))
        }
    }
    // ProtocolMessage envelope.
    if let sessionId { writeField(&w, fieldId: 28132) { $0.writeString(sessionId) } }
    if let userId { writeField(&w, fieldId: -31160) { $0.writeString(userId) } }
    if let accountLoginId, !accountLoginId.isEmpty { writeField(&w, fieldId: 9208) { $0.writeString(accountLoginId) } }
    writeField(&w, fieldId: 17261) { $0.writeString(requestId) }
    writeField(&w, fieldId: -28332) { $0.writeInt64BE(timestamp) }
    return w.data
}
