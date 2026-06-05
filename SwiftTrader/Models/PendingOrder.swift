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
    /// The wire `orderGroupId` — stable across the pending→filled transition and equal to the
    /// eventual `Position.label`. Used to bind R-multiple / slippage metadata to a limit/stop fill
    /// that lands minutes/hours later. Empty when the group id isn't known. (`label` stays the
    /// per-order `orderId`, which cancellation matches on.)
    var groupId: String = ""

    var id: String { label }
    var isBuy: Bool { direction == "BUY" }
}

struct PendingOrdersSnapshot: Codable {
    let pendingOrders: [PendingOrder]
}
