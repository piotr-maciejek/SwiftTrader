import DukascopyClient
import SwiftUI

struct ContentView: View {
    @State private var workspace = WorkspaceViewModel()
    @State private var auth = AuthViewModel(port: AppSettings.shared.port)
    @State private var standaloneAuth = StandaloneAuthViewModel()
    @State private var showLoginSheet = false
    /// Grace-debounced visibility for the connection-health banner: suppressed during a routine
    /// in-place reconnect (~5–21s) so a transient drop reconnects silently. Only shown if the
    /// unhealthy state persists; a failed reconnect goes to the login gate instead (the real error).
    @State private var healthBannerVisible = false

    private var provider: DataProviderMode { AppSettings.shared.dataProvider }

    private var isAuthReady: Bool {
        if case .ready = auth.phase { return true }
        return false
    }

    private var isNativeReady: Bool {
        if case .ready = standaloneAuth.phase { return true }
        return false
    }

    /// In native mode the workspace gates on the native session; in server mode on
    /// the jforex-server auth handshake.
    private var isWorkspaceReady: Bool {
        provider == .native ? isNativeReady : isAuthReady
    }

    @State private var showEMAPopover = false
    @State private var showVolumeMAPopover = false
    @State private var showATRPopover = false
    @State private var showCorrelationEMAPopover = false
    @State private var showCorrelationVolumeMAPopover = false
    @State private var showCorrelationATRPopover = false
    @State private var showMultiTFEMAPopover = false
    @State private var showMultiTFVolumeMAPopover = false
    @State private var showMultiTFATRPopover = false

    var body: some View {
        Group {
            switch provider {
            case .server:
                serverGatedContent
            case .native:
                nativeGatedContent
            }
        }
        .task {
            if provider == .server {
                await auth.start()
            }
            // Native mode does NOT auto-connect: the gate opens the login sheet so
            // the user explicitly confirms which account to use. Saved credentials
            // are still used by Connect — no password re-entry.
        }
        // Server returns 503 for /history until the strategy is ready, so any
        // history fetches that fire during the auth handshake are wasted retries
        // that count against `maxHistoryAttempts`. Defer startAll() until auth
        // reaches .ready (works for both cold-connect and post-PIN flows).
        // In native mode the gate is the native session instead. startAll() is
        // idempotent — guarded by hasStarted internally.
        .onChange(of: isWorkspaceReady, initial: true) { _, ready in
            guard ready else { return }
            if provider == .native, let session = standaloneAuth.session {
                workspace.attachNativeSession(session)
            }
            workspace.startAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            workspace.saveNow()
        }
    }

    @ViewBuilder
    private var serverGatedContent: some View {
        switch auth.phase {
        case .ready:
            mainContent
        case .pinRequired, .failed:
            PinEntrySheet(auth: auth)
                .frame(minWidth: 800, minHeight: 500)
        case .checking, .connecting:
            loadingPlaceholder("Loading chart data...")
        }
    }

    private var isNativePinRequired: Bool {
        if case .pinRequired = standaloneAuth.phase { return true }
        return false
    }

    @ViewBuilder
    private var nativeGatedContent: some View {
        Group {
            if isNativeReady {
                mainContent
            } else {
                nativeConnectGate
            }
        }
        .sheet(isPresented: $showLoginSheet) {
            StandaloneLoginSheet(accounts: AccountStore.shared, auth: standaloneAuth)
        }
        // Captcha PIN challenge (LIVE on a non-whitelisted IP) — layered over the
        // login sheet so cancelling returns cleanly to the account picker.
        .sheet(isPresented: Binding(
            get: { isNativePinRequired },
            set: { presented in if !presented { standaloneAuth.cancelPin() } }
        )) {
            NativePinSheet(auth: standaloneAuth)
        }
    }

    private var nativeConnectGate: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Standalone mode")
                .font(.headline)
            switch standaloneAuth.phase {
            case .connecting:
                ProgressView().controlSize(.small)
                Text("Connecting…").font(.caption).foregroundStyle(.secondary)
            case .failed(let msg):
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .textSelection(.enabled)
                Button("Choose account") { showLoginSheet = true }
            default:
                Button("Choose account / Log in") { showLoginSheet = true }
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .onAppear { showLoginSheet = true }
    }

    private func loadingPlaceholder(_ text: String) -> some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 800, minHeight: 500)
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            if healthBannerVisible, let account = workspace.trading.account, account.isHealthStale {
                connectionBanner(account: account)
            }

            topToolbar

            Divider()

            // Main content: sidebar | (chart + bottom panel) | right panel
            HStack(spacing: 0) {
                if workspace.showLeftPanel {
                    LeftSidebar(workspace: workspace, settings: AppSettings.shared)
                    Divider()
                }

                VStack(spacing: 0) {
                    if let tab = workspace.selectedTab {
                        switch tab.content {
                        case .chart(let vm):
                            chartContent(vm: vm, tabID: tab.id)
                        case .correlation(let vm):
                            correlationContent(vm: vm)
                        case .multiTimeframe(let vm):
                            multiTimeframeContent(vm: vm)
                        }
                    }

                    if workspace.showBottomPanel {
                        Divider()
                        BottomPanel(trading: workspace.trading, tradeHistory: workspace.tradeHistory,
                                    metadata: workspace.positionMetadata)
                    }
                }
                // Order rejections / validation failures surface as a prominent toast at the top
                // of the chart — where the eye is when placing an order — not just the easily-missed
                // line in the bottom panel header.
                .overlay(alignment: .top) {
                    if let error = workspace.trading.orderError {
                        OrderErrorToast(message: error) {
                            withAnimation(.easeOut(duration: 0.2)) { workspace.trading.orderError = nil }
                        }
                    }
                }
                .animation(.spring(duration: 0.25), value: workspace.trading.orderError)

                if workspace.showRightPanel {
                    Divider()
                    RightPanel(newsItems: workspace.newsItems, newsError: workspace.newsError)
                }
            }

            if !workspace.settings.incognitoMode {
                Divider()
                accountStatusBar
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .background(WindowAccessor())
        // Hidden Cmd+Shift+G: dump the focused tab's chart state to the log when a gap is on
        // screen, so we can tell a data-hole from a render artifact. Read: log show … | grep GAP-DIAG
        .background(
            Button("") { workspace.captureGapDiagnostics() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .opacity(0)
        )
        .focusedSceneValue(\.workspace, workspace)
        // Debounce the health banner: only show it once the unhealthy state has persisted past a
        // routine in-place reconnect, so a transient transport drop recovers silently. `.task(id:)`
        // restarts whenever health flips, so a quick recovery cancels the pending show.
        .task(id: workspace.trading.account?.isHealthStale ?? false) {
            guard workspace.trading.account?.isHealthStale ?? false else {
                healthBannerVisible = false
                return
            }
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled {
                healthBannerVisible = workspace.trading.account?.isHealthStale ?? false
            }
        }
    }

    // MARK: - Connection health banner

    private func connectionBanner(account: Account) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            if !account.connected {
                Text("Dukascopy transport disconnected — positions, P&L and order actions may be stale or rejected.")
            } else {
                let seconds = Double(account.lastTickAgeMs) / 1000.0
                Text(String(format: "No price updates for %.0fs — connection may be degraded.", seconds))
            }
            Spacer()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.85))
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

    // MARK: - Top toolbar

    @State private var showShortcuts = false

    private var topToolbar: some View {
        HStack(spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    workspace.showLeftPanel.toggle()
                }
            }) {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 13))
                    .foregroundStyle(workspace.showLeftPanel ? .primary : .tertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Toggle Sidebar (⌥⌘1)")

            Spacer()

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

            // Native mode: switch the connected account without restarting. Re-opens the
            // login sheet; picking a different account + Connect tears down the old session
            // (see StandaloneAuthViewModel.connectOrSwitch).
            if provider == .native {
                Button(action: { showLoginSheet = true }) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Switch account")
            }

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

            panelToggles
        }
        .padding(.horizontal, 4)
        .frame(height: 32)
        .background(.bar)
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
            Text(formatInstrument(vm.currentInstrument))
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

            Divider().frame(height: 16)

            // Candle side (bid/ask) + show-both-lines toggles (chart tabs only).
            Button(action: { vm.switchSide(vm.currentSide.toggled) }) {
                Text(vm.currentSide.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(vm.currentSide == .ask ? Color.orange : Color.secondary)
                    .frame(minWidth: 26)
            }
            .buttonStyle(.borderless)
            .help("Candle side — Bid/Ask (toggle)")

            Button(action: { vm.showBidAsk.toggle() }) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11))
                    .foregroundStyle(vm.showBidAsk ? .primary : .tertiary)
            }
            .buttonStyle(.borderless)
            .help("Show live bid & ask lines")

            Button(action: {
                workspace.selectOrCreateMultiTimeframeTab(instrument: vm.currentInstrument)
            }) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Multi-Timeframe view")

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

            if vm.isBackfilling {
                // Stale cache painted at launch — recently-closed bars are still being
                // backfilled. Takes precedence over "Live" so the visible (gapped) chart
                // is clearly marked as catching up, not a finished render.
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("Updating…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if vm.isConnected {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Live")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if !vm.bars.isEmpty {
                // No live tick yet. Distinguish a genuinely closed market (weekend/holiday)
                // from "still connecting" — otherwise an open-market startup wrongly reads
                // "Market Closed" while the live feed is just catching up.
                let now = Date()
                let marketClosed = NYTradingCalendar.isMarketClosed(at: now) || NYTradingCalendar.isFXHoliday(at: now)
                Circle().fill(marketClosed ? .yellow : .orange).frame(width: 8, height: 8)
                Text(marketClosed ? "Market Closed" : "Connecting…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Disconnected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider().frame(height: 16)

            // Server mode has two layers (client cache + JForex/.bi5 cache) so the
            // light-weight soft refresh is useful. Native mode has a single shared
            // disk cache, so the soft button is redundant — one orange button only.
            if provider == .server {
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
                .help("Refresh — drop the local chart cache and re-fetch from the server")
            }

            Button(action: { vm.hardRefresh() }) {
                Group {
                    if vm.isRefreshingCache && provider == .native {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }
                .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .disabled(vm.isRefreshingCache)
            .help(provider == .native
                ? "Refresh — wipe local cache for this instrument and re-fetch from Dukascopy"
                : "Hard refresh — purge server cache AND force JForex to reconnect (~5–30s outage on all charts)")
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
            onScrollToLiveEdge: { vm.jumpToLiveEdge() },
            showSessions: vm.showSessions,
            currentPeriod: vm.currentPeriod,
            showVolume: vm.showVolume,
            showVolumeMA: vm.showVolumeMA,
            volumeMA: vm.volumeMA,
            showEMA: vm.showEMA,
            emaConfigs: vm.emaConfigs,
            positions: workspace.trading.positions,
            pendingOrders: workspace.trading.pendingOrders,
            currentInstrument: vm.currentInstrument,
            showATR: vm.showATR,
            atrPeriod: vm.atrPeriod,
            atrPips: vm.atrPips,
            todayATRPercent: vm.todayATRPercent,
            onModifyPosition: { label, sl, tp in
                Task { await workspace.trading.modifyPosition(label: label, stopLoss: sl, takeProfit: tp) }
            },
            onModifyPendingEntry: { label, trigger in
                Task { await workspace.trading.modifyPendingEntry(label: label, trigger: trigger) }
            },
            visualOrder: workspace.trading.visualOrderWithLivePrice(for: vm.currentInstrument, currentPrice: vm.bars.last?.close, barCount: vm.bars.count),
            onConfirmVisualOrder: {
                Task { await workspace.trading.confirmVisualOrder(instrument: vm.currentInstrument, livePrice: vm.bars.last?.close) }
            },
            onCancelVisualOrder: {
                workspace.trading.cancelVisualOrder(instrument: vm.currentInstrument)
            },
            onUpdateVisualOrderSL: { price in
                workspace.trading.updateVisualOrderSL(instrument: vm.currentInstrument, price: price, livePrice: vm.bars.last?.close)
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
                workspace.trading.resetVisualOrderAmount(instrument: vm.currentInstrument, livePrice: vm.bars.last?.close)
            },
            accountEquity: workspace.trading.account?.equity,
            visualOrderSpread: workspace.trading.spreads[vm.currentInstrument] ?? 0,
            showQuote: true,
            chartSide: vm.currentSide,
            showBidAskLines: vm.showBidAsk,
            isSubmittingOrder: workspace.trading.isSubmitting,
            drawings: vm.drawings,
            drawingTool: vm.drawingTool,
            selectedDrawingID: vm.selectedDrawingID,
            onCommitDrawing: { drawing in vm.drawings.append(drawing) },
            onDeleteDrawing: { id in vm.drawings.removeAll { $0.id == id } },
            onClearAllDrawings: { vm.drawings = [] },
            onClearAllDrawingsAcrossCells: { vm.drawings = [] },
            onSetDrawingTool: { tool in vm.drawingTool = tool },
            onSelectDrawing: { id in vm.selectedDrawingID = id }
        )
        .background(ChartView.chartBackground)
        .overlay {
            if let status = vm.loadingStatus, vm.bars.isEmpty {
                ChartLoadingCard(
                    status: status,
                    onRetry: { vm.retryFromExhausted() },
                    onForceReconnect: { vm.forceReconnectAndRetry() }
                )
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

            Divider().frame(height: 16)

            // Candle side (bid/ask) + show-both-lines toggles (apply to every cell).
            Button(action: { vm.switchSide(vm.currentSide.toggled) }) {
                Text(vm.currentSide.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(vm.currentSide == .ask ? Color.orange : Color.secondary)
                    .frame(minWidth: 26)
            }
            .buttonStyle(.borderless)
            .help("Candle side — Bid/Ask (toggle)")

            Button(action: { vm.showBidAsk.toggle() }) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11))
                    .foregroundStyle(vm.showBidAsk ? .primary : .tertiary)
            }
            .buttonStyle(.borderless)
            .help("Show live bid & ask lines")

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

        CorrelationView(
            viewModel: vm,
            trading: workspace.trading,
            onInstrumentTap: { workspace.selectOrCreateChartTab(instrument: $0) },
            onMultiTimeframeTap: { workspace.selectOrCreateMultiTimeframeTab(instrument: $0) }
        )
    }

    // MARK: - Multi-timeframe tab content

    @ViewBuilder
    private func multiTimeframeContent(vm: MultiTimeframeViewModel) -> some View {
        HStack {
            Text("\(formatInstrument(vm.instrument)) Multi-Timeframe")
                .font(.system(size: 13, weight: .semibold))

            Picker("", selection: Binding(
                get: { vm.zoom },
                set: { vm.zoom = $0 }
            )) {
                Text("D / 4H / 1H / 15m").tag(TFZoom.standard)
                Text("4H / 1H / 15m / 3m").tag(TFZoom.intraday)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Timeframe zoom")

            // Candle side (bid/ask) + show-both-lines toggles (apply to every cell).
            Button(action: { vm.switchSide(vm.currentSide.toggled) }) {
                Text(vm.currentSide.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(vm.currentSide == .ask ? Color.orange : Color.secondary)
                    .frame(minWidth: 26)
            }
            .buttonStyle(.borderless)
            .help("Candle side — Bid/Ask (toggle)")

            Button(action: { vm.showBidAsk.toggle() }) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11))
                    .foregroundStyle(vm.showBidAsk ? .primary : .tertiary)
            }
            .buttonStyle(.borderless)
            .help("Show live bid & ask lines")

            Divider().frame(height: 16)

            // Correlation screen links for each currency in the pair.
            ForEach(CurrencyCorrelation.currencies(from: vm.instrument), id: \.self) { currency in
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

            Button(action: { showMultiTFVolumeMAPopover.toggle() }) {
                Text("VMA")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(vm.showVolumeMA ? .primary : .tertiary)
            }
            .buttonStyle(.borderless)
            .help("Volume MA")
            .popover(isPresented: $showMultiTFVolumeMAPopover) {
                VolumeMAPopover(
                    showVolumeMA: Binding(get: { vm.showVolumeMA }, set: { vm.showVolumeMA = $0 }),
                    volumeMA: Binding(get: { vm.volumeMA }, set: { vm.volumeMA = $0 })
                )
            }

            Button(action: { showMultiTFEMAPopover.toggle() }) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 11))
                    .foregroundStyle(vm.showEMA ? .primary : .tertiary)
            }
            .buttonStyle(.borderless)
            .help("EMA")
            .popover(isPresented: $showMultiTFEMAPopover) {
                EMAPopover(
                    showEMA: Binding(get: { vm.showEMA }, set: { vm.showEMA = $0 }),
                    emaConfigs: Binding(get: { vm.emaConfigs }, set: { vm.emaConfigs = $0 })
                )
            }

            Button(action: { showMultiTFATRPopover.toggle() }) {
                Text("ATR")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(vm.showATR ? .primary : .tertiary)
            }
            .buttonStyle(.borderless)
            .help("Average True Range")
            .popover(isPresented: $showMultiTFATRPopover) {
                ATRPopover(
                    showATR: Binding(get: { vm.showATR }, set: { vm.showATR = $0 }),
                    atrPeriod: Binding(get: { vm.atrPeriod }, set: { vm.atrPeriod = $0 })
                )
            }

            Divider().frame(height: 16)

            mtfTradingControls(vm: vm)

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)

        Divider()

        MultiTimeframeView(
            viewModel: vm,
            trading: workspace.trading,
            onCellTap: { instrument, period in
                workspace.selectOrCreateChartTab(instrument: instrument, period: period)
            }
        )
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
            .buttonStyle(FilledActionButtonStyle(fill: .green, enabled: tradingEnabled))
            .disabled(!tradingEnabled)

            Button("Sell") {
                trading.beginVisualOrder(
                    direction: "SELL", instrument: vm.currentInstrument, bars: vm.bars)
            }
            .buttonStyle(FilledActionButtonStyle(fill: .red, enabled: tradingEnabled))
            .disabled(!tradingEnabled)
        }
    }

    @ViewBuilder
    private func mtfTradingControls(vm: MultiTimeframeViewModel) -> some View {
        let trading = workspace.trading
        // Seed SL/TP from the lowest-TF cell (last index: 15m standard / 3m intraday) —
        // tighter recent swing produces a tighter stop, which matches the precision the
        // MTF view is for.
        let primaryCell = vm.chartViewModels.last
        let tradingEnabled = !trading.isSubmitting
            && (primaryCell.map { !$0.bars.isEmpty && $0.isConnected } ?? false)
            && trading.visualOrders[vm.instrument] == nil

        HStack(spacing: 6) {
            Button("Buy") {
                if let cell = primaryCell {
                    trading.beginVisualOrder(
                        direction: "BUY", instrument: vm.instrument, bars: cell.bars)
                }
            }
            .buttonStyle(FilledActionButtonStyle(fill: .green, enabled: tradingEnabled))
            .disabled(!tradingEnabled)

            Button("Sell") {
                if let cell = primaryCell {
                    trading.beginVisualOrder(
                        direction: "SELL", instrument: vm.instrument, bars: cell.bars)
                }
            }
            .buttonStyle(FilledActionButtonStyle(fill: .red, enabled: tradingEnabled))
            .disabled(!tradingEnabled)
        }
    }

}

/// Prominent, auto-dismissing banner for an order rejection / validation failure. Slides in at
/// the top of the chart and clears itself after ~6s (or on the ✕). Bound to `TradingViewModel.orderError`.
private struct OrderErrorToast: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 420)
        .background(Color.red.opacity(0.95), in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .padding(.top, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
        // .task(id:) restarts the auto-dismiss timer whenever the message changes, so a fresh
        // rejection gets its own full 6s rather than inheriting the previous one's remaining time.
        .task(id: message) {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { onDismiss() }
        }
    }
}
