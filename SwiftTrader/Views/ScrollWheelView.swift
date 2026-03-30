import SwiftUI
import AppKit

struct CrosshairState: Equatable {
    let barIndex: Int
    let mouseY: CGFloat
}

struct SLTPLineHit {
    let positionLabel: String
    let field: Field
    let originalPrice: Double

    enum Field: Equatable { case stopLoss, takeProfit }
}

struct DragPreviewState: Equatable {
    let positionLabel: String
    let field: SLTPLineHit.Field
    let currentY: CGFloat
    let currentPrice: Double
}

/// Snapshot at drag end; confirmation uses this so macOS `confirmationDialog` cannot see stale `dragPreview` / failed lookups.
struct PendingChartSLTPEdit: Equatable {
    let label: String
    let stopLoss: Double
    let takeProfit: Double
    let confirmationMessage: String
}

struct ChartInteractionView: NSViewRepresentable {
    @Binding var transform: ChartTransform
    let barCount: Int
    let chartWidth: CGFloat
    var onUserDrag: (() -> Void)?
    @Binding var crosshair: CrosshairState?
    var positions: [Position] = []
    var chartHeight: CGFloat = 0
    var priceRange: (min: Double, max: Double) = (0, 1)
    @Binding var dragPreview: DragPreviewState?
    @Binding var pendingSLTPEdit: PendingChartSLTPEdit?

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
        context.coordinator.positions = positions
        context.coordinator.chartHeight = chartHeight
        context.coordinator.priceRange = priceRange
        context.coordinator.dragPreview = $dragPreview
        context.coordinator.pendingSLTPEdit = $pendingSLTPEdit
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(transform: $transform, barCount: barCount, chartWidth: chartWidth,
                    onUserDrag: onUserDrag, crosshair: $crosshair, dragPreview: $dragPreview,
                    pendingSLTPEdit: $pendingSLTPEdit)
    }

    class Coordinator {
        var transform: Binding<ChartTransform>
        var barCount: Int
        var chartWidth: CGFloat
        var lastDragX: CGFloat = 0
        var onUserDrag: (() -> Void)?
        var crosshair: Binding<CrosshairState?>
        var positions: [Position] = []
        var chartHeight: CGFloat = 0
        var priceRange: (min: Double, max: Double) = (0, 1)
        var dragPreview: Binding<DragPreviewState?>
        var pendingSLTPEdit: Binding<PendingChartSLTPEdit?>

        var activeDrag: SLTPLineHit?
        var isDraggingSLTP = false

        init(transform: Binding<ChartTransform>, barCount: Int, chartWidth: CGFloat,
             onUserDrag: (() -> Void)?, crosshair: Binding<CrosshairState?>,
             dragPreview: Binding<DragPreviewState?>,
             pendingSLTPEdit: Binding<PendingChartSLTPEdit?>) {
            self.transform = transform
            self.barCount = barCount
            self.chartWidth = chartWidth
            self.onUserDrag = onUserDrag
            self.crosshair = crosshair
            self.dragPreview = dragPreview
            self.pendingSLTPEdit = pendingSLTPEdit
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

        func yForPrice(_ price: Double) -> CGFloat {
            let normalized = (price - priceRange.min) / (priceRange.max - priceRange.min)
            return chartHeight * (1 - CGFloat(normalized))
        }

        func priceForY(_ y: CGFloat) -> Double {
            let normalized = 1.0 - Double(y / chartHeight)
            return priceRange.min + normalized * (priceRange.max - priceRange.min)
        }

        func hitTestSLTPLine(mouseY: CGFloat) -> SLTPLineHit? {
            let threshold: CGFloat = 5.0
            for pos in positions {
                if pos.stopLoss != 0 {
                    let slY = yForPrice(pos.stopLoss)
                    if abs(mouseY - slY) <= threshold {
                        return SLTPLineHit(positionLabel: pos.label, field: .stopLoss,
                                           originalPrice: pos.stopLoss)
                    }
                }
                if pos.takeProfit != 0 {
                    let tpY = yForPrice(pos.takeProfit)
                    if abs(mouseY - tpY) <= threshold {
                        return SLTPLineHit(positionLabel: pos.label, field: .takeProfit,
                                           originalPrice: pos.takeProfit)
                    }
                }
            }
            return nil
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
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate],
                owner: self, userInfo: nil
            )
            addTrackingArea(area)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .crosshair)
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
            let location = convert(event.locationInWindow, from: nil)
            let flippedY = bounds.height - location.y

            // Check if clicking on an SL/TP line
            let hit = coord.hitTestSLTPLine(mouseY: flippedY)
            if let hit {
                coord.activeDrag = hit
                coord.isDraggingSLTP = true
                coord.crosshair.wrappedValue = nil
                return
            }

            coord.lastDragX = event.locationInWindow.x
            coord.isDraggingSLTP = false
            coord.crosshair.wrappedValue = nil
        }

        override func mouseUp(with event: NSEvent) {
            guard let coord = coordinator else { return }

            if coord.isDraggingSLTP {
                coord.activeDrag = nil
                coord.isDraggingSLTP = false
                if let preview = coord.dragPreview.wrappedValue,
                   let pos = coord.positions.first(where: { $0.label == preview.positionLabel }) {
                    let newSL = preview.field == .stopLoss ? preview.currentPrice : pos.stopLoss
                    let newTP = preview.field == .takeProfit ? preview.currentPrice : pos.takeProfit
                    let fieldName = preview.field == .stopLoss ? "SL" : "TP"
                    let message = "Move \(fieldName) to \(String(format: "%.5f", preview.currentPrice))?"
                    coord.pendingSLTPEdit.wrappedValue = PendingChartSLTPEdit(
                        label: pos.label,
                        stopLoss: newSL,
                        takeProfit: newTP,
                        confirmationMessage: message
                    )
                } else {
                    coord.dragPreview.wrappedValue = nil
                }
                return
            }

            coord.isDraggingSLTP = false
            coord.activeDrag = nil
            mouseMoved(with: event)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let coord = coordinator else { return }

            if coord.isDraggingSLTP, let hit = coord.activeDrag {
                let location = convert(event.locationInWindow, from: nil)
                let flippedY = bounds.height - location.y
                let clampedY = min(max(flippedY, 0), coord.chartHeight)
                let newPrice = coord.priceForY(clampedY)
                coord.dragPreview.wrappedValue = DragPreviewState(
                    positionLabel: hit.positionLabel,
                    field: hit.field,
                    currentY: clampedY,
                    currentPrice: newPrice
                )
                return
            }

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

            // Change cursor when near SL/TP lines
            if coord.hitTestSLTPLine(mouseY: flippedY) != nil {
                NSCursor.resizeUpDown.set()
            } else {
                NSCursor.crosshair.set()
            }

            let barIndex = coord.snappedBarIndex(mouseX: location.x)
            coord.crosshair.wrappedValue = CrosshairState(barIndex: barIndex, mouseY: flippedY)
        }

        override func mouseEntered(with event: NSEvent) {}

        override func mouseExited(with event: NSEvent) {
            coordinator?.crosshair.wrappedValue = nil
        }
    }
}
