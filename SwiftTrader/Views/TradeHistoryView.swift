import SwiftUI

struct TradeHistoryView: View {
    @Bindable var vm: TradeHistoryViewModel
    /// Per-position R-multiple / slippage metadata, joined by `positionId`.
    var metadata: [String: PositionMetadata] = [:]
    @Bindable var settings: AppSettings = AppSettings.shared

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = .current
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if !settings.incognitoMode {
                summaryBar
                Divider()
            }
            tradesBody
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Picker("Range", selection: $vm.preset) {
                ForEach(DateRangePreset.allCases) { p in
                    Text(p.label).tag(p)
                }
            }
            .labelsHidden()
            .frame(width: 160)
            .onChange(of: vm.preset) { _, _ in
                Task { await vm.reload() }
            }

            if vm.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await vm.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }

            if vm.preset == .custom {
                DatePicker("", selection: $vm.customFrom, displayedComponents: .date)
                    .labelsHidden()
                Text("to").font(.system(size: 11)).foregroundStyle(.secondary)
                DatePicker("", selection: $vm.customTo, displayedComponents: .date)
                    .labelsHidden()
                Button("Apply") { Task { await vm.reload() } }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }

            Spacer()

            if let err = vm.error {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var summaryBar: some View {
        let total = vm.totalNetProfit
        let totalR = PositionMetadata.totalRealizedR(trades: vm.trades, metadata: metadata)
        return HStack(spacing: 16) {
            summaryCell(label: "Trades", value: "\(vm.trades.count)")
            summaryCell(label: "Wins",   value: "\(vm.winCount)")
            summaryCell(label: "Losses", value: "\(vm.lossCount)")
            summaryCell(label: "Win rate",
                        value: String(format: "%.0f%%", vm.winRate * 100))
            summaryCell(label: "Net P&L",
                        value: String(format: "%.2f", total),
                        color: total >= 0 ? .green : .red)
            summaryCell(label: "Total R",
                        value: totalR.map { String(format: "%+.2fR", $0) } ?? "—",
                        color: totalR == nil ? .secondary : (totalR! >= 0 ? .green : .red))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.05))
    }

    private func summaryCell(label: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    @ViewBuilder
    private var tradesBody: some View {
        if vm.trades.isEmpty && !vm.isLoading {
            Text("No trades in range")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    headerCell("Close", width: 130)
                    headerCell("Instrument", width: 90)
                    headerCell("Side", width: 50)
                    if !settings.incognitoMode {
                        headerCell("Amount", width: 80)
                    }
                    headerCell("Open", width: 80)
                    headerCell("Close", width: 80)
                    headerCell("Pips", width: 60)
                    headerCell("R", width: 50)
                    headerCell("Slip", width: 56)
                    if !settings.incognitoMode {
                        headerCell("Net P&L", width: 80)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.05))
                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.trades.sorted(by: { $0.closeTime > $1.closeTime })) { t in
                            tradeRow(t)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func tradeRow(_ t: TradeRecord) -> some View {
        HStack(spacing: 0) {
            cell(Self.dateTimeFormatter.string(from: t.closeDate), width: 130)
            cell(formatInstrument(t.instrument), width: 90)
            cell(t.direction, width: 50, color: t.isBuy ? .green : .red)
            if !settings.incognitoMode {
                cell(String(format: "%.2f", t.amount * 10), width: 80)
            }
            cell(String(format: "%.5f", t.openPrice), width: 80)
            cell(String(format: "%.5f", t.closePrice), width: 80)
            cell(String(format: "%.1f", t.profitLossPips), width: 60,
                 color: t.profitLossPips >= 0 ? .green : .red)
            // R + slippage are pips/ratios, not money — shown even in incognito mode.
            rCell(metadata[t.positionId]?.realizedR(closePrice: t.closePrice), width: 50)
            slipCell(metadata[t.positionId]?.slippagePips, width: 56)
            if !settings.incognitoMode {
                cell(String(format: "%.2f", t.profitLoss), width: 80,
                     color: t.profitLoss >= 0 ? .green : .red)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .font(.system(size: 11, design: .monospaced))
    }

    private func headerCell(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
    }

    private func cell(_ text: String, width: CGFloat, color: Color = .primary) -> some View {
        Text(text)
            .foregroundStyle(color)
            .frame(width: width, alignment: .leading)
    }

    /// Realized R-multiple: signed, sign-colored; "—" when metadata is missing or risk is undefined.
    @ViewBuilder
    private func rCell(_ r: Double?, width: CGFloat) -> some View {
        if let r {
            Text(String(format: "%.2fR", r))
                .foregroundStyle(r >= 0 ? Color.green : Color.red)
                .frame(width: width, alignment: .leading)
        } else {
            Text("—").foregroundStyle(.tertiary).frame(width: width, alignment: .leading)
        }
    }

    /// Slippage in pips: positive (worse fill) red, ≤0 green; "—" when absent.
    @ViewBuilder
    private func slipCell(_ pips: Double?, width: CGFloat) -> some View {
        if let pips {
            Text(String(format: "%.1f", pips))
                .foregroundStyle(pips > 0 ? Color.red : Color.green)
                .frame(width: width, alignment: .leading)
        } else {
            Text("—").foregroundStyle(.tertiary).frame(width: width, alignment: .leading)
        }
    }
}
