import SwiftUI

struct ATRPopover: View {
    @Binding var showATR: Bool
    @Binding var atrPeriod: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show ATR", isOn: $showATR)
                .font(.system(size: 12, weight: .medium))

            Divider()

            HStack(spacing: 8) {
                Text("Period")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                TextField("Period", value: $atrPeriod, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .font(.system(size: 11, design: .monospaced))
            }
        }
        .padding(12)
        .frame(width: 180)
    }
}
