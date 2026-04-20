import Foundation

struct TradeRecord: Codable, Identifiable, Equatable {
    let positionId: String
    let instrument: String
    let direction: String
    let amount: Double
    let openPrice: Double
    let closePrice: Double
    let profitLoss: Double
    let grossProfitLoss: Double
    let swaps: Double
    let commission: Double
    let openTime: Int64
    let closeTime: Int64
    let positionType: String

    var id: String { positionId }
    var isBuy: Bool { direction == "BUY" }

    var openDate: Date { Date(timeIntervalSince1970: TimeInterval(openTime) / 1000) }
    var closeDate: Date { Date(timeIntervalSince1970: TimeInterval(closeTime) / 1000) }

    /// Net pips (close - open, signed for direction), using a crude JPY vs non-JPY pip factor.
    var profitLossPips: Double {
        let pipFactor: Double = instrument.contains("JPY") ? 100 : 10_000
        let priceDelta = isBuy ? (closePrice - openPrice) : (openPrice - closePrice)
        return priceDelta * pipFactor
    }
}
