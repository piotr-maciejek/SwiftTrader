import Foundation
import SwiftUI

/// Abstraction over the REST client so tests can swap in a fake.
protocol TradeHistoryFetching: Sendable {
    func fetchClosedTrades(from: Date, to: Date) async throws -> [TradeRecord]
}

extension TradeHistoryService: TradeHistoryFetching {}

@Observable
@MainActor
final class TradeHistoryViewModel {
    var preset: DateRangePreset = .thisWeek
    var customFrom: Date = Calendar.current.startOfDay(for: .now)
    var customTo: Date = .now
    var trades: [TradeRecord] = []
    var isLoading = false
    var error: String?

    private var service: any TradeHistoryFetching

    init(service: any TradeHistoryFetching = TradeHistoryService()) {
        self.service = service
    }

    func reconnect(port: Int) {
        service = TradeHistoryService(
            baseURL: URL(string: "http://localhost:\(port)")!)
        trades = []
    }

    /// Nil when preset is `.custom` and the user has chosen a reversed range.
    /// Non-nil for every other preset.
    var currentRange: ClosedRange<Date>? {
        if preset == .custom {
            guard customFrom <= customTo else { return nil }
            return preset.range(custom: customFrom...customTo)
        }
        return preset.range()
    }

    var totalNetProfit: Double { trades.reduce(0) { $0 + $1.profitLoss } }
    var winCount: Int { trades.filter { $0.profitLoss > 0 }.count }
    var lossCount: Int { trades.filter { $0.profitLoss < 0 }.count }
    var winRate: Double {
        guard !trades.isEmpty else { return 0 }
        return Double(winCount) / Double(trades.count)
    }

    func reload() async {
        guard let range = currentRange else {
            error = "From must be <= To"
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            trades = try await service.fetchClosedTrades(from: range.lowerBound, to: range.upperBound)
        } catch {
            self.error = error.localizedDescription
            trades = []
        }
    }
}
