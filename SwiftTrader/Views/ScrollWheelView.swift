import SwiftUI
import AppKit

struct CrosshairState: Equatable {
    let barIndex: Int
    let mouseY: CGFloat
}

struct ChartInteractionView: NSViewRepresentable {
    @Binding var transform: ChartTransform
    let barCount: Int
    let chartWidth: CGFloat
    var onUserDrag: (() -> Void)?
    @Binding var crosshair: CrosshairState?

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
        context.coordinator.crosshair = $crosshair
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(transform: $transform, barCount: barCount, chartWidth: chartWidth, onUserDrag: onUserDrag, crosshair: $crosshair)
    }

    class Coordinator {
        var transform: Binding<ChartTransform>
        var barCount: Int
        var chartWidth: CGFloat
        var lastDragX: CGFloat = 0
        var onUserDrag: (() -> Void)?
        var crosshair: Binding<CrosshairState?>

        init(transform: Binding<ChartTransform>, barCount: Int, chartWidth: CGFloat, onUserDrag: (() -> Void)?, crosshair: Binding<CrosshairState?>) {
            self.transform = transform
            self.barCount = barCount
            self.chartWidth = chartWidth
            self.onUserDrag = onUserDrag
            self.crosshair = crosshair
        }

        func clampOffset(_ offset: CGFloat) -> CGFloat {
            let totalWidth = CGFloat(barCount) * transform.wrappedValue.candleSlotWidth
            let maxOffset = max(0, totalWidth - chartWidth / 2)
            return min(maxOffset, max(0, offset))
        }

        func snappedBarIndex(mouseX: CGFloat) -> Int {
            let slotWidth = transform.wrappedValue.candleSlotWidth
            let rawIndex = (mouseX + transform.wrappedValue.xOffset - slotWidth / 2) / slotWidth
            return max(0, min(barCount - 1, Int(round(rawIndex))))
        }
    }

    class ChartInteractionNSView: NSView {
        weak var coordinator: Coordinator?

        override var acceptsFirstResponder: Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                owner: self, userInfo: nil
            )
            addTrackingArea(area)
        }

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
            guard let coord = coordinator else { return }
            coord.lastDragX = event.locationInWindow.x
            coord.crosshair.wrappedValue = nil
        }

        override func mouseUp(with event: NSEvent) {
            mouseMoved(with: event)
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

        override func mouseMoved(with event: NSEvent) {
            guard let coord = coordinator, coord.barCount > 0 else { return }
            let location = convert(event.locationInWindow, from: nil)
            let flippedY = bounds.height - location.y
            let barIndex = coord.snappedBarIndex(mouseX: location.x)
            coord.crosshair.wrappedValue = CrosshairState(barIndex: barIndex, mouseY: flippedY)
        }

        override func mouseEntered(with event: NSEvent) {
            NSCursor.crosshair.push()
        }

        override func mouseExited(with event: NSEvent) {
            NSCursor.pop()
            coordinator?.crosshair.wrappedValue = nil
        }
    }
}
