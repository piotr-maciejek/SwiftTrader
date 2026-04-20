import Foundation

struct PendingOrder: Codable, Identifiable, Equatable {
    let label: String
    let instrument: String
    let direction: String
    let amount: Double
    let openPrice: Double
    let stopLoss: Double
    let takeProfit: Double
    let state: String
    let orderType: String

    var id: String { label }
    var isBuy: Bool { direction == "BUY" }
}

struct PendingOrdersSnapshot: Codable {
    let pendingOrders: [PendingOrder]
}
