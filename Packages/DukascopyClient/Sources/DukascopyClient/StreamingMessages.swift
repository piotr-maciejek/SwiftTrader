import Foundation

public extension WireClass {
    static let initRequest      = "com.dukascopy.dds3.transport.msg.ddsApi.InitRequestMessage"
    static let quoteSubscribe   = "com.dukascopy.dds3.transport.msg.feeder.QuoteSubscribeRequestMessage"
    static let quoteSubscribeResp = "com.dukascopy.dds3.transport.msg.feeder.QuoteSubscriptionResponseMessage"
    static let currencyMarket   = "com.dukascopy.dds4.transport.msg.system.CurrencyMarket"
    static let heartbeatRequest = "com.dukascopy.dds4.transport.msg.system.HeartbeatRequestMessage"
    static let heartbeatOk      = "com.dukascopy.dds4.transport.msg.system.HeartbeatOkResponseMessage"
}

// MARK: - InitRequest (fire-and-forget)

public struct InitRequest: Sendable {
    public var sendGroups: Bool = true
    public var sendPacked: Bool = true
    public var sendSettlementPrices: Bool = true
    public var userIdList: Set<String> = []
    public var sessionId: String?
    public var requestId: String?
    public var timestamp: Int64?
    public init() {}

    public func encode() -> Data {
        var w = BinaryWriter()
        w.writeInt32BE(javaStringHashCode(WireClass.initRequest))
        writeField(&w, fieldId: 7369)  { sub in sub.writeBoolean(sendGroups) }
        writeField(&w, fieldId: -13069) { sub in sub.writeBoolean(sendPacked) }
        writeField(&w, fieldId: 16406) { sub in sub.writeBoolean(sendSettlementPrices) }
        if !userIdList.isEmpty {
            writeField(&w, fieldId: 4758) { sub in sub.writeStringSet(userIdList) }
        }
        if let sessionId { writeField(&w, fieldId: 28132) { sub in sub.writeString(sessionId) } }
        if let requestId { writeField(&w, fieldId: 17261) { sub in sub.writeString(requestId) } }
        if let timestamp { writeField(&w, fieldId: -28332) { sub in sub.writeInt64BE(timestamp) } }
        return w.data
    }
}

// MARK: - QuoteSubscribeRequest

public struct QuoteSubscribeRequest: Sendable {
    public var topOfBook: Bool = true
    public var instruments: Set<String>
    public var sources: Set<String> = []
    public var sendFokAmounts: Bool = false
    public var needFirstTimes: Bool = false
    public var subscribeOnSplits: Bool = false
    public var requestId: String?
    public var timestamp: Int64?

    public init(instruments: Set<String>) {
        self.instruments = instruments
    }

    public func encode() -> Data {
        var w = BinaryWriter()
        w.writeInt32BE(javaStringHashCode(WireClass.quoteSubscribe))
        writeField(&w, fieldId: -30563) { sub in sub.writeBoolean(topOfBook) }
        writeField(&w, fieldId: -10266) { sub in sub.writeStringSet(instruments) }
        if !sources.isEmpty {
            writeField(&w, fieldId: -12220) { sub in sub.writeStringSet(sources) }
        }
        writeField(&w, fieldId: -6652)  { sub in sub.writeBoolean(sendFokAmounts) }
        writeField(&w, fieldId: 15839)  { sub in sub.writeBoolean(needFirstTimes) }
        writeField(&w, fieldId: 28892)  { sub in sub.writeBoolean(subscribeOnSplits) }
        if let requestId { writeField(&w, fieldId: 17261) { sub in sub.writeString(requestId) } }
        if let timestamp { writeField(&w, fieldId: -28332) { sub in sub.writeInt64BE(timestamp) } }
        return w.data
    }
}

// MARK: - HeartbeatRequest / HeartbeatOkResponse

public struct HeartbeatRequest: Sendable {
    public var requestTime: Int64?
    public var requestId: String?
    public var synchRequestId: Int64?

    public init() {}

    public init(requestTime: Int64, requestId: String? = nil, synchRequestId: Int64? = nil) {
        self.requestTime = requestTime
        self.requestId = requestId
        self.synchRequestId = synchRequestId
    }

    public func encode() -> Data {
        var w = BinaryWriter()
        w.writeInt32BE(javaStringHashCode(WireClass.heartbeatRequest))
        if let requestTime { writeField(&w, fieldId: -22301) { sub in sub.writeInt64BE(requestTime) } }
        if let requestId { writeField(&w, fieldId: 17261) { sub in sub.writeString(requestId) } }
        if let synchRequestId { writeField(&w, fieldId: -29489) { sub in sub.writeInt64BE(synchRequestId) } }
        return w.data
    }

    public static func decode(from reader: inout BinaryReader) throws -> HeartbeatRequest {
        var msg = HeartbeatRequest()
        while let field = try readField(from: &reader) {
            var v = field.value
            switch field.fieldId {
            case -22301: msg.requestTime = try v.readInt64BE()
            case 17261:  msg.requestId = try v.readString()
            case -29489: msg.synchRequestId = try v.readInt64BE()
            default: break
            }
        }
        return msg
    }
}

public struct HeartbeatOkResponse: Sendable {
    public var requestTime: Int64
    public var receiveTime: Int64
    public var socketWriteInterval: Int64?
    public var synchRequestId: Int64?

    public init(
        requestTime: Int64, receiveTime: Int64,
        socketWriteInterval: Int64? = nil, synchRequestId: Int64? = nil
    ) {
        self.requestTime = requestTime
        self.receiveTime = receiveTime
        self.socketWriteInterval = socketWriteInterval
        self.synchRequestId = synchRequestId
    }

    public func encode() -> Data {
        var w = BinaryWriter()
        w.writeInt32BE(javaStringHashCode(WireClass.heartbeatOk))
        writeField(&w, fieldId: -22301) { sub in sub.writeInt64BE(requestTime) }
        writeField(&w, fieldId: -17841) { sub in sub.writeInt64BE(receiveTime) }
        if let socketWriteInterval {
            writeField(&w, fieldId: -1189) { sub in sub.writeInt64BE(socketWriteInterval) }
        }
        // The server correlates its heartbeat by synchRequestId; the reply must echo it
        // back or the server treats the heartbeat as unanswered and drops the socket.
        if let synchRequestId { writeField(&w, fieldId: -29489) { sub in sub.writeInt64BE(synchRequestId) } }
        return w.data
    }
}

// MARK: - CurrencyOffer (top-of-book extraction only)

public struct CurrencyOffer: Sendable {
    public let price: BigDecimalValue
    public let amount: BigDecimalValue
    public let fokAmount: BigDecimalValue
}

// MARK: - CurrencyMarket (custom codec, not generic field-by-field)

public struct CurrencyMarket: Sendable {
    public let instrument: String  // primary + "/" + secondary
    public let creationTimestampMillis: Int64
    public let indicative: Bool
    public let asks: [CurrencyOffer]
    public let bids: [CurrencyOffer]

    public var bestBid: BigDecimalValue? { bids.first?.price }
    public var bestAsk: BigDecimalValue? { asks.first?.price }
    public var bidVolume: BigDecimalValue? { bids.first?.amount }
    public var askVolume: BigDecimalValue? { asks.first?.amount }

    public static func decode(from reader: inout BinaryReader) throws -> CurrencyMarket {
        let creationTimestamp = try reader.readInt64BE()
        let bits = Int(try reader.readByte())

        let instrumentPrimary: String? = (bits & 1) == 0
            ? try decodeInstrument(from: &reader, table: primaryCodedInstruments)
            : nil
        let instrumentSecondary: String? = (bits & 2) == 0
            ? try decodeInstrument(from: &reader, table: secondaryCodedInstruments)
            : nil
        let indicative = (bits & 4) != 0
        // Skip BigDecimal totals; we don't surface them yet but we must consume them.
        if (bits & 0x08) == 0 { _ = try BigDecimalCodec.decode(from: &reader) }
        if (bits & 0x10) == 0 { _ = try BigDecimalCodec.decode(from: &reader) }
        if (bits & 0x20) == 0 { _ = try BigDecimalCodec.decode(from: &reader) }
        if (bits & 0x40) == 0 { _ = try BigDecimalCodec.decode(from: &reader) }

        let asks = try decodeOffers(from: &reader, asks: true)
        let bids = try decodeOffers(from: &reader, asks: false)

        let instrument = "\(instrumentPrimary ?? "?")/\(instrumentSecondary ?? "?")"
        return CurrencyMarket(
            instrument: instrument,
            creationTimestampMillis: creationTimestamp,
            indicative: indicative,
            asks: asks,
            bids: bids
        )
    }

    private static func decodeInstrument(from reader: inout BinaryReader, table: [String]) throws -> String {
        let first = try reader.readByte()
        if (first & 0x80) != 0 {
            let idx = Int(first & 0x7F)
            guard idx < table.count else { return "?" }
            return table[idx]
        }
        if (first & 0x40) != 0 {
            let len = Int(first & 0x3F)
            let bytes = try reader.readBytes(len)
            return String(data: bytes, encoding: .utf8) ?? ""
        }
        let lenHi = UInt16(first)
        let lenLo = UInt16(try reader.readByte())
        let len = Int((lenHi << 8) | lenLo)
        let bytes = try reader.readBytes(len)
        return String(data: bytes, encoding: .utf8) ?? ""
    }

    private static func decodeOffers(from reader: inout BinaryReader, asks: Bool) throws -> [CurrencyOffer] {
        let size = Int(try reader.readByte())
        guard size > 0 else { return [] }
        var offers: [CurrencyOffer] = []
        offers.reserveCapacity(size)

        let firstPrice = try BigDecimalCodec.decode(from: &reader)
        let firstAmount = try BigDecimalCodec.decode(from: &reader)
        let firstFok = try BigDecimalCodec.decode(from: &reader)
        offers.append(CurrencyOffer(price: firstPrice, amount: firstAmount, fokAmount: firstFok))

        for _ in 1..<size {
            let deltaPrice = try BigDecimalCodec.decode(from: &reader)
            let amount = try BigDecimalCodec.decode(from: &reader)
            let fok = try BigDecimalCodec.decode(from: &reader)
            let price = BigDecimalCodec.operatorAddDelta(
                first: firstPrice, delta: deltaPrice, asks: asks
            )
            offers.append(CurrencyOffer(price: price, amount: amount, fokAmount: fok))
        }
        return offers
    }
}

// Coded instrument tables from the server codec, in order. Top 22 are currencies;
// the rest covers indices, commodities, and a long stock list. We only need the
// currency block for an FX-only client, but include the full list for safety.
private let primaryCodedInstruments: [String] = [
    "USD", "EUR", "CAD", "AUD", "CHF", "GBP", "HKD", "MXN", "NZD", "SGD",
    "XAG", "XAU", "ZAR", "JPY", "PLN", "DKK", "HUF", "NOK", "RUB", "SEK",
    "TRY", "CNH",
    "BRENT.CMD", "WTI.CMD", "DEU.IDX", "FRA.IDX", "CHE.IDX", "GBR.IDX", "JPN.IDX",
    "USA30.IDX", "USATECH.IDX", "USA500.IDX", "AUS.IDX", "ESP.IDX", "HKG.IDX",
    "ITA.IDX", "NLD.IDX", "EUS.IDX",
    "CSG.CHE", "NEST.CHE", "NOVA.CHE", "ROCH.CHE", "UBS.CHE",
    "BMW.DEU", "COMM.DEU", "DEBK.DEU", "EON.DEU", "SIEM.DEU", "VOLK.DEU",
    "CARL.DNK", "DABK.DNK", "APMM.DNK", "NOVO.DNK", "VWS.DNK",
    "BBVA.ESP", "IBER.ESP", "REPS.ESP", "BASA.ESP", "TELE.ESP",
    "BNPP.FRA", "CARR.FRA", "LVHM.FRA", "ORAN.FRA", "RENA.FRA", "SANO.FRA", "TOTA.FRA",
    "888H.GBR", "BHPP.GBR", "BP.GBR", "HSBC.GBR", "RIO.GBR", "VOD.GBR",
    "UNIC.ITA", "ENEL.ITA", "ENI.ITA", "ASGE.ITA", "INSA.ITA",
    "INGG.NLD", "ARMI.NLD", "PHIL.NLD", "RDS.NLD", "UNIL.NLD",
    "DNB.NOR", "SEAD.NOR", "STAT.NOR", "TELE.NOR", "YARA.NOR",
    "NDBK.SWE", "SVEN.SWE", "SWED.SWE", "TESO.SWE", "VOLV.SWE",
    "APPL.USA", "AMAZ.USA", "BOA.USA", "COPA.USA", "CISC.USA", "CHEV.USA",
    "DELL.USA", "DISN.USA", "EBAY.USA", "GEEL.USA", "GEMO.USA", "GOOG.USA",
    "HOME.USA", "HEPA.USA", "IBM.USA", "INTC.USA", "JOJO.USA", "JPMC.USA",
    "COCO.USA", "MCDN.USA", "3MCO.USA", "MSFT.USA", "ORCL.USA", "PRGA.USA",
    "PHMO.USA", "STAR.USA", "ATT.USA", "UNPS.USA", "WMS.USA", "EXXO.USA", "YHOO.USA",
]

private let secondaryCodedInstruments: [String] = [
    "USD", "EUR", "CAD", "AUD", "CHF", "GBP", "HKD", "MXN", "NZD", "SGD",
    "XAG", "XAU", "ZAR", "JPY", "PLN", "DKK", "HUF", "NOK", "RUB", "SEK",
    "TRY", "CNH",
]
