import DukascopyClient
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
            case multiTimeframe(MultiTimeframeViewModel)

            var isChart: Bool {
                if case .chart = self { return true }
                return false
            }

            var isCorrelation: Bool {
                if case .correlation = self { return true }
                return false
            }

            var isMultiTimeframe: Bool {
                if case .multiTimeframe = self { return true }
                return false
            }
        }
    }

    let settings = AppSettings.shared
    let trading: TradingViewModel
    let tradeHistory: TradeHistoryViewModel
    /// R-multiple / slippage metadata, keyed by position id, synced via iCloud. The store persists;
    /// this observable mirror drives the UI (open-positions + History). Updated from the store's
    /// `onChange` (local binds + external iCloud syncs).
    let metadataStore = PositionMetadataStore()
    var positionMetadata: [String: PositionMetadata] = [:]
    /// Saved custom-correlation definitions, synced via iCloud. The store persists; this observable
    /// mirror drives the sidebar's "Custom Correlations" section. Updated from the store's `onChange`
    /// (local create/delete + external iCloud syncs from another Mac).
    let customCorrelationStore = CustomCorrelationStore()
    var customCorrelations: [CustomCorrelation] = []
    var newsItems: [NewsItem] = []
    /// Non-nil while the news/calendar feed is failing (e.g. a subscribe error). Drives a
    /// "news unavailable" badge in the right panel so a failed feed reads differently from
    /// a genuinely empty day. Cleared once events flow again.
    var newsError: String?
    private let diskCache = DiskCandleCache()
    private let candleCache: CandleCache
    /// Shared by every ChartViewModel (regular tabs + correlation cells). One
    /// URLSession + connection pool instead of N + 6M, so a startup fan-out
    /// doesn't fragment HTTP traffic into separate per-tab pools.
    private var marketData: any MarketDataProviding
    private var newsCoordinator: any NewsProviding
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
        marketData = Self.makeMarketDataCoordinator(
            provider: settings.dataProvider, port: settings.port, cache: candleCache
        )
        // Trading: server mode routes through jforex-server; standalone trades natively
        // via the DukascopySession (attached once it connects — see attachNativeSession).
        switch settings.dataProvider {
        case .server:
            trading = TradingViewModel(coordinator: TradingCoordinator(port: settings.port))
        case .native:
            trading = TradingViewModel(coordinator: NativeTradingCoordinator(session: nil))
        }
        // Trade history follows the same split as `trading`: server mode hits jforex-server's
        // REST; standalone reads closed positions over the DukascopySession (attached on
        // connect via attachNativeSession). The native service starts session-less and
        // returns [] until then.
        switch settings.dataProvider {
        case .server:
            tradeHistory = TradeHistoryViewModel(
                service: TradeHistoryService(
                    baseURL: URL(string: "http://localhost:\(settings.port)")!))
        case .native:
            tradeHistory = TradeHistoryViewModel(service: NativeTradeHistoryService(session: nil))
        }
        newsCoordinator = NewsCoordinator(port: settings.port)
        // R-multiple / slippage metadata: the store persists + syncs; mirror its changes into the
        // observable `positionMetadata`, and let `trading` capture into it. `attachNativeSession`
        // re-points both at the confirmed account on connect / account switch. (Set after all stored
        // properties are initialized, since the `[weak self]` capture needs a fully-initialized self.)
        metadataStore.onChange = { [weak self] dict in self?.positionMetadata = dict }
        trading.metadataStore = metadataStore
        trading.accountID = AccountStore.shared.selectedAccountID
        positionMetadata = metadataStore.reload(accountID: AccountStore.shared.selectedAccountID)
        // Heal limit/stop fills that opened AND closed while offline: the live position snapshot
        // never delivered them, but the closed-trade record carries the real fill, so complete any
        // provisional pending-order metadata by id when history loads.
        tradeHistory.onTradesLoaded = { [weak self] trades in self?.completeProvisionalMetadata(from: trades) }
        // Saved custom correlations: load now + mirror future changes (local + cross-machine) so the
        // sidebar stays in sync.
        customCorrelationStore.onChange = { [weak self] list in self?.customCorrelations = list }
        customCorrelations = customCorrelationStore.all()
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
        // Standalone mode is server-independent — don't open the jforex-server trading/news
        // WebSockets (they'd just spam connection-refused while the server is down). Trading
        // and news stay server-routed and only run in server mode.
        if settings.dataProvider == .server {
            trading.start()
            connectNews()
        }
    }

    /// Dump the focused tab's chart state to the log (Cmd+Shift+G) so a suspected gap can be
    /// diagnosed as a data-hole vs a render/layout artifact. Covers the main chart, every MTF cell,
    /// or every correlation cell — whichever the selected tab shows. See ChartViewModel.captureGapDiagnostic.
    func captureGapDiagnostics() {
        guard let tab = selectedTab else { return }
        switch tab.content {
        case .chart(let vm): vm.captureGapDiagnostic()
        case .multiTimeframe(let vm): vm.chartViewModels.forEach { $0.captureGapDiagnostic() }
        case .correlation(let vm): vm.chartViewModels.forEach { $0.captureGapDiagnostic() }
        }
    }

    /// Starts a tab's VM(s) on demand. Idempotent — safe to call repeatedly.
    /// `ChartViewModel.start()` and child VMs in `CorrelationViewModel.startAll()`
    /// / `MultiTimeframeViewModel.startAll()` are guarded by their own
    /// `hasStarted` flags.
    private func startTabIfNeeded(_ tab: Tab) {
        switch tab.content {
        case .chart(let vm): vm.startAsync()
        case .correlation(let vm): Task { await vm.startAll() }
        case .multiTimeframe(let vm): Task { await vm.startAll() }
        }
    }

    private func connectNews() {
        newsTask?.cancel()
        newsTask = Task {
            while !Task.isCancelled {
                do {
                    for try await batch in newsCoordinator.streamNews() {
                        newsError = nil
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
                    newsError = String(describing: error)
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
            case .multiTimeframe(let mvm):
                vm.currentInstrument = mvm.instrument
            }
        }
        let tab = Tab(content: .chart(vm))
        tabs.append(tab)
        selectedTabID = tab.id
        vm.startAsync()
        scheduleSave()
    }

    func selectOrCreateChartTab(instrument: String, period: String? = nil) {
        if let existing = tabs.first(where: {
            if case .chart(let vm) = $0.content { return vm.currentInstrument == instrument }
            return false
        }) {
            if let period, case .chart(let vm) = existing.content, vm.currentPeriod != period {
                vm.switchPeriod(period)
            }
            selectTab(existing.id)
            return
        }

        let resolvedPeriod: String
        if let period {
            resolvedPeriod = period
        } else if let current = selectedTab {
            switch current.content {
            case .chart(let vm): resolvedPeriod = vm.currentPeriod
            case .correlation(let vm): resolvedPeriod = vm.currentPeriod
            case .multiTimeframe: resolvedPeriod = "FIFTEEN_MINS"
            }
        } else {
            resolvedPeriod = "ONE_MIN"
        }

        let vm = ChartViewModel(coordinator: marketData)
        wireStateChanged(vm)
        vm.currentInstrument = instrument
        vm.currentPeriod = resolvedPeriod
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
            case .multiTimeframe: period = "FIFTEEN_MINS"
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

    /// Save a new custom correlation (synced) and open it as a tab. No-op if invalid (the create
    /// sheet already disables Create unless valid; this is a belt-and-braces guard).
    func createCustomCorrelation(name: String, pairs: [String]) {
        let definition = CustomCorrelation(name: name.trimmingCharacters(in: .whitespacesAndNewlines), pairs: pairs)
        guard definition.isValid else { return }
        customCorrelationStore.add(definition)   // persists + syncs; onChange refreshes customCorrelations
        addCustomCorrelationTab(definition)
    }

    /// Open (or switch to) the tab for a saved custom correlation.
    func addCustomCorrelationTab(_ definition: CustomCorrelation) {
        if let existing = tabs.first(where: {
            if case .correlation(let vm) = $0.content { return vm.id == definition.id }
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
            case .multiTimeframe: period = "FIFTEEN_MINS"
            }
        } else {
            period = "ONE_MIN"
        }

        let vm = CorrelationViewModel(
            custom: definition.id, name: definition.name, pairs: definition.pairs,
            period: period, coordinator: marketData
        )
        wireStateChanged(vm)
        let tab = Tab(content: .correlation(vm))
        tabs.append(tab)
        selectedTabID = tab.id
        Task { await vm.startAll() }
        scheduleSave()
    }

    /// Delete a saved custom correlation (synced) and close its open tab, if any.
    func deleteCustomCorrelation(id: UUID) {
        customCorrelationStore.delete(id: id)   // persists + syncs; onChange refreshes customCorrelations
        if let existing = tabs.first(where: {
            if case .correlation(let vm) = $0.content { return vm.id == id }
            return false
        }) {
            closeTab(existing.id)
        }
    }

    func selectOrCreateMultiTimeframeTab(instrument: String) {
        if let existing = tabs.first(where: {
            if case .multiTimeframe(let vm) = $0.content { return vm.instrument == instrument }
            return false
        }) {
            selectTab(existing.id)
            return
        }

        let vm = MultiTimeframeViewModel(instrument: instrument, coordinator: marketData)
        wireStateChanged(vm)
        let tab = Tab(content: .multiTimeframe(vm))
        tabs.append(tab)
        selectedTabID = tab.id
        Task { await vm.startAll() }
        scheduleSave()
    }

    /// Reload every chart tab so the rebucketing toggle change takes effect.
    /// Correlation tabs don't consume 4H/DAILY today, so they don't need a reload.
    /// Multi-TF tabs consume DAILY/4H so they do need a reload.
    func applyRebucketingChange() {
        for tab in tabs {
            switch tab.content {
            case .chart(let vm): vm.applyRebucketingChange()
            case .multiTimeframe(let vm): vm.applyRebucketingChange()
            case .correlation: break
            }
        }
    }

    /// Builds the market-data coordinator for the active provider. Native mode
    /// ignores `port` (it talks to Dukascopy directly); the shared cache is reused
    /// either way so tabs keep one cache + connection pool.
    private static func makeMarketDataCoordinator(
        provider: DataProviderMode, port: Int, cache: CandleCache
    ) -> any MarketDataProviding {
        switch provider {
        case .server:
            return MarketDataCoordinator(port: port, cache: cache)
        case .native:
            return NativeMarketDataCoordinator(cache: cache)
        }
    }

    /// Swap in a freshly-connected native session: rebuild the native coordinator and
    /// broadcast it to every tab (same atomic-swap pattern as `reconnectAll`). Called on
    /// first native connect and on live account switches.
    func attachNativeSession(_ session: DukascopySession) {
        guard settings.dataProvider == .native else { return }
        marketData = NativeMarketDataCoordinator(session: session, cache: candleCache)
        for tab in tabs {
            switch tab.content {
            case .chart(let vm): vm.reconnect(coordinator: marketData)
            case .correlation(let vm): vm.reconnect(coordinator: marketData)
            case .multiTimeframe(let vm): vm.reconnect(coordinator: marketData)
            }
        }
        // Route trading natively through this session: positions / account / spreads now
        // stream from the session, and orders place directly (no jforex-server).
        trading.reconnect(coordinator: NativeTradingCoordinator(session: session))
        // Re-point R-multiple/slippage metadata at the now-confirmed account and reload its dict
        // (cross-machine: shows trades opened on another Mac once iCloud has synced them).
        let acct = AccountStore.shared.selectedAccountID
        trading.accountID = acct
        positionMetadata = metadataStore.reload(accountID: acct)
        // Closed-trade history (History tab) now reads from this session too.
        tradeHistory.setService(NativeTradeHistoryService(session: session))
        // News/calendar also comes from this session in native mode (Dukascopy's own feed),
        // so the right panel works without jforex-server. Re-subscribes on account switch.
        newsCoordinator = NativeNewsCoordinator(session: session)
        newsItems = []
        connectNews()
    }

    /// Complete provisional pending-order metadata from closed-trade history. A limit/stop that
    /// filled and closed entirely while the app was shut never reaches the live position binder, but
    /// its closed-trade record carries the real fill — so finish the record (by id) here. Idempotent:
    /// only touches still-provisional (`fillPrice == 0`) records.
    private func completeProvisionalMetadata(from trades: [TradeRecord]) {
        let acct = trading.accountID
        for t in trades where t.openPrice > 0 {
            guard let rec = metadataStore.record(for: t.positionId, accountID: acct), rec.isProvisional
            else { continue }
            metadataStore.upsert(rec.completed(fillPrice: t.openPrice, openTimeMs: t.openTime), accountID: acct)
        }
    }

    func reconnectAll(port: Int) {
        // Build one fresh coordinator for the new port and broadcast it.
        // All tabs swap to it atomically — no stale per-tab coordinators clinging
        // to the old endpoint, and they all share one URLSession again.
        marketData = Self.makeMarketDataCoordinator(
            provider: settings.dataProvider, port: port, cache: candleCache
        )
        for tab in tabs {
            switch tab.content {
            case .chart(let vm): vm.reconnect(coordinator: marketData)
            case .correlation(let vm): vm.reconnect(coordinator: marketData)
            case .multiTimeframe(let vm): vm.reconnect(coordinator: marketData)
            }
        }
        // Server-routed WebSockets only run in server mode (see startAll).
        if settings.dataProvider == .server {
            trading.reconnect(port: port)
            tradeHistory.reconnect(port: port)
            newsCoordinator = NewsCoordinator(port: port)
            newsItems = []
            connectNews()
        }
    }

    func closeTab(_ id: UUID) {
        guard tabs.count > 1 else { return }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        switch tabs[index].content {
        case .chart(let vm): vm.stop()
        case .correlation(let vm): vm.stopAll()
        case .multiTimeframe(let vm): vm.stopAll()
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

    /// Chart tabs ordered alphabetically by instrument.
    var sortedChartTabs: [Tab] {
        tabs.filter { $0.content.isChart }.sorted { sortKey(for: $0) < sortKey(for: $1) }
    }

    /// Correlation tabs ordered alphabetically by currency.
    var sortedCorrelationTabs: [Tab] {
        tabs.filter { $0.content.isCorrelation }.sorted { sortKey(for: $0) < sortKey(for: $1) }
    }

    /// Multi-timeframe tabs ordered alphabetically by instrument.
    var sortedMultiTimeframeTabs: [Tab] {
        tabs.filter { $0.content.isMultiTimeframe }.sorted { sortKey(for: $0) < sortKey(for: $1) }
    }

    private func sortKey(for tab: Tab) -> String {
        switch tab.content {
        case .chart(let vm): return vm.currentInstrument
        case .correlation(let vm): return vm.currency
        case .multiTimeframe(let vm): return vm.instrument
        }
    }

    /// Cycles the selected tab's timeframe one step in `ChartViewModel.availablePeriods`.
    /// Positive offset = longer timeframe (15m → 1h). No wrap at the ends.
    /// For multi-timeframe tabs, cycles the zoom preset (standard ↔ intraday).
    func cycleSelectedTabPeriod(offset: Int) {
        guard offset != 0, let tab = selectedTab else { return }
        switch tab.content {
        case .chart(let vm):
            cyclePeriod(current: vm.currentPeriod, offset: offset) { vm.switchPeriod($0) }
        case .correlation(let vm):
            cyclePeriod(current: vm.currentPeriod, offset: offset) { vm.switchPeriod($0) }
        case .multiTimeframe(let vm):
            // standard = longer TFs (D/4H/1H/15m); intraday = shorter (4H/1H/15m/5m).
            // offset > 0 → longer (standard), offset < 0 → shorter (intraday).
            vm.zoom = offset > 0 ? .standard : .intraday
        }
    }

    private func cyclePeriod(current: String, offset: Int, apply: (String) -> Void) {
        let periods = ChartViewModel.availablePeriods.map(\.value)
        guard let from = periods.firstIndex(of: current) else { return }
        let to = max(0, min(periods.count - 1, from + offset))
        guard to != from else { return }
        apply(periods[to])
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
                    atrPeriod: vm.atrPeriod,
                    drawings: vm.drawings
                )))
            case .correlation(let vm):
                let isCustom = vm.baseCurrency == nil
                return TabState(id: tab.id, content: .correlation(CorrelationTabState(
                    currency: vm.currency,
                    period: vm.currentPeriod,
                    showSessions: vm.showSessions,
                    showVolume: vm.showVolume,
                    showEMA: vm.showEMA,
                    emaConfigs: vm.emaConfigs.map { EMALineState(from: $0) },
                    showATR: vm.showATR,
                    atrPeriod: vm.atrPeriod,
                    drawings: vm.chartViewModels.map(\.drawings),
                    customID: isCustom ? vm.id : nil,
                    name: isCustom ? vm.title : nil,
                    pairs: isCustom ? vm.instruments : nil
                )))
            case .multiTimeframe(let vm):
                return TabState(id: tab.id, content: .multiTimeframe(MultiTimeframeTabState(
                    instrument: vm.instrument,
                    zoom: vm.zoom,
                    showSessions: vm.showSessions,
                    showVolume: vm.showVolume,
                    showEMA: vm.showEMA,
                    emaConfigs: vm.emaConfigs.map { EMALineState(from: $0) },
                    showATR: vm.showATR,
                    atrPeriod: vm.atrPeriod,
                    drawings: vm.chartViewModels.map(\.drawings)
                )))
            }
        }
        let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabID })
        return WorkspaceState(
            tabs: tabStates,
            selectedTabIndex: selectedIndex,
            showBottomPanel: showBottomPanel,
            showRightPanel: showRightPanel,
            showLeftPanel: showLeftPanel
        )
    }

    private func restoreTabs(from state: WorkspaceState, startTasks: Bool = true) {
        showBottomPanel = state.showBottomPanel
        showRightPanel = state.showRightPanel
        showLeftPanel = state.showLeftPanel

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
                vm.drawings = chartState.drawings
                wireStateChanged(vm)
                let tab = Tab(content: .chart(vm))
                tabs.append(tab)
                if startTasks { vm.startAsync() }

            case .correlation(let corrState):
                let vm: CorrelationViewModel
                if let pairs = corrState.pairs {
                    // Custom (user-picked) correlation.
                    vm = CorrelationViewModel(
                        custom: corrState.customID ?? UUID(),
                        name: corrState.name ?? "Custom",
                        pairs: pairs,
                        period: corrState.period,
                        coordinator: marketData
                    )
                } else {
                    vm = CorrelationViewModel(
                        currency: corrState.currency,
                        period: corrState.period,
                        coordinator: marketData
                    )
                }
                vm.showSessions = corrState.showSessions
                vm.showVolume = corrState.showVolume
                vm.showEMA = corrState.showEMA
                vm.emaConfigs = corrState.emaConfigs.map { $0.toEMALine() }
                vm.showATR = corrState.showATR
                vm.atrPeriod = corrState.atrPeriod
                // Restore per-cell drawings, tolerating a different cell count
                // (e.g. correlation roster changed since the save).
                for (i, cellDrawings) in corrState.drawings.enumerated()
                    where i < vm.chartViewModels.count {
                    vm.chartViewModels[i].drawings = cellDrawings
                }
                wireStateChanged(vm)
                let tab = Tab(content: .correlation(vm))
                tabs.append(tab)
                if startTasks { Task { await vm.startAll() } }

            case .multiTimeframe(let mtfState):
                let vm = MultiTimeframeViewModel(
                    instrument: mtfState.instrument,
                    zoom: mtfState.zoom,
                    coordinator: marketData
                )
                vm.showSessions = mtfState.showSessions
                vm.showVolume = mtfState.showVolume
                vm.showEMA = mtfState.showEMA
                vm.emaConfigs = mtfState.emaConfigs.map { $0.toEMALine() }
                vm.showATR = mtfState.showATR
                vm.atrPeriod = mtfState.atrPeriod
                for (i, cellDrawings) in mtfState.drawings.enumerated()
                    where i < vm.chartViewModels.count {
                    vm.chartViewModels[i].drawings = cellDrawings
                }
                wireStateChanged(vm)
                let tab = Tab(content: .multiTimeframe(vm))
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
        // Per-cell drawings live on the child ChartViewModels; their own
        // didSet → onStateChanged?() needs to reach scheduleSave too.
        for child in vm.chartViewModels {
            child.onStateChanged = { [weak self] in self?.scheduleSave() }
        }
    }

    private func wireStateChanged(_ vm: MultiTimeframeViewModel) {
        vm.onStateChanged = { [weak self] in self?.scheduleSave() }
        for child in vm.chartViewModels {
            child.onStateChanged = { [weak self] in self?.scheduleSave() }
        }
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
