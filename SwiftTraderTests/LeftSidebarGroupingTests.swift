import Testing
@testable import SwiftTrader

@MainActor
struct LeftSidebarGroupingTests {
    @Test
    func eurUsdAppearsUnderBothEurAndUsd() {
        let groups = LeftSidebar.instrumentsByCurrency(["EURUSD"])
        let eur = groups.first { $0.currency == "EUR" }
        let usd = groups.first { $0.currency == "USD" }
        #expect(eur?.instruments == ["EURUSD"])
        #expect(usd?.instruments == ["EURUSD"])
    }

    @Test
    func currenciesAppearInAlphabeticalOrder() {
        // Include pairs from many currencies so all 8 groups exist.
        let instruments = [
            "EURUSD", "USDJPY", "AUDCAD", "GBPCHF", "NZDJPY", "CADCHF",
        ]
        let groups = LeftSidebar.instrumentsByCurrency(instruments)
        let currencies = groups.map(\.currency)
        #expect(currencies == currencies.sorted())
        #expect(currencies == ["AUD", "CAD", "CHF", "EUR", "GBP", "JPY", "NZD", "USD"])
    }

    @Test
    func instrumentsWithinAGroupPreserveInputOrder() {
        // Helper itself doesn't sort — caller (sortedInstruments) does.
        // Verify the helper is faithful to its input order so the sidebar
        // gets the alphabetical order it already computes.
        let groups = LeftSidebar.instrumentsByCurrency(
            ["EURUSD", "AUDUSD", "USDCAD", "USDJPY"]
        )
        let usd = groups.first { $0.currency == "USD" }
        #expect(usd?.instruments == ["EURUSD", "AUDUSD", "USDCAD", "USDJPY"])
    }

    @Test
    func emptyCurrencyGroupsAreOmitted() {
        // Only EUR/USD pairs — no JPY or CHF groups should appear.
        let groups = LeftSidebar.instrumentsByCurrency(["EURUSD"])
        let currencies = Set(groups.map(\.currency))
        #expect(currencies == ["EUR", "USD"])
    }

    @Test
    func everyAudPairLandsUnderAud() {
        let instruments = [
            "AUDUSD", "EURAUD", "GBPAUD", "AUDJPY", "AUDCAD", "AUDNZD", "AUDCHF",
        ]
        let aud = LeftSidebar.instrumentsByCurrency(instruments).first { $0.currency == "AUD" }
        #expect(aud?.instruments.sorted() == instruments.sorted())
    }
}
