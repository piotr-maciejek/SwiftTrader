import Foundation

struct Account: Codable, Equatable {
    let balance: Double
    let equity: Double
    let usedMargin: Double
    let freeMargin: Double
    let currency: String
}

struct TradingSnapshot: Codable {
    let positions: [Position]
    let account: Account
}
