import Foundation

@Observable
@MainActor
final class CorrelationViewModel {
    /// Stable identity. For a currency grid it's a fresh UUID (reuse is keyed on `currency`); for a
    /// custom grid it's the saved `CustomCorrelation.id` (reuse + delete are keyed on it).
    let id: UUID
    /// Tab label — the currency for a currency grid, the user's name for a custom grid.
    let title: String
    /// Base currency for a currency grid; "" for a custom (user-picked) grid. See `baseCurrency`.
    let currency: String
    let instruments: [String]
    let chartViewModels: [ChartViewModel]
    private let coordinator: any MarketDataProviding
    var currentPeriod: String

    /// nil for a custom grid → `CorrelationView` skips the base-currency placeholder cell and the
    /// inverse-pair tint (both only make sense for a single-currency grid).
    var baseCurrency: String? { currency.isEmpty ? nil : currency }
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

    /// A currency grid: pairs derived from `CurrencyCorrelation.pairs[currency]`.
    init(currency: String, period: String, coordinator: any MarketDataProviding) {
        self.id = UUID()
        self.title = currency
        self.currency = currency
        self.currentPeriod = period
        self.coordinator = coordinator
        let pairs = (CurrencyCorrelation.pairs[currency] ?? []).sorted()
        self.instruments = pairs
        self.chartViewModels = Self.cells(for: pairs, period: period, coordinator: coordinator)
    }

    /// A custom grid: an explicit list of 2–6 user-picked pairs under a name.
    init(custom id: UUID, name: String, pairs: [String], period: String, coordinator: any MarketDataProviding) {
        self.id = id
        self.title = name
        self.currency = ""
        self.currentPeriod = period
        self.coordinator = coordinator
        self.instruments = pairs
        self.chartViewModels = Self.cells(for: pairs, period: period, coordinator: coordinator)
    }

    private static func cells(for pairs: [String], period: String,
                              coordinator: any MarketDataProviding) -> [ChartViewModel] {
        pairs.map { instrument in
            let vm = ChartViewModel(coordinator: coordinator)
            vm.currentInstrument = instrument
            vm.currentPeriod = period
            return vm
        }
    }

    func startAll() async {
        await chartViewModels.startGradually(maxConcurrent: coordinator.maxConcurrentColdLoads)
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
