import SwiftUI

struct CorrelationView: View {
    let viewModel: CorrelationViewModel

    private let columns = 3
    private let rows = 2

    var body: some View {
        Grid(horizontalSpacing: 1, verticalSpacing: 1) {
            ForEach(0..<rows, id: \.self) { row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { col in
                        let index = row * columns + col
                        if index < viewModel.chartViewModels.count {
                            correlationCell(
                                vm: viewModel.chartViewModels[index],
                                instrument: viewModel.instruments[index]
                            )
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func correlationCell(vm: ChartViewModel, instrument: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(formatInstrument(instrument))
                    .font(.system(size: 11, weight: .medium))

                if let last = vm.bars.last {
                    Text(String(format: "%.5f", last.close))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(last.close >= last.open ? .green : .red)
                }

                Spacer()

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
                showSessions: vm.showSessions
            )
            .overlay {
                if vm.bars.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.12)))
    }
}
