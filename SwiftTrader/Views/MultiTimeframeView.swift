import SwiftUI

struct MultiTimeframeView: View {
    @Bindable var viewModel: MultiTimeframeViewModel
    @Bindable var trading: TradingViewModel
    /// Tap a cell's period link to open a regular chart tab for the same
    /// instrument on that period.
    var onCellTap: ((_ instrument: String, _ period: String) -> Void)?

    var body: some View {
        Grid(horizontalSpacing: 1, verticalSpacing: 1) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(0..<2, id: \.self) { col in
                        let index = row * 2 + col
                        if index < viewModel.chartViewModels.count {
                            cell(
                                vm: viewModel.chartViewModels[index],
                                period: viewModel.period(at: index)
                            )
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func cell(vm: ChartViewModel, period: String) -> some View {
        let label = ChartViewModel.availablePeriods.first { $0.value == period }?.label ?? period
        let instrument = viewModel.instrument
        let tradingEnabled = !trading.isSubmitting && !vm.bars.isEmpty && vm.isConnected
            && trading.visualOrders[instrument] == nil

        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("\(formatInstrument(instrument)) \(label)")
                    .font(.system(size: 11, weight: .medium))
                    .underline()
                    .onTapGesture { onCellTap?(instrument, period) }
                    .pointerStyle(.link)

                if let last = vm.bars.last {
                    Text(String(format: "%.5f", last.close))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(last.close >= last.open ? .green : .red)
                }

                Spacer()

                Button("B") {
                    trading.beginVisualOrder(direction: "BUY", instrument: instrument, bars: vm.bars)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tradingEnabled ? .white : .white.opacity(0.5))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(tradingEnabled ? Color.green : Color.gray, in: RoundedRectangle(cornerRadius: 3))
                .disabled(!tradingEnabled)
                .help("Buy at \(label)")

                Button("S") {
                    trading.beginVisualOrder(direction: "SELL", instrument: instrument, bars: vm.bars)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tradingEnabled ? .white : .white.opacity(0.5))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(tradingEnabled ? Color.red : Color.gray, in: RoundedRectangle(cornerRadius: 3))
                .disabled(!tradingEnabled)
                .help("Sell at \(label)")

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
                .help("Refresh cache for \(formatInstrument(instrument)) \(label)")

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
                positions: trading.positions,
                pendingOrders: trading.pendingOrders,
                currentInstrument: instrument,
                showATR: vm.showATR,
                atrPeriod: vm.atrPeriod,
                atrPips: vm.atrPips,
                todayATRPercent: vm.todayATRPercent,
                onModifyPosition: { label, sl, tp in
                    Task { await trading.modifyPosition(label: label, stopLoss: sl, takeProfit: tp) }
                },
                visualOrder: trading.visualOrderWithLivePrice(
                    for: instrument,
                    currentPrice: vm.bars.last?.close,
                    barCount: vm.bars.count
                ),
                onConfirmVisualOrder: {
                    Task { await trading.confirmVisualOrder(instrument: instrument, livePrice: vm.bars.last?.close) }
                },
                onCancelVisualOrder: {
                    trading.cancelVisualOrder(instrument: instrument)
                },
                onUpdateVisualOrderSL: { price in
                    trading.updateVisualOrderSL(instrument: instrument, price: price, livePrice: vm.bars.last?.close)
                },
                onUpdateVisualOrderTP: { price in
                    trading.visualOrders[instrument]?.takeProfit = price
                },
                onUpdateVisualOrderEntry: { price in
                    trading.updateVisualOrderEntry(instrument: instrument, price: price)
                },
                onAdjustVisualOrderAmount: { delta in
                    trading.adjustVisualOrderAmount(instrument: instrument, by: delta)
                },
                onResetVisualOrderAmount: {
                    trading.resetVisualOrderAmount(instrument: instrument, livePrice: vm.bars.last?.close)
                },
                accountEquity: trading.account?.equity,
                visualOrderSpread: trading.spreads[instrument] ?? 0,
                isSubmittingOrder: trading.isSubmitting,
                externalCursorTime: viewModel.sharedCursorTime,
                onCursorChange: { time in viewModel.sharedCursorTime = time }
            )
            .overlay {
                if vm.bars.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .background(ChartView.chartBackground)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.12)))
    }
}
