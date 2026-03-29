import SwiftUI

struct MarketSession {
    let name: String
    let timeZone: TimeZone
    // Forex session hours (rectangle boundaries)
    let sessionOpenHour: Int, sessionOpenMinute: Int
    let sessionCloseHour: Int, sessionCloseMinute: Int
    // Stock exchange hours (inner vertical lines)
    let exchangeOpenHour: Int, exchangeOpenMinute: Int
    let exchangeCloseHour: Int, exchangeCloseMinute: Int
    let color: Color

    static let tokyo = MarketSession(
        name: "Tokyo",
        timeZone: TimeZone(identifier: "Asia/Tokyo")!,
        sessionOpenHour: 9, sessionOpenMinute: 0,   // 00:00 UTC
        sessionCloseHour: 18, sessionCloseMinute: 0, // 09:00 UTC
        exchangeOpenHour: 9, exchangeOpenMinute: 0,   // TSE open
        exchangeCloseHour: 15, exchangeCloseMinute: 0, // TSE close
        color: Color.red.opacity(0.08)
    )

    static let london = MarketSession(
        name: "London",
        timeZone: TimeZone(identifier: "Europe/London")!,
        sessionOpenHour: 8, sessionOpenMinute: 0,
        sessionCloseHour: 17, sessionCloseMinute: 0,
        exchangeOpenHour: 8, exchangeOpenMinute: 0,    // LSE open
        exchangeCloseHour: 16, exchangeCloseMinute: 30, // LSE close
        color: Color.blue.opacity(0.08)
    )

    static let newYork = MarketSession(
        name: "New York",
        timeZone: TimeZone(identifier: "America/New_York")!,
        sessionOpenHour: 8, sessionOpenMinute: 0,
        sessionCloseHour: 17, sessionCloseMinute: 0,
        exchangeOpenHour: 9, exchangeOpenMinute: 30,  // NYSE open
        exchangeCloseHour: 16, exchangeCloseMinute: 0, // NYSE close
        color: Color.green.opacity(0.08)
    )

    static let all: [MarketSession] = [tokyo, london, newYork]
}

struct SessionRect {
    let session: MarketSession
    let startBarIndex: Int
    let endBarIndex: Int
    let highPrice: Double
    let lowPrice: Double
    let exchangeOpenBarIndex: Int?
    let exchangeCloseBarIndex: Int?
}
