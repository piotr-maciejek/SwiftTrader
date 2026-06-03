import Foundation
import Testing
@testable import SwiftTrader

private func meta(
    id: String, instrument: String = "EURUSD", direction: String = "BUY",
    pressPrice: Double = 1.1000, fillPrice: Double = 1.1000,
    initialSL: Double = 1.0990, initialTP: Double = 1.1030,
    submitTimeMs: Int64 = 0, openTimeMs: Int64 = 0
) -> PositionMetadata {
    PositionMetadata(
        positionId: id, instrument: instrument, direction: direction,
        pressPrice: pressPrice, initialStopLoss: initialSL, initialTakeProfit: initialTP,
        fillPrice: fillPrice, submitTimeMs: submitTimeMs, openTimeMs: openTimeMs)
}

private func approx(_ a: Double?, _ b: Double, tol: Double = 1e-6) -> Bool {
    guard let a else { return false }
    return abs(a - b) < tol
}

@Suite("PositionMetadata")
@MainActor
struct PositionMetadataTests {

    // MARK: - R-multiple & slippage math

    @Test("Realized R is 2 for risk 10 / reward 20 — BUY and SELL")
    func realizedR2() {
        let buy = meta(id: "b", direction: "BUY", fillPrice: 1.1000, initialSL: 1.0990)
        #expect(approx(buy.riskPips, 10))
        #expect(approx(buy.realizedR(closePrice: 1.1020), 2))   // +20 pips / 10 = 2R

        let sell = meta(id: "s", direction: "SELL", fillPrice: 1.1000, initialSL: 1.1010)
        #expect(approx(sell.riskPips, 10))
        #expect(approx(sell.realizedR(closePrice: 1.0980), 2))  // moved down 20 pips = +2R for a short
    }

    @Test("Losing trade yields negative R")
    func losingR() {
        let buy = meta(id: "b", direction: "BUY", fillPrice: 1.1000, initialSL: 1.0990)
        #expect(approx(buy.realizedR(closePrice: 1.0995), -0.5))  // -5 pips / 10 = -0.5R
    }

    @Test("JPY pip factor used for R")
    func jpyR() {
        let m = meta(id: "j", instrument: "USDJPY", direction: "BUY", fillPrice: 150.00, initialSL: 149.90)
        #expect(approx(m.riskPips, 10))                       // 0.10 * 100
        #expect(approx(m.realizedR(closePrice: 150.20), 2))
    }

    @Test("Slippage sign: positive = worse fill, negative = better")
    func slippageSign() {
        #expect(approx(meta(id: "b", direction: "BUY", pressPrice: 1.1000, fillPrice: 1.1002).slippagePips, 2))
        #expect(approx(meta(id: "s", direction: "SELL", pressPrice: 1.1000, fillPrice: 1.0998).slippagePips, 2))
        #expect(meta(id: "g", direction: "BUY", pressPrice: 1.1000, fillPrice: 1.0999).slippagePips < 0)
    }

    @Test("riskPips undefined → R helpers return nil")
    func riskUndefined() {
        let noSL = meta(id: "n", fillPrice: 1.1000, initialSL: 0)
        #expect(noSL.riskPips == nil)
        #expect(noSL.realizedR(closePrice: 1.1020) == nil)
        #expect(noSL.currentR(markPrice: 1.1020) == nil)
        #expect(noSL.currentR(fromPositionPips: 5) == nil)

        let slOnFill = meta(id: "f", fillPrice: 1.1000, initialSL: 1.1000)
        #expect(slOnFill.riskPips == nil)
    }

    @Test("currentR(fromPositionPips:) matches currentR(markPrice:)")
    func currentRConsistency() {
        let m = meta(id: "c", direction: "BUY", fillPrice: 1.1000, initialSL: 1.0990)
        let mark = 1.1015
        let pips = m.realizedPips(at: mark)
        #expect(approx(m.currentR(fromPositionPips: pips), m.currentR(markPrice: mark) ?? -99))
    }

    // MARK: - Portfolio totals

    private func pos(_ label: String, pips: Double, sl: Double = 1.0990) -> Position {
        Position(label: label, instrument: "EURUSD", direction: "BUY", amount: 0.1,
                 openPrice: 1.1000, stopLoss: sl, takeProfit: 1.1030,
                 profitLoss: 0, profitLossPips: pips, state: "FILLED")
    }

    @Test("totalOpenR sums current R across positions that have metadata")
    func totalOpenRSums() {
        // A: +20 pips / 10 risk = +2R; B: -10 / 10 = -1R; C: no metadata (ignored). Total = +1R.
        let md = ["A": meta(id: "A", fillPrice: 1.1000, initialSL: 1.0990),
                  "B": meta(id: "B", fillPrice: 1.1000, initialSL: 1.0990)]
        let total = PositionMetadata.totalOpenR(
            positions: [pos("A", pips: 20), pos("B", pips: -10), pos("C", pips: 5)], metadata: md)
        #expect(approx(total, 1.0))
    }

    @Test("totalOpenR is nil when no position has metadata")
    func totalOpenRNil() {
        #expect(PositionMetadata.totalOpenR(positions: [pos("X", pips: 10)], metadata: [:]) == nil)
    }

    @Test("totalRealizedR sums realized R across closed trades with metadata")
    func totalRealizedRSums() {
        let t = TradeRecord(positionId: "A", instrument: "EURUSD", direction: "BUY", amount: 0.1,
                            openPrice: 1.1000, closePrice: 1.1020, profitLoss: 0, grossProfitLoss: 0,
                            swaps: 0, commission: 0, openTime: 1, closeTime: 2, positionType: "REGULAR")
        let md = ["A": meta(id: "A", fillPrice: 1.1000, initialSL: 1.0990)]   // risk 10, +20 pips = +2R
        #expect(approx(PositionMetadata.totalRealizedR(trades: [t], metadata: md), 2.0))
        #expect(PositionMetadata.totalRealizedR(trades: [t], metadata: [:]) == nil)
    }

    // MARK: - Store: pruning

    @Test("prune keeps the newest records by open time")
    func prunePicksNewest() {
        var dict: [String: PositionMetadata] = [:]
        for i in 1...5 { dict["p\(i)"] = meta(id: "p\(i)", openTimeMs: Int64(i)) }
        let kept = PositionMetadataStore.prune(dict, max: 3)
        #expect(kept.count == 3)
        #expect(kept["p5"] != nil && kept["p4"] != nil && kept["p3"] != nil)
        #expect(kept["p1"] == nil && kept["p2"] == nil)
    }

    @Test("prune falls back to submit time when open time is 0")
    func pruneFallbackSubmitTime() {
        var dict: [String: PositionMetadata] = [:]
        dict["a"] = meta(id: "a", submitTimeMs: 10, openTimeMs: 0)
        dict["b"] = meta(id: "b", submitTimeMs: 20, openTimeMs: 0)
        dict["c"] = meta(id: "c", submitTimeMs: 30, openTimeMs: 0)
        let kept = PositionMetadataStore.prune(dict, max: 2)
        #expect(kept.count == 2)
        #expect(kept["c"] != nil && kept["b"] != nil && kept["a"] == nil)
    }

    @Test("prune is a no-op below the cap")
    func pruneNoOp() {
        let dict = ["a": meta(id: "a"), "b": meta(id: "b")]
        #expect(PositionMetadataStore.prune(dict, max: 10).count == 2)
    }

    // MARK: - Store: persistence round-trip

    @Test("upsert persists and merge-keeps existing keys (UserDefaults path)")
    func upsertRoundTrip() {
        let suite = "pmtest-store-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let acctID = UUID()

        let store = PositionMetadataStore(defaults: defaults, cloudEnabled: false)
        store.upsert(meta(id: "A"), accountID: acctID)
        store.upsert(meta(id: "B"), accountID: acctID)

        // A fresh store reads both back from the same suite (proves persistence + merge).
        let reopened = PositionMetadataStore(defaults: defaults, cloudEnabled: false)
        let all = reopened.all(accountID: acctID)
        #expect(all.count == 2)
        #expect(all["A"] != nil && all["B"] != nil)
    }

    @Test("metadata is isolated per account")
    func perAccountIsolation() {
        let suite = "pmtest-acct-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PositionMetadataStore(defaults: defaults, cloudEnabled: false)
        let a = UUID(), b = UUID()
        store.upsert(meta(id: "A"), accountID: a)
        store.upsert(meta(id: "B"), accountID: b)
        #expect(store.all(accountID: a).keys.sorted() == ["A"])
        #expect(store.all(accountID: b).keys.sorted() == ["B"])
    }

    // MARK: - Capture + bind

    private func acct() -> Account {
        Account(balance: 10_000, equity: 10_000, usedMargin: 0, freeMargin: 10_000,
                currency: "USD", leverage: 30, connected: true, lastTickAgeMs: 0)
    }

    private func marketOrder() -> VisualOrderState {
        // isEntryOverridden defaults false → orderType == "MARKET".
        VisualOrderState(direction: "BUY", instrument: "EURUSD", entryPrice: 1.1000,
                         marketPrice: 1.1000, amount: 0.1, stopLoss: 1.0990, takeProfit: 1.1030,
                         startBarIndex: 1, endBarIndex: 11)
    }

    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    @Test("Submit-time capture binds to the new position id; pre-existing positions don't bind")
    func captureBindsOnAppearance() async {
        let fake = FakeTradingCoordinator()
        let suite = "pmtest-bind-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PositionMetadataStore(defaults: defaults, cloudEnabled: false)
        let acctID = UUID()

        let vm = TradingViewModel(coordinator: fake)
        vm.metadataStore = store
        vm.accountID = acctID
        vm.start()

        for _ in 0..<100 {
            if fake.snapshotContinuation != nil { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(fake.snapshotContinuation != nil)

        // Pre-existing position at connect must NOT bind.
        let old = Position(label: "OLD", instrument: "EURUSD", direction: "BUY", amount: 0.1,
                           openPrice: 1.0900, stopLoss: 0, takeProfit: 0,
                           profitLoss: 0, profitLossPips: 0, state: "FILLED")
        fake.snapshotContinuation?.yield(TradingSnapshot(positions: [old], account: acct(), spreads: nil))
        await settle()
        #expect(store.all(accountID: acctID).isEmpty)

        // Submit a market order: press 1.1000, initial SL 1.0990.
        vm.visualOrders["EURUSD"] = marketOrder()
        await vm.confirmVisualOrder(instrument: "EURUSD", livePrice: 1.1000)
        #expect(fake.submitCallCount == 1)

        // The fill appears as a new position at 1.1002 (2 pip worse fill).
        let filled = Position(label: "ST_EURUSD_1", instrument: "EURUSD", direction: "BUY", amount: 0.1,
                              openPrice: 1.1002, stopLoss: 1.0990, takeProfit: 1.1030,
                              profitLoss: 0, profitLossPips: 0, state: "FILLED")
        fake.snapshotContinuation?.yield(TradingSnapshot(positions: [old, filled], account: acct(), spreads: nil))
        await settle()

        let bound = store.all(accountID: acctID)["ST_EURUSD_1"]
        #expect(bound != nil)
        #expect(bound?.pressPrice == 1.1000)
        #expect(bound?.fillPrice == 1.1002)
        #expect(bound?.initialStopLoss == 1.0990)
        #expect(approx(bound?.slippagePips, 2))

        // Re-yielding the same snapshot must not double-bind.
        fake.snapshotContinuation?.yield(TradingSnapshot(positions: [old, filled], account: acct(), spreads: nil))
        await settle()
        #expect(store.all(accountID: acctID).count == 1)

        vm.stop()
    }

    @Test("Two concurrent same-pair submits bind FIFO to two new ids")
    func concurrentSubmitsFIFO() async {
        let fake = FakeTradingCoordinator()
        let suite = "pmtest-fifo-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PositionMetadataStore(defaults: defaults, cloudEnabled: false)
        let acctID = UUID()

        let vm = TradingViewModel(coordinator: fake)
        vm.metadataStore = store
        vm.accountID = acctID
        vm.start()
        for _ in 0..<100 {
            if fake.snapshotContinuation != nil { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        // Seed empty.
        fake.snapshotContinuation?.yield(TradingSnapshot(positions: [], account: acct(), spreads: nil))
        await settle()

        // First submit: press 1.1000. Second: press 1.2000. FIFO → first capture binds to first new id.
        vm.visualOrders["EURUSD"] = marketOrder()
        await vm.confirmVisualOrder(instrument: "EURUSD", livePrice: 1.1000)
        var second = marketOrder(); second.entryPrice = 1.2000; second.marketPrice = 1.2000
        vm.visualOrders["EURUSD"] = second
        await vm.confirmVisualOrder(instrument: "EURUSD", livePrice: 1.2000)

        let p1 = Position(label: "ID1", instrument: "EURUSD", direction: "BUY", amount: 0.1,
                          openPrice: 1.1001, stopLoss: 1.0990, takeProfit: 1.1030,
                          profitLoss: 0, profitLossPips: 0, state: "FILLED")
        let p2 = Position(label: "ID2", instrument: "EURUSD", direction: "BUY", amount: 0.1,
                          openPrice: 1.2001, stopLoss: 1.1990, takeProfit: 1.2030,
                          profitLoss: 0, profitLossPips: 0, state: "FILLED")
        fake.snapshotContinuation?.yield(TradingSnapshot(positions: [p1, p2], account: acct(), spreads: nil))
        await settle()

        let all = store.all(accountID: acctID)
        #expect(all.count == 2)
        #expect(all["ID1"]?.pressPrice == 1.1000)   // oldest capture → first-iterated new id
        #expect(all["ID2"]?.pressPrice == 1.2000)
        vm.stop()
    }
}
