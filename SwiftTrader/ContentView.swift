import SwiftUI

struct ContentView: View {
    @State private var workspace = WorkspaceViewModel()
    @State private var auth = AuthViewModel(port: AppSettings.shared.port)
    @State private var showEMAPopover = false
    @State private var showVolumeMAPopover = false
    @State private var showATRPopover = false
    @State private var showCorrelationEMAPopover = false
    @State private var showCorrelationVolumeMAPopover = false
    @State private var showCorrelationATRPopover = false

    var body: some View {
        Group {
            switch auth.phase {
            case .ready:
                mainContent
            case .pinRequired, .failed:
                PinEntrySheet(auth: auth)
                    .frame(minWidth: 800, minHeight: 500)
            case .checking, .connecting:
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading chart data...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 800, minHeight: 500)
            }
        }
        .task {
            workspace.startAll()
            await auth.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            workspace.saveNow()
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Tab bar
            tabBar

            Divider()

            // Main content: (header + chart + bottom panel) | right panel
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if let tab = workspace.selectedTab {
                        switch tab.content {
                        case .chart(let vm):
                            chartContent(vm: vm, tabID: tab.id)
                        case .correlation(let vm):
                            correlationContent(vm: vm)
                        }
                    }

                    if workspace.showBottomPanel {
                        Divider()
                        BottomPanel(trading: workspace.trading)
                    }
                }

                if workspace.showRightPanel {
                    Divider()
                    RightPanel(newsItems: workspace.newsItems)
                }
            }

            Divider()
            accountStatusBar
        }
        .frame(minWidth: 800, minHeight: 500)
        .background(WindowAccessor())
        .focusedSceneValue(\.workspace, workspace)
    }

    // MARK: - Account status bar

    private var accountStatusBar: some View {
        HStack(spacing: 16) {
            if let account = workspace.trading.account {
                accountField("Balance", value: account.balance, currency: account.currency)
                accountField("Equity", value: account.equity, currency: account.currency,
                             color: account.equity >= account.balance ? .green : .red)
                accountField("Margin", value: account.usedMargin, currency: account.currency)
                accountField("Free", value: account.freeMargin, currency: account.currency)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(.bar)
    }

    private func accountField(_ label: String, value: Double, currency: String,
                              color: Color = .primary) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(String(format: "%.2f %@", value, currency))
                .foregroundStyle(color)
        }
        .font(.system(size: 10, design: .monospaced))
    }

    // MARK: - Tab bar

    private var chartTabs: [WorkspaceViewModel.Tab] {
        workspace.tabs.filter { if case .chart = $0.content { return true }; return false }
    }

    private var correlationTabs: [WorkspaceViewModel.Tab] {
        workspace.tabs.filter { if case .correlation = $0.content { return true }; return false }
    }

    private func isChartTab(_ id: UUID) -> Bool {
        workspace.tabs.first(where: { $0.id == id }).map {
            if case .chart = $0.content { return true }; return false
        } ?? false
    }

    // MARK: - Gesture-based tab drag state

    @State private var draggedTabID: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var tabFrames: [UUID: CGRect] = [:]  // in row coordinate space
    @State private var showShortcuts = false

    private func reorderDuringDrag(tab: WorkspaceViewModel.Tab, rowTabs: [WorkspaceViewModel.Tab]) {
        guard let dragFrame = tabFrames[tab.id] else { return }
        let dragCenter = dragFrame.midX + dragOffset

        for other in rowTabs where other.id != tab.id {
            guard let otherFrame = tabFrames[other.id] else { continue }
            let otherIndex = workspace.tabs.firstIndex(where: { $0.id == other.id })!
            let dragIndex = workspace.tabs.firstIndex(where: { $0.id == tab.id })!

            // If dragging right and center passes another tab's midpoint
            if dragIndex < otherIndex && dragCenter > otherFrame.midX {
                workspace.moveTab(id: tab.id, beforeID: other.id)
                // moveTab puts us before other, but we want after — so move other before us
                workspace.moveTab(id: other.id, beforeID: tab.id)
                return
            }
            // If dragging left and center passes another tab's midpoint
            if dragIndex > otherIndex && dragCenter < otherFrame.midX {
                workspace.moveTab(id: tab.id, beforeID: other.id)
                return
            }
        }
    }

    private var tabBar: some View {
        VStack(spacing: 0) {
            // Row 1: chart tabs
            HStack(spacing: 0) {
                ForEach(chartTabs) { tab in
                    tabButton(for: tab, coordinateSpace: "chartRow", rowTabs: chartTabs)
                }

                // New tab button
                Button(action: { workspace.addTab() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("New Tab (⌘T)")

                // Sort tabs by global FX turnover (BIS Triennial Survey)
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        workspace.sortTabsByVolume()
                    }
                }) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Sort tabs by trading volume")

                Spacer()

                // Keyboard shortcuts help
                Button(action: { showShortcuts = true }) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Keyboard Shortcuts")
                .popover(isPresented: $showShortcuts) {
                    ShortcutsPopover()
                }

                // Settings gear
                Button(action: { workspace.showSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Settings")
                .popover(isPresented: $workspace.showSettings) {
                    SettingsView(
                        settings: workspace.settings,
                        onPortChanged: { port in
                            workspace.reconnectAll(port: port)
                            auth.updatePort(port)
                        },
                        onRebucketingChanged: {
                            workspace.applyRebucketingChange()
                        }
                    )
                }

                // Panel toggle buttons
                panelToggles
            }
            .padding(.horizontal, 4)
            .frame(height: 32)
            .background(.bar)
            .coordinateSpace(name: "chartRow")

            // Row 2: correlation tabs (only when present)
            if !correlationTabs.isEmpty {
                Divider()
                HStack(spacing: 0) {
                    ForEach(correlationTabs) { tab in
                        tabButton(for: tab, coordinateSpace: "correlationRow", rowTabs: correlationTabs)
                    }
                    Spacer()
                }
                .padding(.horizontal, 4)
                .frame(height: 32)
                .background(.bar)
                .coordinateSpace(name: "correlationRow")
            }
        }
    }

    private func tabButton(for tab: WorkspaceViewModel.Tab, coordinateSpace: String,
                           rowTabs: [WorkspaceViewModel.Tab]) -> some View {
        let isSelected = tab.id == workspace.selectedTabID
        let isDragged = tab.id == draggedTabID

        let periodLabel = { (p: String) in
            ChartViewModel.availablePeriods.first { $0.value == p }?.label ?? p
        }
        let label: String = switch tab.content {
        case .chart(let vm): "\(formatInstrument(vm.currentInstrument)) \(periodLabel(vm.currentPeriod))"
        case .correlation(let vm): "\(vm.currency) ⊞ \(periodLabel(vm.currentPeriod))"
        }

        return HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .lineLimit(1)

            if workspace.tabs.count > 1 {
                Button(action: { workspace.closeTab(tab.id) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .offset(x: isDragged ? dragOffset : 0)
        .zIndex(isDragged ? 1 : 0)
        .opacity(isDragged ? 0.8 : 1)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { tabFrames[tab.id] = geo.frame(in: .named(coordinateSpace)) }
                    .onChange(of: geo.frame(in: .named(coordinateSpace))) { _, frame in
                        if !isDragged { tabFrames[tab.id] = frame }
                    }
            }
        )
        .gesture(
            DragGesture(minimumDistance: 5)
                .onChanged { value in
                    if draggedTabID == nil {
                        draggedTabID = tab.id
                        // Snapshot current frame before dragging changes layout
                        tabFrames[tab.id] = tabFrames[tab.id]
                    }
                    dragOffset = value.translation.width
                    reorderDuringDrag(tab: tab, rowTabs: rowTabs)
                }
                .onEnded { _ in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        dragOffset = 0
                        draggedTabID = nil
                    }
                }
        )
        .onTapGesture { workspace.selectTab(tab.id) }
    }

    // MARK: - Panel toggles

    private var panelToggles: some View {
        HStack(spacing: 2) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    workspace.showBottomPanel.toggle()
                }
            }) {
                Image(systemName: "rectangle.bottomhalf.inset.filled")
                    .font(.system(size: 13))
                    .foregroundStyle(workspace.showBottomPanel ? .primary : .tertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Toggle Bottom Panel (⇧⌘Y)")

            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    workspace.showRightPanel.toggle()
                }
            }) {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 13))
                    .foregroundStyle(workspace.showRightPanel ? .primary : .tertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Toggle Right Panel (⌥⌘0)")
        }
    }

    // MARK: - Chart tab content

    @ViewBuilder
    private func chartContent(vm: ChartViewModel, tabID: UUID) -> some View {
        // Header
        HStack {
            Picker("", selection: Binding(
                get: { vm.currentInstrument },
                set: { vm.switchInstrument($0) }
            )) {
                ForEach(vm.availableInstruments, id: \.self) { instrument in
                    Text(formatInstrument(instrument)).tag(instrument)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            Button(action: { workspace.cycleSelectedTabPeriod(offset: -1) }) {
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Shorter Timeframe (⌘⌃↓)")

            Picker("", selection: Binding(
                get: { vm.currentPeriod },
                set: { vm.switchPeriod($0) }
            )) {
                ForEach(ChartViewModel.availablePeriods, id: \.value) { period in
                    Text(period.label).tag(period.value)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            Button(action: { workspace.cycleSelectedTabPeriod(offset: 1) }) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Longer Timeframe (⌘⌃↑)")

            Divider().frame(height: 16)

            // Correlation screen buttons
            ForEach(CurrencyCorrelation.currencies(from: vm.currentInstrument), id: \.self) { currency in
                Button("\(currency) \u{229e}") {
                    workspace.addCorrelationTab(currency: currency)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help("\(currency) Correlation")
            }

            Button(action: { vm.showSessions.toggle() }) {
                Image(systemName: "clock.arrow.2.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(vm.showSessions ? .primary : .tertiary)
            }
            .buttonStyle(.borderless)
            .help("Market Sessions")

            Button(action: { vm.showVolume.toggle() }) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(vm.showVolume ? .primary : .tertiary)
            }
            .buttonStyle(.borderless)
            .help("Volume")

            Button(action: { showVolumeMAPopover.toggle() }) {
                Text("VMA")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(vm.showVolumeMA ? .primary : .tertiary)
            }
            .buttonStyle(.borderless)
            .help("Volume MA")
            .popover(isPresented: $showVolumeMAPopover) {
                VolumeMAPopover(
                    showVolumeMA: Binding(get: { vm.showVolumeMA }, set: { vm.showVolumeMA = $0 }),
                    volumeMA: Binding(get: { vm.volumeMA }, set: { vm.volumeMA = $0 })
                )
            }

            Button(action: { showEMAPopover.toggle() }) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 11))
                    .foregroundStyle(vm.showEMA ? .primary : .tertiary)
            }
            .buttonStyle(.borderless)
            .help("EMA")
            .popover(isPresented: $showEMAPopover) {
                EMAPopover(
                    showEMA: Binding(get: { vm.showEMA }, set: { vm.showEMA = $0 }),
                    emaConfigs: Binding(get: { vm.emaConfigs }, set: { vm.emaConfigs = $0 })
                )
            }

            Button(action: { showATRPopover.toggle() }) {
                Text("ATR")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(vm.showATR ? .primary : .tertiary)
            }
            .buttonStyle(.borderless)
            .help("Average True Range")
            .popover(isPresented: $showATRPopover) {
                ATRPopover(
                    showATR: Binding(get: { vm.showATR }, set: { vm.showATR = $0 }),
                    atrPeriod: Binding(get: { vm.atrPeriod }, set: { vm.atrPeriod = $0 })
                )
            }

            Divider().frame(height: 16)

            // Trading controls
            tradingControls(vm: vm)

            Spacer()

            if vm.isConnected {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Live")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if !vm.bars.isEmpty {
                Circle().fill(.yellow).frame(width: 8, height: 8)
                Text("Market Closed")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Disconnected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider().frame(height: 16)

            Button(action: { vm.refreshCache() }) {
                Group {
                    if vm.isRefreshingCache {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .disabled(vm.isRefreshingCache)
            .help("Refresh cache — delete server-side Dukascopy cache and reload (last resort)")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)

        Divider()

        // Chart
        ChartView(
            bars: vm.bars,
            transform: Binding(
                get: { vm.transform },
                set: { vm.transform = $0 }
            ),
            onChartWidthChanged: { vm.chartWidth = $0 },
            onUserDrag: { vm.onUserScroll() },
            showSessions: vm.showSessions,
            currentPeriod: vm.currentPeriod,
            showVolume: vm.showVolume,
            showVolumeMA: vm.showVolumeMA,
            volumeMA: vm.volumeMA,
            showEMA: vm.showEMA,
            emaConfigs: vm.emaConfigs,
            positions: workspace.trading.positions,
            currentInstrument: vm.currentInstrument,
            showATR: vm.showATR,
            atrPeriod: vm.atrPeriod,
            atrPips: vm.atrPips,
            todayATRPercent: vm.todayATRPercent,
            onModifyPosition: { label, sl, tp in
                Task { await workspace.trading.modifyPosition(label: label, stopLoss: sl, takeProfit: tp) }
            },
            visualOrder: workspace.trading.visualOrderWithLivePrice(for: vm.currentInstrument, currentPrice: vm.bars.last?.close, barCount: vm.bars.count),
            onConfirmVisualOrder: {
                Task { await workspace.trading.confirmVisualOrder(instrument: vm.currentInstrument) }
            },
            onCancelVisualOrder: {
                workspace.trading.cancelVisualOrder(instrument: vm.currentInstrument)
            },
            onUpdateVisualOrderSL: { price in
                workspace.trading.updateVisualOrderSL(instrument: vm.currentInstrument, price: price)
            },
            onUpdateVisualOrderTP: { price in
                workspace.trading.visualOrders[vm.currentInstrument]?.takeProfit = price
            },
            onUpdateVisualOrderEntry: { price in
                workspace.trading.updateVisualOrderEntry(instrument: vm.currentInstrument, price: price)
            },
            onAdjustVisualOrderAmount: { delta in
                workspace.trading.adjustVisualOrderAmount(instrument: vm.currentInstrument, by: delta)
            },
            onResetVisualOrderAmount: {
                workspace.trading.resetVisualOrderAmount(instrument: vm.currentInstrument)
            },
            accountEquity: workspace.trading.account?.equity,
            isSubmittingOrder: workspace.trading.isSubmitting
        )
        .overlay {
            if let status = vm.loadingStatus, vm.bars.isEmpty {
                ChartLoadingCard(status: status)
            } else if let status = vm.loadingStatus, case .loadingEarlier = status.stage {
                ChartLoadingCard(status: status)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
            } else if let err = vm.error, vm.loadingStatus == nil {
                VStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(8)
            }
        }
        .id(tabID)
    }

    // MARK: - Correlation tab content

    @ViewBuilder
    private func correlationContent(vm: CorrelationViewModel) -> some View {
        // Header: currency label + period picker only
        HStack {
            Text("\(vm.currency) Correlation")
                .font(.system(size: 13, weight: .semibold))

            Button(action: { workspace.cycleSelectedTabPeriod(offset: -1) }) {
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Shorter Timeframe (⌘⌃↓)")

            Picker("", selection: Binding(
                get: { vm.currentPeriod },
                set: { vm.switchPeriod($0) }
            )) {
                ForEach(ChartViewModel.availablePeriods, id: \.value) { period in
                    Text(period.label).tag(period.value)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            Button(action: { workspace.cycleSelectedTabPeriod(offset: 1) }) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Longer Timeframe (⌘⌃↑)")

            Button(action: { vm.showSessions.toggle() }) {
                Image(systemName: "clock.arrow.2.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(vm.showSessions ? .primary : .tertiary)
            }
            .buttonStyle(.borderless)
            .help("Market Sessions")

            Button(action: { vm.showVolume.toggle() }) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(vm.showVolume ? .primary : .tertiary)
            }
            .buttonStyle(.borderless)
            .help("Volume")

            Button(action: { showCorrelationVolumeMAPopover.toggle() }) {
                Text("VMA")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(vm.showVolumeMA ? .primary : .tertiary)
            }
            .buttonStyle(.borderless)
            .help("Volume MA")
            .popover(isPresented: $showCorrelationVolumeMAPopover) {
                VolumeMAPopover(
                    showVolumeMA: Binding(get: { vm.showVolumeMA }, set: { vm.showVolumeMA = $0 }),
                    volumeMA: Binding(get: { vm.volumeMA }, set: { vm.volumeMA = $0 })
                )
            }

            Button(action: { showCorrelationEMAPopover.toggle() }) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 11))
                    .foregroundStyle(vm.showEMA ? .primary : .tertiary)
            }
            .buttonStyle(.borderless)
            .help("EMA")
            .popover(isPresented: $showCorrelationEMAPopover) {
                EMAPopover(
                    showEMA: Binding(get: { vm.showEMA }, set: { vm.showEMA = $0 }),
                    emaConfigs: Binding(get: { vm.emaConfigs }, set: { vm.emaConfigs = $0 })
                )
            }

            Button(action: { showCorrelationATRPopover.toggle() }) {
                Text("ATR")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(vm.showATR ? .primary : .tertiary)
            }
            .buttonStyle(.borderless)
            .help("Average True Range")
            .popover(isPresented: $showCorrelationATRPopover) {
                ATRPopover(
                    showATR: Binding(get: { vm.showATR }, set: { vm.showATR = $0 }),
                    atrPeriod: Binding(get: { vm.atrPeriod }, set: { vm.atrPeriod = $0 })
                )
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)

        Divider()

        CorrelationView(viewModel: vm, onInstrumentTap: { workspace.selectOrCreateChartTab(instrument: $0) })
    }

    // MARK: - Trading controls

    @ViewBuilder
    private func tradingControls(vm: ChartViewModel) -> some View {
        let trading = workspace.trading
        let tradingEnabled = !trading.isSubmitting && !vm.bars.isEmpty && vm.isConnected

        HStack(spacing: 6) {
            Button("Buy") {
                trading.beginVisualOrder(
                    direction: "BUY", instrument: vm.currentInstrument, bars: vm.bars)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tradingEnabled ? .white : .white.opacity(0.6))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(tradingEnabled ? Color.green : Color.gray, in: RoundedRectangle(cornerRadius: 4))
            .disabled(!tradingEnabled)

            Button("Sell") {
                trading.beginVisualOrder(
                    direction: "SELL", instrument: vm.currentInstrument, bars: vm.bars)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tradingEnabled ? .white : .white.opacity(0.6))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(tradingEnabled ? Color.red : Color.gray, in: RoundedRectangle(cornerRadius: 4))
            .disabled(!tradingEnabled)
        }
    }

}
