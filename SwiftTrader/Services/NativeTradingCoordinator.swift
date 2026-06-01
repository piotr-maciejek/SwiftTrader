import Foundation
import DukascopyClient

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
    private var listenersStarted = false
    private var lastTickEmit = Date.distantPast

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
            try await applyLeg(gid: gid, isTP: false, newPrice: stopLoss, existingId: st.slId, scale: scale)
            if tpChanged { await waitForLeg(gid: gid, isTP: false, expected: stopLoss, scale: scale) }
        }
        if tpChanged {
            try await applyLeg(gid: gid, isTP: true, newPrice: takeProfit, existingId: st.tpId, scale: scale)
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

    /// Poll the live snapshot until `gid`'s leg reflects `expected` (or timeout), so a
    /// following leg isn't sent inside Dukascopy's per-second order window.
    private func waitForLeg(gid: String, isTP: Bool, expected: Double, scale: Int, timeout: TimeInterval = 4) async {
        guard let session else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            guard let g = (await session.positionsSnapshot()).first(where: { $0.orderGroupId == gid }) else { continue }
            let actual = isTP ? protective(g).tpPrice : protective(g).slPrice
            if !priceDiffers(actual, expected, scale: scale) { return }
        }
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

    private func registerSnapshot(id: UUID, cont: AsyncThrowingStream<TradingSnapshot, Error>.Continuation) async {
        guard session != nil else { cont.finish(throwing: NativeTradingError.notConnected); return }
        snapshotConts[id] = cont
        await startListenersIfNeeded()
        cont.yield(buildSnapshot())
    }
    private func unregisterSnapshot(_ id: UUID) { snapshotConts[id] = nil }

    private func registerPending(id: UUID, cont: AsyncThrowingStream<PendingOrdersSnapshot, Error>.Continuation) async {
        guard session != nil else { cont.finish(throwing: NativeTradingError.notConnected); return }
        pendingConts[id] = cont
        await startListenersIfNeeded()
        cont.yield(PendingOrdersSnapshot(pendingOrders: buildPending()))
    }
    private func unregisterPending(_ id: UUID) { pendingConts[id] = nil }

    private func startListenersIfNeeded() async {
        guard !listenersStarted, let session else { return }
        listenersStarted = true
        groups = await session.positionsSnapshot()
        account = try? await session.accountSnapshot()
        // Order/position updates → refresh groups + account, re-emit both streams.
        Task { [weak self] in
            guard let self, let session = await self.session else { return }
            for await _ in await session.orderEvents() { await self.onOrderEvent() }
        }
        // Ticks → update rates/spreads + live P&L (throttled).
        Task { [weak self] in
            guard let self, let session = await self.session else { return }
            for await tick in await session.tickStream() { await self.onTick(tick) }
        }
    }

    private func onOrderEvent() async {
        guard let session else { return }
        groups = await session.positionsSnapshot()
        account = try? await session.accountSnapshot()
        emitSnapshot()
        emitPending()
    }

    private func onTick(_ tick: CurrencyMarket) {
        let key = tick.instrument.replacingOccurrences(of: "/", with: "")
        if let bid = tick.bestBid?.doubleValue, let ask = tick.bestAsk?.doubleValue {
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
        let acct: Account = account.map { Account(native: $0, connected: true) }
            ?? Account(balance: 0, equity: 0, usedMargin: 0, freeMargin: 0,
                       currency: "USD", leverage: 0, connected: session != nil, lastTickAgeMs: 0)
        // Spreads keyed slashless, in pips, to match server-mode `spreads`.
        var pipSpreads: [String: Double] = [:]
        for (k, v) in spreads { pipSpreads[k] = v * PnLConverter.pipFactor(for: k) }
        return TradingSnapshot(positions: positions, account: acct, spreads: pipSpreads)
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
            orderType: orderType(side: side, stopDirection: opening.stopDirection))
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
