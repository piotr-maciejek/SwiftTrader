import SwiftUI

struct RightPanel: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Market News")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            Text("No news available")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 260)
    }
}
