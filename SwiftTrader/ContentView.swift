import SwiftUI

struct ContentView: View {
    @State private var workspace = WorkspaceViewModel()
    @State private var auth = AuthViewModel(port: AppSettings.shared.port)
    @State private var showBuyPopover = false
    @State private var showSellPopover = false
    @State private var showEMAPopover = false
    @State private var showCorrelationEMAPopover = false

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
                    Text("Connecting to server...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 800, minHeight: 500)
            }
        }
        .task { await auth.start() }
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
                    RightPanel()
                }
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .background(WindowAccessor())
        .focusedSceneValue(\.workspace, workspace)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            // Tabs
            ForEach(workspace.tabs) { tab in
                tabButton(for: tab)
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
            .dropDestination(for: String.self) { items, _ in
                guard let draggedIDString = items.first,
                      let draggedID = UUID(uuidString: draggedIDString),
                      let index = workspace.tabs.firstIndex(where: { $0.id == draggedID }),
                      index != workspace.tabs.count - 1
                else { return false }
                withAnimation(.easeInOut(duration: 0.2)) {
                    let tab = workspace.tabs.remove(at: index)
                    workspace.tabs.append(tab)
                }
                return true
            }

            Spacer()

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
                SettingsView(settings: workspace.settings) { port in
                    workspace.reconnectAll(port: port)
                    auth.updatePort(port)
                }
            }

            // Panel toggle buttons
            panelToggles
        }
        .padding(.horizontal, 4)
        .frame(height: 32)
        .background(.bar)
    }

    private func tabButton(for tab: WorkspaceViewModel.Tab) -> some View {
        let isSelected = tab.id == workspace.selectedTabID

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
        .onTapGesture { workspace.selectTab(tab.id) }
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let draggedIDString = items.first,
                  let draggedID = UUID(uuidString: draggedIDString)
            else { return false }
            withAnimation(.easeInOut(duration: 0.2)) {
                workspace.moveTab(id: draggedID, beforeID: tab.id)
            }
            return true
        }
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
            showVolume: vm.showVolume,
            showEMA: vm.showEMA,
            emaConfigs: vm.emaConfigs,
            positions: workspace.trading.positions,
            currentInstrument: vm.currentInstrument,
            onModifyPosition: { label, sl, tp in
                Task { await workspace.trading.modifyPosition(label: label, stopLoss: sl, takeProfit: tp) }
            }
        )
        .overlay {
            if vm.bars.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Connecting to server...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)

        Divider()

        CorrelationView(viewModel: vm)
    }

    // MARK: - Trading controls

    @ViewBuilder
    private func tradingControls(vm: ChartViewModel) -> some View {
        let trading = workspace.trading
        let tradingEnabled = !trading.isSubmitting && !vm.bars.isEmpty && vm.isConnected

        HStack(spacing: 6) {
            // Mode toggle
            Toggle(isOn: Binding(
                get: { trading.oneClickMode },
                set: { trading.oneClickMode = $0 }
            )) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10))
            }
            .toggleStyle(.checkbox)
            .help(trading.oneClickMode ? "One-click mode (auto SL/TP)" : "Manual mode")

            Button("Buy") {
                if trading.oneClickMode {
                    Task {
                        await trading.submitOneClickOrder(
                            direction: "BUY", instrument: vm.currentInstrument, bars: vm.bars)
                    }
                } else {
                    showBuyPopover = true
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tradingEnabled ? .white : .white.opacity(0.6))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(tradingEnabled ? Color.green : Color.gray, in: RoundedRectangle(cornerRadius: 4))
            .disabled(!tradingEnabled)
            .popover(isPresented: $showBuyPopover) {
                OrderEntryView(
                    direction: "BUY",
                    instrument: vm.currentInstrument,
                    currentPrice: vm.bars.last?.close ?? 0,
                    amount: Binding(get: { trading.amount }, set: { trading.amount = $0 })
                ) { amt, sl, tp in
                    Task {
                        await trading.submitMarketOrder(
                            instrument: vm.currentInstrument, direction: "BUY",
                            amount: amt, stopLoss: sl, takeProfit: tp)
                    }
                }
            }

            Button("Sell") {
                if trading.oneClickMode {
                    Task {
                        await trading.submitOneClickOrder(
                            direction: "SELL", instrument: vm.currentInstrument, bars: vm.bars)
                    }
                } else {
                    showSellPopover = true
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tradingEnabled ? .white : .white.opacity(0.6))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(tradingEnabled ? Color.red : Color.gray, in: RoundedRectangle(cornerRadius: 4))
            .disabled(!tradingEnabled)
            .popover(isPresented: $showSellPopover) {
                OrderEntryView(
                    direction: "SELL",
                    instrument: vm.currentInstrument,
                    currentPrice: vm.bars.last?.close ?? 0,
                    amount: Binding(get: { trading.amount }, set: { trading.amount = $0 })
                ) { amt, sl, tp in
                    Task {
                        await trading.submitMarketOrder(
                            instrument: vm.currentInstrument, direction: "SELL",
                            amount: amt, stopLoss: sl, takeProfit: tp)
                    }
                }
            }
        }
    }

}
