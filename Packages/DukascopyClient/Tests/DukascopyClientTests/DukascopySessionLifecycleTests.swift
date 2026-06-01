import Foundation
import Testing
@testable import DukascopyClient

/// Lifecycle behaviour that doesn't need a live connection: the state-change broadcast
/// and the terminal-teardown stream finishing. These guard the standalone recovery path
/// — a transport death must reach observers (`stateStream`) and must terminate the data
/// multicast consumers (`tickStream`/`orderEvents`/`newsEvents`) so they stop hanging.
@Suite("DukascopySession lifecycle")
struct DukascopySessionLifecycleTests {

    private func makeSession() -> DukascopySession {
        DukascopySession(
            environment: .demo,
            credentials: AuthCredentials(login: "test", passwordHash: "deadbeef")
        )
    }

    /// Race `op` against a timeout so a regression that leaves a stream hanging fails the
    /// test instead of wedging the whole suite. Returns nil on timeout.
    private func withTimeout<T: Sendable>(
        _ seconds: Double, _ op: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await op() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    @Test("stateStream yields the current state immediately on subscribe")
    func stateStreamYieldsCurrent() async {
        let session = makeSession()
        let first: DukascopySession.State? = await withTimeout(2) {
            for await state in await session.stateStream() { return state }
            return .connected  // sentinel: an empty stream (shouldn't happen) ≠ .disconnected
        }
        // nil = timed out; otherwise the first yielded state.
        #expect(first == .disconnected)
    }

    // MARK: - Quote watchdog heuristic (shouldResubscribe)

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("no resubscribe when nothing is subscribed")
    func watchdogIgnoresEmpty() {
        #expect(DukascopySession.shouldResubscribe(
            subscribed: [], quoteSubscribedAt: [:], lastTickAt: [:],
            lastAnyTickAt: t0, now: t0) == false)
    }

    @Test("no resubscribe when the feed is dead (closed market) — nothing has ticked")
    func watchdogIgnoresDeadFeed() {
        // AUD/CHF subscribed 60s ago, never ticked, but NOTHING has ticked recently.
        #expect(DukascopySession.shouldResubscribe(
            subscribed: ["AUD/CHF"],
            quoteSubscribedAt: ["AUD/CHF": t0],
            lastTickAt: [:],
            lastAnyTickAt: t0,                       // last tick was at t0…
            now: t0.addingTimeInterval(60)) == false) // …60s ago → feed not live
    }

    @Test("resubscribe when a subscribed pair never ticked while the feed is live")
    func watchdogFlagsSilentPairOnLiveFeed() {
        // EUR/USD ticking 1s ago (feed live); AUD/CHF subscribed 30s ago, never ticked.
        let now = t0.addingTimeInterval(30)
        #expect(DukascopySession.shouldResubscribe(
            subscribed: ["EUR/USD", "AUD/CHF"],
            quoteSubscribedAt: ["EUR/USD": t0, "AUD/CHF": t0],
            lastTickAt: ["EUR/USD": now.addingTimeInterval(-1)],
            lastAnyTickAt: now.addingTimeInterval(-1),
            now: now) == true)
    }

    @Test("no resubscribe when the pair has already ticked")
    func watchdogIgnoresPairThatTicked() {
        let now = t0.addingTimeInterval(30)
        #expect(DukascopySession.shouldResubscribe(
            subscribed: ["AUD/CHF"],
            quoteSubscribedAt: ["AUD/CHF": t0],
            lastTickAt: ["AUD/CHF": now.addingTimeInterval(-5)],
            lastAnyTickAt: now.addingTimeInterval(-5),
            now: now) == false)
    }

    @Test("no resubscribe within the grace window after subscribing")
    func watchdogRespectsGrace() {
        // Subscribed only 5s ago — give it time before crying foul, even on a live feed.
        let now = t0.addingTimeInterval(5)
        #expect(DukascopySession.shouldResubscribe(
            subscribed: ["EUR/USD", "AUD/CHF"],
            quoteSubscribedAt: ["EUR/USD": t0, "AUD/CHF": t0],
            lastTickAt: ["EUR/USD": now.addingTimeInterval(-1)],
            lastAnyTickAt: now.addingTimeInterval(-1),
            now: now) == false)
    }

    @Test("close() finishes the tick/order/news multicast streams so consumers terminate")
    func closeFinishesDataStreams() async {
        let session = makeSession()
        let tick = await session.tickStream()
        let order = await session.orderEvents()
        let news = await session.newsEvents()
        // Let the (async) stream registrations land on the actor before tearing down.
        for _ in 0..<200 { await Task.yield() }

        await session.close()

        // Each loop must COMPLETE (stream finished) rather than hang. The timeout turns a
        // regression — a stream left open — into a failure instead of a wedged suite.
        let completed = await withTimeout(3) { () -> Bool in
            for await _ in tick {}
            for await _ in order {}
            for await _ in news {}
            return true
        }
        #expect(completed == true)
    }
}
