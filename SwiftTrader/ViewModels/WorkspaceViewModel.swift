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
    var tabs: [Tab] = []
    var selectedTabID: UUID?
    var showBottomPanel = false
    var showRightPanel = false
    var showSettings = false

    var selectedTab: Tab? {
        tabs.first { $0.id == selectedTabID }
    }

    init() {
        trading = TradingViewModel(coordinator: TradingCoordinator(port: settings.port))
        addTab()
        trading.start()
    }

    func addTab() {
        let vm = ChartViewModel(coordinator: MarketDataCoordinator(port: settings.port, cache: candleCache))
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
        Task { await vm.start() }
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
        let tab = Tab(content: .correlation(vm))
        tabs.append(tab)
        selectedTabID = tab.id
        Task { await vm.startAll() }
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
    }

    func selectTab(_ id: UUID) {
        selectedTabID = id
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
