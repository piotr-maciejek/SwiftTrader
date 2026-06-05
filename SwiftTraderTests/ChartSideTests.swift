import DukascopyClient
import Foundation
import Testing
@testable import SwiftTrader

@Suite("ChartSide")
struct ChartSideTests {

    @Test("ChartSide maps to the wire OfferSide")
    func offerSideMapping() {
        #expect(ChartSide.bid.offerSide == .bid)
        #expect(ChartSide.ask.offerSide == .ask)
    }

    @Test("toggled flips the side")
    func toggled() {
        #expect(ChartSide.bid.toggled == .ask)
        #expect(ChartSide.ask.toggled == .bid)
    }

    @Test("Codable round-trip via the stable raw value")
    func codableRoundTrip() throws {
        for side in ChartSide.allCases {
            let data = try JSONEncoder().encode(side)
            #expect(String(data: data, encoding: .utf8) == "\"\(side.rawValue)\"")
            #expect(try JSONDecoder().decode(ChartSide.self, from: data) == side)
        }
        // Raw tokens are load-bearing (cache filenames / persisted state) — pin them.
        #expect(ChartSide.bid.rawValue == "BID")
        #expect(ChartSide.ask.rawValue == "ASK")
    }

    @Test("ChartTabState back-compat: old JSON without side/showBidAsk decodes to BID / false")
    func tabStateBackCompat() throws {
        let legacy = """
        {"instrument":"EURUSD","period":"ONE_HOUR","showSessions":true,"showVolume":true,
         "showEMA":true,"emaConfigs":[]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ChartTabState.self, from: legacy)
        #expect(decoded.side == .bid)
        #expect(decoded.showBidAsk == false)
    }

    @Test("ChartTabState persists side + showBidAsk round-trip")
    func tabStateRoundTrip() throws {
        let state = ChartTabState(instrument: "USDJPY", period: "ONE_MIN", showSessions: false,
                                  showVolume: false, showEMA: false, emaConfigs: [],
                                  side: .ask, showBidAsk: true)
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(ChartTabState.self, from: data)
        #expect(back.side == .ask)
        #expect(back.showBidAsk == true)
    }
}
