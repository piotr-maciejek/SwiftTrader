import Foundation
import SwiftUI
import os

private let orderMetaLog = Logger(subsystem: "com.swifttrader", category: "ordermeta")

@Observable
@MainActor
final class TradingViewModel {
    var positions: [Position] = []
    var pendingOrders: [PendingOrder] = []
    var account: Account?
    var spreads: [String: Double] = [:]
    var isConnected = false
    var isSubmitting = false
    var orderError: String?
    var visualOrders: [String: VisualOrderState] = [:]

    /// R-multiple / slippage persistence. Injected by `WorkspaceViewModel`; nil → capture is a no-op.
    var metadataStore: PositionMetadataStore?
    var accountID: UUID?

    private var coordinator: any TradingCoordinating
    private var wsTask: Task<Void, Never>?
    private var pendingWsTask: Task<Void, Never>?

    /// Submit-time captures awaiting the position's first appearance in the snapshot stream.
    private var pendingCaptures: [PendingCapture] = []
    /// Labels already seen (pre-existing at connect, or already bound) — never (re)bind these.
    private var knownPositionIds: Set<String> = []
    private var didSeedKnownIds = false

    private struct PendingCapture {
        let instrument: String
        let direction: String
        let pressPrice: Double
        let initialStopLoss: Double
        let initialTakeProfit: Double
        let submitTimeMs: Int64
    }

    var amount = 0.01

    init(coordinator: any TradingCoordinating = TradingCoordinator()) {
        self.coordinator = coordinator
    }

    func start() {
        connectWebSocket()
        connectPendingOrdersWebSocket()
    }

    func stop() {
        wsTask?.cancel()
        wsTask = nil
        pendingWsTask?.cancel()
        pendingWsTask = nil
        isConnected = false
        // A reconnect / account switch invalidates the binding state: positions re-seed and any
        // unmatched captures belong to the old session.
        pendingCaptures.removeAll()
        knownPositionIds.removeAll()
        didSeedKnownIds = false
    }

    func reconnect(port: Int) {
        stop()
        coordinator = TradingCoordinator(port: port)
        positions = []
        pendingOrders = []
        start()
    }

    /// Swap to a different coordinator (e.g. the native session-backed one) and
    /// restart the snapshot/pending streams. Used when the standalone session connects.
    func reconnect(coordinator: any TradingCoordinating) {
        stop()
        self.coordinator = coordinator
        positions = []
        pendingOrders = []
        start()
    }

    // MARK: - Order submission

    @discardableResult
    func submitMarketOrder(instrument: String, direction: String,
                           amount: Double? = nil, stopLoss: Double, takeProfit: Double) async throws -> Position {
        isSubmitting = true
        defer { isSubmitting = false }
        orderError = nil

        do {
            return try await coordinator.submitOrder(
                instrument: instrument, direction: direction,
                amount: amount ?? self.amount,
                stopLoss: stopLoss, takeProfit: takeProfit)
        } catch {
            orderError = error.localizedDescription
            throw error
        }
    }

    func beginVisualOrder(direction: String, instrument: String, bars: [CandleBar]) {
        guard bars.count >= 2, let currentPrice = bars.last?.close else {
            orderError = "Not enough candle data"
            return
        }

        let (sl, tp) = Self.visualOrderSLTP(direction: direction, bars: bars, currentPrice: currentPrice)
        let nextIndex = bars.count + 1

        var initialAmount = amount
        var marginCapped = false
        if let equity = account?.equity, let freeMargin = account?.freeMargin {
            let sizing = PositionSizing.calculate(
                equity: equity, freeMargin: freeMargin, riskFraction: 0.005,
                entryPrice: currentPrice, stopLoss: sl,
                leverage: account?.leverage ?? 30,
                spread: spreads[instrument] ?? 0)
            initialAmount = sizing.lots
            marginCapped = sizing.isMarginCapped
        }

        visualOrders[instrument] = VisualOrderState(
            direction: direction,
            instrument: instrument,
            entryPrice: currentPrice,
            marketPrice: currentPrice,
            amount: initialAmount,
            stopLoss: sl,
            takeProfit: tp,
            startBarIndex: nextIndex,
            endBarIndex: nextIndex + 10,
            isAmountOverridden: false,
            isMarginCapped: marginCapped,
            isEntryOverridden: false
        )
    }

    /// Compute initial SL/TP for visual order. Always returns valid values
    /// by scanning recent bars for a reasonable stop level.
    nonisolated static func visualOrderSLTP(direction: String, bars: [CandleBar], currentPrice: Double) -> (stopLoss: Double, takeProfit: Double) {
        // Look at the last few completed bars to find a reasonable SL
        let lookback = min(5, bars.count)
        let recentBars = bars.suffix(lookback).filter { !$0.partial }

        // Floor distance keeps SL outside the spread (avoids instant stop-out) without
        // pushing it artificially far from the recent swing. 0.01% of price is ≈1 pip
        // for non-JPY majors and ≈1.5 pips for JPY pairs — tight enough that bar-based
        // stops on low timeframes (e.g. 3m) come through, wide enough to dodge typical
        // spreads. Previous 0.001 floor (≈10 pips on AUDCAD) was masking the recent
        // swing on low TFs.
        let floor = abs(currentPrice) * 0.0001
        if direction == "BUY" {
            let lowestLow = recentBars.map(\.low).min() ?? currentPrice
            let sl = min(lowestLow, currentPrice - floor)
            let risk = currentPrice - sl
            return (stopLoss: sl, takeProfit: currentPrice + risk * 3)
        } else {
            let highestHigh = recentBars.map(\.high).max() ?? currentPrice
            let sl = max(highestHigh, currentPrice + floor)
            let risk = sl - currentPrice
            return (stopLoss: sl, takeProfit: currentPrice - risk * 3)
        }
    }

    func visualOrder(for instrument: String) -> VisualOrderState? {
        visualOrders[instrument]
    }

    func visualOrderWithLivePrice(for instrument: String, currentPrice: Double?, barCount: Int) -> VisualOrderState? {
        guard var order = visualOrders[instrument], let price = currentPrice else {
            return visualOrders[instrument]
        }
        order.marketPrice = price
        if !order.isEntryOverridden {
            order.entryPrice = price
        }
        let boxWidth = order.endBarIndex - order.startBarIndex
        order.startBarIndex = barCount + 1
        order.endBarIndex = barCount + 1 + boxWidth
        if !order.isAmountOverridden,
           let equity = account?.equity,
           let freeMargin = account?.freeMargin {
            let result = PositionSizing.calculate(
                equity: equity, freeMargin: freeMargin,
                riskFraction: 0.005,
                entryPrice: order.entryPrice, stopLoss: order.stopLoss,
                leverage: account?.leverage ?? 30,
                spread: spreads[instrument] ?? 0)
            order.amount = result.lots
            order.isMarginCapped = result.isMarginCapped
        }
        return order
    }

    func updateVisualOrderEntry(instrument: String, price: Double) {
        guard var order = visualOrders[instrument] else { return }
        order.entryPrice = price
        order.isEntryOverridden = true
        visualOrders[instrument] = order
        recalculateAmount(for: instrument)
    }

    /// Keeps the visual-order state intact until the server confirms the fill.
    /// On failure, the user sees the error and still has the box to retry or cancel.
    ///
    /// `livePrice` is the latest tick for the instrument; for MARKET orders we re-size
    /// against it just before sending so the dict's entryPrice (possibly stale from
    /// click time) cannot poison the amount.
    func confirmVisualOrder(instrument: String, livePrice: Double? = nil) async {
        guard !isSubmitting, var order = visualOrders[instrument] else { return }

        if order.orderType == "MARKET",
           !order.isAmountOverridden,
           !order.isEntryOverridden,
           let live = livePrice,
           let equity = account?.equity,
           let freeMargin = account?.freeMargin {
            order.entryPrice = live
            let result = PositionSizing.calculate(
                equity: equity, freeMargin: freeMargin,
                riskFraction: 0.005,
                entryPrice: live, stopLoss: order.stopLoss,
                leverage: account?.leverage ?? 30,
                spread: spreads[instrument] ?? 0)
            order.amount = result.lots
            order.isMarginCapped = result.isMarginCapped
            visualOrders[instrument] = order
        }

        isSubmitting = true
        defer { isSubmitting = false }
        orderError = nil
        // Snapshot the press-time market price + initial SL/TP for R-multiple & slippage. The press
        // price must be the REAL live tick on the SAME side as the fill, so slippage measures
        // execution drift and not the bid-ask spread: a BUY fills at the ASK, a SELL at the BID. Pull
        // the freshest (bid, ask) straight from the trading feed at press; fall back to the chart's
        // live bid (candle close) + spread only if the feed has no quote. Pending orders use the
        // intended entry. Buffered now, bound to the resulting position's id when it appears (see
        // bindPendingCaptures), only on a SUCCESSFUL submit (inside the `do`).
        let quote = await coordinator.currentQuote(instrument: instrument)
        let bidAtPress = quote?.bid ?? livePrice ?? order.entryPrice
        let askAtPress = quote?.ask ?? (bidAtPress + (spreads[instrument] ?? 0))
        let marketPress = order.direction == "BUY" ? askAtPress : bidAtPress
        let capture = PendingCapture(
            instrument: order.instrument,
            direction: order.direction,
            pressPrice: order.orderType == "MARKET" ? marketPress : order.entryPrice,
            initialStopLoss: order.stopLoss,
            initialTakeProfit: order.takeProfit,
            submitTimeMs: Int64(Date().timeIntervalSince1970 * 1000))
        do {
            _ = try await coordinator.submitOrder(
                instrument: order.instrument,
                direction: order.direction,
                amount: order.amount,
                stopLoss: order.stopLoss,
                takeProfit: order.takeProfit,
                orderType: order.orderType,
                entryPrice: order.orderType == "MARKET" ? nil : order.entryPrice)
            pendingCaptures.append(capture)
            orderMetaLog.notice("CAPTURE \(order.instrument, privacy: .public) \(order.direction, privacy: .public) \(order.orderType, privacy: .public) live=\(livePrice ?? -1) quote=\(quote.map { "\($0.bid)/\($0.ask)" } ?? "nil", privacy: .public) entry=\(order.entryPrice) press=\(capture.pressPrice) SL=\(order.stopLoss) TP=\(order.takeProfit) pending=\(self.pendingCaptures.count)")
            visualOrders.removeValue(forKey: instrument)
        } catch {
            orderError = error.localizedDescription
            // keep the visual order for retry.
        }
    }

    func cancelVisualOrder(instrument: String) {
        guard !isSubmitting else { return }
        visualOrders.removeValue(forKey: instrument)
    }

    func adjustVisualOrderAmount(instrument: String, by delta: Double) {
        guard visualOrders[instrument] != nil else { return }
        let newAmount = max(0.001, (visualOrders[instrument]?.amount ?? 0.001) + delta)
        visualOrders[instrument]?.amount = newAmount
        visualOrders[instrument]?.isAmountOverridden = true
    }

    /// `livePrice` keeps the dict's entryPrice in sync with the live preview before
    /// recalc, so dragging SL relative to where the entry visually sits produces
    /// a stopDistance that matches what the user sees.
    func updateVisualOrderSL(instrument: String, price: Double, livePrice: Double? = nil) {
        guard var order = visualOrders[instrument] else { return }
        if !order.isEntryOverridden, let live = livePrice {
            order.entryPrice = live
        }
        order.stopLoss = price
        visualOrders[instrument] = order
        recalculateAmount(for: instrument)
    }

    func resetVisualOrderAmount(instrument: String, livePrice: Double? = nil) {
        guard var order = visualOrders[instrument] else { return }
        if !order.isEntryOverridden, let live = livePrice {
            order.entryPrice = live
        }
        order.isAmountOverridden = false
        visualOrders[instrument] = order
        recalculateAmount(for: instrument)
    }

    func closePosition(label: String) async {
        do {
            try await coordinator.closeOrder(label: label)
        } catch {
            orderError = error.localizedDescription
        }
    }

    func modifyPosition(label: String, stopLoss: Double, takeProfit: Double) async {
        do {
            _ = try await coordinator.modifyOrder(label: label, stopLoss: stopLoss, takeProfit: takeProfit)
        } catch {
            orderError = error.localizedDescription
        }
    }

    // MARK: - Order Calculation

    struct OneClickParams: Equatable {
        let stopLoss: Double
        let takeProfit: Double
    }

    enum OneClickError: Error, Equatable {
        case insufficientData
        case invalidRisk(String)
    }

    /// Pure calculation of one-click order SL/TP. Exposed for testing.
    nonisolated static func calculateOneClick(direction: String, bars: [CandleBar]) -> Result<OneClickParams, OneClickError> {
        guard let previous = lastCompletedBar(in: bars),
              let current = bars.last else {
            return .failure(.insufficientData)
        }

        let currentPrice = current.close
        if direction == "BUY" {
            let stopLoss = previous.low
            let risk = currentPrice - stopLoss
            guard risk > 0 else {
                return .failure(.invalidRisk("current price below previous low"))
            }
            return .success(OneClickParams(stopLoss: stopLoss, takeProfit: currentPrice + risk * 3))
        } else {
            let stopLoss = previous.high
            let risk = stopLoss - currentPrice
            guard risk > 0 else {
                return .failure(.invalidRisk("current price above previous high"))
            }
            return .success(OneClickParams(stopLoss: stopLoss, takeProfit: currentPrice - risk * 3))
        }
    }

    nonisolated static func lastCompletedBar(in bars: [CandleBar]) -> CandleBar? {
        guard !bars.isEmpty else { return nil }
        if let last = bars.last, !last.partial {
            return bars.count >= 2 ? bars[bars.count - 2] : nil
        }
        return bars.count >= 3 ? bars[bars.count - 3] : (bars.count >= 2 ? bars[bars.count - 2] : nil)
    }

    // MARK: - Private

    private func recalculateAmount(for instrument: String) {
        guard var order = visualOrders[instrument],
              !order.isAmountOverridden,
              let equity = account?.equity,
              let freeMargin = account?.freeMargin else { return }
        let result = PositionSizing.calculate(
            equity: equity, freeMargin: freeMargin,
            riskFraction: 0.005,
            entryPrice: order.entryPrice, stopLoss: order.stopLoss,
            leverage: account?.leverage ?? 30,
            spread: spreads[instrument] ?? 0)
        order.amount = result.lots
        order.isMarginCapped = result.isMarginCapped
        visualOrders[instrument] = order
    }

    private func connectWebSocket() {
        wsTask?.cancel()
        wsTask = Task {
            while !Task.isCancelled {
                do {
                    for try await snapshot in coordinator.streamSnapshots() {
                        if !isConnected { isConnected = true }
                        positions = snapshot.positions
                        account = snapshot.account
                        if let s = snapshot.spreads { spreads = s }
                        bindPendingCaptures(snapshot.positions)
                    }
                } catch is CancellationError {
                    break
                } catch {
                    isConnected = false
                    try? await Task.sleep(for: .seconds(3))
                }
            }
            isConnected = false
        }
    }

    /// Bind submit-time captures to newly-appeared positions; seed pre-existing ones so they
    /// never bind. Runs on every snapshot, on the main actor (no added concurrency).
    private func bindPendingCaptures(_ positions: [Position]) {
        // First snapshot after (re)connect: everything already open pre-dates our submits — record
        // their ids so they never bind. They still DISPLAY any synced metadata via the id join.
        if !didSeedKnownIds {
            didSeedKnownIds = true
            knownPositionIds.formUnion(positions.map(\.label))
            return
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // Expire captures whose position never showed within a generous window.
        pendingCaptures.removeAll { nowMs - $0.submitTimeMs > 30_000 }
        for pos in positions where !knownPositionIds.contains(pos.label) {
            // Defer until the fill price is populated. A just-appeared position can report
            // openPrice == 0 for a snapshot or two before the fill propagates; binding then records
            // fillPrice 0, which poisons R (risk = |0 − SL|, huge → ~0R) and slippage (→ "—"). Don't
            // mark it known yet, so it binds on the snapshot where the real fill arrives.
            guard pos.openPrice > 0 else { continue }
            // Newly appeared: match the OLDEST pending capture for this instrument+direction within
            // 15s (FIFO disambiguates concurrent same-pair submits).
            if let idx = pendingCaptures.firstIndex(where: {
                $0.instrument == pos.instrument && $0.direction == pos.direction
                    && nowMs - $0.submitTimeMs <= 15_000
            }) {
                let cap = pendingCaptures.remove(at: idx)
                let meta = PositionMetadata(
                    positionId: pos.label, instrument: pos.instrument, direction: pos.direction,
                    pressPrice: cap.pressPrice, initialStopLoss: cap.initialStopLoss,
                    initialTakeProfit: cap.initialTakeProfit, fillPrice: pos.openPrice,
                    submitTimeMs: cap.submitTimeMs, openTimeMs: nowMs)
                orderMetaLog.notice("BIND \(pos.label, privacy: .public) \(pos.instrument, privacy: .public) \(pos.direction, privacy: .public) fill=\(pos.openPrice) press=\(cap.pressPrice) SL=\(cap.initialStopLoss) ageMs=\(nowMs - cap.submitTimeMs) -> slip=\(meta.slippagePips ?? -99999) risk=\(meta.riskPips ?? -1)")
                metadataStore?.upsert(meta, accountID: accountID)
            } else {
                orderMetaLog.notice("NO-MATCH new position \(pos.label, privacy: .public) \(pos.instrument, privacy: .public) \(pos.direction, privacy: .public) fill=\(pos.openPrice) pendingCaptures=\(self.pendingCaptures.count)")
            }
            // Double-bind guard: once seen, never rebind — even if no capture matched.
            knownPositionIds.insert(pos.label)
        }
    }

    private func connectPendingOrdersWebSocket() {
        pendingWsTask?.cancel()
        pendingWsTask = Task {
            while !Task.isCancelled {
                do {
                    for try await snapshot in coordinator.streamPendingOrders() {
                        pendingOrders = snapshot.pendingOrders
                    }
                } catch is CancellationError {
                    break
                } catch {
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }
}
