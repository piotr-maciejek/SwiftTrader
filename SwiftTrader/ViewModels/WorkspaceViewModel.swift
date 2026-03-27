import SwiftUI

@Observable
@MainActor
final class WorkspaceViewModel {
    struct Tab: Identifiable {
        let id = UUID()
        let viewModel: ChartViewModel
    }

    let settings = AppSettings.shared
    let trading: TradingViewModel
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
        let vm = ChartViewModel(coordinator: MarketDataCoordinator(port: settings.port))
        if let current = selectedTab?.viewModel {
            vm.currentInstrument = current.currentInstrument
            vm.currentPeriod = current.currentPeriod
        }
        let tab = Tab(viewModel: vm)
        tabs.append(tab)
        selectedTabID = tab.id
        Task { await tab.viewModel.start() }
    }

    func reconnectAll(port: Int) {
        for tab in tabs {
            tab.viewModel.reconnect(port: port)
        }
        trading.reconnect(port: port)
    }

    func closeTab(_ id: UUID) {
        guard tabs.count > 1 else { return }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].viewModel.stop()
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
