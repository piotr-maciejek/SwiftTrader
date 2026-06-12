import Foundation

/// One shared live-candle aggregation per `(instrument, period)`, multicast to every chart that
/// displays it.
///
/// Without this layer, each chart that calls `streamCandles` builds its OWN forming bar from the
/// shared tick feed — so N charts of the same instrument+period (a main chart + an MTF panel + a
/// correlation cell) seed at different instants and drift apart on the live and recently-closed
/// bars. Here a single "driver" stream per key feeds every subscriber, and a chart that attaches
/// later immediately **replays** the current forming bar — so all charts show the identical bar.
///
/// Mirrors `DukascopySession`'s tick multicast: register/unregister via `onTermination`, replay
/// the latest value on attach, and ref-count so the driver runs only while someone is watching.
actor LiveCandleMulticaster {
    struct Key: Hashable, Sendable {
        let instrument: String
        let period: String
        var side: ChartSide = .bid
    }

    /// Produces the single per-key aggregation stream (the coordinator's `rawCandleStream`).
    /// Captures the coordinator weakly so the multicaster's persistent state never pins it across
    /// a reconnect; (re)invoked when the first subscriber for a key attaches.
    typealias DriverFactory = @Sendable () -> AsyncThrowingStream<CandleBar, Error>

    private final class Entry {
        var continuations: [UUID: AsyncThrowingStream<CandleBar, Error>.Continuation] = [:]
        var current: CandleBar?            // last published bar, replayed to late subscribers
        var task: Task<Void, Never>?       // the running driver
        var generation: Int = 0            // identity of the current driver run
    }

    private var entries: [Key: Entry] = [:]
    private var generationCounter = 0
    /// Ids whose stream terminated BEFORE their register hop landed (consumer cancelled
    /// immediately after subscribe). Register consumes the tombstone and skips the dead
    /// subscriber entirely. Ids currently live in an entry sit in `registeredIds`; both
    /// sets are bounded — every tombstone is consumed by its (always-spawned) register.
    private var preTerminated: Set<UUID> = []
    private var registeredIds: Set<UUID> = []
    /// Register/unregister hops processed so far. Test hook: a subscriber whose stream
    /// terminates produces exactly one of each, so tests can await race quiescence
    /// deterministically instead of polling ambiguous mid-flight state.
    private var lifecycleHops = 0
    /// Injectable clock so replay-eligibility (market open/closed) is testable without the
    /// wall clock. Defaults to the real time in production.
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    /// Subscribe a chart to the shared aggregation for `key`. The first subscriber starts the
    /// driver; a later subscriber attaches and immediately replays the current forming bar.
    /// `nonisolated` so the coordinator can call it synchronously and return the stream.
    nonisolated func subscribe(
        key: Key, driverFactory: @escaping DriverFactory
    ) -> AsyncThrowingStream<CandleBar, Error> {
        let id = UUID()
        return AsyncThrowingStream<CandleBar, Error> { continuation in
            // The register hop and the termination handler's unregister hop reach the
            // actor UNORDERED: a consumer cancelling right after subscribe can run
            // unregister first. `unregister` tombstones that case and `register`
            // consumes the tombstone — otherwise the dead continuation (whose handler
            // has already fired, once) would sit in the entry forever and pin a
            // zombie driver consuming ticks until coordinator shutdown.
            Task { await self.register(key: key, id: id, continuation: continuation, driverFactory: driverFactory) }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.unregister(key: key, id: id) }
            }
        }
    }

    private func register(
        key: Key, id: UUID,
        continuation: AsyncThrowingStream<CandleBar, Error>.Continuation,
        driverFactory: @escaping DriverFactory
    ) {
        lifecycleHops += 1
        // The stream died before this hop landed — its termination handler already ran
        // (and runs only once), so nothing would ever remove this continuation again.
        if preTerminated.remove(id) != nil { return }
        registeredIds.insert(id)
        let entry: Entry
        if let existing = entries[key] {
            entry = existing
        } else {
            entry = Entry()
            entries[key] = entry
        }
        // Insert, THEN replay — no `await` between, and `yield` is synchronous, so a concurrent
        // publish can't interleave: the new subscriber sees `current` via replay or the next bar
        // via fan-out, never both/neither, never reordered.
        entry.continuations[id] = continuation
        if let cur = entry.current, replayEligible(cur) {
            continuation.yield(cur)
        }
        if entry.task == nil {
            generationCounter += 1
            let gen = generationCounter
            entry.generation = gen
            entry.task = Task { [weak self] in
                await self?.runDriver(key: key, generation: gen, factory: driverFactory)
            }
        }
    }

    private func runDriver(key: Key, generation: Int, factory: DriverFactory) async {
        do {
            for try await bar in factory() {
                publish(key: key, generation: generation, bar: bar)
            }
            driverEnded(key: key, generation: generation, error: nil)
        } catch is CancellationError {
            driverEnded(key: key, generation: generation, error: nil)
        } catch {
            driverEnded(key: key, generation: generation, error: error)
        }
    }

    private func publish(key: Key, generation: Int, bar: CandleBar) {
        // Ignore a superseded driver (its key was torn down and rebuilt under a new generation).
        guard let entry = entries[key], entry.generation == generation else { return }
        entry.current = bar
        for (_, c) in entry.continuations { c.yield(bar) }
    }

    private func unregister(key: Key, id: UUID) {
        lifecycleHops += 1
        guard registeredIds.remove(id) != nil else {
            // Terminated before register landed — tombstone so register skips it.
            preTerminated.insert(id)
            return
        }
        guard let entry = entries[key] else { return }   // driver already ended / shutdown
        entry.continuations.removeValue(forKey: id)
        if entry.continuations.isEmpty {
            entry.task?.cancel()
            entries.removeValue(forKey: key)
        }
    }

    private func driverEnded(key: Key, generation: Int, error: Error?) {
        guard let entry = entries[key], entry.generation == generation else { return }
        // Finish every subscriber so each chart's retry loop wakes and re-subscribes (which, via
        // `register`, starts a fresh driver under a new generation). Clean finish and error both
        // drive the retry — matching the previous per-chart contract.
        for (_, c) in entry.continuations {
            if let error { c.finish(throwing: error) } else { c.finish() }
        }
        entry.task = nil
        entries.removeValue(forKey: key)
    }

    /// Cancel every driver and drop all state — a safety net for coordinator teardown so no driver
    /// keeps consuming a dead session's ticks if a subscriber ever leaked.
    func shutdown() {
        for (_, entry) in entries {
            entry.task?.cancel()
            for (_, c) in entry.continuations { c.finish() }
        }
        entries.removeAll()
    }

    /// Current subscriber count for a key (0 if none). Used by tests to synchronize
    /// deterministically on registration; harmless in production.
    func subscriberCount(_ key: Key) -> Int { entries[key]?.continuations.count ?? 0 }

    /// See `lifecycleHops`. Test hook; harmless in production.
    func lifecycleHopCount() -> Int { lifecycleHops }

    /// Replay only a genuinely-live forming bar, and only while the market is open — never a
    /// partial left over from before a weekend/holiday close (mirrors the driver's own gate).
    func replayEligible(_ bar: CandleBar) -> Bool {
        let n = now()
        return bar.partial
            && !NYTradingCalendar.isMarketClosed(at: n)
            && !NYTradingCalendar.isFXHoliday(at: n)
    }
}
