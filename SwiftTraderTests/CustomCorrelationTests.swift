import Testing
import Foundation
@testable import SwiftTrader

@Suite("CustomCorrelation")
@MainActor
struct CustomCorrelationTests {

    // MARK: - Model validation

    @Test("isValid: non-empty name + 2…6 unique pairs")
    func isValid() {
        #expect(CustomCorrelation(name: "A", pairs: ["EURUSD", "GBPUSD"]).isValid)
        #expect(CustomCorrelation(name: "A", pairs: ["EURUSD", "GBPUSD", "USDJPY"]).isValid)
        // too few / too many
        #expect(!CustomCorrelation(name: "A", pairs: ["EURUSD"]).isValid)
        #expect(!CustomCorrelation(name: "A",
            pairs: ["EURUSD", "GBPUSD", "USDJPY", "USDCHF", "USDCAD", "AUDUSD", "NZDUSD"]).isValid)
        // duplicate pair
        #expect(!CustomCorrelation(name: "A", pairs: ["EURUSD", "EURUSD"]).isValid)
        // empty / whitespace name
        #expect(!CustomCorrelation(name: "", pairs: ["EURUSD", "GBPUSD"]).isValid)
        #expect(!CustomCorrelation(name: "   ", pairs: ["EURUSD", "GBPUSD"]).isValid)
    }

    // MARK: - Store round-trip (injected UserDefaults, iCloud off)

    private func makeStore() -> (store: CustomCorrelationStore, defaults: UserDefaults, suite: String) {
        let suite = "cctest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (CustomCorrelationStore(defaults: defaults, cloudEnabled: false), defaults, suite)
    }

    @Test("Store add / all / delete round-trip")
    func storeRoundTrip() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let a = CustomCorrelation(name: "Carry", pairs: ["NZDJPY", "AUDJPY"])
        let b = CustomCorrelation(name: "USD", pairs: ["EURUSD", "GBPUSD", "AUDUSD"])
        store.add(a)
        store.add(b)
        #expect(Set(store.all().map(\.id)) == Set([a.id, b.id]))

        store.delete(id: a.id)
        #expect(store.all().map(\.id) == [b.id])
    }

    @Test("Store re-add by id replaces; the cap prunes the oldest")
    func storeReplaceAndCap() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        for i in 0..<(CustomCorrelationStore.maxRecords + 5) {
            store.add(CustomCorrelation(name: "n\(i)", pairs: ["EURUSD", "GBPUSD"]))
        }
        #expect(store.all().count == CustomCorrelationStore.maxRecords)
    }

    // MARK: - Grid columns

    @Test("gridColumns fits 2–6 custom pairs; currency grids unchanged")
    func gridColumns() {
        #expect(CorrelationView.gridColumns(count: 2, isCurrency: false) == 2)
        #expect(CorrelationView.gridColumns(count: 3, isCurrency: false) == 3)
        #expect(CorrelationView.gridColumns(count: 4, isCurrency: false) == 2)
        #expect(CorrelationView.gridColumns(count: 5, isCurrency: false) == 3)
        #expect(CorrelationView.gridColumns(count: 6, isCurrency: false) == 3)
        #expect(CorrelationView.gridColumns(count: 6, isCurrency: true) == 3)
        #expect(CorrelationView.gridColumns(count: 7, isCurrency: true) == 4)
    }

    // MARK: - Tab state codable + back-compat

    @Test("Custom CorrelationTabState round-trips with customID/name/pairs")
    func tabStateRoundTrip() throws {
        let id = UUID()
        let state = CorrelationTabState(
            currency: "", period: "ONE_HOUR", showSessions: true, showVolume: true,
            showEMA: true, emaConfigs: [], customID: id, name: "Carry", pairs: ["NZDJPY", "AUDJPY"])
        let back = try JSONDecoder().decode(CorrelationTabState.self, from: JSONEncoder().encode(state))
        #expect(back.pairs == ["NZDJPY", "AUDJPY"])
        #expect(back.name == "Carry")
        #expect(back.customID == id)
    }

    @Test("Old currency CorrelationTabState JSON (no custom fields) decodes to currency mode")
    func tabStateBackCompat() throws {
        let json = """
        {"currency":"EUR","period":"ONE_HOUR","showSessions":true,"showVolume":true,"showEMA":true,"emaConfigs":[]}
        """.data(using: .utf8)!
        let state = try JSONDecoder().decode(CorrelationTabState.self, from: json)
        #expect(state.currency == "EUR")
        #expect(state.pairs == nil)        // currency mode
        #expect(state.customID == nil)
    }

    // MARK: - Custom view-model

    @Test("CorrelationViewModel(custom:) has no base currency and exactly the chosen pairs")
    func customViewModel() {
        let vm = CorrelationViewModel(
            custom: UUID(), name: "Carry", pairs: ["NZDJPY", "AUDJPY", "EURUSD"],
            period: "ONE_HOUR", coordinator: MockMarketDataCoordinator())
        #expect(vm.baseCurrency == nil)
        #expect(vm.title == "Carry")
        #expect(vm.instruments == ["NZDJPY", "AUDJPY", "EURUSD"])
        #expect(vm.chartViewModels.count == 3)
    }
}
