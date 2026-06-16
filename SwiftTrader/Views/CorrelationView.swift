import SwiftUI

struct CorrelationView: View {
    let viewModel: CorrelationViewModel
    @Bindable var trading: TradingViewModel
    var onInstrumentTap: ((String) -> Void)?
    var onMultiTimeframeTap: ((String) -> Void)?

    private var count: Int { viewModel.chartViewModels.count }

    /// Column count for the grid. Currency grids keep their original layout (6–7 pairs); custom grids
    /// fit 2–6 pairs (2→2, 3→3, 4→2, 5→3, 6→3). Pure → unit-testable.
    static func gridColumns(count: Int, isCurrency: Bool) -> Int {
        if isCurrency { return count <= 6 ? 3 : 4 }
        return count <= 3 ? max(count, 1) : (count == 4 ? 2 : 3)
    }

    private var columns: Int {
        Self.gridColumns(count: count, isCurrency: viewModel.baseCurrency != nil)
    }

    private var rows: Int {
        if viewModel.baseCurrency != nil { return 2 }
        return max(1, Int(ceil(Double(count) / Double(columns))))
    }

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
                                inverse: viewModel.baseCurrency.map {
                                    CurrencyCorrelation.isInverse(currency: $0, instrument: viewModel.instruments[index])
                                } ?? false
                            )
                        } else if index == columns * rows - 1, let base = viewModel.baseCurrency {
                            currencyLabelCell(base)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func currencyLabelCell(_ base: String) -> some View {
        Text(base)
            .font(.system(size: 48, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ChartView.chartBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.12)))
    }

    private func correlationCell(vm: ChartViewModel, instrument: String, inverse: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(formatInstrument(instrument))
                    .font(.system(size: 11, weight: .medium))
                    .underline()
                    .onTapGesture { onInstrumentTap?(instrument) }
                    .pointerStyle(.link)

                Button(action: { onMultiTimeframeTap?(instrument) }) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Multi-Timeframe view")

                if let last = vm.bars.last {
                    Text(String(format: "%.5f", last.close))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(last.close >= last.open ? .green : .red)
                }

                let tradingEnabled = !trading.isSubmitting
                    && !vm.bars.isEmpty
                    && vm.isConnected
                    && trading.visualOrders[instrument] == nil

                Button("B") {
                    trading.beginVisualOrder(direction: "BUY", instrument: instrument, bars: vm.bars)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tradingEnabled ? .white : .white.opacity(0.6))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tradingEnabled ? Color.green : Color.gray, in: RoundedRectangle(cornerRadius: 3))
                .disabled(!tradingEnabled)
                .help("Buy \(formatInstrument(instrument))")

                Button("S") {
                    trading.beginVisualOrder(direction: "SELL", instrument: instrument, bars: vm.bars)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tradingEnabled ? .white : .white.opacity(0.6))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tradingEnabled ? Color.red : Color.gray, in: RoundedRectangle(cornerRadius: 3))
                .disabled(!tradingEnabled)
                .help("Sell \(formatInstrument(instrument))")

                Spacer()

                // Server mode: soft + hard. Native mode: one orange "hard" button only.
                if AppSettings.shared.dataProvider == .server {
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
                }

                Button(action: { vm.hardRefresh() }) {
                    Group {
                        if vm.isRefreshingCache && AppSettings.shared.dataProvider == .native {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(width: 12, height: 12)
                }
                .buttonStyle(.borderless)
                .disabled(vm.isRefreshingCache)
                .help(AppSettings.shared.dataProvider == .native
                    ? "Refresh — wipe local cache for \(formatInstrument(instrument)) and re-fetch"
                    : "Hard refresh — purge cache AND reconnect (~5–30s outage)")

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
                onScrollToLiveEdge: { vm.jumpToLiveEdge() },
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
                onModifyPendingEntry: { label, trigger in
                    Task { await trading.modifyPendingEntry(label: label, trigger: trigger) }
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
                visualOrderQuoteRate: trading.quoteToAccountRate(for: instrument) ?? 1,
                chartSide: vm.currentSide,
                showBidAskLines: vm.showBidAsk,
                isSubmittingOrder: trading.isSubmitting,
                externalCursorTime: viewModel.sharedCursorTime,
                onCursorChange: { time in viewModel.sharedCursorTime = time },
                drawings: vm.drawings,
                drawingTool: vm.drawingTool,
                selectedDrawingID: vm.selectedDrawingID,
                onCommitDrawing: { drawing in vm.drawings.append(drawing) },
                onDeleteDrawing: { id in vm.drawings.removeAll { $0.id == id } },
                onClearAllDrawings: { vm.drawings = [] },
                onClearAllDrawingsAcrossCells: {
                    for cell in viewModel.chartViewModels { cell.drawings = [] }
                },
                onSetDrawingTool: { tool in vm.drawingTool = tool },
                onSelectDrawing: { id in vm.selectedDrawingID = id }
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
            : ChartView.chartBackground
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.12)))
    }
}
