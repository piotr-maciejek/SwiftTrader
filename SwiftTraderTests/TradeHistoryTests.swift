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

    @Test("reload populates trades and computes summary")
    func reloadPopulates() async {
        let fake = FakeTradeHistoryService()
        fake.result = .success([
            TradeRecord(positionId: "A", instrument: "EURUSD", direction: "BUY", amount: 0.01,
                        openPrice: 1.10, closePrice: 1.11,
                        profitLoss: 100, grossProfitLoss: 100, swaps: 0, commission: 0,
                        openTime: 0, closeTime: 1, positionType: "REGULAR"),
            TradeRecord(positionId: "B", instrument: "USDJPY", direction: "SELL", amount: 0.01,
                        openPrice: 150, closePrice: 151,
                        profitLoss: -50, grossProfitLoss: -50, swaps: 0, commission: 0,
                        openTime: 0, closeTime: 2, positionType: "REGULAR"),
        ])
        let vm = TradeHistoryViewModel(service: fake)
        await vm.reload()
        #expect(vm.trades.count == 2)
        #expect(vm.winCount == 1)
        #expect(vm.lossCount == 1)
        #expect(abs(vm.totalNetProfit - 50) < 1e-9)
        #expect(vm.error == nil)
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
}
