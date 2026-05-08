import SwiftUI

@Observable
@MainActor
final class WorkspaceViewModel {
    struct Tab: Identifiable {
        let id = UUID()
        let content: TabContent

        enum TabContent {
            case chart(ChartViewModel)
            case correlation(CorrelationViewModel)

            var isChart: Bool {
                if case .chart = self { return true }
                return false
            }
        }
    }

    let settings = AppSettings.shared
    let trading: TradingViewModel
    let tradeHistory: TradeHistoryViewModel
    var newsItems: [NewsItem] = []
    private let diskCache = DiskCandleCache()
    private let candleCache: CandleCache
    /// Shared by every ChartViewModel (regular tabs + correlation cells). One
    /// URLSession + connection pool instead of N + 6M, so a startup fan-out
    /// doesn't fragment HTTP traffic into separate per-tab pools.
    private var marketData: MarketDataCoordinator
    private var newsCoordinator: NewsCoordinator
    private var newsTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    var tabs: [Tab] = []
    var selectedTabID: UUID?
    var showBottomPanel = false {
        didSet { scheduleSave() }
    }
    var showRightPanel = false {
        didSet { scheduleSave() }
    }
    var showLeftPanel = true {
        didSet { scheduleSave() }
    }
    var sidebarSort: SidebarSort = .volume {
        didSet { scheduleSave() }
    }
    var showSettings = false
    /// Workspace-level instrument list, populated once on startAll(). Drives the
    /// sidebar's "+ pair" picker. Per-tab ChartViewModel still keeps its own
    /// `availableInstruments` for its picker; the two converge after first fetch.
    var availableInstruments: [String] = []

    var selectedTab: Tab? {
        tabs.first { $0.id == selectedTabID }
    }

    private var hasStarted = false

    init() {
        candleCache = CandleCache(diskCache: diskCache)
        marketData = MarketDataCoordinator(port: settings.port, cache: candleCache)
        trading = TradingViewModel(coordinator: TradingCoordinator(port: settings.port))
        tradeHistory = TradeHistoryViewModel(
            service: TradeHistoryService(
                baseURL: URL(string: "http://localhost:\(settings.port)")!))
        newsCoordinator = NewsCoordinator(port: settings.port)
        // NOTE: Do NOT start tasks here. SwiftUI re-evaluates @State initializers
        // on every body evaluation, creating (and discarding) many WorkspaceViewModels.
        // Only the first instance is kept; the rest are garbage-collected — but any
        // Tasks launched from init() continue running as orphans.
        if let saved = WorkspaceStateService.shared.load(), !saved.tabs.isEmpty {
            restoreTabs(from: saved, startTasks: false)
        } else {
            addTabWithoutStarting()
        }
    }

    /// Called once from ContentView's .task to start WebSocket/REST tasks.
    /// Only starts the currently-selected tab — other restored tabs stay idle
    /// until the user picks them. Avoids the thundering herd of N tabs all
    /// fetching history + opening WebSockets at cold-start.
    func startAll() {
        guard !hasStarted else { return }
        hasStarted = true
        Task {
            await candleCache.hydrate()
            if let tab = selectedTab {
                startTabIfNeeded(tab)
            }
        }
        Task {
            if let instruments = try? await marketData.fetchInstruments(),
               !instruments.isEmpty {
                availableInstruments = instruments
            }
        }
        trading.start()
        connectNews()
    }

    /// Starts a tab's VM(s) on demand. Idempotent — safe to call repeatedly.
    /// `ChartViewModel.start()` and child VMs in `CorrelationViewModel.startAll()`
    /// are guarded by their own `hasStarted` flags.
    private func startTabIfNeeded(_ tab: Tab) {
        switch tab.content {
        case .chart(let vm): vm.startAsync()
        case .correlation(let vm): Task { await vm.startAll() }
        }
    }

    private func connectNews() {
        newsTask?.cancel()
        newsTask = Task {
            while !Task.isCancelled {
                do {
                    for try await batch in newsCoordinator.streamNews() {
                        for item in batch {
                            if let idx = newsItems.firstIndex(where: { $0.id == item.id }) {
                                newsItems[idx] = item
                            } else {
                                newsItems.insert(item, at: 0)
                            }
                        }
                        if newsItems.count > 100 {
                            newsItems = Array(newsItems.prefix(100))
                        }
                    }
                } catch is CancellationError {
                    break
                } catch {
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    /// Creates a default tab without starting tasks (used by init to avoid orphaned tasks).
    private func addTabWithoutStarting() {
        let vm = ChartViewModel(coordinator: marketData)
        wireStateChanged(vm)
        let tab = Tab(content: .chart(vm))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func addTab() {
        let vm = ChartViewModel(coordinator: marketData)
        wireStateChanged(vm)
        if let current = selectedTab {
            switch current.content {
            case .chart(let cvm):
                vm.currentInstrument = cvm.currentInstrument
                vm.currentPeriod = cvm.currentPeriod
            case .correlation(let cvm):
                vm.currentPeriod = cvm.currentPeriod
            }
        }
        let tab = Tab(content: .chart(vm))
        tabs.append(tab)
        selectedTabID = tab.id
        vm.startAsync()
        scheduleSave()
    }

    func selectOrCreateChartTab(instrument: String) {
        if let existing = tabs.first(where: {
            if case .chart(let vm) = $0.content { return vm.currentInstrument == instrument }
            return false
        }) {
            selectTab(existing.id)
            return
        }

        let period: String
        if let current = selectedTab {
            switch current.content {
            case .chart(let vm): period = vm.currentPeriod
            case .correlation(let vm): period = vm.currentPeriod
            }
        } else {
            period = "ONE_MIN"
        }

        let vm = ChartViewModel(coordinator: marketData)
        wireStateChanged(vm)
        vm.currentInstrument = instrument
        vm.currentPeriod = period
        let tab = Tab(content: .chart(vm))
        tabs.append(tab)
        selectedTabID = tab.id
        vm.startAsync()
        scheduleSave()
    }

    func addCorrelationTab(currency: String) {
        // If a correlation tab for this currency already exists, switch to it
        if let existing = tabs.first(where: {
            if case .correlation(let vm) = $0.content { return vm.currency == currency }
            return false
        }) {
            selectTab(existing.id)
            return
        }

        let period: String
        if let current = selectedTab {
            switch current.content {
            case .chart(let vm): period = vm.currentPeriod
            case .correlation(let vm): period = vm.currentPeriod
            }
        } else {
            period = "ONE_MIN"
        }

        let vm = CorrelationViewModel(
            currency: currency,
            period: period,
            coordinator: marketData
        )
        wireStateChanged(vm)
        let tab = Tab(content: .correlation(vm))
        tabs.append(tab)
        selectedTabID = tab.id
        Task { await vm.startAll() }
        scheduleSave()
    }

    /// Reload every chart tab so the rebucketing toggle change takes effect.
    /// Correlation tabs don't consume 4H/DAILY today, so they don't need a reload.
    func applyRebucketingChange() {
        for tab in tabs {
            if case .chart(let vm) = tab.content {
                vm.applyRebucketingChange()
            }
        }
    }

    func reconnectAll(port: Int) {
        // Build one fresh MarketDataCoordinator for the new port and broadcast it.
        // All tabs swap to it atomically — no stale per-tab coordinators clinging
        // to the old endpoint, and they all share one URLSession again.
        marketData = MarketDataCoordinator(port: port, cache: candleCache)
        for tab in tabs {
            switch tab.content {
            case .chart(let vm): vm.reconnect(coordinator: marketData)
            case .correlation(let vm): vm.reconnect(coordinator: marketData)
            }
        }
        trading.reconnect(port: port)
        tradeHistory.reconnect(port: port)
        newsCoordinator = NewsCoordinator(port: port)
        newsItems = []
        connectNews()
    }

    func closeTab(_ id: UUID) {
        guard tabs.count > 1 else { return }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        switch tabs[index].content {
        case .chart(let vm): vm.stop()
        case .correlation(let vm): vm.stopAll()
        }
        tabs.remove(at: index)
        if selectedTabID == id {
            let newIndex = min(index, tabs.count - 1)
            selectedTabID = tabs[newIndex].id
        }
        scheduleSave()
    }

    func selectTab(_ id: UUID) {
        selectedTabID = id
        scheduleSave()
        if let tab = tabs.first(where: { $0.id == id }) {
            startTabIfNeeded(tab)
        }
    }

    /// Chart tabs ordered by the active sidebar sort mode.
    var sortedChartTabs: [Tab] {
        sortedTabs(tabs.filter { $0.content.isChart })
    }

    /// Correlation tabs ordered by the active sidebar sort mode.
    var sortedCorrelationTabs: [Tab] {
        sortedTabs(tabs.filter { !$0.content.isChart })
    }

    private func sortedTabs(_ subset: [Tab]) -> [Tab] {
        switch sidebarSort {
        case .volume:
            return subset.sorted { a, b in
                let ar = volumeRank(for: a), br = volumeRank(for: b)
                if ar != br { return ar > br }
                return volumeKey(for: a) < volumeKey(for: b)
            }
        case .alphabetical:
            return subset.sorted { volumeKey(for: $0) < volumeKey(for: $1) }
        }
    }

    private func volumeRank(for tab: Tab) -> Double {
        switch tab.content {
        case .chart(let vm): return FXVolumeRank.rank(pair: vm.currentInstrument)
        case .correlation(let vm): return FXVolumeRank.rank(currency: vm.currency)
        }
    }

    private func volumeKey(for tab: Tab) -> String {
        switch tab.content {
        case .chart(let vm): return vm.currentInstrument
        case .correlation(let vm): return vm.currency
        }
    }

    /// Cycles the selected tab's timeframe one step in `ChartViewModel.availablePeriods`.
    /// Positive offset = longer timeframe (15m → 30m). No wrap at the ends.
    func cycleSelectedTabPeriod(offset: Int) {
        guard offset != 0, let tab = selectedTab else { return }
        let periods = ChartViewModel.availablePeriods.map(\.value)
        let current: String
        switch tab.content {
        case .chart(let vm): current = vm.currentPeriod
        case .correlation(let vm): current = vm.currentPeriod
        }
        guard let from = periods.firstIndex(of: current) else { return }
        let to = max(0, min(periods.count - 1, from + offset))
        guard to != from else { return }
        let target = periods[to]
        switch tab.content {
        case .chart(let vm): vm.switchPeriod(target)
        case .correlation(let vm): vm.switchPeriod(target)
        }
    }

    // MARK: - State persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    /// Save immediately without debounce. Also called on app termination.
    func saveNow() {
        WorkspaceStateService.shared.save(snapshot())
    }

    private func snapshot() -> WorkspaceState {
        let tabStates = tabs.map { tab -> TabState in
            switch tab.content {
            case .chart(let vm):
                return TabState(id: tab.id, content: .chart(ChartTabState(
                    instrument: vm.currentInstrument,
                    period: vm.currentPeriod,
                    showSessions: vm.showSessions,
                    showVolume: vm.showVolume,
                    showEMA: vm.showEMA,
                    emaConfigs: vm.emaConfigs.map { EMALineState(from: $0) },
                    showATR: vm.showATR,
                    atrPeriod: vm.atrPeriod
                )))
            case .correlation(let vm):
                return TabState(id: tab.id, content: .correlation(CorrelationTabState(
                    currency: vm.currency,
                    period: vm.currentPeriod,
                    showSessions: vm.showSessions,
                    showVolume: vm.showVolume,
                    showEMA: vm.showEMA,
                    emaConfigs: vm.emaConfigs.map { EMALineState(from: $0) },
                    showATR: vm.showATR,
                    atrPeriod: vm.atrPeriod
                )))
            }
        }
        let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabID })
        return WorkspaceState(
            tabs: tabStates,
            selectedTabIndex: selectedIndex,
            showBottomPanel: showBottomPanel,
            showRightPanel: showRightPanel,
            showLeftPanel: showLeftPanel,
            sidebarSort: sidebarSort
        )
    }

    private func restoreTabs(from state: WorkspaceState, startTasks: Bool = true) {
        showBottomPanel = state.showBottomPanel
        showRightPanel = state.showRightPanel
        showLeftPanel = state.showLeftPanel
        sidebarSort = state.sidebarSort

        for tabState in state.tabs {
            switch tabState.content {
            case .chart(let chartState):
                let vm = ChartViewModel(coordinator: marketData)
                vm.currentInstrument = chartState.instrument
                vm.currentPeriod = chartState.period
                vm.showSessions = chartState.showSessions
                vm.showVolume = chartState.showVolume
                vm.showEMA = chartState.showEMA
                vm.emaConfigs = chartState.emaConfigs.map { $0.toEMALine() }
                vm.showATR = chartState.showATR
                vm.atrPeriod = chartState.atrPeriod
                wireStateChanged(vm)
                let tab = Tab(content: .chart(vm))
                tabs.append(tab)
                if startTasks { vm.startAsync() }

            case .correlation(let corrState):
                let vm = CorrelationViewModel(
                    currency: corrState.currency,
                    period: corrState.period,
                    coordinator: marketData
                )
                vm.showSessions = corrState.showSessions
                vm.showVolume = corrState.showVolume
                vm.showEMA = corrState.showEMA
                vm.emaConfigs = corrState.emaConfigs.map { $0.toEMALine() }
                vm.showATR = corrState.showATR
                vm.atrPeriod = corrState.atrPeriod
                wireStateChanged(vm)
                let tab = Tab(content: .correlation(vm))
                tabs.append(tab)
                if startTasks { Task { await vm.startAll() } }
            }
        }

        if let index = state.selectedTabIndex, index < tabs.count {
            selectedTabID = tabs[index].id
        } else {
            selectedTabID = tabs.first?.id
        }
    }

    private func wireStateChanged(_ vm: ChartViewModel) {
        vm.onStateChanged = { [weak self] in self?.scheduleSave() }
    }

    private func wireStateChanged(_ vm: CorrelationViewModel) {
        vm.onStateChanged = { [weak self] in self?.scheduleSave() }
    }
}

// MARK: - FocusedValue support for menu commands

struct WorkspaceFocusedKey: FocusedValueKey {
    typealias Value = WorkspaceViewModel
}

extension FocusedValues {
    var workspace: WorkspaceViewModel? {
        get { self[WorkspaceFocusedKey.self] }
        set { self[WorkspaceFocusedKey.self] = newValue }
    }
}
