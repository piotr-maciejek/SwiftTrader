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
        }
    }

    let settings = AppSettings.shared
    let trading: TradingViewModel
    private let candleCache = CandleCache()
    private var saveTask: Task<Void, Never>?
    var tabs: [Tab] = []
    var selectedTabID: UUID?
    var showBottomPanel = false {
        didSet { scheduleSave() }
    }
    var showRightPanel = false {
        didSet { scheduleSave() }
    }
    var showSettings = false

    var selectedTab: Tab? {
        tabs.first { $0.id == selectedTabID }
    }

    private var hasStarted = false

    init() {
        trading = TradingViewModel(coordinator: TradingCoordinator(port: settings.port))
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
    func startAll() {
        guard !hasStarted else { return }
        hasStarted = true
        for tab in tabs {
            switch tab.content {
            case .chart(let vm): vm.startAsync()
            case .correlation(let vm): Task { await vm.startAll() }
            }
        }
        trading.start()
    }

    /// Creates a default tab without starting tasks (used by init to avoid orphaned tasks).
    private func addTabWithoutStarting() {
        let vm = ChartViewModel(coordinator: MarketDataCoordinator(port: settings.port, cache: candleCache))
        wireStateChanged(vm)
        let tab = Tab(content: .chart(vm))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func addTab() {
        let vm = ChartViewModel(coordinator: MarketDataCoordinator(port: settings.port, cache: candleCache))
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

    func addCorrelationTab(currency: String) {
        // If a correlation tab for this currency already exists, switch to it
        if let existing = tabs.first(where: {
            if case .correlation(let vm) = $0.content { return vm.currency == currency }
            return false
        }) {
            selectedTabID = existing.id
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
            port: settings.port,
            cache: candleCache
        )
        wireStateChanged(vm)
        let tab = Tab(content: .correlation(vm))
        tabs.append(tab)
        selectedTabID = tab.id
        Task { await vm.startAll() }
        scheduleSave()
    }

    func reconnectAll(port: Int) {
        for tab in tabs {
            switch tab.content {
            case .chart(let vm): vm.reconnect(port: port)
            case .correlation(let vm): vm.reconnect(port: port)
            }
        }
        trading.reconnect(port: port)
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
    }

    func moveTab(id: UUID, beforeID: UUID) {
        guard id != beforeID,
              let _ = tabs.firstIndex(where: { $0.id == id }),
              let _ = tabs.firstIndex(where: { $0.id == beforeID })
        else { return }
        let tab = tabs.remove(at: tabs.firstIndex(where: { $0.id == id })!)
        let insertIndex = tabs.firstIndex(where: { $0.id == beforeID }) ?? tabs.endIndex
        tabs.insert(tab, at: insertIndex)
        scheduleSave()
    }

    func moveTabToEnd(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              index != tabs.count - 1
        else { return }
        let tab = tabs.remove(at: index)
        tabs.append(tab)
        scheduleSave()
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
                    emaConfigs: vm.emaConfigs.map { EMALineState(from: $0) }
                )))
            case .correlation(let vm):
                return TabState(id: tab.id, content: .correlation(CorrelationTabState(
                    currency: vm.currency,
                    period: vm.currentPeriod,
                    showSessions: vm.showSessions,
                    showVolume: vm.showVolume,
                    showEMA: vm.showEMA,
                    emaConfigs: vm.emaConfigs.map { EMALineState(from: $0) }
                )))
            }
        }
        let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabID })
        return WorkspaceState(
            tabs: tabStates,
            selectedTabIndex: selectedIndex,
            showBottomPanel: showBottomPanel,
            showRightPanel: showRightPanel
        )
    }

    private func restoreTabs(from state: WorkspaceState, startTasks: Bool = true) {
        showBottomPanel = state.showBottomPanel
        showRightPanel = state.showRightPanel

        for tabState in state.tabs {
            switch tabState.content {
            case .chart(let chartState):
                let vm = ChartViewModel(
                    coordinator: MarketDataCoordinator(port: settings.port, cache: candleCache)
                )
                vm.currentInstrument = chartState.instrument
                vm.currentPeriod = chartState.period
                vm.showSessions = chartState.showSessions
                vm.showVolume = chartState.showVolume
                vm.showEMA = chartState.showEMA
                vm.emaConfigs = chartState.emaConfigs.map { $0.toEMALine() }
                wireStateChanged(vm)
                let tab = Tab(content: .chart(vm))
                tabs.append(tab)
                if startTasks { vm.startAsync() }

            case .correlation(let corrState):
                let vm = CorrelationViewModel(
                    currency: corrState.currency,
                    period: corrState.period,
                    port: settings.port,
                    cache: candleCache
                )
                vm.showSessions = corrState.showSessions
                vm.showVolume = corrState.showVolume
                vm.showEMA = corrState.showEMA
                vm.emaConfigs = corrState.emaConfigs.map { $0.toEMALine() }
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
