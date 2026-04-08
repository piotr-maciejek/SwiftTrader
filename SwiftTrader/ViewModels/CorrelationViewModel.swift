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

    init(currency: String, period: String, port: Int, cache: CandleCache) {
        self.currency = currency
        self.currentPeriod = period
        let pairs = CurrencyCorrelation.pairs[currency] ?? []
        self.instruments = pairs
        self.chartViewModels = pairs.map { instrument in
            let vm = ChartViewModel(
                coordinator: MarketDataCoordinator(port: port, cache: cache)
            )
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

    func reconnect(port: Int) {
        for vm in chartViewModels {
            vm.reconnect(port: port)
        }
    }
}
