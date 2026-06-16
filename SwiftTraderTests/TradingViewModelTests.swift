import Foundation
import Testing
@testable import SwiftTrader

/// Fake coordinator driven by injected Results + manual gating so tests can observe
/// viewmodel state mid-flight (before the submit resolves).
final class FakeTradingCoordinator: TradingCoordinating, @unchecked Sendable {
    var submitResult: Result<Position, Error> = .success(
        Position(label: "ST_EURUSD_1", instrument: "EURUSD", direction: "BUY",
                 amount: 0.01, openPrice: 1.1000,
                 stopLoss: 1.0950, takeProfit: 1.1150,
                 profitLoss: 0, profitLossPips: 0, state: "FILLED"))

    var submitCallCount = 0
    /// If non-nil, submit will await this continuation before returning — used to inspect mid-flight state.
    var submitGate: AsyncStream<Void>.Iterator?

    /// Fires once per `submitOrder` entry, AFTER `submitCallCount` is bumped, so gated tests
    /// can deterministically await "a submit is in flight" instead of polling `isSubmitting`.
    /// The VM sets `isSubmitting` on the MainActor before the nonisolated submit hop, so
    /// observing it true does NOT guarantee the call has been counted yet (the increment runs
    /// post-hop on another thread) — that gap is the source of the old flake.
    let submitEntered: AsyncStream<Void>
    private let submitEnteredContinuation: AsyncStream<Void>.Continuation

    init() {
        (submitEntered, submitEnteredContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    var lastSubmitOrderType: String?
    var lastSubmitEntryPrice: Double?

    /// Captured on the first call to streamPendingOrders so tests can push snapshots.
    var pendingOrdersContinuation: AsyncThrowingStream<PendingOrdersSnapshot, Error>.Continuation?
    /// Captured on the first call to streamSnapshots so tests can push trading snapshots.
    var snapshotContinuation: AsyncThrowingStream<TradingSnapshot, Error>.Continuation?
    /// Captured on the first call to orderRejections so tests can push broker rejections.
    var rejectionContinuation: AsyncStream<String>.Continuation?

    func submitOrder(instrument: String, direction: String, amount: Double,
                     stopLoss: Double, takeProfit: Double,
                     orderType: String, entryPrice: Double?) async throws -> Position {
        submitCallCount += 1
        lastSubmitOrderType = orderType
        lastSubmitEntryPrice = entryPrice
        submitEnteredContinuation.yield(())
        if var iterator = submitGate {
            _ = await iterator.next()
            submitGate = iterator
        }
        return try submitResult.get()
    }

    func closeOrder(label: String) async throws {}

    var modifyCallCount = 0
    func modifyOrder(label: String, stopLoss: Double, takeProfit: Double) async throws -> Position {
        modifyCallCount += 1
        return try submitResult.get()
    }

    var modifyEntryCallCount = 0
    func modifyPendingEntry(label: String, newTriggerPrice: Double) async throws {
        modifyEntryCallCount += 1
    }

    func streamSnapshots() -> AsyncThrowingStream<TradingSnapshot, Error> {
        AsyncThrowingStream { continuation in
            self.snapshotContinuation = continuation
            continuation.onTermination = { _ in }
        }
    }

    func streamPendingOrders() -> AsyncThrowingStream<PendingOrdersSnapshot, Error> {
        AsyncThrowingStream { continuation in
            self.pendingOrdersContinuation = continuation
            continuation.onTermination = { _ in }
        }
    }

    func orderRejections() -> AsyncStream<String> {
        AsyncStream { continuation in
            self.rejectionContinuation = continuation
            continuation.onTermination = { _ in }
        }
    }
}

struct FakeError: Error, LocalizedError {
    let msg: String
    var errorDescription: String? { msg }
}

private func makeBars(count: Int, close: Double = 1.1000) -> [CandleBar] {
    (0..<count).map { i in
        CandleBar(time: Int64(i), open: 1.0990, high: 1.1010, low: 1.0980,
                  close: close, volume: 100, partial: false)
    }
}

@Suite("Visual Order Submit Race")
@MainActor
struct VisualOrderSubmitRaceTests {

    @Test("Successful submit removes the visual order")
    func successRemovesVisualOrder() async {
        let fake = FakeTradingCoordinator()
        let vm = TradingViewModel(coordinator: fake)
        vm.beginVisualOrder(direction: "BUY", instrument: "EURUSD", bars: makeBars(count: 50))
        #expect(vm.visualOrder(for: "EURUSD") != nil)

        await vm.confirmVisualOrder(instrument: "EURUSD")

        #expect(vm.visualOrder(for: "EURUSD") == nil)
        #expect(vm.isSubmitting == false)
        #expect(vm.orderError == nil)
        #expect(fake.submitCallCount == 1)
    }

    @Test("Failed submit keeps the visual order for retry and exposes the error")
    func failureKeepsVisualOrder() async {
        let fake = FakeTradingCoordinator()
        fake.submitResult = .failure(FakeError(msg: "instrument 'XAUUSD' is not subscribed"))
        let vm = TradingViewModel(coordinator: fake)
        vm.beginVisualOrder(direction: "BUY", instrument: "EURUSD", bars: makeBars(count: 50))

        await vm.confirmVisualOrder(instrument: "EURUSD")

        #expect(vm.visualOrder(for: "EURUSD") != nil)
        #expect(vm.isSubmitting == false)
        #expect(vm.orderError == "instrument 'XAUUSD' is not subscribed")
        #expect(fake.submitCallCount == 1)
    }

    @Test("Retry after failure can succeed and then removes the visual order")
    func retryAfterFailure() async {
        let fake = FakeTradingCoordinator()
        fake.submitResult = .failure(FakeError(msg: "transient"))
        let vm = TradingViewModel(coordinator: fake)
        vm.beginVisualOrder(direction: "BUY", instrument: "EURUSD", bars: makeBars(count: 50))

        await vm.confirmVisualOrder(instrument: "EURUSD")
        #expect(vm.visualOrder(for: "EURUSD") != nil)

        // Server recovers, user retries.
        fake.submitResult = .success(
            Position(label: "ST_EURUSD_2", instrument: "EURUSD", direction: "BUY",
                     amount: 0.01, openPrice: 1.1, stopLoss: 1.09, takeProfit: 1.12,
                     profitLoss: 0, profitLossPips: 0, state: "FILLED"))
        await vm.confirmVisualOrder(instrument: "EURUSD")

        #expect(vm.visualOrder(for: "EURUSD") == nil)
        #expect(fake.submitCallCount == 2)
    }

    @Test("isSubmitting flips true while awaiting, flips back false after")
    func isSubmittingReflectsInFlight() async {
        // Gate the submit so we can observe mid-flight state.
        let (stream, cont) = AsyncStream.makeStream(of: Void.self)
        let fake = FakeTradingCoordinator()
        fake.submitGate = stream.makeAsyncIterator()
        let vm = TradingViewModel(coordinator: fake)
        vm.beginVisualOrder(direction: "BUY", instrument: "EURUSD", bars: makeBars(count: 50))

        let task = Task { await vm.confirmVisualOrder(instrument: "EURUSD") }
        // Let the submit reach the gate before we assert.
        var entered = fake.submitEntered.makeAsyncIterator()
        _ = await entered.next()
        #expect(vm.isSubmitting == true)
        #expect(vm.visualOrder(for: "EURUSD") != nil)

        cont.yield(())
        cont.finish()
        await task.value

        #expect(vm.isSubmitting == false)
        #expect(vm.visualOrder(for: "EURUSD") == nil)
    }

    @Test("Second confirm while in flight is ignored (no duplicate submit)")
    func concurrentConfirmsDoNotDoubleSubmit() async {
        let (stream, cont) = AsyncStream.makeStream(of: Void.self)
        let fake = FakeTradingCoordinator()
        fake.submitGate = stream.makeAsyncIterator()
        let vm = TradingViewModel(coordinator: fake)
        vm.beginVisualOrder(direction: "BUY", instrument: "EURUSD", bars: makeBars(count: 50))

        let first = Task { await vm.confirmVisualOrder(instrument: "EURUSD") }
        var entered = fake.submitEntered.makeAsyncIterator()
        _ = await entered.next()
        // Second call while first still pending should short-circuit.
        await vm.confirmVisualOrder(instrument: "EURUSD")
        #expect(fake.submitCallCount == 1)

        cont.yield(())
        cont.finish()
        await first.value
        #expect(fake.submitCallCount == 1)
    }

    @Test("cancelVisualOrder is ignored while a submit is in flight")
    func cancelIgnoredWhileSubmitting() async {
        let (stream, cont) = AsyncStream.makeStream(of: Void.self)
        let fake = FakeTradingCoordinator()
        fake.submitGate = stream.makeAsyncIterator()
        let vm = TradingViewModel(coordinator: fake)
        vm.beginVisualOrder(direction: "BUY", instrument: "EURUSD", bars: makeBars(count: 50))

        let task = Task { await vm.confirmVisualOrder(instrument: "EURUSD") }
        var entered = fake.submitEntered.makeAsyncIterator()
        _ = await entered.next()

        // While submit is in flight, cancel should be a no-op — user shouldn't be able
        // to discard a pending order and lose the ability to see its outcome.
        vm.cancelVisualOrder(instrument: "EURUSD")
        #expect(vm.visualOrder(for: "EURUSD") != nil)

        cont.yield(())
        cont.finish()
        await task.value
        #expect(vm.visualOrder(for: "EURUSD") == nil) // removed on success, not by cancel
    }

    @Test("Confirm on an instrument without a visual order is a no-op")
    func confirmWithoutOrderIsNoop() async {
        let fake = FakeTradingCoordinator()
        let vm = TradingViewModel(coordinator: fake)

        await vm.confirmVisualOrder(instrument: "EURUSD")

        #expect(fake.submitCallCount == 0)
        #expect(vm.orderError == nil)
    }
}

@Suite("Currency-Aware Sizing")
@MainActor
struct CurrencyAwareSizingTests {

    private func makeAccount(currency: String) -> Account {
        Account(balance: 10_000, equity: 10_000, usedMargin: 0, freeMargin: 10_000,
                currency: currency, leverage: 30, connected: true, lastTickAgeMs: 0)
    }

    /// Push one snapshot through the fake's stream so the VM picks up account + rates
    /// via the same path production uses.
    private func feed(_ vm: TradingViewModel, _ fake: FakeTradingCoordinator,
                      account: Account, rates: [String: Double]?) async {
        vm.start()
        for _ in 0..<50 {
            if fake.snapshotContinuation != nil { break }
            await Task.yield()
        }
        fake.snapshotContinuation?.yield(
            TradingSnapshot(positions: [], account: account, spreads: [:], rates: rates))
        for _ in 0..<50 {
            if vm.account != nil { break }
            await Task.yield()
        }
    }

    @Test("Cross-currency pair sizes with the converted rate")
    func crossCurrencySizing() async throws {
        let fake = FakeTradingCoordinator()
        let vm = TradingViewModel(coordinator: fake)
        // EUR account trading USDJPY; JPY→EUR comes from the inverse of EURJPY = 171.
        await feed(vm, fake, account: makeAccount(currency: "EUR"),
                   rates: ["EURJPY": 171.0])

        let bars = (0..<50).map { i in
            CandleBar(time: Int64(i), open: 149.90, high: 150.10, low: 149.80,
                      close: 150.00, volume: 100, partial: false)
        }
        vm.beginVisualOrder(direction: "BUY", instrument: "USDJPY", bars: bars)

        let order = try #require(vm.visualOrder(for: "USDJPY"))
        let (sl, _) = TradingViewModel.visualOrderSLTP(direction: "BUY", bars: bars, currentPrice: 150.00)
        let expected = PositionSizing.calculate(
            equity: 10_000, freeMargin: 10_000, riskFraction: 0.005,
            entryPrice: 150.00, stopLoss: sl, leverage: 30,
            spread: 0, quoteToAccountRate: 1.0 / 171.0)
        #expect(order.amount == expected.lots)
        #expect(order.isConversionUnavailable == false)
        vm.stop()
    }

    @Test("Missing rate refuses to auto-size and flags the order")
    func missingRateKeepsManualAmount() async throws {
        let fake = FakeTradingCoordinator()
        let vm = TradingViewModel(coordinator: fake)
        // EUR account, JPY-quote pair, but no rates at all (server mode).
        await feed(vm, fake, account: makeAccount(currency: "EUR"), rates: nil)

        let bars = (0..<50).map { i in
            CandleBar(time: Int64(i), open: 149.90, high: 150.10, low: 149.80,
                      close: 150.00, volume: 100, partial: false)
        }
        vm.beginVisualOrder(direction: "BUY", instrument: "USDJPY", bars: bars)

        let order = try #require(vm.visualOrder(for: "USDJPY"))
        #expect(order.isConversionUnavailable == true)
        #expect(order.amount == vm.amount)   // untouched default, not an auto-size
        #expect(order.isMarginCapped == false)
        vm.stop()
    }

    @Test("Same-currency pair sizes with no rates dict at all")
    func sameCurrencyNeedsNoRates() async throws {
        let fake = FakeTradingCoordinator()
        let vm = TradingViewModel(coordinator: fake)
        // USD account trading EURUSD (quote USD): rate is 1 without any streamed rates.
        await feed(vm, fake, account: makeAccount(currency: "USD"), rates: nil)

        vm.beginVisualOrder(direction: "BUY", instrument: "EURUSD", bars: makeBars(count: 50))

        let order = try #require(vm.visualOrder(for: "EURUSD"))
        #expect(order.isConversionUnavailable == false)
        let (sl, _) = TradingViewModel.visualOrderSLTP(
            direction: "BUY", bars: makeBars(count: 50), currentPrice: 1.1000)
        let expected = PositionSizing.calculate(
            equity: 10_000, freeMargin: 10_000, riskFraction: 0.005,
            entryPrice: 1.1000, stopLoss: sl, leverage: 30,
            spread: 0, quoteToAccountRate: 1)
        #expect(order.amount == expected.lots)
        vm.stop()
    }
}

@Suite("Order Rejection Stream")
@MainActor
struct OrderRejectionStreamTests {

    @Test("A late broker rejection surfaces as orderError")
    func lateRejectionSetsOrderError() async {
        let fake = FakeTradingCoordinator()
        let vm = TradingViewModel(coordinator: fake)
        vm.start()

        for _ in 0..<50 {
            if fake.rejectionContinuation != nil { break }
            await Task.yield()
        }
        #expect(fake.rejectionContinuation != nil)

        fake.rejectionContinuation?.yield("Order rejected (REJECTED): insufficient margin — EUR/USD")

        for _ in 0..<50 {
            if vm.orderError != nil { break }
            await Task.yield()
        }
        #expect(vm.orderError == "Order rejected (REJECTED): insufficient margin — EUR/USD")
        vm.stop()
    }
}

@Suite("Pending Orders Stream")
@MainActor
struct PendingOrdersStreamTests {

    @Test("Pending orders snapshot propagates to view model")
    func pendingOrdersPopulateOnSnapshot() async {
        let fake = FakeTradingCoordinator()
        let vm = TradingViewModel(coordinator: fake)
        vm.start()

        // Wait for the VM to subscribe and capture the continuation.
        for _ in 0..<50 {
            if fake.pendingOrdersContinuation != nil { break }
            await Task.yield()
        }
        #expect(fake.pendingOrdersContinuation != nil)

        let order = PendingOrder(label: "ST_EURUSD_123", instrument: "EURUSD",
                                 direction: "BUY", amount: 0.01, openPrice: 1.1200,
                                 stopLoss: 1.1100, takeProfit: 1.1400,
                                 state: "OPENED", orderType: "BUY_STOP")
        fake.pendingOrdersContinuation?.yield(PendingOrdersSnapshot(pendingOrders: [order]))

        // Let the VM handle the yield.
        for _ in 0..<50 {
            if !vm.pendingOrders.isEmpty { break }
            await Task.yield()
        }

        #expect(vm.pendingOrders.count == 1)
        #expect(vm.pendingOrders.first?.label == "ST_EURUSD_123")
        #expect(vm.pendingOrders.first?.orderType == "BUY_STOP")

        vm.stop()
    }
}

@Suite("Order price (SL/TP side) validation")
struct OrderPriceValidationTests {
    private typealias VM = TradingViewModel

    @Test("Valid BUY: SL below, TP above entry → no error")
    func validBuy() {
        #expect(VM.orderPriceError(direction: "BUY", entryPrice: 1.1000,
                                   stopLoss: 1.0950, takeProfit: 1.1150) == nil)
    }

    @Test("Valid SELL: SL above, TP below entry → no error")
    func validSell() {
        #expect(VM.orderPriceError(direction: "SELL", entryPrice: 1.1000,
                                   stopLoss: 1.1050, takeProfit: 1.0850) == nil)
    }

    @Test("BUY with SL above entry (the bug) → error")
    func buyWrongSideSL() {
        let err = VM.orderPriceError(direction: "BUY", entryPrice: 1.1000,
                                     stopLoss: 1.1050, takeProfit: 1.1150)
        #expect(err != nil)
        #expect(err?.contains("Stop-loss") == true)
    }

    @Test("BUY with TP below entry → error")
    func buyWrongSideTP() {
        let err = VM.orderPriceError(direction: "BUY", entryPrice: 1.1000,
                                     stopLoss: 1.0950, takeProfit: 1.0900)
        #expect(err?.contains("Take-profit") == true)
    }

    @Test("SELL with SL below entry → error")
    func sellWrongSideSL() {
        let err = VM.orderPriceError(direction: "SELL", entryPrice: 1.1000,
                                     stopLoss: 1.0950, takeProfit: 1.0850)
        #expect(err?.contains("Stop-loss") == true)
    }

    @Test("SL/TP of 0 means unset → always allowed")
    func zeroStopsAllowed() {
        #expect(VM.orderPriceError(direction: "BUY", entryPrice: 1.1000,
                                   stopLoss: 0, takeProfit: 0) == nil)
    }

    @Test("SL exactly at entry is rejected (degenerate, instant stop-out)")
    func slAtEntryRejected() {
        #expect(VM.orderPriceError(direction: "BUY", entryPrice: 1.1000,
                                   stopLoss: 1.1000, takeProfit: 1.1150) != nil)
    }

    @Test("No entry price (0) → cannot validate, allow through")
    func noEntryAllows() {
        #expect(VM.orderPriceError(direction: "BUY", entryPrice: 0,
                                   stopLoss: 1.1050, takeProfit: 1.0900) == nil)
    }
}

/// The modify path (drag a resting order's SL/TP) must run the same wrong-side guard as submit —
/// Dukascopy does NOT reject a pending order whose protective leg is on the wrong side of the
/// trigger; it fills and stops out on the same tick. Open positions are exempt (break-even/trailing).
@Suite("Modify-path wrong-side guard")
@MainActor
struct ModifyGuardTests {
    private func pending(_ dir: String, type: String, entry: Double,
                         sl: Double = 0, tp: Double = 0) -> PendingOrder {
        PendingOrder(label: "ST_AUDCAD_1", instrument: "AUDCAD", direction: dir,
                     amount: 0.01, openPrice: entry, stopLoss: sl, takeProfit: tp,
                     state: "PENDING", orderType: type, groupId: "G1")
    }

    @Test("BUY LIMIT modified so SL sits above trigger (the bug) → blocked, coordinator not called")
    func buyLimitWrongSideSL() async {
        let fake = FakeTradingCoordinator()
        let vm = TradingViewModel(coordinator: fake)
        vm.pendingOrders = [pending("BUY", type: "BUY_LIMIT", entry: 0.98930)]
        await vm.modifyPosition(label: "ST_AUDCAD_1", stopLoss: 0.98942, takeProfit: 0.99184)
        #expect(vm.orderError?.contains("Stop-loss") == true)
        #expect(fake.modifyCallCount == 0)
    }

    @Test("SELL STOP modified so SL sits below trigger → blocked")
    func sellStopWrongSideSL() async {
        let fake = FakeTradingCoordinator()
        let vm = TradingViewModel(coordinator: fake)
        vm.pendingOrders = [pending("SELL", type: "SELL_STOP", entry: 1.2000)]
        await vm.modifyPosition(label: "ST_AUDCAD_1", stopLoss: 1.1950, takeProfit: 1.1900)
        #expect(vm.orderError?.contains("Stop-loss") == true)
        #expect(fake.modifyCallCount == 0)
    }

    @Test("Valid pending modify → passes through to the coordinator")
    func validModifyProceeds() async {
        let fake = FakeTradingCoordinator()
        let vm = TradingViewModel(coordinator: fake)
        vm.pendingOrders = [pending("BUY", type: "BUY_LIMIT", entry: 0.98930)]
        await vm.modifyPosition(label: "ST_AUDCAD_1", stopLoss: 0.98800, takeProfit: 0.99184)
        #expect(vm.orderError == nil)
        #expect(fake.modifyCallCount == 1)
    }

    @Test("Matches the order by groupId too (SL/TP edits route via groupId)")
    func matchesByGroupId() async {
        let fake = FakeTradingCoordinator()
        let vm = TradingViewModel(coordinator: fake)
        vm.pendingOrders = [pending("BUY", type: "BUY_LIMIT", entry: 0.98930)]
        await vm.modifyPosition(label: "G1", stopLoss: 0.98942, takeProfit: 0.99184)
        #expect(vm.orderError?.contains("Stop-loss") == true)
        #expect(fake.modifyCallCount == 0)
    }

    @Test("Open position (no matching pending) is exempt — a break-even SL above entry passes")
    func openPositionExempt() async {
        let fake = FakeTradingCoordinator()
        let vm = TradingViewModel(coordinator: fake)
        // No pending order with this label → treated as an open position, guard does not apply.
        await vm.modifyPosition(label: "FILLED_POS_9", stopLoss: 1.1050, takeProfit: 1.1200)
        #expect(vm.orderError == nil)
        #expect(fake.modifyCallCount == 1)
    }

    // Entry-drag path: moving the trigger past the resting SL/TP is the same wrong-side hazard
    // reached from the other side (a BUY STOP whose entry slides below its SL).

    @Test("BUY STOP entry dragged below its resting SL → blocked, coordinator not called")
    func buyStopEntryBelowSL() async {
        let fake = FakeTradingCoordinator()
        let vm = TradingViewModel(coordinator: fake)
        vm.pendingOrders = [pending("BUY", type: "BUY_STOP", entry: 0.99076, sl: 0.99054, tp: 0.99232)]
        await vm.modifyPendingEntry(label: "ST_AUDCAD_1", trigger: 0.99017) // now below SL
        #expect(vm.orderError?.contains("Stop-loss") == true)
        #expect(fake.modifyEntryCallCount == 0)
    }

    @Test("SELL STOP entry dragged above its resting SL → blocked")
    func sellStopEntryAboveSL() async {
        let fake = FakeTradingCoordinator()
        let vm = TradingViewModel(coordinator: fake)
        vm.pendingOrders = [pending("SELL", type: "SELL_STOP", entry: 1.2000, sl: 1.2050, tp: 1.1900)]
        await vm.modifyPendingEntry(label: "ST_AUDCAD_1", trigger: 1.2070) // now above SL
        #expect(vm.orderError?.contains("Stop-loss") == true)
        #expect(fake.modifyEntryCallCount == 0)
    }

    @Test("Entry dragged past the resting TP is also blocked")
    func entryPastTP() async {
        let fake = FakeTradingCoordinator()
        let vm = TradingViewModel(coordinator: fake)
        vm.pendingOrders = [pending("BUY", type: "BUY_LIMIT", entry: 0.98930, sl: 0.98800, tp: 0.99184)]
        await vm.modifyPendingEntry(label: "ST_AUDCAD_1", trigger: 0.99200) // now above TP
        #expect(vm.orderError?.contains("Take-profit") == true)
        #expect(fake.modifyEntryCallCount == 0)
    }

    @Test("Valid entry move (stays between SL and TP) → passes through to the coordinator")
    func validEntryMoveProceeds() async {
        let fake = FakeTradingCoordinator()
        let vm = TradingViewModel(coordinator: fake)
        vm.pendingOrders = [pending("BUY", type: "BUY_STOP", entry: 0.99076, sl: 0.99000, tp: 0.99232)]
        await vm.modifyPendingEntry(label: "ST_AUDCAD_1", trigger: 0.99050) // still above SL, below TP
        #expect(vm.orderError == nil)
        #expect(fake.modifyEntryCallCount == 1)
    }
}
