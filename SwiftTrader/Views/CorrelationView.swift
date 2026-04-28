import SwiftUI

struct CorrelationView: View {
    let viewModel: CorrelationViewModel
    var onInstrumentTap: ((String) -> Void)?

    private let columns = 3
    private let rows = 2

    var body: some View {
        Grid(horizontalSpacing: 1, verticalSpacing: 1) {
            ForEach(0..<rows, id: \.self) { row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { col in
                        let index = row * columns + col
                        if index < viewModel.chartViewModels.count {
                            correlationCell(
                                vm: viewModel.chartViewModels[index],
                                instrument: viewModel.instruments[index],
                                inverse: CurrencyCorrelation.isInverse(
                                    currency: viewModel.currency,
                                    instrument: viewModel.instruments[index]
                                )
                            )
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func correlationCell(vm: ChartViewModel, instrument: String, inverse: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(formatInstrument(instrument))
                    .font(.system(size: 11, weight: .medium))
                    .underline()
                    .onTapGesture { onInstrumentTap?(instrument) }
                    .pointerStyle(.link)

                if let last = vm.bars.last {
                    Text(String(format: "%.5f", last.close))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(last.close >= last.open ? .green : .red)
                }

                Spacer()

                Button(action: { vm.refreshCache() }) {
                    Group {
                        if vm.isRefreshingCache {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise.circle")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 12, height: 12)
                }
                .buttonStyle(.borderless)
                .disabled(vm.isRefreshingCache)
                .help("Refresh cache for \(formatInstrument(instrument))")

                Button(action: { vm.hardRefresh() }) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.borderless)
                .disabled(vm.isRefreshingCache)
                .help("Hard refresh — purge cache AND reconnect (~5–30s outage)")

                Circle()
                    .fill(vm.isConnected ? .green : (vm.bars.isEmpty ? .red : .yellow))
                    .frame(width: 5, height: 5)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)

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
                showATR: vm.showATR,
                atrPeriod: vm.atrPeriod,
                atrPips: vm.atrPips,
                todayATRPercent: vm.todayATRPercent
            )
            .overlay {
                if vm.bars.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .background(inverse
            ? Color(red: 0.15, green: 0.15, blue: 0.25)
            : Color(nsColor: .controlBackgroundColor)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.12)))
    }
}
