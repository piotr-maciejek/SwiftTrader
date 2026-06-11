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

    @Test("Completed bar appends and triggers cache (raw period)")
    func handleBarCompletedAppendsAndCaches() async {
        let mock = MockMarketDataCoordinator()
        let vm = ChartViewModel(coordinator: mock)
        // ONE_HOUR is a raw (non-derived) period, so a completed bar is cached directly.
        // Derived periods (5m/15m/30m/3m/4H/Daily/Weekly) rebuild from their source and
        // intentionally skip cacheBar — covered separately below.
        vm.currentPeriod = "ONE_HOUR"
        vm.bars = [makeBar(time: 1000)]

        vm.handleBar(makeBar(time: 2000),
                     expectedInstrument: "EURUSD", expectedPeriod: "ONE_HOUR")

        #expect(vm.bars.count == 2)

        // Let the async cache task run
        try? await Task.sleep(for: .milliseconds(50))
        #expect(mock.cachedBars.count == 1)
        #expect(mock.cachedBars[0].bar.time == 2000)
    }

    @Test("Cache write keys by the bar's chart identity even if the user switches mid-hop")
    func handleBarCachesUnderGuardTimeIdentity() async {
        // handleBar's staleness guard checks instrument/period synchronously, but the
        // cacheBar write hops through an async Task. If that Task read the CURRENT
        // chart identity, an instrument switch in between would file this EURUSD bar
        // under the new pair's disk cache key — a cross-pair poison that survives
        // restarts. The write must carry the guard-time (expected*) identity.
        let mock = MockMarketDataCoordinator()
        let vm = ChartViewModel(coordinator: mock)
        vm.currentPeriod = "ONE_HOUR"
        vm.bars = [makeBar(time: 1000)]

        vm.handleBar(makeBar(time: 2000),
                     expectedInstrument: "EURUSD", expectedPeriod: "ONE_HOUR")
        // Switch the chart BEFORE the unstructured Task body runs (it can't start
        // until this synchronous main-actor code yields).
        vm.currentInstrument = "USDJPY"
        vm.currentPeriod = "FIFTEEN_MINS"

        try? await Task.sleep(for: .milliseconds(50))
        #expect(mock.cachedBars.count == 1)
        #expect(mock.cachedBars[0].instrument == "EURUSD")
        #expect(mock.cachedBars[0].period == "ONE_HOUR")
    }

    @Test("Completed bar on a derived period appends but skips cache")
    func handleBarDerivedAppendsButSkipsCache() async {
        let mock = MockMarketDataCoordinator()
        let vm = ChartViewModel(coordinator: mock)
        // 15m is derived from 1m client-side; the derived bar must NOT be persisted
        // (only its 1m source is cached), or the cache would hold un-refreshable bars.
        vm.currentPeriod = "FIFTEEN_MINS"
        vm.bars = [makeBar(time: 1000)]

        vm.handleBar(makeBar(time: 2000),
                     expectedInstrument: "EURUSD", expectedPeriod: "FIFTEEN_MINS")

        #expect(vm.bars.count == 2)

        try? await Task.sleep(for: .milliseconds(50))
        #expect(mock.cachedBars.isEmpty)
    }

    // MARK: - handleBar: intra-session gap suppression

    @Test("Forming bar past an intra-session gap is not painted as a floating candle")
    func gapSuppressesFloatingFormingBar() {
        let vm = ChartViewModel(coordinator: MockMarketDataCoordinator())
        vm.currentPeriod = "FIFTEEN_MINS"
        let base: Int64 = 1_700_000_000_000
        vm.bars = [makeBar(time: base), makeBar(time: base + 900_000)]   // tail at base+15m

        // Forming bar 3 buckets ahead (base+30m and +45m are missing) — a late-subscriber drift.
        vm.handleBar(makeBar(time: base + 900_000 * 4, partial: true),
                     expectedInstrument: "EURUSD", expectedPeriod: "FIFTEEN_MINS")

        // Not appended as a lone candle floating past the gap; reconcile fills it instead.
        #expect(vm.bars.count == 2)
        #expect(vm.bars.last?.time == base + 900_000)
    }

    @Test("Forming bar one contiguous bucket ahead still appends")
    func contiguousFormingBarAppends() {
        let vm = ChartViewModel(coordinator: MockMarketDataCoordinator())
        vm.currentPeriod = "FIFTEEN_MINS"
        let base: Int64 = 1_700_000_000_000
        vm.bars = [makeBar(time: base)]

        vm.handleBar(makeBar(time: base + 900_000, partial: true),
                     expectedInstrument: "EURUSD", expectedPeriod: "FIFTEEN_MINS")

        #expect(vm.bars.count == 2)
        #expect(vm.bars.last?.time == base + 900_000)
    }

    @Test("Forming bar past a weekend-sized gap still appends (legitimate reopen)")
    func weekendGapStillAppends() {
        let vm = ChartViewModel(coordinator: MockMarketDataCoordinator())
        vm.currentPeriod = "FIFTEEN_MINS"
        let base: Int64 = 1_700_000_000_000
        vm.bars = [makeBar(time: base)]

        // ~50h later (a weekend) — beyond the heal window, so it appends as a legitimate reopen.
        vm.handleBar(makeBar(time: base + 50 * 3_600_000, partial: true),
                     expectedInstrument: "EURUSD", expectedPeriod: "FIFTEEN_MINS")

        #expect(vm.bars.count == 2)
    }

    // MARK: - firstIntraSessionGapIndex: periodic self-heal detector

    @Test("Detects an intra-session hole in the series")
    func detectsIntraSessionGap() {
        let vm = ChartViewModel(coordinator: MockMarketDataCoordinator())
        vm.currentPeriod = "FIVE_MINS"
        let base: Int64 = 1_700_000_000_000
        // base, +5m, then jump to +20m (missing +10m and +15m)
        vm.bars = [makeBar(time: base), makeBar(time: base + 300_000), makeBar(time: base + 1_200_000)]

        #expect(vm.firstIntraSessionGapIndex() == 2)
    }

    @Test("Contiguous series has no gap")
    func contiguousSeriesNoGap() {
        let vm = ChartViewModel(coordinator: MockMarketDataCoordinator())
        vm.currentPeriod = "FIVE_MINS"
        let base: Int64 = 1_700_000_000_000
        vm.bars = [makeBar(time: base), makeBar(time: base + 300_000), makeBar(time: base + 600_000)]

        #expect(vm.firstIntraSessionGapIndex() == nil)
    }

    @Test("Weekend-sized hole is not flagged as an intra-session gap")
    func weekendHoleNotFlagged() {
        let vm = ChartViewModel(coordinator: MockMarketDataCoordinator())
        vm.currentPeriod = "FIVE_MINS"
        let base: Int64 = 1_700_000_000_000
        vm.bars = [makeBar(time: base), makeBar(time: base + 50 * 3_600_000)]   // ~weekend

        #expect(vm.firstIntraSessionGapIndex() == nil)
    }

    @Test("Session-aligned periods are never gap-flagged")
    func sessionAlignedNeverFlagged() {
        let vm = ChartViewModel(coordinator: MockMarketDataCoordinator())
        vm.currentPeriod = "DAILY"
        let base: Int64 = 1_700_000_000_000
        vm.bars = [makeBar(time: base), makeBar(time: base + 5 * 86_400_000)]

        #expect(vm.firstIntraSessionGapIndex() == nil)
    }

    // MARK: - intraSessionGapIndex: shared load-path / live-path gap rule

    @Test("Static gap index flags a hole in a cached series before painting")
    func staticGapIndexFlagsHole() {
        let base: Int64 = 1_700_000_000_000
        let gapped = [makeBar(time: base), makeBar(time: base + 180_000), makeBar(time: base + 720_000)]
        #expect(ChartViewModel.intraSessionGapIndex(in: gapped, period: "THREE_MINS") == 2)
    }

    @Test("Static gap index passes a contiguous cached series")
    func staticGapIndexPassesContiguous() {
        let base: Int64 = 1_700_000_000_000
        let ok = [makeBar(time: base), makeBar(time: base + 180_000), makeBar(time: base + 360_000)]
        #expect(ChartViewModel.intraSessionGapIndex(in: ok, period: "THREE_MINS") == nil)
    }

    @Test("Static gap index ignores weekend-sized holes and session-aligned periods")
    func staticGapIndexIgnoresWeekendAndDaily() {
        let base: Int64 = 1_700_000_000_000
        let weekend = [makeBar(time: base), makeBar(time: base + 50 * 3_600_000)]
        #expect(ChartViewModel.intraSessionGapIndex(in: weekend, period: "THREE_MINS") == nil)
        let daily = [makeBar(time: base), makeBar(time: base + 5 * 86_400_000)]
        #expect(ChartViewModel.intraSessionGapIndex(in: daily, period: "DAILY") == nil)
    }

    // MARK: - reconciledBars: live forming bar always wins for its bucket

    @Test("Reconcile keeps the complete live forming bar over an incomplete same-bucket authoritative bar")
    func reconcileLiveBarWinsSameBucket() {
        // The rebuild path can emit the in-progress bucket as a mis-flagged CLOSED bar built from
        // only the 1m bars already on disk — thin/incomplete. Our live forming bar holds the full
        // bucket and must win, or the chart paints a "missing-data" candle that drifts from peers.
        let live = makeBar(time: 900_000, high: 1.5, low: 0.5, close: 1.4, partial: true)
        let authoritative = [
            makeBar(time: 0),
            makeBar(time: 900_000, high: 1.05, low: 0.99, close: 1.0, partial: false),
        ]

        let result = ChartViewModel.reconciledBars(authoritative: authoritative, current: [], liveForming: live)

        #expect(result.count == 2)
        #expect(result.last?.time == 900_000)
        #expect(result.last?.partial == true)
        #expect(result.last?.high == 1.5)   // the live bar, not the incomplete 1.05
    }

    @Test("Reconcile appends the live forming bar after the last closed authoritative bar")
    func reconcileAppendsLiveBeyondClosed() {
        let live = makeBar(time: 1_800_000, partial: true)
        let authoritative = [makeBar(time: 0), makeBar(time: 900_000)]

        let result = ChartViewModel.reconciledBars(authoritative: authoritative, current: [], liveForming: live)

        #expect(result.map(\.time) == [0, 900_000, 1_800_000])
        #expect(result.last?.partial == true)
    }

    @Test("Reconcile drops authoritative partials and needs no live bar")
    func reconcileFiltersAuthoritativePartials() {
        let authoritative = [makeBar(time: 0), makeBar(time: 900_000, partial: true)]

        let result = ChartViewModel.reconciledBars(authoritative: authoritative, current: [], liveForming: nil)

        #expect(result.count == 1)
        #expect(result.last?.time == 0)
    }

    @Test("Reconcile ignores a non-partial live bar")
    func reconcileIgnoresNonPartialLive() {
        let authoritative = [makeBar(time: 0), makeBar(time: 900_000)]

        let result = ChartViewModel.reconciledBars(
            authoritative: authoritative, current: [], liveForming: makeBar(time: 1_800_000, partial: false))

        #expect(result.map(\.time) == [0, 900_000])
    }

    @Test("Reconcile never shrinks a just-closed bar (the AUDCAD 3m downgrade bug)")
    func reconcileDoesNotShrinkJustClosed() {
        // The just-closed bar the live aggregation captured COMPLETELY (wide range, real close)...
        let liveClosed = makeBar(time: 900_000, open: 1.10, high: 1.1010, low: 1.0980, close: 1.0995)
        let forming = makeBar(time: 1_800_000, partial: true)
        let current = [makeBar(time: 0), liveClosed, forming]
        // ...but authoritative LAGS (narrower low/high, an earlier close) because its 1m source
        // hasn't flushed the bucket. Merge must keep the wider live data, not downgrade.
        let authoritative = [makeBar(time: 0),
                             makeBar(time: 900_000, open: 1.10, high: 1.1005, low: 1.0990, close: 1.0998)]

        let merged = ChartViewModel.reconciledBars(
            authoritative: authoritative, current: current, liveForming: forming)
            .first { $0.time == 900_000 }

        #expect(merged?.low == 1.0980)    // kept the live low, not authoritative's 1.0990
        #expect(merged?.high == 1.1010)   // kept the live high
        #expect(merged?.close == 1.0995)  // kept the live close (live spans authoritative)
    }

    @Test("Reconcile widens a genuinely-incomplete live bar from authoritative")
    func reconcileWidensIncompleteLive() {
        // Live opened mid-bucket (narrow); authoritative is the complete, wider one → take it.
        let liveNarrow = makeBar(time: 900_000, open: 1.1000, high: 1.1002, low: 1.0998, close: 1.1001)
        let current = [makeBar(time: 0), liveNarrow]
        let authoritative = [makeBar(time: 0),
                             makeBar(time: 900_000, open: 1.0990, high: 1.1010, low: 1.0980, close: 1.1005)]

        let merged = ChartViewModel.reconciledBars(
            authoritative: authoritative, current: current, liveForming: nil)
            .first { $0.time == 900_000 }

        #expect(merged?.low == 1.0980)    // union low (authoritative wider)
        #expect(merged?.high == 1.1010)   // union high
        #expect(merged?.open == 1.0990)   // authoritative open (live didn't span it → incomplete)
        #expect(merged?.close == 1.1005)  // authoritative close
    }

    @Test("Reconcile catches up a STALE chart (drops the stale tail for the newer authoritative series)")
    func reconcileCatchesUpStaleChart() {
        // The chart's live feed stalled: its last (frozen, partial) bar is OLD. Authoritative has
        // since backfilled newer closed bars. The stale bar must NOT pin the series to the past.
        let staleLast = makeBar(time: 900_000, partial: true)
        let current = [makeBar(time: 0), staleLast]
        let authoritative = [makeBar(time: 0), makeBar(time: 900_000),
                             makeBar(time: 1_800_000), makeBar(time: 2_700_000)]

        let result = ChartViewModel.reconciledBars(
            authoritative: authoritative, current: current, liveForming: staleLast)

        #expect(result.map(\.time) == [0, 900_000, 1_800_000, 2_700_000])  // caught up to the newer series
        #expect(result.last?.partial == false)   // adopted authoritative's closed bar, not the stale partial
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
        // Seed the key the VM actually paints from. 15m now toggles with rebucketing
        // (.aggregated when on), so resolve the display key the same way start() does
        // rather than hard-coding .server.
        let key = CandleCache.CacheKey.forDisplay(
            instrument: "EURUSD", period: "FIFTEEN_MINS",
            clientSideRebucketing: AppSettings.shared.clientSideRebucketing
        )
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

    // MARK: - scrollToEnd / autoscroll on width change

    /// Bars at 10px slot width (default xScale 1.0).
    private func bars(_ n: Int) -> [CandleBar] {
        (0..<n).map { makeBar(time: Int64($0 + 1) * 1000) }
    }

    @Test("liveEdgeOffset puts the last bar at the live edge with a 10% right margin")
    func liveEdgeOffsetLeavesRightMargin() {
        // 100 bars × 10px slot = 1000 content; 300px viewport.
        let off = ChartView.liveEdgeOffset(barCount: 100, slotWidth: 10, chartWidth: 300)
        #expect(off == 1000 - 300 * (1 - ChartView.rightMarginFraction))   // 1000 - 270 = 730

        // Last bar's screen x sits inside the viewport, ~10% from the right edge.
        let lastX = CGFloat(100 - 1) * 10 - off + 10 / 2   // index*slot - offset + half-slot
        #expect(lastX < 300)
        #expect(lastX > 300 * (1 - ChartView.rightMarginFraction) - 10)
    }

    @Test("liveEdgeOffset keeps a chart shorter than the viewport left-anchored")
    func liveEdgeOffsetShortChartLeftAnchored() {
        // 5 bars × 10 = 50 content, well under a 300px viewport → offset clamps to 0.
        let off = ChartView.liveEdgeOffset(barCount: 5, slotWidth: 10, chartWidth: 300)
        #expect(off == 0)
    }

    // MARK: - xOffsetCenteringTime: viewport anchoring (TF switch + reconcile drift guard)

    /// 1-minute spaced bar times, count `n`.
    private func minuteTimes(_ n: Int) -> [Int64] {
        (0..<n).map { Int64($0) * 60_000 }
    }

    @Test("xOffsetCenteringTime puts the targeted bar-time at the viewport center")
    func centeringTimePlacesBarAtCenter() {
        let times = minuteTimes(100)            // 100 bars × 10px = 1000 content
        let off = DrawingMath.xOffsetCenteringTime(times[50], barTimes: times, slotWidth: 10, chartWidth: 200)
        // Bar 50's screen x must equal chartWidth/2 (not clamped: raw 405 ∈ [0, 820]).
        let x = DrawingMath.xForBar(index: 50, xOffset: off, slotWidth: 10)
        #expect(x == 100)
        // Round-trips through the inverse map.
        #expect(DrawingMath.timeMsForX(100, barTimes: times, xOffset: off, slotWidth: 10) == times[50])
    }

    @Test("xOffsetCenteringTime centers a near-live time (keeping future room), clamps only at the left edge")
    func centeringTimeKeepsFutureRoom() {
        let times = minuteTimes(100)
        // The newest bar CAN be centered — leaving empty future room on the right (no live-edge snap).
        let last = DrawingMath.xOffsetCenteringTime(times[99], barTimes: times, slotWidth: 10, chartWidth: 200)
        #expect(DrawingMath.xForBar(index: 99, xOffset: last, slotWidth: 10) == 100)   // bar 99 at center
        #expect(last > ChartView.liveEdgeOffset(barCount: 100, slotWidth: 10, chartWidth: 200))  // past the live edge
        // The oldest bar can't be centered — offset clamps at 0 (left-anchored).
        let first = DrawingMath.xOffsetCenteringTime(times[0], barTimes: times, slotWidth: 10, chartWidth: 200)
        #expect(first == 0)
    }

    @Test("reconcile drift guard: re-centering after a front-advance keeps the same time fixed")
    func centeringTimeSurvivesFrontAdvance() {
        // Parked centered on t=3_000_000 (bar 50 of the old window).
        let oldTimes = minuteTimes(100)
        let centerMs = oldTimes[50]
        let oldOffset = DrawingMath.xOffsetCenteringTime(centerMs, barTimes: oldTimes, slotWidth: 10, chartWidth: 200)

        // Reconcile swaps in a fresh window: drop 5 off the front, add 5 at the end.
        let newTimes = (5..<105).map { Int64($0) * 60_000 }
        let newOffset = DrawingMath.xOffsetCenteringTime(centerMs, barTimes: newTimes, slotWidth: 10, chartWidth: 200)

        // The offset shifts by exactly the dropped-bar count × slot — so the same moment stays put.
        #expect(newOffset == oldOffset - 5 * 10)
        #expect(DrawingMath.timeMsForX(100, barTimes: newTimes, xOffset: newOffset, slotWidth: 10) == centerMs)
    }

    // MARK: - quoteReadout: live Bid / Ask / Spread overlay text

    @Test("quoteReadout: BID mode — close is the bid, ask = close + spread, spread in pips")
    func quoteReadoutNonJPY() {
        let s = ChartView.quoteReadout(close: 0.99082, spread: 0.00013, side: .bid, instrument: "EURUSD")
        #expect(s == "Bid 0.99082   Ask 0.99095   Spr 1.3p")
    }

    @Test("quoteReadout: JPY pair uses 3 decimals and the 100x pip factor")
    func quoteReadoutJPY() {
        let s = ChartView.quoteReadout(close: 150.123, spread: 0.012, side: .bid, instrument: "USDJPY")
        #expect(s == "Bid 150.123   Ask 150.135   Spr 1.2p")
    }

    @Test("quoteReadout: no live spread → '—' and ask == bid")
    func quoteReadoutNoSpread() {
        let s = ChartView.quoteReadout(close: 1.10000, spread: 0, side: .bid, instrument: "EURUSD")
        #expect(s == "Bid 1.10000   Ask 1.10000   Spr —")
    }

    @Test("quoteReadout: ASK mode — close is the ask, bid = close − spread")
    func quoteReadoutAskMode() {
        let s = ChartView.quoteReadout(close: 0.99095, spread: 0.00013, side: .ask, instrument: "EURUSD")
        #expect(s == "Bid 0.99082   Ask 0.99095   Spr 1.3p")
    }

    @Test("bidAsk: bid-mode puts close at bid, ask-mode puts close at ask")
    func bidAskHelper() {
        let b = ChartView.bidAsk(close: 1.2000, spread: 0.0002, side: .bid)
        #expect(abs(b.bid - 1.2000) < 1e-9 && abs(b.ask - 1.2002) < 1e-9)
        let a = ChartView.bidAsk(close: 1.2002, spread: 0.0002, side: .ask)
        #expect(abs(a.bid - 1.2000) < 1e-9 && abs(a.ask - 1.2002) < 1e-9)
    }

    @Test("scrollToEnd clears the one-shot guard so the view re-positions for a fresh dataset")
    func scrollToEndClearsGuard() {
        let vm = ChartViewModel(coordinator: MockMarketDataCoordinator())
        vm.bars = bars(100)
        vm.transform.hasAutoScrolledToEnd = true   // a prior snap already happened
        vm.scrollToEnd()
        #expect(vm.transform.hasAutoScrolledToEnd == false)
        vm.stop()
    }

    @Test("a width change snaps to the live edge while following, and re-centers the anchor while parked")
    func widthChangeRepositionsViewport() {
        let vm = ChartViewModel(coordinator: MockMarketDataCoordinator())
        vm.bars = bars(100)   // times 1000…100000, slot 10 at xScale 1

        // Following the edge: a new width clears the guard so the view re-snaps to the new margin.
        vm.transform.hasAutoScrolledToEnd = true
        vm.autoScroll = true
        vm.viewportAnchorTimeMs = nil
        vm.chartWidth = 600
        #expect(vm.transform.hasAutoScrolledToEnd == false)

        // Parked on an anchored time: a width change re-centers that time (no live-edge snap; guard
        // stays set so the view's one-shot snap doesn't fight it).
        vm.transform.hasAutoScrolledToEnd = true
        vm.autoScroll = false
        vm.viewportAnchorTimeMs = 50_000   // bar index 49
        vm.chartWidth = 800
        #expect(vm.transform.hasAutoScrolledToEnd == true)
        let expected = DrawingMath.xOffsetCenteringTime(
            50_000, barTimes: vm.bars.map(\.time), slotWidth: vm.transform.candleSlotWidth, chartWidth: 800)
        #expect(vm.transform.xOffset == expected)
        vm.stop()
    }

    @Test("jumpToLiveEdge clears the parked anchor, re-enables autoscroll, and re-arms the snap")
    func jumpToLiveEdgeResetsFollowState() {
        let vm = ChartViewModel(coordinator: MockMarketDataCoordinator())
        vm.bars = bars(100)
        // Parked away from the live edge.
        vm.autoScroll = false
        vm.viewportAnchorTimeMs = 50_000
        vm.transform.hasAutoScrolledToEnd = true

        vm.jumpToLiveEdge()

        #expect(vm.autoScroll == true)
        #expect(vm.viewportAnchorTimeMs == nil)
        // scrollToEnd() clears the one-shot guard so ChartView re-snaps to the live edge.
        #expect(vm.transform.hasAutoScrolledToEnd == false)
        vm.stop()
    }

    // MARK: - Stale-cache backfill detection (launch "Updating…" badge / forming-bar gate)

    /// A Date in UTC from y/m/d h:m — the trading calendar resolves weekday/hour in ET,
    /// so a UTC noon lands mid-session on a weekday and well inside the weekend on Sat.
    private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    @Test("cacheIsBehind false when the newest closed bar trails by under ~2 intervals")
    func cacheBehindFreshIsFalse() {
        let now = utc(2026, 6, 3)                       // Wednesday — market open, ref == now
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        // Newest closed 1H bar 90 min back: the current bucket is still forming, so this is
        // a healthy cache — gap (1.5h) is under the 2-interval (2h) threshold.
        let bars = [makeBar(time: nowMs - 90 * 60 * 1000)]
        #expect(ChartViewModel.cacheIsBehind(bars: bars, period: "ONE_HOUR", now: now) == false)
    }

    @Test("cacheIsBehind true when the cache trails by many intervals")
    func cacheBehindStaleIsTrue() {
        let now = utc(2026, 6, 3)                       // Wednesday — market open
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let bars = [makeBar(time: nowMs - 10 * 3600 * 1000)]  // 10h behind → many missing 1H bars
        #expect(ChartViewModel.cacheIsBehind(bars: bars, period: "ONE_HOUR", now: now) == true)
    }

    @Test("cacheIsBehind false over the weekend when the cache reaches the Friday close")
    func cacheBehindWeekendClampIsFalse() {
        let now = utc(2026, 6, 6)                       // Saturday — market closed
        // A cache that ends exactly at the last session close has nothing missing; without
        // the lastSessionClose clamp the Sat-noon "now" would wrongly read it as ~19h stale.
        let fridayCloseMs = NYTradingCalendar.lastSessionCloseMs(at: now)
        let bars = [makeBar(time: fridayCloseMs)]
        #expect(ChartViewModel.cacheIsBehind(bars: bars, period: "ONE_HOUR", now: now) == false)
    }

    @Test("cacheIsBehind false for an empty or unknown-period series")
    func cacheBehindDegenerateIsFalse() {
        let now = utc(2026, 6, 3)
        #expect(ChartViewModel.cacheIsBehind(bars: [], period: "ONE_HOUR", now: now) == false)
        let bars = [makeBar(time: 0)]
        #expect(ChartViewModel.cacheIsBehind(bars: bars, period: "NOT_A_PERIOD", now: now) == false)
    }

    @Test("handleBar suppresses a forming bar beyond the tail while backfilling")
    func handleBarSuppressesFormingBarWhileBackfilling() {
        let vm = ChartViewModel(coordinator: MockMarketDataCoordinator())
        vm.bars = [makeBar(time: 1000)]
        vm.isBackfilling = true
        // A live tick opens a bucket beyond the stale tail — appending it would jam a
        // candle against the unfilled gap, so it must be dropped until backfill finishes.
        vm.handleBar(makeBar(time: 5000, partial: true),
                     expectedInstrument: "EURUSD", expectedPeriod: "FIFTEEN_MINS")
        #expect(vm.bars.count == 1)
    }

    @Test("handleBar still updates the same-timestamp bar in place while backfilling")
    func handleBarUpdatesSameTimestampWhileBackfilling() {
        let vm = ChartViewModel(coordinator: MockMarketDataCoordinator())
        vm.bars = [makeBar(time: 1000, close: 1.1)]
        vm.isBackfilling = true
        // The gate only blocks new buckets beyond the tail; an in-place refresh of the
        // current bar is still allowed.
        vm.handleBar(makeBar(time: 1000, close: 1.5, partial: true),
                     expectedInstrument: "EURUSD", expectedPeriod: "FIFTEEN_MINS")
        #expect(vm.bars.count == 1)
        #expect(vm.bars[0].close == 1.5)
    }
}
