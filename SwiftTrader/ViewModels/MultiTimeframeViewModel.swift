import Foundation

@Observable
@MainActor
final class MultiTimeframeViewModel {
    let instrument: String
    var zoom: TFZoom {
        didSet {
            guard zoom != oldValue else { return }
            applyZoom()
            onStateChanged?()
        }
    }
    let chartViewModels: [ChartViewModel]
    private let coordinator: any MarketDataProviding

    var showSessions = true {
        didSet {
            for vm in chartViewModels { vm.showSessions = showSessions }
            onStateChanged?()
        }
    }
    var showVolume = true {
        didSet {
            for vm in chartViewModels { vm.showVolume = showVolume }
            onStateChanged?()
        }
    }
    var showVolumeMA = true {
        didSet {
            for vm in chartViewModels { vm.showVolumeMA = showVolumeMA }
            onStateChanged?()
        }
    }
    var volumeMA: EMALine = EMALine(period: 20, color: .cyan) {
        didSet {
            for vm in chartViewModels { vm.volumeMA = volumeMA }
            onStateChanged?()
        }
    }
    var showEMA = true {
        didSet {
            for vm in chartViewModels { vm.showEMA = showEMA }
            onStateChanged?()
        }
    }
    var emaConfigs: [EMALine] = EMALine.defaults {
        didSet {
            for vm in chartViewModels { vm.emaConfigs = emaConfigs }
            onStateChanged?()
        }
    }
    var showATR = true {
        didSet {
            for vm in chartViewModels { vm.showATR = showATR }
            onStateChanged?()
        }
    }
    var atrPeriod = 14 {
        didSet {
            for vm in chartViewModels { vm.atrPeriod = atrPeriod }
            onStateChanged?()
        }
    }
    /// Candle side for the whole grid (applied to every cell via `switchSide`).
    var currentSide: ChartSide = .bid
    var showBidAsk = false {
        didSet {
            for vm in chartViewModels { vm.showBidAsk = showBidAsk }
            onStateChanged?()
        }
    }

    var onStateChanged: (() -> Void)?

    /// Time (UTC ms) under the user's cursor in any of the 4 cells. All other
    /// cells render a synced ghost crosshair at the bar covering this time.
    /// Cleared when the cursor leaves all cells.
    var sharedCursorTime: Int64?

    init(instrument: String, zoom: TFZoom = .standard, coordinator: any MarketDataProviding) {
        self.instrument = instrument
        self.zoom = zoom
        self.coordinator = coordinator
        self.chartViewModels = zoom.periods.map { period in
            let vm = ChartViewModel(coordinator: coordinator)
            vm.currentInstrument = instrument
            vm.currentPeriod = period
            return vm
        }
    }

    /// Period at the given grid index (0=top-left, 1=top-right, 2=bottom-left, 3=bottom-right).
    func period(at index: Int) -> String {
        zoom.periods[index]
    }

    func startAll() async {
        await chartViewModels.startGradually(maxConcurrent: coordinator.maxConcurrentColdLoads)
    }

    func stopAll() {
        for vm in chartViewModels { vm.stop() }
    }

    func reconnect(coordinator: any MarketDataProviding) {
        for vm in chartViewModels {
            vm.reconnect(coordinator: coordinator)
        }
    }

    func applyRebucketingChange() {
        for vm in chartViewModels {
            vm.applyRebucketingChange()
        }
    }

    /// Switch the candle side for every cell (staggered reloads).
    func switchSide(_ side: ChartSide) {
        guard side != currentSide else { return }
        currentSide = side
        onStateChanged?()
        for (i, vm) in chartViewModels.enumerated() {
            vm.currentSide = side
            Task {
                if i > 0 { try? await Task.sleep(for: .milliseconds(100 * i)) }
                vm.reloadCurrentChart()
            }
        }
    }

    private func applyZoom() {
        let periods = zoom.periods
        for (i, vm) in chartViewModels.enumerated() where i < periods.count {
            let target = periods[i]
            guard vm.currentPeriod != target else { continue }
            vm.currentPeriod = target
            // Stagger reloads to avoid flooding the server with simultaneous
            // history requests when zooming.
            Task {
                if i > 0 {
                    try? await Task.sleep(for: .milliseconds(100 * i))
                }
                vm.reloadCurrentChart()
            }
        }
    }
}
