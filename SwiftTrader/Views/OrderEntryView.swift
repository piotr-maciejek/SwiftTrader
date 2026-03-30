import SwiftUI

struct OrderEntryView: View {
    let direction: String
    let instrument: String
    let currentPrice: Double
    @Binding var amount: Double
    let onSubmit: (Double, Double, Double) -> Void

    @State private var amountText: String = ""
    @State private var stopLossText: String = ""
    @State private var takeProfitText: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(direction)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(direction == "BUY" ? .green : .red)
                Text(formatInstrument(instrument))
                    .font(.system(size: 13, weight: .medium))
            }

            HStack(spacing: 4) {
                Text("Amount")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                Button(action: { adjustAmount(by: -0.001) }) {
                    Image(systemName: "minus")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                TextField("e.g. 0.001", text: $amountText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .multilineTextAlignment(.center)
                Button(action: { adjustAmount(by: 0.001) }) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }

            HStack {
                Text("Price:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(String(format: "%.5f", currentPrice))
                    .font(.system(size: 11, design: .monospaced))
            }

            Divider()

            LabeledField(label: "Stop Loss", text: $stopLossText, placeholder: "e.g. \(String(format: "%.5f", suggestedSL))")
            LabeledField(label: "Take Profit", text: $takeProfitText, placeholder: "e.g. \(String(format: "%.5f", suggestedTP))")

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Confirm") {
                    let amt = Double(amountText) ?? amount
                    let sl = Double(stopLossText) ?? 0
                    let tp = Double(takeProfitText) ?? 0
                    amount = amt
                    onSubmit(amt, sl, tp)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(Double(amountText) == nil || Double(stopLossText) == nil || Double(takeProfitText) == nil)
            }
        }
        .padding()
        .frame(width: 260)
        .onAppear {
            amountText = String(format: "%g", amount)
            stopLossText = String(format: "%.5f", suggestedSL)
            takeProfitText = String(format: "%.5f", suggestedTP)
        }
    }

    private func adjustAmount(by delta: Double) {
        let current = Double(amountText) ?? amount
        let newAmount = max(0.001, current + delta)
        amountText = String(format: "%g", newAmount)
    }

    private var suggestedSL: Double {
        let offset = direction == "BUY" ? -0.0020 : 0.0020
        return currentPrice + offset
    }

    private var suggestedTP: Double {
        let offset = direction == "BUY" ? 0.0060 : -0.0060
        return currentPrice + offset
    }

}

private struct LabeledField: View {
    let label: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
        }
    }
}
