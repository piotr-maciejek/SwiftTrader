import Testing
import Foundation
@testable import SwiftTrader

@Suite("MultiTimeframeViewModel")
@MainActor
struct MultiTimeframeViewModelTests {

    @Test("Standard zoom creates 4 children with D, 4H, 1H, 15m")
    func standardZoomChildren() {
        let vm = MultiTimeframeViewModel(
            instrument: "EURUSD", zoom: .standard,
            coordinator: MockMarketDataCoordinator()
        )
        #expect(vm.chartViewModels.count == 4)
        #expect(vm.chartViewModels[0].currentPeriod == "DAILY")
        #expect(vm.chartViewModels[1].currentPeriod == "FOUR_HOURS")
        #expect(vm.chartViewModels[2].currentPeriod == "ONE_HOUR")
        #expect(vm.chartViewModels[3].currentPeriod == "FIFTEEN_MINS")
        for child in vm.chartViewModels {
            #expect(child.currentInstrument == "EURUSD")
        }
    }

    @Test("Intraday zoom creates 4 children with 4H, 1H, 15m, 3m")
    func intradayZoomChildren() {
        let vm = MultiTimeframeViewModel(
            instrument: "GBPUSD", zoom: .intraday,
            coordinator: MockMarketDataCoordinator()
        )
        #expect(vm.chartViewModels.count == 4)
        #expect(vm.chartViewModels[0].currentPeriod == "FOUR_HOURS")
        #expect(vm.chartViewModels[1].currentPeriod == "ONE_HOUR")
        #expect(vm.chartViewModels[2].currentPeriod == "FIFTEEN_MINS")
        #expect(vm.chartViewModels[3].currentPeriod == "THREE_MINS")
    }

    @Test("Switching zoom updates child periods")
    func switchZoomUpdatesChildren() {
        let vm = MultiTimeframeViewModel(
            instrument: "USDJPY", zoom: .standard,
            coordinator: MockMarketDataCoordinator()
        )
        vm.zoom = .intraday
        #expect(vm.chartViewModels[0].currentPeriod == "FOUR_HOURS")
        #expect(vm.chartViewModels[3].currentPeriod == "THREE_MINS")
    }

    @Test("Setting display flags propagates to all children")
    func displayFlagPropagation() {
        let vm = MultiTimeframeViewModel(
            instrument: "EURUSD", zoom: .standard,
            coordinator: MockMarketDataCoordinator()
        )
        vm.showSessions = false
        vm.showVolume = false
        vm.showEMA = false
        vm.showATR = false
        vm.atrPeriod = 21

        for child in vm.chartViewModels {
            #expect(child.showSessions == false)
            #expect(child.showVolume == false)
            #expect(child.showEMA == false)
            #expect(child.showATR == false)
            #expect(child.atrPeriod == 21)
        }
    }

    @Test("MultiTimeframeTabState round-trips with defaults")
    func tabStateRoundTrip() throws {
        let original = MultiTimeframeTabState(instrument: "EURUSD")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MultiTimeframeTabState.self, from: data)
        #expect(decoded.instrument == "EURUSD")
        #expect(decoded.zoom == .standard)
        #expect(decoded.showATR == true)
        #expect(decoded.atrPeriod == 14)
    }

    @Test("MultiTimeframeTabState decodes from minimal JSON")
    func tabStateMinimalDecode() throws {
        let json = """
        {"instrument":"GBPUSD"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MultiTimeframeTabState.self, from: json)
        #expect(decoded.instrument == "GBPUSD")
        #expect(decoded.zoom == .standard)
        #expect(decoded.showSessions == true)
    }

    @Test("Workspace state round-trips multiTimeframe tab")
    func workspaceStateRoundTripMultiTF() throws {
        let tab = TabState(id: UUID(), content: .multiTimeframe(
            MultiTimeframeTabState(instrument: "AUDUSD", zoom: .intraday)
        ))
        let state = WorkspaceState(
            tabs: [tab], selectedTabIndex: 0,
            showBottomPanel: false, showRightPanel: false
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: data)
        #expect(decoded.tabs.count == 1)
        if case .multiTimeframe(let mtf) = decoded.tabs[0].content {
            #expect(mtf.instrument == "AUDUSD")
            #expect(mtf.zoom == .intraday)
        } else {
            Issue.record("Expected multiTimeframe content")
        }
    }
}
