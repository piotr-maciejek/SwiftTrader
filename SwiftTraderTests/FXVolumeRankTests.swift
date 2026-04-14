import XCTest
@testable import SwiftTrader

final class FXVolumeRankTests: XCTestCase {
    func testCurrencyRankOrdering() {
        XCTAssertGreaterThan(FXVolumeRank.rank(currency: "USD"), FXVolumeRank.rank(currency: "EUR"))
        XCTAssertGreaterThan(FXVolumeRank.rank(currency: "EUR"), FXVolumeRank.rank(currency: "JPY"))
        XCTAssertGreaterThan(FXVolumeRank.rank(currency: "JPY"), FXVolumeRank.rank(currency: "GBP"))
        XCTAssertGreaterThan(FXVolumeRank.rank(currency: "GBP"), FXVolumeRank.rank(currency: "CHF"))
        XCTAssertGreaterThan(FXVolumeRank.rank(currency: "AUD"), FXVolumeRank.rank(currency: "NZD"))
    }

    func testPairRankOrdering() {
        XCTAssertGreaterThan(FXVolumeRank.rank(pair: "EURUSD"), FXVolumeRank.rank(pair: "USDJPY"))
        XCTAssertGreaterThan(FXVolumeRank.rank(pair: "USDJPY"), FXVolumeRank.rank(pair: "GBPUSD"))
        XCTAssertGreaterThan(FXVolumeRank.rank(pair: "GBPUSD"), FXVolumeRank.rank(pair: "USDCHF"))
        XCTAssertGreaterThan(FXVolumeRank.rank(pair: "AUDUSD"), FXVolumeRank.rank(pair: "NZDUSD"))
        // A major-leg pair outranks a cross of two smaller legs.
        XCTAssertGreaterThan(FXVolumeRank.rank(pair: "EURJPY"), FXVolumeRank.rank(pair: "AUDNZD"))
    }

    func testUnknownSymbolsRankZero() {
        XCTAssertEqual(FXVolumeRank.rank(currency: "XXX"), 0)
        XCTAssertEqual(FXVolumeRank.rank(pair: "XXXYYY"), 0)
        XCTAssertEqual(FXVolumeRank.rank(pair: "EUR"), 0)
        XCTAssertEqual(FXVolumeRank.rank(pair: ""), 0)
    }
}
