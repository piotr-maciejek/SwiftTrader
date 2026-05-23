import Foundation

@Observable
@MainActor
final class CorrelationViewModel {
    let currency: String
    let instruments: [String]
    let chartViewModels: [ChartViewModel]
    var currentPeriod: String
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

    var onStateChanged: (() -> Void)?

    /// Time (UTC ms) under the user's cursor in any cell. All other cells
    /// render a synced ghost vertical crosshair at the bar covering this time.
    /// Cleared when the cursor leaves all cells. Ephemeral — not persisted.
    var sharedCursorTime: Int64?

    init(currency: String, period: String, coordinator: any MarketDataProviding) {
        self.currency = currency
        self.currentPeriod = period
        let pairs = (CurrencyCorrelation.pairs[currency] ?? []).sorted()
        self.instruments = pairs
        self.chartViewModels = pairs.map { instrument in
            let vm = ChartViewModel(coordinator: coordinator)
            vm.currentInstrument = instrument
            vm.currentPeriod = period
            return vm
        }
    }

    func startAll() async {
        await withTaskGroup(of: Void.self) { group in
            for vm in chartViewModels {
                group.addTask { await vm.start() }
            }
        }
    }

    func switchPeriod(_ period: String) {
        guard period != currentPeriod else { return }
        currentPeriod = period
        for (i, vm) in chartViewModels.enumerated() {
            vm.currentPeriod = period
            // Stagger reloads to avoid overwhelming the server with concurrent requests
            Task {
                if i > 0 {
                    try? await Task.sleep(for: .milliseconds(100 * i))
                }
                vm.reloadCurrentChart()
            }
        }
    }

    func stopAll() {
        for vm in chartViewModels {
            vm.stop()
        }
    }

    func reconnect(coordinator: any MarketDataProviding) {
        for vm in chartViewModels {
            vm.reconnect(coordinator: coordinator)
        }
    }
}
