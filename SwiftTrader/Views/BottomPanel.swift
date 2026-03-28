import SwiftUI

struct BottomPanel: View {
    let trading: TradingViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Open Positions")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                if let error = trading.orderError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            if trading.positions.isEmpty {
                Text("No open positions")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                positionsList
            }
        }
        .frame(height: 180)
    }

    private var positionsList: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                headerCell("Instrument", width: 90)
                headerCell("Side", width: 50)
                headerCell("Amount", width: 60)
                headerCell("Open", width: 80)
                headerCell("SL", width: 80)
                headerCell("TP", width: 80)
                headerCell("P&L", width: 80)
                headerCell("Pips", width: 60)
                Spacer()
                headerCell("", width: 50)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.05))

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(trading.positions) { position in
                        positionRow(position)
                        Divider()
                    }
                }
            }
        }
    }

    private func positionRow(_ position: Position) -> some View {
        HStack(spacing: 0) {
            cell(formatInstrument(position.instrument), width: 90)
            cell(position.direction, width: 50,
                 color: position.isBuy ? .green : .red)
            cell(String(format: "%.3f", position.amount), width: 60)
            cell(String(format: "%.5f", position.openPrice), width: 80)
            cell(String(format: "%.5f", position.stopLoss), width: 80)
            cell(String(format: "%.5f", position.takeProfit), width: 80)
            cell(String(format: "%.2f", position.profitLoss), width: 80,
                 color: position.profitLoss >= 0 ? .green : .red)
            cell(String(format: "%.1f", position.profitLossPips), width: 60,
                 color: position.profitLossPips >= 0 ? .green : .red)

            Spacer()

            Button("Close") {
                Task { await trading.closePosition(label: position.label) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.red)
            .frame(width: 50)
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
