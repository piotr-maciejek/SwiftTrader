import Foundation
import Testing
@testable import DukascopyClient

/// Pure tests for the order-ack matchers that correlate inbound order events with
/// in-flight order operations (and decide rejected vs accepted vs no-match).
@Suite("Order ack matching")
struct OrderAckTests {

    private typealias Meta = DukascopySession.PendingOrderAckMeta
    private typealias Outcome = DukascopySession.OrderAckOutcome

    private func submitMeta(instrument: String = "EUR/USD", label: String? = "ST_EURUSD",
                            at: Date = Date(timeIntervalSince1970: 100)) -> Meta {
        Meta(instrument: instrument, label: label, orderGroupId: nil, submittedAt: at)
    }

    private func groupOpMeta(gid: String, instrument: String = "EUR/USD",
                             at: Date = Date(timeIntervalSince1970: 100)) -> Meta {
        Meta(instrument: instrument, label: nil, orderGroupId: gid, submittedAt: at)
    }

    private func response(requestId: String? = nil, state: String, label: String? = nil,
                          instrument: String? = nil, notes: String? = nil) -> ExtApiOrderResponse {
        var r = ExtApiOrderResponse()
        r.requestId = requestId
        r.state = state
        r.label = label
        r.instrument = instrument
        r.notes = notes
        return r
    }

    // MARK: - ExtApiOrderResponse matching

    @Test("Echoed requestId + REJECTED state resolves that op as rejected with the reason")
    func requestIdRejected() {
        let pending = ["req-1": submitMeta()]
        let hit = DukascopySession.ackMatch(
            response: response(requestId: "req-1", state: "REJECTED", notes: "insufficient margin"),
            pending: pending)
        #expect(hit?.key == "req-1")
        #expect(hit?.outcome == .rejected(state: "REJECTED", reason: "insufficient margin"))
    }

    @Test("Echoed requestId with a non-rejected state resolves accepted")
    func requestIdAccepted() {
        let pending = ["req-1": submitMeta()]
        let hit = DukascopySession.ackMatch(
            response: response(requestId: "req-1", state: "FILLED"), pending: pending)
        #expect(hit?.key == "req-1")
        #expect(hit?.outcome == .accepted)
    }

    @Test("Rejected response without requestId falls back to the newest label match")
    func rejectionFallsBackToLabel() {
        let pending = [
            "old": submitMeta(label: "ST_EURUSD", at: Date(timeIntervalSince1970: 100)),
            "new": submitMeta(label: "ST_EURUSD", at: Date(timeIntervalSince1970: 200)),
        ]
        let hit = DukascopySession.ackMatch(
            response: response(state: "REJECTED", label: "ST_EURUSD"), pending: pending)
        #expect(hit?.key == "new")
        #expect(hit?.outcome == .rejected(state: "REJECTED", reason: nil))
    }

    @Test("Non-rejected response without requestId is not an ack")
    func unmatchedAcceptIsNil() {
        let pending = ["req-1": submitMeta()]
        let hit = DukascopySession.ackMatch(
            response: response(state: "FILLED", label: "ST_EURUSD"), pending: pending)
        #expect(hit == nil)
    }

    @Test("Rejection matching nothing in flight returns nil")
    func rejectionWithNoCandidates() {
        let pending = ["req-1": submitMeta(instrument: "EUR/USD", label: "ST_EURUSD")]
        let hit = DukascopySession.ackMatch(
            response: response(state: "REJECTED", label: "ST_USDJPY", instrument: "USD/JPY"),
            pending: pending)
        #expect(hit == nil)
    }

    // MARK: - OrderMsg matching

    @Test("Rejected order update resolves the op targeting its group")
    func orderRejectionByGroupId() {
        var o = OrderMsg()
        o.orderGroupId = "g-9"
        o.state = "REJECTED"
        let pending = ["req-1": groupOpMeta(gid: "g-9")]
        let hit = DukascopySession.ackMatch(order: o, pending: pending)
        #expect(hit?.key == "req-1")
        #expect(hit?.outcome == .rejected(state: "REJECTED", reason: nil))
    }

    @Test("Rejected order update without a known group falls back to the newest same-instrument submit")
    func orderRejectionByInstrument() {
        var o = OrderMsg()
        o.instrument = "EUR/USD"
        o.state = "ERROR"
        let pending = [
            "old": submitMeta(at: Date(timeIntervalSince1970: 100)),
            "new": submitMeta(at: Date(timeIntervalSince1970: 200)),
        ]
        let hit = DukascopySession.ackMatch(order: o, pending: pending)
        #expect(hit?.key == "new")
        #expect(hit?.outcome == .rejected(state: "ERROR", reason: nil))
    }

    @Test("Normal order lifecycle states are not acks (FILLED, CANCELLED, PENDING)")
    func benignOrderStatesIgnored() {
        let pending = ["req-1": submitMeta()]
        for state in ["FILLED", "CANCELLED", "PENDING", "CREATED"] {
            var o = OrderMsg()
            o.instrument = "EUR/USD"
            o.state = state
            #expect(DukascopySession.ackMatch(order: o, pending: pending) == nil)
        }
    }

    // MARK: - OrderGroup matching

    @Test("OPEN group on the instrument accepts the OLDEST in-flight submit (FIFO)")
    func openGroupAcceptsOldestSubmit() {
        var g = OrderGroup()
        g.orderGroupId = "g-1"
        g.instrument = "EUR/USD"
        g.status = "OPEN"
        let pending = [
            "first": submitMeta(at: Date(timeIntervalSince1970: 100)),
            "second": submitMeta(at: Date(timeIntervalSince1970: 200)),
        ]
        let hit = DukascopySession.ackMatch(group: g, pending: pending)
        #expect(hit?.key == "first")
        #expect(hit?.outcome == .accepted)
    }

    @Test("Group update referencing a close/modify op's group accepts it (even CLOSE status)")
    func groupUpdateAcceptsGroupOp() {
        var g = OrderGroup()
        g.orderGroupId = "g-7"
        g.instrument = "EUR/USD"
        g.status = "CLOSE"
        let pending = ["req-1": groupOpMeta(gid: "g-7")]
        let hit = DukascopySession.ackMatch(group: g, pending: pending)
        #expect(hit?.key == "req-1")
        #expect(hit?.outcome == .accepted)
    }

    @Test("Group carrying a nested REJECTED order rejects the op on that group")
    func groupNestedRejection() {
        var bad = OrderMsg()
        bad.state = "REJECTED"
        var g = OrderGroup()
        g.orderGroupId = "g-7"
        g.instrument = "EUR/USD"
        g.status = "OPEN"
        g.orders = [bad]
        let pending = ["req-1": groupOpMeta(gid: "g-7")]
        let hit = DukascopySession.ackMatch(group: g, pending: pending)
        #expect(hit?.key == "req-1")
        #expect(hit?.outcome == .rejected(state: "REJECTED", reason: nil))
    }

    @Test("CLOSE group on an instrument with only submits in flight is not an ack")
    func closeGroupIgnoredForSubmits() {
        var g = OrderGroup()
        g.orderGroupId = "g-other"
        g.instrument = "EUR/USD"
        g.status = "CLOSE"
        let pending = ["req-1": submitMeta()]
        #expect(DukascopySession.ackMatch(group: g, pending: pending) == nil)
    }

    @Test("OPEN group on a different instrument is not an ack")
    func openGroupOtherInstrumentIgnored() {
        var g = OrderGroup()
        g.orderGroupId = "g-1"
        g.instrument = "USD/JPY"
        g.status = "OPEN"
        let pending = ["req-1": submitMeta(instrument: "EUR/USD")]
        #expect(DukascopySession.ackMatch(group: g, pending: pending) == nil)
    }

    @Test("isRejected truth table")
    func isRejectedStates() {
        for state in ["REJECTED", "ERROR", "REVOKED"] {
            #expect(response(state: state).isRejected)
        }
        for state in ["CREATED", "PENDING", "FILLED", "CANCELLED"] {
            #expect(!response(state: state).isRejected)
        }
    }
}
