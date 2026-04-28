import Testing
import Foundation
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

    @Test("Partial bar dropped when bars is empty (history not loaded yet)")
    func handleBarPartialDroppedWhenEmpty() {
        // Showing a single live candle with no historical context is misleading,
        // and dismisses the ChartLoadingCard overlay (gated on bars.isEmpty).
        // Partials are only meaningful as the right edge of a populated chart.
        let mock = MockMarketDataCoordinator()
        let vm = ChartViewModel(coordinator: mock)

        vm.handleBar(makeBar(time: 1000, partial: true),
                     expectedInstrument: "EURUSD", expectedPeriod: "FIFTEEN_MINS")

        #expect(vm.bars.isEmpty)
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

    // MARK: - barCount(for:) via fetchCandles count

    @Test("Daily period requests 250 bars")
    func startDailyRequests250() async {
        let mock = MockMarketDataCoordinator()
        mock.instrumentsResult = .success(["EURUSD"])
        mock.fetchCandlesResult = .success([makeBar(time: 100)])
        let vm = ChartViewModel(coordinator: mock)
        vm.currentPeriod = "DAILY"

        await vm.start()

        #expect(mock.fetchCandlesCalls.first?.count == 250)
        vm.stop()
    }

    @Test("Intraday period requests 1000 bars")
    func startIntradayRequests1000() async {
        let mock = MockMarketDataCoordinator()
        mock.instrumentsResult = .success(["EURUSD"])
        mock.fetchCandlesResult = .success([makeBar(time: 100)])
        let vm = ChartViewModel(coordinator: mock)
        vm.currentPeriod = "FIFTEEN_MINS"

        await vm.start()

        #expect(mock.fetchCandlesCalls.first?.count == 1000)
        vm.stop()
    }

    @Test("Four-hour period requests 500 bars")
    func startFourHourRequests500() async {
        let mock = MockMarketDataCoordinator()
        mock.instrumentsResult = .success(["EURUSD"])
        mock.fetchCandlesResult = .success([makeBar(time: 100)])
        let vm = ChartViewModel(coordinator: mock)
        vm.currentPeriod = "FOUR_HOURS"

        await vm.start()

        #expect(mock.fetchCandlesCalls.first?.count == 500)
        vm.stop()
    }

    // MARK: - Live ATR today% update

    @Test("handleBar updates todayATRPercent when bar extends today's high")
    func handleBarUpdatesATRPercent() {
        let mock = MockMarketDataCoordinator()
        let vm = ChartViewModel(coordinator: mock)
        vm.bars = [makeBar(time: 1000)]

        // Simulate state after loadATR: ATR = 0.0100, today's range so far 1.100–1.104
        vm.atrValue = 0.0100
        vm.todayATRPercent = 40.0  // (1.104-1.100)/0.01*100
        vm.setTodayATRRange(
            dayStart: Date.distantPast,
            high: 1.104,
            low: 1.100
        )

        // New bar with higher high: 1.107 → range becomes 1.107-1.100 = 0.007 → 70%
        vm.handleBar(makeBar(time: 2000, high: 1.107, low: 1.101, close: 1.106),
                     expectedInstrument: "EURUSD", expectedPeriod: "FIFTEEN_MINS")

        #expect(vm.todayATRPercent != nil)
        #expect(abs(vm.todayATRPercent! - 70.0) < 0.01)
    }

    @Test("handleBar does not lower todayATRPercent when bar is within existing range")
    func handleBarDoesNotShrinkATRRange() {
        let mock = MockMarketDataCoordinator()
        let vm = ChartViewModel(coordinator: mock)
        vm.bars = [makeBar(time: 1000)]

        vm.atrValue = 0.0100
        vm.todayATRPercent = 40.0
        vm.setTodayATRRange(
            dayStart: Date.distantPast,
            high: 1.104,
            low: 1.100
        )

        // Bar within existing range — should not change percentage
        vm.handleBar(makeBar(time: 2000, high: 1.103, low: 1.101, close: 1.102),
                     expectedInstrument: "EURUSD", expectedPeriod: "FIFTEEN_MINS")

        #expect(abs(vm.todayATRPercent! - 40.0) < 0.01)
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

    // MARK: - Loading status

    @Test("loadingStatus clears after a successful history load")
    func loadingStatusClearsAfterSuccess() async {
        let mock = MockMarketDataCoordinator()
        mock.instrumentsResult = .success(["EURUSD"])
        mock.fetchCandlesResult = .success([makeBar(time: 100)])
        let vm = ChartViewModel(coordinator: mock)

        await vm.start()
        #expect(vm.loadingStatus == nil)
        vm.stop()
    }

    @Test("loadingStatus carries attempt + lastError on retry")
    func loadingStatusRetryShape() {
        let s = LoadingStatus.loadingHistory(
            attempt: 3, period: "DAILY", rebucketing: true,
            coldCache: true, lastError: "timeout"
        )
        #expect(s.message.contains("attempt 3"))
        #expect(s.lastError == "timeout")
        #expect(s.detail?.contains("6000") == true)
    }

    @Test("loadingStatus.detail nil on warm cache")
    func loadingStatusWarmCacheNoDetail() {
        let s = LoadingStatus.loadingHistory(
            attempt: 1, period: "DAILY", rebucketing: true,
            coldCache: false, lastError: nil
        )
        #expect(s.detail == nil)
    }

    // MARK: - Warm-cache cold start

    @Test("start() with warm cache paints bars before fetchInstruments resolves")
    func startWarmCachePaintsImmediately() async {
        let mock = MockMarketDataCoordinator()
        // Pre-seed the cache as if disk hydration just finished.
        let cached = [makeBar(time: 100), makeBar(time: 200), makeBar(time: 300)]
        let key = CandleCache.CacheKey(instrument: "EURUSD", period: "FIFTEEN_MINS", source: .server)
        _ = await mock.cache.merge(cached, for: key)

        // Simulate a sluggish server: instruments call fails forever, fetchCandles never returns
        // useful data. Even so, start() should paint the cached bars from disk.
        struct NeverError: Error {}
        mock.instrumentsResult = .failure(NeverError())
        mock.fetchCandlesResult = .success([])

        let vm = ChartViewModel(coordinator: mock)
        // Run start() in a background Task so we can observe state mid-flight.
        let startTask = Task { await vm.start() }
        // Give the cache-paint a chance to run before the fetchInstruments retry kicks in.
        for _ in 0..<20 {
            if !vm.bars.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(vm.bars.count == 3)
        #expect(vm.bars.map(\.time) == [100, 200, 300])
        // No overlay over warm bars — ContentView keys off bars.isEmpty so the loading card
        // is hidden when bars are populated.
        #expect(vm.loadingStatus == nil || vm.loadingStatus?.stage != .connecting)

        startTask.cancel()
        vm.stop()
    }

    @Test("start() with cold cache shows .connecting status")
    func startColdCacheShowsConnecting() async {
        let mock = MockMarketDataCoordinator()
        // Empty cache; failing instruments call so we stay in the connect-retry loop.
        struct NeverError: Error {}
        mock.instrumentsResult = .failure(NeverError())

        let vm = ChartViewModel(coordinator: mock)
        let startTask = Task { await vm.start() }
        for _ in 0..<20 {
            if vm.loadingStatus != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(vm.bars.isEmpty)
        #expect(vm.loadingStatus?.stage == .connecting)

        startTask.cancel()
        vm.stop()
    }
}
