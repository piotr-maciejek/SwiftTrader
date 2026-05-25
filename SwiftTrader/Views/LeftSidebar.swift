import SwiftUI

struct LeftSidebar: View {
    @Bindable var workspace: WorkspaceViewModel
    @Bindable var settings: AppSettings
    @State private var hoveredKey: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                pairsSection
                correlationsSection
            }
            .padding(.vertical, 4)
        }
        .frame(width: 220)
        .background(.bar)
    }

    // MARK: - Pairs

    private var pairsSection: some View {
        let instruments = sortedInstruments()
        return Group {
            pairsHeader
            if instruments.isEmpty {
                Text("Loading…")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            } else {
                switch settings.pairsGroupingMode {
                case .alphabetical:
                    ForEach(instruments, id: \.self) { instrument in
                        pairRow(instrument: instrument)
                    }
                case .byCurrency:
                    ForEach(Self.instrumentsByCurrency(instruments), id: \.currency) { group in
                        currencyGroupHeader(group.currency)
                        ForEach(group.instruments, id: \.self) { instrument in
                            pairRow(instrument: instrument, scopeKey: group.currency)
                        }
                    }
                }
            }
        }
    }

    private var pairsHeader: some View {
        HStack(spacing: 6) {
            Text("Pairs")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            Picker("", selection: $settings.pairsGroupingMode) {
                Text("A-Z").tag(PairsGroupingMode.alphabetical)
                Text("Group").tag(PairsGroupingMode.byCurrency)
            }
            .pickerStyle(.segmented)
            .controlSize(.mini)
            .fixedSize()
            .help("Sort pairs alphabetically, or group by currency")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func currencyGroupHeader(_ currency: String) -> some View {
        Text(currency)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    /// Buckets each instrument under every recognized currency it contains
    /// (base AND quote), in alphabetical currency order. EURUSD therefore
    /// appears under both EUR and USD. Currencies with zero matching
    /// instruments are omitted. Pure — exposed `static` for unit testing.
    static func instrumentsByCurrency(_ instruments: [String])
        -> [(currency: String, instruments: [String])]
    {
        let currencies = Array(CurrencyCorrelation.pairs.keys).sorted()
        var result: [(currency: String, instruments: [String])] = []
        for currency in currencies {
            let matches = instruments.filter { instrument in
                CurrencyCorrelation.currencies(from: instrument).contains(currency)
            }
            if !matches.isEmpty {
                result.append((currency: currency, instruments: matches))
            }
        }
        return result
    }

    private func sortedInstruments() -> [String] {
        // Union of (server-provided list) and (instruments already in tabs from
        // saved state). Saved-state-only instruments may appear if the server
        // hasn't returned its instrument list yet, or if the user has a tab for
        // an instrument the server stopped subscribing to.
        var set = Set(workspace.availableInstruments)
        for tab in workspace.tabs {
            if case .chart(let vm) = tab.content {
                set.insert(vm.currentInstrument)
            }
        }
        return Array(set).sorted()
    }

    /// Badge shown on a pair row while a visual position tool is open on it,
    /// so the user can find their way back. Pure mapping (color-free) for tests.
    enum VisualOrderBadge { case buy, sell }

    static func visualOrderBadge(for state: VisualOrderState?) -> VisualOrderBadge? {
        guard let state else { return nil }
        switch state.direction {
        case "BUY":  return .buy
        case "SELL": return .sell
        default:     return nil
        }
    }

    private func pairRow(instrument: String, scopeKey: String? = nil) -> some View {
        let tab = chartTab(for: instrument)
        let key = scopeKey.map { "pair:\($0):\(instrument)" } ?? "pair:\(instrument)"
        let isHovered = hoveredKey == key
        let isSelected = tab?.id == workspace.selectedTabID
        let dot = pairDotColor(instrument: instrument, chartTab: tab)
        let periodLabel: String
        if let tab, case .chart(let vm) = tab.content {
            periodLabel = ChartViewModel.availablePeriods.first { $0.value == vm.currentPeriod }?.label ?? vm.currentPeriod
        } else {
            periodLabel = ""
        }
        let mtfTab = multiTimeframeTab(for: instrument)
        let mtfSelected = mtfTab?.id == workspace.selectedTabID
        // Reading visualOrders here makes the row re-render when a tool
        // opens/cancels/confirms (TradingViewModel is @Observable).
        let badge = Self.visualOrderBadge(for: workspace.trading.visualOrders[instrument])

        return HStack(spacing: 6) {
            Circle()
                .fill(dot)
                .frame(width: 6, height: 6)

            Text(formatInstrument(instrument))
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(tab == nil ? 0.55 : 1.0)

            Spacer()

            if let badge {
                Image(systemName: badge == .buy ? "arrowtriangle.up.fill"
                                                : "arrowtriangle.down.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(badge == .buy ? Color.green : Color.red)
                    .help("\(badge == .buy ? "Buy" : "Sell") order being placed on \(formatInstrument(instrument))")
                    .accessibilityLabel("\(badge == .buy ? "Buy" : "Sell") order in progress")
            }

            if !periodLabel.isEmpty {
                Text(periodLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
            }

            Button(action: {
                workspace.selectOrCreateMultiTimeframeTab(instrument: instrument)
            }) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 11, weight: mtfSelected ? .semibold : .regular))
                    .foregroundStyle(mtfSelected
                                     ? Color.accentColor
                                     : Color.secondary.opacity(mtfTab != nil ? 1.0 : 0.45))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Multi-Timeframe view for \(formatInstrument(instrument))")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.18)
                      : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.selectOrCreateChartTab(instrument: instrument)
        }
        .onHover { hovering in
            hoveredKey = hovering ? key : (hoveredKey == key ? nil : hoveredKey)
        }
    }

    private func multiTimeframeTab(for instrument: String) -> WorkspaceViewModel.Tab? {
        workspace.tabs.first {
            if case .multiTimeframe(let vm) = $0.content { return vm.instrument == instrument }
            return false
        }
    }

    private func chartTab(for instrument: String) -> WorkspaceViewModel.Tab? {
        workspace.tabs.first {
            if case .chart(let vm) = $0.content { return vm.currentInstrument == instrument }
            return false
        }
    }

    /// Aggregates live state across every VM that holds this instrument:
    /// the dedicated chart tab (if any) plus correlation and multi-TF children
    /// that include this pair. Green if any source is connected, yellow if any
    /// has bars loaded, gray otherwise.
    private func pairDotColor(instrument: String, chartTab: WorkspaceViewModel.Tab?) -> Color {
        var anyConnected = false
        var anyBars = false

        if let tab = chartTab, case .chart(let vm) = tab.content {
            anyConnected = anyConnected || vm.isConnected
            anyBars = anyBars || !vm.bars.isEmpty
        }

        for tab in workspace.tabs {
            switch tab.content {
            case .correlation(let cvm):
                for child in cvm.chartViewModels where child.currentInstrument == instrument {
                    anyConnected = anyConnected || child.isConnected
                    anyBars = anyBars || !child.bars.isEmpty
                }
            case .multiTimeframe(let mvm) where mvm.instrument == instrument:
                for child in mvm.chartViewModels {
                    anyConnected = anyConnected || child.isConnected
                    anyBars = anyBars || !child.bars.isEmpty
                }
            case .chart, .multiTimeframe:
                break
            }
        }

        if anyConnected { return .green }
        if anyBars { return .yellow }
        return .secondary.opacity(0.35)
    }

    // MARK: - Correlations

    private var correlationsSection: some View {
        Group {
            sectionHeader("Currency Correlations")
            ForEach(sortedCurrencies(), id: \.self) { currency in
                correlationRow(currency: currency)
            }
        }
    }

    private func sortedCurrencies() -> [String] {
        Array(CurrencyCorrelation.pairs.keys).sorted()
    }

    private func correlationRow(currency: String) -> some View {
        let tab = correlationTab(for: currency)
        let key = "corr:\(currency)"
        let isHovered = hoveredKey == key
        let isSelected = tab?.id == workspace.selectedTabID
        let info = correlationRowInfo(tab: tab)

        return rowView(
            key: key,
            label: "\(currency) ⊞",
            periodLabel: info.periodLabel,
            dotColor: info.dotColor,
            opacity: tab == nil ? 0.55 : 1.0,
            isSelected: isSelected,
            isHovered: isHovered
        )
        .onTapGesture {
            workspace.addCorrelationTab(currency: currency)
        }
        .onHover { hovering in
            hoveredKey = hovering ? key : (hoveredKey == key ? nil : hoveredKey)
        }
    }

    private func correlationTab(for currency: String) -> WorkspaceViewModel.Tab? {
        workspace.tabs.first {
            if case .correlation(let vm) = $0.content { return vm.currency == currency }
            return false
        }
    }

    private struct RowInfo {
        let periodLabel: String
        let dotColor: Color
    }

    private func correlationRowInfo(tab: WorkspaceViewModel.Tab?) -> RowInfo {
        guard let tab, case .correlation(let vm) = tab.content else {
            return RowInfo(periodLabel: "", dotColor: .secondary.opacity(0.35))
        }
        let label = ChartViewModel.availablePeriods.first { $0.value == vm.currentPeriod }?.label ?? vm.currentPeriod
        let anyConnected = vm.chartViewModels.contains { $0.isConnected }
        let anyBars = vm.chartViewModels.contains { !$0.bars.isEmpty }
        let dot: Color = if anyConnected {
            .green
        } else if anyBars {
            .yellow
        } else {
            .secondary.opacity(0.35)
        }
        return RowInfo(periodLabel: label, dotColor: dot)
    }

    // MARK: - Shared row

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func rowView(key: String, label: String, periodLabel: String,
                         dotColor: Color, opacity: Double,
                         isSelected: Bool, isHovered: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)

            Text(label)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(opacity)

            Spacer()

            if !periodLabel.isEmpty {
                Text(periodLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.18)
                      : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
    }
}
