import SwiftUI

struct VolumeMAPopover: View {
    @Binding var showVolumeMA: Bool
    @Binding var volumeMA: EMALine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show Volume MA", isOn: $showVolumeMA)
                .font(.system(size: 12, weight: .medium))

            Divider()

            HStack(spacing: 8) {
                Text("Period")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                TextField("Period", value: $volumeMA.period, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .font(.system(size: 11, design: .monospaced))

                RoundedRectangle(cornerRadius: 3)
                    .fill(volumeMA.color)
                    .frame(width: 32, height: 4)
                    .onTapGesture {
                        let colors = EMALine.presetColors
                        if let idx = colors.firstIndex(where: { $0 == volumeMA.color }) {
                            volumeMA.color = colors[(idx + 1) % colors.count]
                        } else {
                            volumeMA.color = colors[0]
                        }
                    }
            }
        }
        .padding(12)
        .frame(width: 200)
    }
}
