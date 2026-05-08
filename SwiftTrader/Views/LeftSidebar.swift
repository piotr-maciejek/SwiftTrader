import SwiftUI

struct LeftSidebar: View {
    @Bindable var workspace: WorkspaceViewModel
    @State private var hoveredKey: String?

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    pairsSection
                    correlationsSection
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 220)
        .background(.bar)
    }

    // MARK: - Header

    private var sidebarHeader: some View {
        HStack(spacing: 4) {
            Picker("", selection: $workspace.sidebarSort) {
                Image(systemName: "chart.bar.xaxis").tag(SidebarSort.volume)
                Image(systemName: "textformat").tag(SidebarSort.alphabetical)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Sort by volume / alphabetical")

            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    // MARK: - Pairs

    private var pairsSection: some View {
        let instruments = sortedInstruments()
        return Group {
            sectionHeader("Pairs")
            if instruments.isEmpty {
                Text("Loading…")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            } else {
                ForEach(instruments, id: \.self) { instrument in
                    pairRow(instrument: instrument)
                }
            }
        }
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
        let all = Array(set)
        switch workspace.sidebarSort {
        case .volume:
            return all.sorted { a, b in
                let ar = FXVolumeRank.rank(pair: a), br = FXVolumeRank.rank(pair: b)
                if ar != br { return ar > br }
                return a < b
            }
        case .alphabetical:
            return all.sorted()
        }
    }

    private func pairRow(instrument: String) -> some View {
        let tab = chartTab(for: instrument)
        let key = "pair:\(instrument)"
        let isHovered = hoveredKey == key
        let isSelected = tab?.id == workspace.selectedTabID
        let dot = pairDotColor(instrument: instrument, chartTab: tab)
        let periodLabel: String
        if let tab, case .chart(let vm) = tab.content {
            periodLabel = ChartViewModel.availablePeriods.first { $0.value == vm.currentPeriod }?.label ?? vm.currentPeriod
        } else {
            periodLabel = ""
        }

        return rowView(
            key: key,
            label: formatInstrument(instrument),
            periodLabel: periodLabel,
            dotColor: dot,
            opacity: tab == nil ? 0.55 : 1.0,
            isSelected: isSelected,
            isHovered: isHovered
        )
        .onTapGesture {
            workspace.selectOrCreateChartTab(instrument: instrument)
        }
        .onHover { hovering in
            hoveredKey = hovering ? key : (hoveredKey == key ? nil : hoveredKey)
        }
    }

    private func chartTab(for instrument: String) -> WorkspaceViewModel.Tab? {
        workspace.tabs.first {
            if case .chart(let vm) = $0.content { return vm.currentInstrument == instrument }
            return false
        }
    }

    /// Aggregates live state across every VM that holds this instrument:
    /// the dedicated chart tab (if any) plus correlation children that include
    /// this pair. Green if any source is connected, yellow if any has bars
    /// loaded, gray otherwise.
    private func pairDotColor(instrument: String, chartTab: WorkspaceViewModel.Tab?) -> Color {
        var anyConnected = false
        var anyBars = false

        if let tab = chartTab, case .chart(let vm) = tab.content {
            anyConnected = anyConnected || vm.isConnected
            anyBars = anyBars || !vm.bars.isEmpty
        }

        for tab in workspace.tabs {
            if case .correlation(let cvm) = tab.content {
                for child in cvm.chartViewModels where child.currentInstrument == instrument {
                    anyConnected = anyConnected || child.isConnected
                    anyBars = anyBars || !child.bars.isEmpty
                }
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
        let all = Array(CurrencyCorrelation.pairs.keys)
        switch workspace.sidebarSort {
        case .volume:
            return all.sorted { a, b in
                let ar = FXVolumeRank.rank(currency: a), br = FXVolumeRank.rank(currency: b)
                if ar != br { return ar > br }
                return a < b
            }
        case .alphabetical:
            return all.sorted()
        }
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
