import SwiftUI

struct TradeHistoryView: View {
    @Bindable var vm: TradeHistoryViewModel

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
            summaryBar
            Divider()
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
        return HStack(spacing: 16) {
            summaryCell(label: "Trades", value: "\(vm.trades.count)")
            summaryCell(label: "Wins",   value: "\(vm.winCount)")
            summaryCell(label: "Losses", value: "\(vm.lossCount)")
            summaryCell(label: "Win rate",
                        value: String(format: "%.0f%%", vm.winRate * 100))
            summaryCell(label: "Net P&L",
                        value: String(format: "%.2f", total),
                        color: total >= 0 ? .green : .red)
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
                    headerCell("Amount", width: 80)
                    headerCell("Open", width: 80)
                    headerCell("Close", width: 80)
                    headerCell("Pips", width: 60)
                    headerCell("Net P&L", width: 80)
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
            cell(String(format: "%.2f", t.amount * 10), width: 80)
            cell(String(format: "%.5f", t.openPrice), width: 80)
            cell(String(format: "%.5f", t.closePrice), width: 80)
            cell(String(format: "%.1f", t.profitLossPips), width: 60,
                 color: t.profitLossPips >= 0 ? .green : .red)
            cell(String(format: "%.2f", t.profitLoss), width: 80,
                 color: t.profitLoss >= 0 ? .green : .red)
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
}
