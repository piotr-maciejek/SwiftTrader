import Foundation
import Testing
@testable import DukascopyClient

/// The last-resort wire guard: a stop-loss / take-profit on the wrong side of the entry must
/// never reach Dukascopy (it would fill and instantly stop out — a real money-losing round-trip).
@Suite("Stop-side wire validation")
struct OrderStopValidationTests {

    private func bd(_ v: Double) -> BigDecimalValue { BigDecimalValue(v, scale: 5) }

    @Test("Valid BUY (SL below, TP above) does not throw")
    func validBuy() throws {
        try DukascopySession.validateStops(side: "BUY", entry: 1.1000,
                                           stopLoss: bd(1.0950), takeProfit: bd(1.1150))
    }

    @Test("Valid SELL (SL above, TP below) does not throw")
    func validSell() throws {
        try DukascopySession.validateStops(side: "SELL", entry: 1.1000,
                                           stopLoss: bd(1.1050), takeProfit: bd(1.0850))
    }

    @Test("BUY with SL above entry throws invalidStops")
    func buyWrongSideSL() {
        #expect(throws: DukascopySession.SessionError.self) {
            try DukascopySession.validateStops(side: "BUY", entry: 1.1000,
                                               stopLoss: bd(1.1050), takeProfit: bd(1.1150))
        }
    }

    @Test("SELL with TP above entry throws invalidStops")
    func sellWrongSideTP() {
        #expect(throws: DukascopySession.SessionError.self) {
            try DukascopySession.validateStops(side: "SELL", entry: 1.1000,
                                               stopLoss: bd(1.1050), takeProfit: bd(1.1150))
        }
    }

    @Test("nil SL/TP (none set) does not throw")
    func nilStopsAllowed() throws {
        try DukascopySession.validateStops(side: "BUY", entry: 1.1000,
                                           stopLoss: nil, takeProfit: nil)
    }
}
