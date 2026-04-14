import Testing
import Foundation
@testable import SwiftTrader

@Suite("WorkspaceViewModel.moveSelectedTab")
@MainActor
struct WorkspaceMoveTabTests {

    private func makeChartTab() -> WorkspaceViewModel.Tab {
        WorkspaceViewModel.Tab(content: .chart(ChartViewModel(coordinator: MockMarketDataCoordinator())))
    }

    private func makeCorrelationTab() -> WorkspaceViewModel.Tab {
        let vm = CorrelationViewModel(currency: "USD", period: "FIFTEEN_MINS", port: 8080, cache: CandleCache())
        return WorkspaceViewModel.Tab(content: .correlation(vm))
    }

    /// Build a workspace with the given tab layout. `kinds` is a string like
    /// "ccXc" where 'c' is a chart tab and 'X' is a correlation tab, in order.
    private func makeWorkspace(layout: String) -> WorkspaceViewModel {
        let ws = WorkspaceViewModel()
        ws.tabs = layout.map { c in
            c == "X" ? makeCorrelationTab() : makeChartTab()
        }
        return ws
    }

    private func layout(_ ws: WorkspaceViewModel) -> String {
        ws.tabs.map { $0.content.isChart ? "c" : "X" }.joined()
    }

    @Test("Move rightmost chart tab left when a correlation tab sits between (regression)")
    func moveLastChartTabLeftAcrossCorrelation() {
        // Repro for the original bug: with tabs = [c, c, X, c] and the rightmost
        // chart selected, moveSelectedTab(-1) used to be a no-op because it hit
        // the correlation tab and broke out of the loop.
        let ws = makeWorkspace(layout: "ccXc")
        let leftMost = ws.tabs[0].id
        let middleChart = ws.tabs[1].id
        let moved = ws.tabs[3].id
        ws.selectedTabID = moved

        ws.moveSelectedTab(offset: -1)

        let chartRow = ws.tabs.filter { $0.content.isChart }.map { $0.id }
        #expect(chartRow == [leftMost, moved, middleChart])
    }

    @Test("Move leftmost chart tab right across correlation tab")
    func moveFirstChartTabRightAcrossCorrelation() {
        let ws = makeWorkspace(layout: "cXcc")
        let moved = ws.tabs[0].id
        let middleChart = ws.tabs[2].id
        let rightChart = ws.tabs[3].id
        ws.selectedTabID = moved

        ws.moveSelectedTab(offset: 1)

        let chartRow = ws.tabs.filter { $0.content.isChart }.map { $0.id }
        #expect(chartRow == [middleChart, moved, rightChart])
    }

    @Test("Correlation tab moves within its own row, skipping chart tabs")
    func correlationMovesWithinRow() {
        // Two correlation tabs separated by a chart tab.
        let ws = makeWorkspace(layout: "XcX")
        ws.selectedTabID = ws.tabs[2].id  // rightmost correlation tab
        let moved = ws.tabs[2].id

        ws.moveSelectedTab(offset: -1)

        #expect(layout(ws) == "XXc")
        let corrRow = ws.tabs.filter { !$0.content.isChart }
        #expect(corrRow[0].id == moved)
    }

    @Test("Move right on rightmost chart tab in its row is a no-op")
    func rightmostChartTabRightIsNoOp() {
        let ws = makeWorkspace(layout: "ccXc")
        ws.selectedTabID = ws.tabs[3].id
        let before = ws.tabs.map { $0.id }

        ws.moveSelectedTab(offset: 1)

        #expect(ws.tabs.map { $0.id } == before)
    }

    @Test("Move left on leftmost chart tab in its row is a no-op")
    func leftmostChartTabLeftIsNoOp() {
        let ws = makeWorkspace(layout: "cXcc")
        ws.selectedTabID = ws.tabs[0].id
        let before = ws.tabs.map { $0.id }

        ws.moveSelectedTab(offset: -1)

        #expect(ws.tabs.map { $0.id } == before)
    }

    @Test("Move within a pure chart row behaves as expected")
    func pureChartRowMove() {
        let ws = makeWorkspace(layout: "ccc")
        let firstID = ws.tabs[0].id
        ws.selectedTabID = firstID

        ws.moveSelectedTab(offset: 1)

        #expect(ws.tabs[1].id == firstID)

        ws.moveSelectedTab(offset: 1)
        #expect(ws.tabs[2].id == firstID)

        // Already at the end — no-op.
        ws.moveSelectedTab(offset: 1)
        #expect(ws.tabs[2].id == firstID)
    }

    @Test("Multi-step move skips multiple cross-row tabs")
    func multiStepSkipsCrossRow() {
        // [c0, X, X, c1] — move c0 to the right by 1 in its row, should end up at position 3.
        let ws = makeWorkspace(layout: "cXXc")
        ws.selectedTabID = ws.tabs[0].id
        let moved = ws.tabs[0].id

        ws.moveSelectedTab(offset: 1)

        #expect(layout(ws) == "XXcc")
        let chartRow = ws.tabs.filter { $0.content.isChart }
        #expect(chartRow[0].id != moved)
        #expect(chartRow[1].id == moved)
    }
}
