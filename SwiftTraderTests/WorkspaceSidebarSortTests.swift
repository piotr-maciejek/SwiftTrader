import Testing
import Foundation
@testable import SwiftTrader

@Suite("WorkspaceViewModel sidebar sorting")
@MainActor
struct WorkspaceSidebarSortTests {

    private func makeChartTab(_ instrument: String) -> WorkspaceViewModel.Tab {
        let vm = ChartViewModel(coordinator: MockMarketDataCoordinator())
        vm.currentInstrument = instrument
        return WorkspaceViewModel.Tab(content: .chart(vm))
    }

    private func makeCorrelationTab(_ currency: String) -> WorkspaceViewModel.Tab {
        let vm = CorrelationViewModel(currency: currency, period: "FIFTEEN_MINS",
                                      coordinator: MockMarketDataCoordinator())
        return WorkspaceViewModel.Tab(content: .correlation(vm))
    }

    private func makeWorkspace() -> WorkspaceViewModel {
        WorkspaceViewModel()
    }

    @Test("Volume sort: chart tabs ordered by FX turnover product")
    func volumeSortChartTabs() {
        let ws = makeWorkspace()
        ws.tabs = [
            makeChartTab("NZDCAD"),
            makeChartTab("EURUSD"),
            makeChartTab("GBPJPY"),
        ]
        ws.sidebarSort = .volume

        let order = ws.sortedChartTabs.compactMap { tab -> String? in
            if case .chart(let vm) = tab.content { return vm.currentInstrument }
            return nil
        }
        #expect(order == ["EURUSD", "GBPJPY", "NZDCAD"])
    }

    @Test("Alphabetical sort: chart tabs ordered by instrument code")
    func alphabeticalSortChartTabs() {
        let ws = makeWorkspace()
        ws.tabs = [
            makeChartTab("USDJPY"),
            makeChartTab("AUDCAD"),
            makeChartTab("EURGBP"),
        ]
        ws.sidebarSort = .alphabetical

        let order = ws.sortedChartTabs.compactMap { tab -> String? in
            if case .chart(let vm) = tab.content { return vm.currentInstrument }
            return nil
        }
        #expect(order == ["AUDCAD", "EURGBP", "USDJPY"])
    }

    @Test("Volume sort: correlation tabs ordered by currency turnover")
    func volumeSortCorrelationTabs() {
        let ws = makeWorkspace()
        ws.tabs = [
            makeCorrelationTab("NZD"),
            makeCorrelationTab("USD"),
            makeCorrelationTab("JPY"),
        ]
        ws.sidebarSort = .volume

        let order = ws.sortedCorrelationTabs.compactMap { tab -> String? in
            if case .correlation(let vm) = tab.content { return vm.currency }
            return nil
        }
        #expect(order == ["USD", "JPY", "NZD"])
    }

    @Test("Alphabetical sort: correlation tabs ordered by currency code")
    func alphabeticalSortCorrelationTabs() {
        let ws = makeWorkspace()
        ws.tabs = [
            makeCorrelationTab("USD"),
            makeCorrelationTab("AUD"),
            makeCorrelationTab("EUR"),
        ]
        ws.sidebarSort = .alphabetical

        let order = ws.sortedCorrelationTabs.compactMap { tab -> String? in
            if case .correlation(let vm) = tab.content { return vm.currency }
            return nil
        }
        #expect(order == ["AUD", "EUR", "USD"])
    }

    @Test("Sorted views split chart and correlation tabs into separate sections")
    func sortedViewsSplitByType() {
        let ws = makeWorkspace()
        ws.tabs = [
            makeChartTab("EURUSD"),
            makeCorrelationTab("USD"),
            makeChartTab("GBPUSD"),
            makeCorrelationTab("EUR"),
        ]
        ws.sidebarSort = .volume

        #expect(ws.sortedChartTabs.count == 2)
        #expect(ws.sortedCorrelationTabs.count == 2)
        for tab in ws.sortedChartTabs { #expect(tab.content.isChart) }
        for tab in ws.sortedCorrelationTabs { #expect(!tab.content.isChart) }
    }

    @Test("WorkspaceState round-trips sidebar fields")
    func workspaceStateRoundTripsSidebarFields() throws {
        let original = WorkspaceState(
            tabs: [], selectedTabIndex: nil,
            showBottomPanel: true, showRightPanel: false,
            showLeftPanel: false, sidebarSort: .alphabetical
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: data)
        #expect(decoded.showLeftPanel == false)
        #expect(decoded.sidebarSort == .alphabetical)
    }
}
