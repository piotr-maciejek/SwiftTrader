import Foundation

struct Position: Codable, Identifiable, Equatable {
    let label: String
    let instrument: String
    let direction: String
    let amount: Double
    let openPrice: Double
    let stopLoss: Double
    let takeProfit: Double
    let profitLoss: Double
    let profitLossPips: Double
    let state: String

    var id: String { label }
    var isBuy: Bool { direction == "BUY" }
}
