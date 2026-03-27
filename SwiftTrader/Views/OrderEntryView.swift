import SwiftUI

struct OrderEntryView: View {
    let direction: String
    let instrument: String
    let currentPrice: Double
    let onSubmit: (Double, Double) -> Void

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

            HStack {
                Text("Amount:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("0.001")
                    .font(.system(size: 11, design: .monospaced))
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
                    let sl = Double(stopLossText) ?? 0
                    let tp = Double(takeProfitText) ?? 0
                    onSubmit(sl, tp)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(Double(stopLossText) == nil || Double(takeProfitText) == nil)
            }
        }
        .padding()
        .frame(width: 260)
        .onAppear {
            stopLossText = String(format: "%.5f", suggestedSL)
            takeProfitText = String(format: "%.5f", suggestedTP)
        }
    }

    private var suggestedSL: Double {
        let offset = direction == "BUY" ? -0.0020 : 0.0020
        return currentPrice + offset
    }

    private var suggestedTP: Double {
        let offset = direction == "BUY" ? 0.0060 : -0.0060
        return currentPrice + offset
    }

    private func formatInstrument(_ instrument: String) -> String {
        guard instrument.count == 6 else { return instrument }
        let idx = instrument.index(instrument.startIndex, offsetBy: 3)
        return "\(instrument[..<idx])/\(instrument[idx...])"
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
