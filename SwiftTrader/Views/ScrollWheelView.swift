import SwiftUI
import AppKit

struct ChartInteractionView: NSViewRepresentable {
    @Binding var transform: ChartTransform
    let barCount: Int
    let chartWidth: CGFloat
    var onUserDrag: (() -> Void)?

    func makeNSView(context: Context) -> ChartInteractionNSView {
        let view = ChartInteractionNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ChartInteractionNSView, context: Context) {
        context.coordinator.transform = $transform
        context.coordinator.barCount = barCount
        context.coordinator.chartWidth = chartWidth
        context.coordinator.onUserDrag = onUserDrag
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(transform: $transform, barCount: barCount, chartWidth: chartWidth, onUserDrag: onUserDrag)
    }

    class Coordinator {
        var transform: Binding<ChartTransform>
        var barCount: Int
        var chartWidth: CGFloat
        var lastDragX: CGFloat = 0
        var onUserDrag: (() -> Void)?

        init(transform: Binding<ChartTransform>, barCount: Int, chartWidth: CGFloat, onUserDrag: (() -> Void)?) {
            self.transform = transform
            self.barCount = barCount
            self.chartWidth = chartWidth
            self.onUserDrag = onUserDrag
        }

        func clampOffset(_ offset: CGFloat) -> CGFloat {
            let totalWidth = CGFloat(barCount) * transform.wrappedValue.candleSlotWidth
            // Allow scrolling past the end so the last bar can sit in the middle
            let maxOffset = max(0, totalWidth - chartWidth / 2)
            return min(maxOffset, max(0, offset))
        }
    }

    class ChartInteractionNSView: NSView {
        weak var coordinator: Coordinator?

        override var acceptsFirstResponder: Bool { true }

        override func scrollWheel(with event: NSEvent) {
            guard let coord = coordinator else { return }
            let zoomDelta = event.scrollingDeltaY * 0.02
            let oldScale = coord.transform.wrappedValue.xScale
            let newScale = max(0.3, min(5.0, oldScale + zoomDelta))

            let visibleEnd = coord.transform.wrappedValue.xOffset + coord.chartWidth
            let ratio = newScale / oldScale

            coord.transform.wrappedValue.xScale = newScale
            coord.transform.wrappedValue.xOffset = coord.clampOffset(visibleEnd * ratio - coord.chartWidth)
        }

        override func mouseDown(with event: NSEvent) {
            coordinator?.lastDragX = event.locationInWindow.x
        }

        override func mouseDragged(with event: NSEvent) {
            guard let coord = coordinator else { return }
            let currentX = event.locationInWindow.x
            let deltaX = currentX - coord.lastDragX
            coord.lastDragX = currentX
            coord.transform.wrappedValue.xOffset = coord.clampOffset(
                coord.transform.wrappedValue.xOffset - deltaX
            )
            coord.onUserDrag?()
        }
    }
}
