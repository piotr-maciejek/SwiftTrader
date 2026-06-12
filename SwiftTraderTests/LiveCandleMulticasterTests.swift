import Testing
import Foundation
@testable import SwiftTrader

private func bar(_ time: Int64, close: Double, partial: Bool = true) -> CandleBar {
    CandleBar(time: time, open: 1.0, high: 1.2, low: 0.9, close: close, volume: 100, partial: partial)
}

private let KEY = LiveCandleMulticaster.Key(instrument: "EURUSD", period: "FIFTEEN_MINS")

/// A fixed weekday noon UTC so replay-eligibility (market open) is deterministic, not weekend-flaky.
private func openMarketClock() -> Date {
    var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 3; c.hour = 12  // Wednesday
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: c)!
}

/// Controllable stand-in for the coordinator's `rawCandleStream`. Each `factory()` builds a fresh
/// stream; the test feeds bars via `emit`, ends it via `finish`, and observes how many times the
/// factory ran (dedup) and whether the driver was cancelled (teardown).
private final class DriverProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _cancelled = false
    private var _cont: AsyncThrowingStream<CandleBar, Error>.Continuation?

    var calls: Int { lock.withLock { _calls } }
    var cancelled: Bool { lock.withLock { _cancelled } }
    var ready: Bool { lock.withLock { _cont != nil } }

    func factory() -> AsyncThrowingStream<CandleBar, Error> {
        lock.withLock { _calls += 1 }
        return AsyncThrowingStream<CandleBar, Error> { cont in
            self.lock.withLock { self._cont = cont }
            cont.onTermination = { [weak self] _ in self?.lock.withLock { self?._cancelled = true } }
        }
    }

    func emit(_ b: CandleBar) { (lock.withLock { _cont })?.yield(b) }
    func finish(throwing error: Error? = nil) {
        let c = lock.withLock { _cont }
        if let error { c?.finish(throwing: error) } else { c?.finish() }
    }
}

private struct DrainResult { var bars: [CandleBar] = []; var error: Error? }

private func drain(_ stream: AsyncThrowingStream<CandleBar, Error>) async -> DrainResult {
    var r = DrainResult()
    do { for try await b in stream { r.bars.append(b) } } catch { r.error = error }
    return r
}

/// Spin the cooperative pool until `cond` holds (bounded), yielding so actor work can run.
private func waitUntil(_ cond: @escaping () async -> Bool) async {
    for _ in 0..<100_000 where !(await cond()) { await Task.yield() }
}

/// Like `waitUntil`, but sleeps between checks (bounded ~10s) so background tasks get
/// scheduled even when the whole suite runs in parallel — pure yield-spinning can burn
/// its budget before a starved task ever runs.
private func settle(_ cond: @escaping () async -> Bool) async {
    for _ in 0..<10_000 {
        if await cond() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

private struct TestError: Error {}

@Suite("LiveCandleMulticaster")
struct LiveCandleMulticasterTests {

    @Test("two subscribers of one key share ONE driver and receive the same bars")
    func multicastAndDedup() async {
        let hub = LiveCandleMulticaster(now: openMarketClock)
        let probe = DriverProbe()
        let s1 = hub.subscribe(key: KEY) { probe.factory() }
        let s2 = hub.subscribe(key: KEY) { probe.factory() }
        let t1 = Task { await drain(s1) }
        let t2 = Task { await drain(s2) }
        await waitUntil { await hub.subscriberCount(KEY) == 2 }   // both attached

        probe.emit(bar(1000, close: 1.1))
        probe.emit(bar(1000, close: 1.2))
        probe.finish()
        let r1 = await t1.value
        let r2 = await t2.value

        #expect(probe.calls == 1)                                // ONE aggregation for both charts
        #expect(r1.bars.map(\.close) == [1.1, 1.2])
        #expect(r2.bars.map(\.close) == [1.1, 1.2])
    }

    @Test("a late subscriber immediately replays the current forming bar")
    func lateSubscriberReplays() async {
        let hub = LiveCandleMulticaster(now: openMarketClock)
        let probe = DriverProbe()
        let s1 = hub.subscribe(key: KEY) { probe.factory() }
        let t1 = Task { await drain(s1) }
        await waitUntil { probe.ready }
        probe.emit(bar(1000, close: 1.5))                        // becomes `current`

        let s2 = hub.subscribe(key: KEY) { probe.factory() }
        let t2 = Task { await drain(s2) }
        await waitUntil { await hub.subscriberCount(KEY) == 2 }   // s2 registered → replay delivered

        probe.emit(bar(1000, close: 1.6))
        probe.finish()
        let r1 = await t1.value
        let r2 = await t2.value

        #expect(probe.calls == 1)
        #expect(r1.bars.map(\.close) == [1.5, 1.6])
        #expect(r2.bars.map(\.close) == [1.5, 1.6])              // replay(1.5) then fan-out(1.6)
    }

    @Test("closing the last subscriber cancels the driver")
    func cancelOnLast() async {
        let hub = LiveCandleMulticaster(now: openMarketClock)
        let probe = DriverProbe()
        let s = hub.subscribe(key: KEY) { probe.factory() }
        let consumer = Task { await drain(s) }
        await waitUntil { probe.ready }

        consumer.cancel()                                        // drops the stream → unsubscribe
        await waitUntil { probe.cancelled }
        #expect(probe.cancelled)
        await waitUntil { await hub.subscriberCount(KEY) == 0 }
        #expect(await hub.subscriberCount(KEY) == 0)
    }

    @Test("a driver error finishes ALL subscribers with that error")
    func errorFansOut() async {
        let hub = LiveCandleMulticaster(now: openMarketClock)
        let probe = DriverProbe()
        let s1 = hub.subscribe(key: KEY) { probe.factory() }
        let s2 = hub.subscribe(key: KEY) { probe.factory() }
        let t1 = Task { await drain(s1) }
        let t2 = Task { await drain(s2) }
        await waitUntil { await hub.subscriberCount(KEY) == 2 }

        probe.finish(throwing: TestError())
        let r1 = await t1.value
        let r2 = await t2.value
        #expect(r1.error is TestError)
        #expect(r2.error is TestError)
    }

    @Test("a subscriber cancelled before registration lands never leaks a zombie driver")
    func cancelBeforeRegisterDoesNotLeak() async {
        // The consumer is cancelled IMMEDIATELY after subscribe, racing the actor-hop
        // that registers the continuation. If termination is observed before
        // registration (and never again after — handlers fire once), the entry keeps
        // a dead continuation forever and its driver consumes ticks until shutdown.
        // Repeat to give the race real chances to land in the bad order.
        let hub = LiveCandleMulticaster(now: openMarketClock)
        for i in 0..<50 {
            let probe = DriverProbe()
            let s = hub.subscribe(key: KEY) { probe.factory() }
            let consumer = Task { await drain(s) }
            consumer.cancel()
            _ = await consumer.value
            // Each subscribe whose stream terminates produces exactly one register hop
            // and one unregister hop — waiting on the hop count is quiescence, free of
            // the mid-flight ambiguity of polling subscriberCount directly.
            await settle { await hub.lifecycleHopCount() == 2 * (i + 1) }
            #expect(await hub.lifecycleHopCount() == 2 * (i + 1))
            #expect(await hub.subscriberCount(KEY) == 0)
            if probe.calls > 0 {       // register won the race → its driver must be dead
                await settle { probe.cancelled }
                #expect(probe.cancelled)
            }
        }
    }

    @Test("after the driver ends, a fresh subscribe starts a new driver")
    func restartsAfterEnd() async {
        let hub = LiveCandleMulticaster(now: openMarketClock)
        let probe = DriverProbe()
        let s1 = hub.subscribe(key: KEY) { probe.factory() }
        let t1 = Task { await drain(s1) }
        await waitUntil { probe.ready }
        probe.finish()                                           // driver ends
        _ = await t1.value
        #expect(probe.calls == 1)

        let s2 = hub.subscribe(key: KEY) { probe.factory() }
        let t2 = Task { await drain(s2) }
        await waitUntil { probe.calls == 2 }                     // new driver started
        #expect(probe.calls == 2)
        probe.finish()
        _ = await t2.value
    }
}
