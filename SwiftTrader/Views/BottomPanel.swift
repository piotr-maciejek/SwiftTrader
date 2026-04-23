import SwiftUI

struct BottomPanel: View {
    let trading: TradingViewModel
    @Bindable var tradeHistory: TradeHistoryViewModel
    @State private var tab: Tab = .open
    @State private var editingLabel: String?
    @State private var editingField: EditField?
    @State private var editText = ""

    private enum EditField { case stopLoss, takeProfit }
    private enum Tab: String, CaseIterable {
        case open, pending, history
        var label: String {
            switch self {
            case .open: return "Open Positions"
            case .pending: return "Pending Orders"
            case .history: return "History"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { t in
                        Text(t.label).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 380)
                .onChange(of: tab) { _, new in
                    if new == .history && tradeHistory.trades.isEmpty {
                        Task { await tradeHistory.reload() }
                    }
                }

                Spacer()

                if (tab == .open || tab == .pending), let error = trading.orderError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            switch tab {
            case .open:
                if trading.positions.isEmpty {
                    Text("No open positions")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    positionsList
                }
            case .pending:
                if trading.pendingOrders.isEmpty {
                    Text("No pending orders")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    pendingOrdersList
                }
            case .history:
                TradeHistoryView(vm: tradeHistory)
            }
        }
        .frame(height: 240)
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

    private func isEditing(_ position: Position, field: EditField) -> Bool {
        editingLabel == position.label && editingField == field
    }

    private func positionRow(_ position: Position) -> some View {
        HStack(spacing: 0) {
            cell(formatInstrument(position.instrument), width: 90)
            cell(position.direction, width: 50,
                 color: position.isBuy ? .green : .red)
            cell(String(format: "%.2f", position.amount * 10), width: 60)
            cell(String(format: "%.5f", position.openPrice), width: 80)

            // SL
            if isEditing(position, field: .stopLoss) {
                TextField("", text: $editText)
                    .id("\(position.label)-stopLoss")
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 80)
                    .onSubmit { commitEdit(for: position) }
                    .onExitCommand { cancelEdit() }
            } else {
                Text(position.stopLoss == 0 ? "—" : String(format: "%.5f", position.stopLoss))
                    .foregroundStyle(position.stopLoss == 0 ? .tertiary : .primary)
                    .frame(width: 80, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { startEdit(position, field: .stopLoss, value: position.stopLoss) }
            }

            // TP
            if isEditing(position, field: .takeProfit) {
                TextField("", text: $editText)
                    .id("\(position.label)-takeProfit")
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 80)
                    .onSubmit { commitEdit(for: position) }
                    .onExitCommand { cancelEdit() }
            } else {
                Text(position.takeProfit == 0 ? "—" : String(format: "%.5f", position.takeProfit))
                    .foregroundStyle(position.takeProfit == 0 ? .tertiary : .primary)
                    .frame(width: 80, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { startEdit(position, field: .takeProfit, value: position.takeProfit) }
            }

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

    private var pendingOrdersList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                headerCell("Instrument", width: 90)
                headerCell("Side", width: 50)
                headerCell("Type", width: 90)
                headerCell("Amount", width: 60)
                headerCell("Entry", width: 80)
                headerCell("SL", width: 80)
                headerCell("TP", width: 80)
                Spacer()
                headerCell("", width: 60)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.05))

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(trading.pendingOrders) { order in
                        pendingOrderRow(order)
                        Divider()
                    }
                }
            }
        }
    }

    private func pendingOrderRow(_ order: PendingOrder) -> some View {
        HStack(spacing: 0) {
            cell(formatInstrument(order.instrument), width: 90)
            cell(order.direction, width: 50,
                 color: order.isBuy ? .green : .red)
            cell(formatOrderType(order.orderType), width: 90)
            cell(String(format: "%.2f", order.amount * 10), width: 60)
            cell(String(format: "%.5f", order.openPrice), width: 80)

            // SL
            if editingLabel == order.label && editingField == .stopLoss {
                TextField("", text: $editText)
                    .id("\(order.label)-stopLoss")
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 80)
                    .onSubmit { commitPendingEdit(for: order) }
                    .onExitCommand { cancelEdit() }
            } else {
                Text(order.stopLoss == 0 ? "—" : String(format: "%.5f", order.stopLoss))
                    .foregroundStyle(order.stopLoss == 0 ? .tertiary : .primary)
                    .frame(width: 80, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editText = order.stopLoss == 0 ? "" : String(format: "%.5f", order.stopLoss)
                        editingLabel = order.label
                        editingField = .stopLoss
                    }
            }

            // TP
            if editingLabel == order.label && editingField == .takeProfit {
                TextField("", text: $editText)
                    .id("\(order.label)-takeProfit")
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 80)
                    .onSubmit { commitPendingEdit(for: order) }
                    .onExitCommand { cancelEdit() }
            } else {
                Text(order.takeProfit == 0 ? "—" : String(format: "%.5f", order.takeProfit))
                    .foregroundStyle(order.takeProfit == 0 ? .tertiary : .primary)
                    .frame(width: 80, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editText = order.takeProfit == 0 ? "" : String(format: "%.5f", order.takeProfit)
                        editingLabel = order.label
                        editingField = .takeProfit
                    }
            }

            Spacer()

            Button("Cancel") {
                Task { await trading.closePosition(label: order.label) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.red)
            .frame(width: 60)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .font(.system(size: 11, design: .monospaced))
    }

    private func commitPendingEdit(for order: PendingOrder) {
        guard editingLabel == order.label, let field = editingField else { return }
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let val = Double(trimmed) else {
            cancelEdit()
            return
        }
        let latest = trading.pendingOrders.first(where: { $0.label == order.label }) ?? order
        switch field {
        case .stopLoss:
            Task { await trading.modifyPosition(label: latest.label, stopLoss: val, takeProfit: latest.takeProfit) }
        case .takeProfit:
            Task { await trading.modifyPosition(label: latest.label, stopLoss: latest.stopLoss, takeProfit: val) }
        }
        cancelEdit()
    }

    private func formatOrderType(_ type: String) -> String {
        type.replacingOccurrences(of: "_", with: " ")
    }

    private func startEdit(_ position: Position, field: EditField, value: Double) {
        editText = value == 0 ? "" : String(format: "%.5f", value)
        editingLabel = position.label
        editingField = field
    }

    private func cancelEdit() {
        editingLabel = nil
        editingField = nil
    }

    /// Commits using `editingField` at action time so a reused macOS `TextField` cannot call the wrong handler.
    private func commitEdit(for position: Position) {
        guard editingLabel == position.label, let field = editingField else { return }
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let val = Double(trimmed) else {
            cancelEdit()
            return
        }
        let latest = trading.positions.first(where: { $0.label == position.label }) ?? position
        switch field {
        case .stopLoss:
            Task { await trading.modifyPosition(label: latest.label, stopLoss: val, takeProfit: latest.takeProfit) }
        case .takeProfit:
            Task { await trading.modifyPosition(label: latest.label, stopLoss: latest.stopLoss, takeProfit: val) }
        }
        cancelEdit()
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
