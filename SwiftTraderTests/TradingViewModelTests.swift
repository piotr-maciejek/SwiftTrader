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

    var lastSubmitOrderType: String?
    var lastSubmitEntryPrice: Double?

    /// Captured on the first call to streamPendingOrders so tests can push snapshots.
    var pendingOrdersContinuation: AsyncThrowingStream<PendingOrdersSnapshot, Error>.Continuation?

    func submitOrder(instrument: String, direction: String, amount: Double,
                     stopLoss: Double, takeProfit: Double,
                     orderType: String, entryPrice: Double?) async throws -> Position {
        submitCallCount += 1
        lastSubmitOrderType = orderType
        lastSubmitEntryPrice = entryPrice
        if var iterator = submitGate {
            _ = await iterator.next()
            submitGate = iterator
        }
        return try submitResult.get()
    }

    func closeOrder(label: String) async throws {}

    func modifyOrder(label: String, stopLoss: Double, takeProfit: Double) async throws -> Position {
        try submitResult.get()
    }

    func streamSnapshots() -> AsyncThrowingStream<TradingSnapshot, Error> {
        AsyncThrowingStream { continuation in continuation.onTermination = { _ in } }
    }

    func streamPendingOrders() -> AsyncThrowingStream<PendingOrdersSnapshot, Error> {
        AsyncThrowingStream { continuation in
            self.pendingOrdersContinuation = continuation
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
        for _ in 0..<20 {
            if vm.isSubmitting { break }
            await Task.yield()
        }
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
        for _ in 0..<20 {
            if vm.isSubmitting { break }
            await Task.yield()
        }
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
        for _ in 0..<20 {
            if vm.isSubmitting { break }
            await Task.yield()
        }

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
