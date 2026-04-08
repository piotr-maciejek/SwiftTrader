import Testing
@testable import SwiftTrader

private func makeBar(time: Int64, open: Double = 1.0, high: Double = 1.2, low: Double = 0.9, close: Double = 1.1, volume: Double = 100, partial: Bool = false) -> CandleBar {
    CandleBar(time: time, open: open, high: high, low: low, close: close, volume: volume, partial: partial)
}

@Suite("ChartViewModel")
@MainActor
struct ChartViewModelTests {

    // MARK: - handleBar: partial bars

    @Test("Partial bar replaces last bar with same timestamp")
    func handleBarPartialUpdatesLastBar() {
        let mock = MockMarketDataCoordinator()
        let vm = ChartViewModel(coordinator: mock)
        vm.bars = [makeBar(time: 1000, close: 1.1)]

        vm.handleBar(makeBar(time: 1000, close: 1.5, partial: true),
                     expectedInstrument: "EURUSD", expectedPeriod: "FIFTEEN_MINS")

        #expect(vm.bars.count == 1)
        #expect(vm.bars[0].close == 1.5)
    }

    @Test("Partial bar with newer timestamp appends")
    func handleBarPartialAppendsNewTime() {
        let mock = MockMarketDataCoordinator()
        let vm = ChartViewModel(coordinator: mock)
        vm.bars = [makeBar(time: 1000)]

        vm.handleBar(makeBar(time: 2000, partial: true),
                     expectedInstrument: "EURUSD", expectedPeriod: "FIFTEEN_MINS")

        #expect(vm.bars.count == 2)
        #expect(vm.bars[1].time == 2000)
    }

    @Test("Partial bar appends to empty bars array")
    func handleBarPartialAppendsToEmpty() {
        let mock = MockMarketDataCoordinator()
        let vm = ChartViewModel(coordinator: mock)

        vm.handleBar(makeBar(time: 1000, partial: true),
                     expectedInstrument: "EURUSD", expectedPeriod: "FIFTEEN_MINS")

        #expect(vm.bars.count == 1)
    }

    // MARK: - handleBar: completed bars

    @Test("Completed bar replaces bar with same timestamp")
    func handleBarCompletedReplaces() {
        let mock = MockMarketDataCoordinator()
        let vm = ChartViewModel(coordinator: mock)
        vm.bars = [makeBar(time: 1000, close: 1.1, partial: true)]

        vm.handleBar(makeBar(time: 1000, close: 1.3),
                     expectedInstrument: "EURUSD", expectedPeriod: "FIFTEEN_MINS")

        #expect(vm.bars.count == 1)
        #expect(vm.bars[0].close == 1.3)
        #expect(vm.bars[0].partial == false)
    }

    @Test("Completed bar appends and triggers cache")
    func handleBarCompletedAppendsAndCaches() async {
        let mock = MockMarketDataCoordinator()
        let vm = ChartViewModel(coordinator: mock)
        vm.bars = [makeBar(time: 1000)]

        vm.handleBar(makeBar(time: 2000),
                     expectedInstrument: "EURUSD", expectedPeriod: "FIFTEEN_MINS")

        #expect(vm.bars.count == 2)

        // Let the async cache task run
        try? await Task.sleep(for: .milliseconds(50))
        #expect(mock.cachedBars.count == 1)
        #expect(mock.cachedBars[0].bar.time == 2000)
    }

    // MARK: - handleBar: stale connection guard

    @Test("Bar ignored when expected instrument doesn't match")
    func handleBarIgnoresStaleInstrument() {
        let mock = MockMarketDataCoordinator()
        let vm = ChartViewModel(coordinator: mock)
        vm.bars = [makeBar(time: 1000)]

        vm.handleBar(makeBar(time: 2000),
                     expectedInstrument: "GBPUSD", expectedPeriod: "FIFTEEN_MINS")

        #expect(vm.bars.count == 1)
    }

    @Test("Bar ignored when expected period doesn't match")
    func handleBarIgnoresStalePeriod() {
        let mock = MockMarketDataCoordinator()
        let vm = ChartViewModel(coordinator: mock)
        vm.bars = [makeBar(time: 1000)]

        vm.handleBar(makeBar(time: 2000),
                     expectedInstrument: "EURUSD", expectedPeriod: "ONE_MIN")

        #expect(vm.bars.count == 1)
    }

    // MARK: - switchInstrument / switchPeriod

    @Test("Switch instrument clears bars and resets transform")
    func switchInstrumentClearsBars() {
        let mock = MockMarketDataCoordinator()
        let vm = ChartViewModel(coordinator: mock)
        vm.bars = [makeBar(time: 1000), makeBar(time: 2000)]
        vm.transform.xOffset = 500

        vm.switchInstrument("GBPUSD")

        #expect(vm.bars.isEmpty)
        #expect(vm.transform.xOffset == 0)
        #expect(vm.currentInstrument == "GBPUSD")
    }

    @Test("Switch to same instrument is no-op")
    func switchInstrumentNoOpForSame() {
        let mock = MockMarketDataCoordinator()
        let vm = ChartViewModel(coordinator: mock)
        vm.bars = [makeBar(time: 1000)]

        vm.switchInstrument("EURUSD")

        #expect(vm.bars.count == 1) // bars not cleared
    }

    @Test("Switch period clears bars and resets transform")
    func switchPeriodClearsBars() {
        let mock = MockMarketDataCoordinator()
        let vm = ChartViewModel(coordinator: mock)
        vm.bars = [makeBar(time: 1000), makeBar(time: 2000)]
        vm.transform.xOffset = 500

        vm.switchPeriod("ONE_HOUR")

        #expect(vm.bars.isEmpty)
        #expect(vm.transform.xOffset == 0)
        #expect(vm.currentPeriod == "ONE_HOUR")
    }

    // MARK: - start() flow

    @Test("start() fetches instruments and loads history")
    func startFetchesInstrumentsAndHistory() async {
        let mock = MockMarketDataCoordinator()
        mock.instrumentsResult = .success(["EURUSD", "GBPUSD", "USDJPY"])
        mock.fetchCandlesResult = .success([makeBar(time: 100), makeBar(time: 200)])
        let vm = ChartViewModel(coordinator: mock)

        await vm.start()

        #expect(mock.fetchInstrumentsCalled)
        #expect(vm.availableInstruments == ["EURUSD", "GBPUSD", "USDJPY"])
        #expect(vm.bars.count == 2)
        vm.stop()
    }

    @Test("start() retains current instrument if not in server list")
    func startRetainsCurrentInstrument() async {
        let mock = MockMarketDataCoordinator()
        mock.instrumentsResult = .success(["GBPUSD", "USDJPY"])
        mock.fetchCandlesResult = .success([makeBar(time: 100)])
        let vm = ChartViewModel(coordinator: mock)
        vm.currentInstrument = "EURCAD"

        await vm.start()

        #expect(vm.availableInstruments.contains("EURCAD"))
        vm.stop()
    }

    @Test("start() guard prevents double start")
    func startGuardPreventsDoubleStart() async {
        let mock = MockMarketDataCoordinator()
        mock.instrumentsResult = .success(["EURUSD"])
        mock.fetchCandlesResult = .success([makeBar(time: 100)])
        let vm = ChartViewModel(coordinator: mock)

        await vm.start()
        await vm.start()

        #expect(mock.fetchCandlesCalls.count == 1) // only called once
        vm.stop()
    }
}
