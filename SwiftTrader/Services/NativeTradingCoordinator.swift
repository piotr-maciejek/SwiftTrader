import Foundation
import DukascopyClient
import os

private let tradingLog = Logger(subsystem: "com.swifttrader", category: "native")

enum NativeTradingError: LocalizedError {
    case notConnected
    case notSupported(String)
    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to Dukascopy."
        case .notSupported(let what): return "\(what) is not supported in standalone mode yet."
        }
    }
}

/// Standalone `TradingCoordinating` backed by a native `DukascopySession` — places
/// market/limit/stop orders, closes positions, cancels pending orders, and streams
/// live positions/account/spreads (mirrors the server `TradingCoordinator` surface,
/// so `TradingViewModel` is unchanged). Order placement is fire-and-forget; the
/// resulting state arrives via the session's `orderEvents()` and is republished here.
///
/// Wire amount is in UNITS; the app's `amount` is in millions (JForex convention,
/// same as server mode), so units = amount × 1_000_000.
actor NativeTradingCoordinator: TradingCoordinating {
    private let session: DukascopySession?

    private var rates: [String: Double] = [:]     // slashless instrument → mid price
    private var spreads: [String: Double] = [:]   // slashless instrument → spread (price units)
    private var groups: [OrderGroup] = []
    private var account: DukascopyClient.AccountInfo?

    private var snapshotConts: [UUID: AsyncThrowingStream<TradingSnapshot, Error>.Continuation] = [:]
    private var pendingConts: [UUID: AsyncThrowingStream<PendingOrdersSnapshot, Error>.Continuation] = [:]
    /// Late/unsolicited broker rejections (e.g. a modify dropped after its ack window).
    private var rejectionConts: [UUID: AsyncStream<String>.Continuation] = [:]
    /// Memoized one-time startup: loads the connect-time account + groups and starts the live
    /// listeners. Awaited by every stream registration so the first yield can't observe an empty
    /// `groups` (see `startup`). A fresh coordinator (per reconnect/attach) gets a fresh task.
    private var startupTask: Task<Void, Never>?
    private var lastTickEmit = Date.distantPast
    /// When the last tick arrived — feeds `Account.lastTickAgeMs` so the connection banner
    /// can flag a degraded (silent) feed. Nil until the first tick.
    private var lastTickAt: Date?
    /// Live session connectivity, driven by the session's state stream — feeds
    /// `Account.connected` so a dead transport raises the banner instead of a stale `true`.
    private var sessionConnected = true
    /// Guards the closed-position reconcile so an overlapping trigger (post-close + periodic sweep)
    /// can't fire a second redundant query while one is already in flight.
    private var reconcileInFlight = false

    init(session: DukascopySession?) {
        self.session = session
    }

    // MARK: - Order operations

    func submitOrder(instrument: String, direction: String, amount: Double,
                     stopLoss: Double, takeProfit: Double,
                     orderType: String, entryPrice: Double?) async throws -> Position {
        guard let session else { throw NativeTradingError.notConnected }
        let wire = NativeMarketDataCoordinator.toSlashedPair(instrument)
        let scale = instrument.contains("JPY") ? 3 : 5
        let units = BigDecimalValue(amount * 1_000_000, scale: 0)
        let sl = stopLoss > 0 ? BigDecimalValue(stopLoss, scale: scale) : nil
        let tp = takeProfit > 0 ? BigDecimalValue(takeProfit, scale: scale) : nil
        let label = "ST_\(instrument)"

        switch orderType {
        case "MARKET":
            try await session.submitMarketOrder(
                instrument: wire, side: direction, amount: units,
                stopLoss: sl, takeProfit: tp, label: label)
        case "BUY_LIMIT", "SELL_LIMIT", "BUY_STOP", "SELL_STOP":
            guard let entryPrice else { throw NativeTradingError.notSupported("pending order without entry price") }
            let kind: PendingKind = orderType.hasSuffix("LIMIT") ? .limit : .stop
            try await session.submitPendingOrder(
                instrument: wire, side: direction, kind: kind, amount: units,
                triggerPrice: BigDecimalValue(entryPrice, scale: scale),
                stopLoss: sl, takeProfit: tp, label: label)
        default:
            throw NativeTradingError.notSupported("order type \(orderType)")
        }
        // Fire-and-forget; the live snapshot delivers the real position. Best-effort echo.
        return Position(label: label, instrument: instrument, direction: direction, amount: amount,
                        openPrice: entryPrice ?? 0, stopLoss: stopLoss, takeProfit: takeProfit,
                        profitLoss: 0, profitLossPips: 0, state: "PENDING")
    }

    /// Serves both "close position" (label = orderGroupId) and "cancel pending"
    /// (label = the pending order's orderId) — the app uses one button for both.
    func closeOrder(label: String) async throws {
        guard let session else { throw NativeTradingError.notConnected }
        let live = await session.positionsSnapshot()
        // If `label` is a PENDING order's id, cancel it; otherwise close the group.
        for g in live {
            if let o = g.orders.first(where: { $0.orderId == label }), o.state == "PENDING" {
                try await session.cancelOrder(orderId: label)
                return
            }
        }
        try await session.closePosition(positionId: label)
        // The close is fire-and-forget; its confirming OrderGroup CLOSE event can be dropped by the
        // feed, leaving the position shown as open. Reconcile against the broker's closed-position DB
        // shortly after so the UI self-heals even when that event never arrives. The periodic sweep
        // (see the self-heal poll) is the general backstop; this just makes the common path snappy.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.reconcileStaleClosed()
        }
    }

    /// Drop any locally-open position the broker reports closed (a missed CLOSE event). Windowed to
    /// the last 2h — a freshly-closed position always falls inside it, and a closed-position query
    /// over that span is cheap. Safe to call often: it only prunes broker-confirmed closes.
    private func reconcileStaleClosed() async {
        guard let session, !reconcileInFlight else { return }
        reconcileInFlight = true
        defer { reconcileInFlight = false }
        let sinceMs = Int64(Date().timeIntervalSince1970 * 1000) - 2 * 60 * 60 * 1000
        await session.reconcileClosedPositions(sinceMillis: sinceMs)
    }

    /// Modify (or add/remove) SL and TP on an open position or pending entry.
    /// `label` is the orderGroupId (open position) or the pending entry's orderId.
    ///
    /// Dukascopy rate-limits order ops (~1/s); firing SL and TP back-to-back drops the
    /// second (verified on demo 2026-06-01, and the same issue server mode fixed in
    /// `JForexStrategy.modifyOrder`). So we mirror that: send only the leg that actually
    /// changed, and when both change, wait for the first to land before sending the second.
    func modifyOrder(label: String, stopLoss: Double, takeProfit: Double) async throws -> Position {
        guard let session else { throw NativeTradingError.notConnected }
        let live = await session.positionsSnapshot()
        guard let group = resolveGroup(label: label, in: live),
              let gid = group.orderGroupId, let inst = group.instrument else {
            throw NativeTradingError.notSupported("modifying SL/TP for unknown order \(label)")
        }
        let scale = inst.contains("JPY") ? 3 : 5
        let st = protective(group)
        let slChanged = priceDiffers(stopLoss, st.slPrice, scale: scale)
        let tpChanged = priceDiffers(takeProfit, st.tpPrice, scale: scale)

        if slChanged {
            let firstSentAt = Date()
            try await applyLeg(gid: gid, isTP: false, newPrice: stopLoss, existingId: st.slId, scale: scale)
            if tpChanged {
                await waitForLeg(gid: gid, isTP: false, expected: stopLoss, scale: scale)
                // Spacing floor: waitForLeg confirming (or timing out) isn't enough on its
                // own to guarantee the legs land a full rate-limit window apart.
                let remainder = Self.legSpacingRemainder(sinceFirstSend: firstSentAt)
                if remainder > 0 { try? await Task.sleep(for: .seconds(remainder)) }
            }
        }
        if tpChanged {
            try await applyLeg(gid: gid, isTP: true, newPrice: takeProfit, existingId: st.tpId, scale: scale)
            if slChanged, await !waitForLeg(gid: gid, isTP: true, expected: takeProfit, scale: scale) {
                tradingLog.warning(
                    "modifyOrder \(gid, privacy: .public): TP leg not reflected in snapshot within timeout — verify the position's protection"
                )
            }
        }

        // Best-effort echo; the authoritative state arrives via the snapshot stream.
        let after = (await session.positionsSnapshot()).first { $0.orderGroupId == gid }
        return after.flatMap { position(from: $0) ?? pendingEcho($0, sl: stopLoss, tp: takeProfit) }
            ?? Position(label: gid, instrument: inst.replacingOccurrences(of: "/", with: ""),
                        direction: group.side ?? "BUY",
                        amount: (group.amount?.doubleValue ?? 0) / 1_000_000,
                        openPrice: group.pricePosOpen?.doubleValue ?? 0,
                        stopLoss: stopLoss, takeProfit: takeProfit,
                        profitLoss: 0, profitLossPips: 0, state: "FILLED")
    }

    /// Amend a resting pending order's entry/trigger price in place. `label` is the pending order's
    /// id (= its opening order's orderId). Resolves the group, recomputes limit-vs-stop from the
    /// opening order's `stopDirection`, and sends the amend; authoritative state returns via the stream.
    func modifyPendingEntry(label: String, newTriggerPrice: Double) async throws {
        guard let session else { throw NativeTradingError.notConnected }
        let live = await session.positionsSnapshot()
        guard let group = resolveGroup(label: label, in: live),
              let gid = group.orderGroupId, let inst = group.instrument,
              let opening = openingOrder(group), opening.state == "PENDING",
              let orderId = opening.orderId else {
            throw NativeTradingError.notSupported("modifying entry price for unknown pending order \(label)")
        }
        let scale = inst.contains("JPY") ? 3 : 5
        let isLimit = orderType(side: opening.side ?? "BUY", stopDirection: opening.stopDirection).hasSuffix("LIMIT")
        try await session.modifyPendingEntry(
            orderGroupId: gid, orderId: orderId,
            newTriggerPrice: BigDecimalValue(newTriggerPrice, scale: scale), isLimit: isLimit)
    }

    /// Apply one SL/TP leg: modify an existing protective order, add a new one, or
    /// (price ≤ 0) cancel the existing one.
    private func applyLeg(gid: String, isTP: Bool, newPrice: Double, existingId: String?, scale: Int) async throws {
        guard let session else { throw NativeTradingError.notConnected }
        if newPrice > 0 {
            try await session.modifyProtectiveOrder(
                orderGroupId: gid, isTakeProfit: isTP,
                newPrice: BigDecimalValue(newPrice, scale: scale), existingProtectiveOrderId: existingId)
        } else if let existingId {
            try await session.cancelOrder(orderId: existingId)   // clear the protective order
        }
        // price ≤ 0 with no existing order → nothing to do.
    }

    /// Poll the live snapshot until `gid`'s leg reflects `expected` (or timeout).
    /// Returns whether the leg was actually observed to land — a `false` return is a
    /// timeout, NOT a confirmation, so callers must not treat it as "safe to proceed".
    @discardableResult
    private func waitForLeg(gid: String, isTP: Bool, expected: Double, scale: Int, timeout: TimeInterval = 4) async -> Bool {
        guard let session else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            guard let g = (await session.positionsSnapshot()).first(where: { $0.orderGroupId == gid }) else { continue }
            let actual = isTP ? protective(g).tpPrice : protective(g).slPrice
            if !priceDiffers(actual, expected, scale: scale) { return true }
        }
        return false
    }

    /// How much longer the second SL/TP leg must wait so the two sends sit at least a
    /// full broker rate-limit window apart, however the first leg's wait ended (early
    /// confirmation or timeout). 1.2s = the ~1/s order-op pacing plus margin.
    static func legSpacingRemainder(
        sinceFirstSend sentAt: Date, now: Date = Date(), minimumSpacing: TimeInterval = 1.2
    ) -> TimeInterval {
        max(0, minimumSpacing - now.timeIntervalSince(sentAt))
    }

    /// Resolve a group by orderGroupId (open position) or by a contained order's id (pending entry).
    private func resolveGroup(label: String, in groups: [OrderGroup]) -> OrderGroup? {
        groups.first { $0.orderGroupId == label }
            ?? groups.first { g in g.orders.contains { $0.orderId == label } }
    }

    /// Current SL/TP prices and their protective-order ids (0 / nil when absent),
    /// distinguished by `stopDirection` (SL: LESS_BID/GREATER_ASK; TP: GREATER_BID/LESS_ASK).
    private func protective(_ g: OrderGroup) -> (slPrice: Double, slId: String?, tpPrice: Double, tpId: String?) {
        var slPrice = 0.0, tpPrice = 0.0
        var slId: String?, tpId: String?
        for o in g.orders where o.direction == "CLOSE" {
            guard let price = o.priceStop?.doubleValue else { continue }
            switch o.stopDirection {
            case "LESS_BID", "GREATER_ASK": slPrice = price; slId = o.orderId
            case "GREATER_BID", "LESS_ASK": tpPrice = price; tpId = o.orderId
            default: break
            }
        }
        return (slPrice, slId, tpPrice, tpId)
    }

    /// Treat near-equal prices (within half a pippette at the instrument's scale) as unchanged.
    private func priceDiffers(_ a: Double, _ b: Double, scale: Int) -> Bool {
        abs(a - b) > pow(10.0, Double(-scale)) / 2
    }

    /// Echo for a pending entry whose SL/TP was just changed (its `position(from:)` is nil
    /// because the entry isn't FILLED).
    private func pendingEcho(_ g: OrderGroup, sl: Double, tp: Double) -> Position? {
        guard let opening = openingOrder(g), opening.state == "PENDING",
              let id = g.orderGroupId, let inst = g.instrument else { return nil }
        return Position(
            label: id, instrument: inst.replacingOccurrences(of: "/", with: ""),
            direction: opening.side ?? "BUY",
            amount: (opening.amount?.doubleValue ?? g.amount?.doubleValue ?? 0) / 1_000_000,
            openPrice: opening.priceStop?.doubleValue ?? 0,
            stopLoss: sl, takeProfit: tp, profitLoss: 0, profitLossPips: 0, state: "PENDING")
    }

    // MARK: - Snapshot streams

    nonisolated func streamSnapshots() -> AsyncThrowingStream<TradingSnapshot, Error> {
        AsyncThrowingStream { cont in
            let id = UUID()
            let task = Task { await self.registerSnapshot(id: id, cont: cont) }
            cont.onTermination = { _ in task.cancel(); Task { await self.unregisterSnapshot(id) } }
        }
    }

    nonisolated func streamPendingOrders() -> AsyncThrowingStream<PendingOrdersSnapshot, Error> {
        AsyncThrowingStream { cont in
            let id = UUID()
            let task = Task { await self.registerPending(id: id, cont: cont) }
            cont.onTermination = { _ in task.cancel(); Task { await self.unregisterPending(id) } }
        }
    }

    nonisolated func orderRejections() -> AsyncStream<String> {
        AsyncStream { cont in
            let id = UUID()
            let task = Task { await self.registerRejections(id: id, cont: cont) }
            cont.onTermination = { _ in task.cancel(); Task { await self.unregisterRejections(id) } }
        }
    }

    private func registerSnapshot(id: UUID, cont: AsyncThrowingStream<TradingSnapshot, Error>.Continuation) async {
        guard session != nil else { cont.finish(throwing: NativeTradingError.notConnected); return }
        snapshotConts[id] = cont
        await ensureStarted()
        cont.yield(buildSnapshot())
    }
    private func unregisterSnapshot(_ id: UUID) { snapshotConts[id] = nil }

    private func registerPending(id: UUID, cont: AsyncThrowingStream<PendingOrdersSnapshot, Error>.Continuation) async {
        guard session != nil else { cont.finish(throwing: NativeTradingError.notConnected); return }
        pendingConts[id] = cont
        await ensureStarted()
        cont.yield(PendingOrdersSnapshot(pendingOrders: buildPending()))
    }
    private func unregisterPending(_ id: UUID) { pendingConts[id] = nil }

    private func registerRejections(id: UUID, cont: AsyncStream<String>.Continuation) async {
        guard session != nil else { cont.finish(); return }
        rejectionConts[id] = cont
        await ensureStarted()
    }
    private func unregisterRejections(_ id: UUID) { rejectionConts[id] = nil }

    /// Run (once) the memoized startup and await its completion — so a caller that yields right after
    /// is guaranteed `account` + `groups` are loaded. Concurrent registrations share the one task.
    private func ensureStarted() async {
        if startupTask == nil { startupTask = Task { await self.startup() } }
        await startupTask?.value
    }

    /// Start the live listeners, then load the connect-time account + groups DETERMINISTICALLY:
    /// snapshot `groups` only AFTER `accountSnapshot()` resolves. That call blocks until the
    /// PackedAccountInfo lands, and the same message populates `positions` — so by the time we read
    /// it, the resting pending-order / position groups are present. Snapshotting before the account
    /// arrives (the old bug) left `groups` empty, so the first stream yield dropped resting pending
    /// orders that never generate a later order event.
    private func startup() async {
        guard let session else { return }
        startListenerTasks(session)
        account = try? await session.accountSnapshot()
        groups = await session.positionsSnapshot()
    }

    private func startListenerTasks(_ session: DukascopySession) {
        // Order/position updates → refresh groups + account, re-emit both streams
        // (and surface any broker rejection riding on the event).
        Task { [weak self] in
            guard let self, let session = await self.session else { return }
            for await event in await session.orderEvents() { await self.onOrderEvent(event) }
        }
        // Ticks → update rates/spreads + live P&L (throttled).
        Task { [weak self] in
            guard let self, let session = await self.session else { return }
            for await tick in await session.tickStream() { await self.onTick(tick) }
        }
        // Session state → drive the connection banner's `connected` flag and re-emit so a
        // transport death surfaces immediately, even with no further ticks.
        Task { [weak self] in
            guard let self, let session = await self.session else { return }
            for await state in await session.stateStream() { await self.onSessionState(state) }
        }
        // Account + order-group self-heal poll. The deterministic `startup` load covers the connect
        // case; this keeps equity live and re-snapshots groups so orders placed/cancelled mid-session
        // (incl. from another machine) — which may not generate a local order event — still surface.
        // `refreshGroupsIfChanged` re-emits only on a real change, so there's no churn.
        Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self, let session = await self.session else { return }
                if let acct = try? await session.accountSnapshot(timeout: 15) {
                    await self.updateAccount(acct)
                }
                await self.refreshGroupsIfChanged()
                // Backstop for a missed CLOSE event from ANY cause (manual close, SL/TP fill, or a
                // close on another machine): every ~10s, prune positions the broker reports closed.
                // Throttled relative to the 2s account poll so the extra closed-position query is light.
                tick += 1
                if tick % 5 == 0 { await self.reconcileStaleClosed() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Re-snapshot the session's order groups and re-emit if the derived pending orders or positions
    /// changed. Guards against the connect race where `groups` is captured (via `positionsSnapshot()`)
    /// before the PackedAccountInfo lands: a resting pending order delivered just after that snapshot,
    /// and never modified, would otherwise never surface (it generates no `orderEvents()`). Polled
    /// from the account loop so it converges within one interval; the change check keeps it quiet when
    /// nothing moved.
    private func refreshGroupsIfChanged() async {
        guard let session else { return }
        let oldPending = buildPending()
        let oldPositions = groups.compactMap { position(from: $0) }
        groups = await session.positionsSnapshot()
        if buildPending() != oldPending { emitPending() }
        if groups.compactMap({ position(from: $0) }) != oldPositions { emitSnapshot() }
    }

    private func updateAccount(_ acct: DukascopyClient.AccountInfo) {
        account = acct
        emitSnapshot()
    }

    private func onSessionState(_ state: DukascopySession.State) {
        sessionConnected = (state == .connected)
        emitSnapshot()
    }

    private func onOrderEvent(_ event: OrderEvent) async {
        guard let session else { return }
        // Surface broker rejections that arrive after the submitting call already
        // returned (the in-call ack window catches the prompt ones, which throw).
        if let message = Self.rejectionMessage(for: event) {
            for (_, c) in rejectionConts { c.yield(message) }
        }
        groups = await session.positionsSnapshot()
        account = try? await session.accountSnapshot()
        emitSnapshot()
        emitPending()
    }

    /// Human-readable description of a rejection carried by an order event, or nil.
    static func rejectionMessage(for event: OrderEvent) -> String? {
        switch event {
        case .response(let r) where r.isRejected:
            let detail = r.notes ?? r.comments
            return "Order rejected (\(r.state ?? "REJECTED"))"
                + (detail.map { ": \($0)" } ?? "")
                + (r.instrument.map { " — \($0)" } ?? "")
        case .order(let o) where ["REJECTED", "ERROR", "REVOKED"].contains(o.state ?? ""):
            return "Order rejected (\(o.state ?? "REJECTED"))"
                + (o.instrument.map { " — \($0)" } ?? "")
        default:
            return nil
        }
    }

    /// Subscribe the cross pair needed to convert `quoteCurrency` into `accountCurrency`
    /// so a conversion rate starts streaming for position sizing. Both orderings are
    /// requested (only the one Dukascopy actually lists produces ticks; the other is
    /// ignored upstream, which is harmless). No-op when the currencies already match.
    func ensureConversionRate(quoteCurrency: String, accountCurrency: String) async {
        guard let session, quoteCurrency != accountCurrency else { return }
        let pairs: Set<String> = ["\(quoteCurrency)/\(accountCurrency)", "\(accountCurrency)/\(quoteCurrency)"]
        try? await session.ensureSubscribedQuotes(pairs)
    }

    /// Latest live (bid, ask) reconstructed from the per-tick mid + spread (mid = (bid+ask)/2,
    /// spread = ask−bid, so bid = mid − spread/2, ask = mid + spread/2). Updated on EVERY tick
    /// (unlike the throttled snapshot), so it's the freshest price at the moment of an order press.
    func currentQuote(instrument: String) async -> (bid: Double, ask: Double)? {
        let key = instrument.replacingOccurrences(of: "/", with: "")
        guard let mid = rates[key], let spread = spreads[key] else { return nil }
        return (bid: mid - spread / 2, ask: mid + spread / 2)
    }

    private func onTick(_ tick: CurrencyMarket) {
        lastTickAt = Date()
        let key = tick.instrument.replacingOccurrences(of: "/", with: "")
        // Only accept a sane two-sided quote. A degenerate tick (bid ≤ 0, missing side, or crossed)
        // — which the feed can emit briefly right after connect — would otherwise poison rates/spreads
        // (spread ≈ the whole price when bid ≈ 0), inflating the bid/ask readout, the order-box risk,
        // position sizing AND the captured slippage press price. Drop it; keep the last good values.
        if let bid = tick.bestBid?.doubleValue, let ask = tick.bestAsk?.doubleValue,
           bid > 0, ask > 0, ask >= bid {
            rates[key] = (bid + ask) / 2
            spreads[key] = ask - bid
        }
        // Throttle live P&L re-emits to ~3/s so a busy tape doesn't flood the main actor.
        let now = Date()
        if now.timeIntervalSince(lastTickEmit) > 0.33 {
            lastTickEmit = now
            emitSnapshot()
        }
    }

    // MARK: - Mapping

    private func emitSnapshot() {
        let snap = buildSnapshot()
        for (_, c) in snapshotConts { c.yield(snap) }
    }
    private func emitPending() {
        let snap = PendingOrdersSnapshot(pendingOrders: buildPending())
        for (_, c) in pendingConts { c.yield(snap) }
    }

    private func buildSnapshot() -> TradingSnapshot {
        let positions = groups.compactMap { position(from: $0) }
        let connected = sessionConnected && session != nil
        // Tick-age only signals a degraded feed while the market is open — FX is closed
        // weekends/holidays, so no ticks then is healthy, not stale. Zero until the first
        // tick (or while closed) keeps the banner from firing on a fresh connect.
        let now = Date()
        let marketOpen = !NYTradingCalendar.isMarketClosed(at: now) && !NYTradingCalendar.isFXHoliday(at: now)
        let tickAgeMs: Int64 = (marketOpen && lastTickAt != nil)
            ? Int64(now.timeIntervalSince(lastTickAt!) * 1000)
            : 0
        let acct: Account = account.map { Account(native: $0, connected: connected, lastTickAgeMs: tickAgeMs) }
            ?? Account(balance: 0, equity: 0, usedMargin: 0, freeMargin: 0,
                       currency: "USD", leverage: 0, connected: connected, lastTickAgeMs: tickAgeMs)
        // Spreads in PRICE units (ask − bid), matching server mode — JForexStrategy
        // broadcasts ask−bid, not pips. The visual-order R:R and risk-sizing formulas add
        // the spread to price-unit distances, so publishing pips here made the spread
        // ~10,000× too large and collapsed R:R to 0 (and skewed position sizing).
        // `rates` rides along so position sizing can convert quote-currency risk into
        // the account currency (server mode sends no rates and sizing degrades safely).
        return TradingSnapshot(positions: positions, account: acct, spreads: spreads, rates: rates)
    }

    private func buildPending() -> [PendingOrder] {
        groups.compactMap { pendingOrder(from: $0) }
    }

    private func openingOrder(_ g: OrderGroup) -> OrderMsg? {
        g.orders.first { $0.direction == "OPEN" }
    }

    /// A filled position: the group's opening order is not PENDING.
    private func position(from g: OrderGroup) -> Position? {
        guard let opening = openingOrder(g), opening.state != "PENDING",
              let id = g.orderGroupId, let inst = g.instrument else { return nil }
        let slashless = inst.replacingOccurrences(of: "/", with: "")
        let side = g.side ?? opening.side ?? "BUY"
        let open = g.pricePosOpen?.doubleValue ?? opening.pricePosOpen?.doubleValue ?? 0
        let amountUnits = g.amount?.doubleValue ?? 0
        let (sl, tp) = stopLossTakeProfit(g)
        let mark = rates[slashless] ?? g.pricePl?.doubleValue ?? open
        let pnl = PnLConverter.compute(
            side: side, openPrice: open, markPrice: mark, amountUnits: amountUnits,
            instrument: slashless, accountCurrency: account?.currency ?? "USD", rates: rates)
        return Position(
            label: id, instrument: slashless, direction: side,
            amount: amountUnits / 1_000_000, openPrice: open,
            stopLoss: sl, takeProfit: tp, profitLoss: pnl.money, profitLossPips: pnl.pips,
            state: opening.state ?? "FILLED")
    }

    /// A pending entry order (limit/stop not yet triggered).
    private func pendingOrder(from g: OrderGroup) -> PendingOrder? {
        guard let opening = openingOrder(g), opening.state == "PENDING",
              let orderId = opening.orderId, let inst = g.instrument else { return nil }
        let slashless = inst.replacingOccurrences(of: "/", with: "")
        let side = opening.side ?? "BUY"
        let trigger = opening.priceStop?.doubleValue ?? 0
        let amountUnits = opening.amount?.doubleValue ?? g.amount?.doubleValue ?? 0
        let (sl, tp) = stopLossTakeProfit(g)
        return PendingOrder(
            label: orderId, instrument: slashless, direction: side,
            amount: amountUnits / 1_000_000, openPrice: trigger,
            stopLoss: sl, takeProfit: tp, state: "PENDING",
            orderType: orderType(side: side, stopDirection: opening.stopDirection),
            groupId: g.orderGroupId ?? "")
    }

    /// SL/TP prices from the group's protective CLOSE orders, distinguished by
    /// `stopDirection` (SL: LESS_BID/GREATER_ASK; TP: GREATER_BID/LESS_ASK).
    private func stopLossTakeProfit(_ g: OrderGroup) -> (Double, Double) {
        var sl = 0.0, tp = 0.0
        for o in g.orders where o.direction == "CLOSE" {
            guard let price = o.priceStop?.doubleValue else { continue }
            switch o.stopDirection {
            case "LESS_BID", "GREATER_ASK": sl = price
            case "GREATER_BID", "LESS_ASK": tp = price
            default: break
            }
        }
        return (sl, tp)
    }

    /// Pending order type string from side + entry stopDirection.
    private func orderType(side: String, stopDirection: String?) -> String {
        switch stopDirection {
        case "LESS_ASK": return "BUY_LIMIT"
        case "GREATER_BID": return "SELL_LIMIT"
        case "GREATER_ASK": return "BUY_STOP"
        case "LESS_BID": return "SELL_STOP"
        default: return side == "BUY" ? "BUY_LIMIT" : "SELL_LIMIT"
        }
    }
}
