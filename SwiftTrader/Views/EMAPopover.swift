import SwiftUI

struct EMAPopover: View {
    @Binding var showEMA: Bool
    @Binding var emaConfigs: [EMALine]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show EMAs", isOn: $showEMA)
                .font(.system(size: 12, weight: .medium))

            Divider()

            ForEach($emaConfigs) { $line in
                HStack(spacing: 8) {
                    TextField("Period", value: $line.period, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .font(.system(size: 11, design: .monospaced))

                    // Color swatch — cycles through presets on click
                    RoundedRectangle(cornerRadius: 3)
                        .fill(line.color)
                        .frame(width: 32, height: 4)
                        .onTapGesture {
                            let colors = EMALine.presetColors
                            if let idx = colors.firstIndex(where: { $0 == line.color }) {
                                line.color = colors[(idx + 1) % colors.count]
                            } else {
                                line.color = colors[0]
                            }
                        }

                    Button(action: {
                        emaConfigs.removeAll { $0.id == line.id }
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }

            if emaConfigs.count < 3 {
                Button(action: {
                    let usedColors = Set(emaConfigs.map(\.color))
                    let nextColor = EMALine.presetColors.first { !usedColors.contains($0) } ?? .yellow
                    emaConfigs.append(EMALine(period: 20, color: nextColor))
                }) {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .frame(width: 220)
    }
}
