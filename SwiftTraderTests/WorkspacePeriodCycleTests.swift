import Testing
import Foundation
@testable import SwiftTrader

@Suite("WorkspaceViewModel.cycleSelectedTabPeriod")
@MainActor
struct WorkspacePeriodCycleTests {

    private func makeWorkspaceWithChartTab(period: String = "FIFTEEN_MINS")
        -> (WorkspaceViewModel, ChartViewModel) {
        let ws = WorkspaceViewModel()
        let vm = ChartViewModel(coordinator: MockMarketDataCoordinator())
        vm.currentPeriod = period
        let tab = WorkspaceViewModel.Tab(content: .chart(vm))
        ws.tabs = [tab]
        ws.selectedTabID = tab.id
        return (ws, vm)
    }

    private func makeWorkspaceWithCorrelationTab(period: String = "FIFTEEN_MINS")
        -> (WorkspaceViewModel, CorrelationViewModel) {
        let ws = WorkspaceViewModel()
        let vm = CorrelationViewModel(currency: "USD", period: period, port: 8080, cache: CandleCache())
        let tab = WorkspaceViewModel.Tab(content: .correlation(vm))
        ws.tabs = [tab]
        ws.selectedTabID = tab.id
        return (ws, vm)
    }

    @Test("Cycle up on chart tab advances to the next longer period")
    func cycleUpChart() {
        let (ws, vm) = makeWorkspaceWithChartTab(period: "FIFTEEN_MINS")
        ws.cycleSelectedTabPeriod(offset: 1)
        #expect(vm.currentPeriod == "THIRTY_MINS")
    }

    @Test("Cycle down on chart tab retreats to the next shorter period")
    func cycleDownChart() {
        let (ws, vm) = makeWorkspaceWithChartTab(period: "FIFTEEN_MINS")
        ws.cycleSelectedTabPeriod(offset: -1)
        #expect(vm.currentPeriod == "TEN_MINS")
    }

    @Test("Cycle up at WEEKLY is a no-op")
    func cycleUpAtTop() {
        let (ws, vm) = makeWorkspaceWithChartTab(period: "WEEKLY")
        ws.cycleSelectedTabPeriod(offset: 1)
        #expect(vm.currentPeriod == "WEEKLY")
    }

    @Test("Cycle down at ONE_SEC is a no-op")
    func cycleDownAtBottom() {
        let (ws, vm) = makeWorkspaceWithChartTab(period: "ONE_SEC")
        ws.cycleSelectedTabPeriod(offset: -1)
        #expect(vm.currentPeriod == "ONE_SEC")
    }

    @Test("Cycle on correlation tab updates its currentPeriod")
    func cycleCorrelationTab() {
        let (ws, vm) = makeWorkspaceWithCorrelationTab(period: "FIFTEEN_MINS")
        ws.cycleSelectedTabPeriod(offset: 1)
        #expect(vm.currentPeriod == "THIRTY_MINS")
    }

    @Test("No selected tab: cycle is a silent no-op")
    func cycleWithNoSelection() {
        let ws = WorkspaceViewModel()
        ws.tabs = []
        ws.selectedTabID = nil
        ws.cycleSelectedTabPeriod(offset: 1)  // must not crash
    }

    @Test("Zero offset is a no-op")
    func zeroOffset() {
        let (ws, vm) = makeWorkspaceWithChartTab(period: "FIFTEEN_MINS")
        ws.cycleSelectedTabPeriod(offset: 0)
        #expect(vm.currentPeriod == "FIFTEEN_MINS")
    }
}
