import DukascopyClient
import Foundation
import Testing
@testable import SwiftTrader

@Suite("DateRangePreset")
struct DateRangePresetTests {

    /// Fixed calendar so tests don't depend on runner's locale.
    private func calendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 2 // Monday
        return cal
    }

    private func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? Date(timeIntervalSince1970: 0)
    }

    @Test("Today spans start-of-day to just-before-next-day")
    func todayRange() {
        let cal = calendar()
        let now = date("2026-04-15T14:30:00.000Z")
        let r = DateRangePreset.today.range(now: now, calendar: cal)
        #expect(r.lowerBound == date("2026-04-15T00:00:00.000Z"))
        #expect(r.upperBound < date("2026-04-16T00:00:00.000Z"))
        #expect(r.upperBound >= date("2026-04-15T23:59:59.000Z"))
    }

    @Test("Yesterday is the full previous day")
    func yesterdayRange() {
        let cal = calendar()
        let now = date("2026-04-15T14:30:00.000Z")
        let r = DateRangePreset.yesterday.range(now: now, calendar: cal)
        #expect(r.lowerBound == date("2026-04-14T00:00:00.000Z"))
        #expect(r.upperBound < date("2026-04-15T00:00:00.000Z"))
    }

    @Test("This week starts on Monday for firstWeekday=2")
    func thisWeekStartsMonday() {
        let cal = calendar()
        // 2026-04-15 is a Wednesday
        let now = date("2026-04-15T14:30:00.000Z")
        let r = DateRangePreset.thisWeek.range(now: now, calendar: cal)
        #expect(r.lowerBound == date("2026-04-13T00:00:00.000Z")) // Monday
        #expect(r.upperBound < date("2026-04-20T00:00:00.000Z")) // next Monday
    }

    @Test("Previous week is the full prior calendar week")
    func previousWeek() {
        let cal = calendar()
        let now = date("2026-04-15T14:30:00.000Z")
        let r = DateRangePreset.previousWeek.range(now: now, calendar: cal)
        #expect(r.lowerBound == date("2026-04-06T00:00:00.000Z"))
        #expect(r.upperBound < date("2026-04-13T00:00:00.000Z"))
    }

    @Test("This month is first-of-month through end-of-month")
    func thisMonth() {
        let cal = calendar()
        let now = date("2026-04-15T14:30:00.000Z")
        let r = DateRangePreset.thisMonth.range(now: now, calendar: cal)
        #expect(r.lowerBound == date("2026-04-01T00:00:00.000Z"))
        #expect(r.upperBound < date("2026-05-01T00:00:00.000Z"))
    }

    @Test("Previous year is the full prior calendar year")
    func previousYear() {
        let cal = calendar()
        let now = date("2026-04-15T14:30:00.000Z")
        let r = DateRangePreset.previousYear.range(now: now, calendar: cal)
        #expect(r.lowerBound == date("2025-01-01T00:00:00.000Z"))
        #expect(r.upperBound < date("2026-01-01T00:00:00.000Z"))
    }

    @Test("Custom passes through the supplied range")
    func customPassesThrough() {
        let cal = calendar()
        let from = date("2026-02-01T00:00:00.000Z")
        let to   = date("2026-02-28T23:59:59.000Z")
        let r = DateRangePreset.custom.range(now: .now, calendar: cal, custom: from...to)
        #expect(r.lowerBound == from)
        #expect(r.upperBound == to)
    }
}

/// Minimal fake for VM tests.
final class FakeTradeHistoryService: TradeHistoryFetching, @unchecked Sendable {
    var result: Result<[TradeRecord], Error> = .success([])
    var lastFrom: Date?
    var lastTo: Date?

    func fetchClosedTrades(from: Date, to: Date) async throws -> [TradeRecord] {
        lastFrom = from
        lastTo = to
        return try result.get()
    }
}

@Suite("TradeHistoryViewModel")
@MainActor
struct TradeHistoryViewModelTests {

    /// Close time within the default `.thisWeek` window so the range clamp keeps the trade.
    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    @Test("reload populates trades and computes summary")
    func reloadPopulates() async {
        let fake = FakeTradeHistoryService()
        fake.result = .success([
            TradeRecord(positionId: "A", instrument: "EURUSD", direction: "BUY", amount: 0.01,
                        openPrice: 1.10, closePrice: 1.11,
                        profitLoss: 100, grossProfitLoss: 100, swaps: 0, commission: 0,
                        openTime: 0, closeTime: nowMs, positionType: "REGULAR"),
            TradeRecord(positionId: "B", instrument: "USDJPY", direction: "SELL", amount: 0.01,
                        openPrice: 150, closePrice: 151,
                        profitLoss: -50, grossProfitLoss: -50, swaps: 0, commission: 0,
                        openTime: 0, closeTime: nowMs, positionType: "REGULAR"),
        ])
        let vm = TradeHistoryViewModel(service: fake)
        await vm.reload()
        #expect(vm.trades.count == 2)
        #expect(vm.winCount == 1)
        #expect(vm.lossCount == 1)
        #expect(abs(vm.totalNetProfit - 50) < 1e-9)
        #expect(vm.error == nil)
    }

    @Test("reload clamps to the selected window — an adjacent day's trade is dropped")
    func reloadClampsToRange() async {
        let cal = Calendar.current
        let todayNoon = cal.date(byAdding: .hour, value: 12, to: cal.startOfDay(for: .now))!
        let yesterdayNoon = cal.date(byAdding: .day, value: -1, to: todayNoon)!
        func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }

        let fake = FakeTradeHistoryService()
        fake.result = .success([
            TradeRecord(positionId: "TODAY", instrument: "EURUSD", direction: "BUY", amount: 0.01,
                        openPrice: 1, closePrice: 1.1, profitLoss: 1, grossProfitLoss: 1, swaps: 0,
                        commission: 0, openTime: ms(todayNoon), closeTime: ms(todayNoon), positionType: "REGULAR"),
            TradeRecord(positionId: "YESTERDAY", instrument: "EURUSD", direction: "BUY", amount: 0.01,
                        openPrice: 1, closePrice: 1.1, profitLoss: 1, grossProfitLoss: 1, swaps: 0,
                        commission: 0, openTime: ms(yesterdayNoon), closeTime: ms(yesterdayNoon), positionType: "REGULAR"),
        ])
        let vm = TradeHistoryViewModel(service: fake)
        vm.preset = .today
        await vm.reload()
        #expect(vm.trades.map(\.id) == ["TODAY"])
    }

    @Test("reload surfaces errors and clears trades")
    func reloadPropagatesError() async {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "server died" }
        }
        let fake = FakeTradeHistoryService()
        fake.result = .failure(Boom())
        let vm = TradeHistoryViewModel(service: fake)
        vm.trades = [
            TradeRecord(positionId: "stale", instrument: "EURUSD", direction: "BUY", amount: 0.01,
                        openPrice: 1.0, closePrice: 1.0, profitLoss: 0, grossProfitLoss: 0,
                        swaps: 0, commission: 0, openTime: 0, closeTime: 0, positionType: "REGULAR")
        ]
        await vm.reload()
        #expect(vm.trades.isEmpty)
        #expect(vm.error == "server died")
    }

    @Test("Custom with to < from is rejected before hitting the service")
    func customReversedRangeRejected() async {
        let fake = FakeTradeHistoryService()
        let vm = TradeHistoryViewModel(service: fake)
        vm.preset = .custom
        vm.customFrom = Date(timeIntervalSince1970: 1_000_000)
        vm.customTo = Date(timeIntervalSince1970: 500_000)
        await vm.reload()
        #expect(vm.error != nil)
        #expect(fake.lastFrom == nil) // service not called
    }

    /// `setService` is how `attachNativeSession` rewires history onto a freshly-connected
    /// standalone session — it must drop stale trades and pull from the new source.
    @Test("setService swaps the source and clears stale trades")
    func setServiceSwapsAndClears() async {
        let first = FakeTradeHistoryService()
        first.result = .success([
            TradeRecord(positionId: "OLD", instrument: "EURUSD", direction: "BUY", amount: 0.01,
                        openPrice: 1.0, closePrice: 1.0, profitLoss: 1, grossProfitLoss: 1,
                        swaps: 0, commission: 0, openTime: 0, closeTime: nowMs, positionType: "REGULAR"),
        ])
        let vm = TradeHistoryViewModel(service: first)
        await vm.reload()
        #expect(vm.trades.count == 1)

        let second = FakeTradeHistoryService()
        second.result = .success([
            TradeRecord(positionId: "NEW1", instrument: "GBPUSD", direction: "SELL", amount: 0.02,
                        openPrice: 1.3, closePrice: 1.29, profitLoss: 9, grossProfitLoss: 9,
                        swaps: 0, commission: 0, openTime: 0, closeTime: nowMs, positionType: "REGULAR"),
            TradeRecord(positionId: "NEW2", instrument: "GBPUSD", direction: "BUY", amount: 0.02,
                        openPrice: 1.3, closePrice: 1.31, profitLoss: 9, grossProfitLoss: 9,
                        swaps: 0, commission: 0, openTime: 0, closeTime: nowMs, positionType: "REGULAR"),
        ])
        vm.setService(second)
        #expect(vm.trades.isEmpty)   // stale trades dropped immediately on swap
        await vm.reload()
        #expect(vm.trades.map(\.id) == ["NEW1", "NEW2"])  // now sourced from the new service
    }
}

@Suite("NativeTradeHistoryService")
struct NativeTradeHistoryServiceTests {

    private func position(
        id: String = "P1", long: Bool = true, merged: Bool = false, instrument: String = "EUR/USD",
        amount: Double? = 1000, open: Double? = 1.16448, current: Double? = nil, close: Double? = 1.1646,
        pl: Double? = 0.12, swaps: Double? = 0, gross: Double? = 0.12, commission: Double? = -0.22,
        currency: String? = "PLN", openMs: Int64? = 1_700_000_000_000, closeMs: Int64? = 1_700_000_600_000
    ) -> ClosedPosition {
        ClosedPosition(
            positionId: id, isLong: long, isMerged: merged, instrument: instrument,
            amount: amount, openPrice: open, currentPrice: current, closePrice: close,
            profitLoss: pl, swaps: swaps, grossProfitLoss: gross, commission: commission,
            commissionCurrency: currency, openDateMillis: openMs, closeDateMillis: closeMs)
    }

    @Test("maps a ClosedPosition to a TradeRecord 1:1 (LONG → BUY, fields, ms times)")
    func mapsLong() {
        let r = NativeTradeHistoryService.map(position())
        #expect(r.positionId == "P1")
        #expect(r.direction == "BUY")
        #expect(r.isBuy)
        #expect(r.instrument == "EUR/USD")
        #expect(r.amount == 1000)
        #expect(r.openPrice == 1.16448)
        #expect(r.closePrice == 1.1646)
        #expect(r.profitLoss == 0.12)
        #expect(r.grossProfitLoss == 0.12)
        #expect(r.commission == -0.22)
        #expect(r.openTime == 1_700_000_000_000)
        #expect(r.closeTime == 1_700_000_600_000)
        #expect(r.positionType == "REGULAR")
    }

    @Test("SHORT → SELL and MERGED positionType carry through")
    func mapsShortMerged() {
        let r = NativeTradeHistoryService.map(position(long: false, merged: true))
        #expect(r.direction == "SELL")
        #expect(!r.isBuy)
        #expect(r.positionType == "MERGED")
    }

    @Test("nil decimals/dates default to 0 (TradeRecord fields are non-optional)")
    func mapsNilDefaults() {
        let r = NativeTradeHistoryService.map(position(
            amount: nil, open: nil, close: nil, pl: nil, swaps: nil, gross: nil,
            commission: nil, currency: nil, openMs: nil, closeMs: nil))
        #expect(r.amount == 0)
        #expect(r.openPrice == 0)
        #expect(r.closePrice == 0)
        #expect(r.profitLoss == 0)
        #expect(r.openTime == 0)
        #expect(r.closeTime == 0)
    }

    @Test("no session → empty result (history VM is built before native connect)")
    func noSessionReturnsEmpty() async throws {
        let service = NativeTradeHistoryService(session: nil)
        let trades = try await service.fetchClosedTrades(from: .distantPast, to: .now)
        #expect(trades.isEmpty)
    }
}
