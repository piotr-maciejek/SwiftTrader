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

    private func makeMultiTFTab(_ instrument: String) -> WorkspaceViewModel.Tab {
        let vm = MultiTimeframeViewModel(instrument: instrument, zoom: .standard,
                                         coordinator: MockMarketDataCoordinator())
        return WorkspaceViewModel.Tab(content: .multiTimeframe(vm))
    }

    private func makeWorkspace() -> WorkspaceViewModel {
        WorkspaceViewModel()
    }

    @Test("Chart tabs sort alphabetically")
    func chartTabsAlphabetical() {
        let ws = makeWorkspace()
        ws.tabs = [
            makeChartTab("USDJPY"),
            makeChartTab("AUDCAD"),
            makeChartTab("EURGBP"),
        ]
        let order = ws.sortedChartTabs.compactMap { tab -> String? in
            if case .chart(let vm) = tab.content { return vm.currentInstrument }
            return nil
        }
        #expect(order == ["AUDCAD", "EURGBP", "USDJPY"])
    }

    @Test("Correlation tabs sort alphabetically")
    func correlationTabsAlphabetical() {
        let ws = makeWorkspace()
        ws.tabs = [
            makeCorrelationTab("USD"),
            makeCorrelationTab("AUD"),
            makeCorrelationTab("EUR"),
        ]
        let order = ws.sortedCorrelationTabs.compactMap { tab -> String? in
            if case .correlation(let vm) = tab.content { return vm.currency }
            return nil
        }
        #expect(order == ["AUD", "EUR", "USD"])
    }

    @Test("Multi-TF tabs sort alphabetically by instrument")
    func multiTFTabsAlphabetical() {
        let ws = makeWorkspace()
        ws.tabs = [
            makeMultiTFTab("USDJPY"),
            makeMultiTFTab("AUDCAD"),
            makeMultiTFTab("EURGBP"),
        ]
        let order = ws.sortedMultiTimeframeTabs.compactMap { tab -> String? in
            if case .multiTimeframe(let vm) = tab.content { return vm.instrument }
            return nil
        }
        #expect(order == ["AUDCAD", "EURGBP", "USDJPY"])
    }

    @Test("Sorted views split tabs by type")
    func sortedViewsSplitByType() {
        let ws = makeWorkspace()
        ws.tabs = [
            makeChartTab("EURUSD"),
            makeCorrelationTab("USD"),
            makeMultiTFTab("GBPUSD"),
            makeChartTab("AUDUSD"),
            makeCorrelationTab("EUR"),
        ]
        #expect(ws.sortedChartTabs.count == 2)
        #expect(ws.sortedCorrelationTabs.count == 2)
        #expect(ws.sortedMultiTimeframeTabs.count == 1)
    }

    @Test("WorkspaceState round-trips left-panel field")
    func workspaceStateRoundTripsLeftPanel() throws {
        let original = WorkspaceState(
            tabs: [], selectedTabIndex: nil,
            showBottomPanel: true, showRightPanel: false,
            showLeftPanel: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: data)
        #expect(decoded.showLeftPanel == false)
    }
}
