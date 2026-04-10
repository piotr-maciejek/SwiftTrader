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
    var visualOrder: VisualOrderState? = nil
    var onConfirmVisualOrder: (() -> Void)? = nil
    var onCancelVisualOrder: (() -> Void)? = nil
    var onUpdateVisualOrderSL: ((Double) -> Void)? = nil
    var onUpdateVisualOrderTP: ((Double) -> Void)? = nil
    var onAdjustVisualOrderAmount: ((Double) -> Void)? = nil

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
        context.coordinator.visualOrder = visualOrder
        context.coordinator.onConfirmVisualOrder = onConfirmVisualOrder
        context.coordinator.onCancelVisualOrder = onCancelVisualOrder
        context.coordinator.onUpdateVisualOrderSL = onUpdateVisualOrderSL
        context.coordinator.onUpdateVisualOrderTP = onUpdateVisualOrderTP
        context.coordinator.onAdjustVisualOrderAmount = onAdjustVisualOrderAmount
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

        // Visual order state
        var visualOrder: VisualOrderState?
        var onConfirmVisualOrder: (() -> Void)?
        var onCancelVisualOrder: (() -> Void)?
        var onUpdateVisualOrderSL: ((Double) -> Void)?
        var onUpdateVisualOrderTP: ((Double) -> Void)?
        var onAdjustVisualOrderAmount: ((Double) -> Void)?
        var isDraggingVisualSLTP = false
        var visualDragField: SLTPLineHit.Field?

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

        func hitTestVisualOrderLine(mouseY: CGFloat) -> SLTPLineHit.Field? {
            guard let vo = visualOrder else { return nil }
            let threshold: CGFloat = 5.0
            let slY = yForPrice(vo.stopLoss)
            if abs(mouseY - slY) <= threshold { return .stopLoss }
            let tpY = yForPrice(vo.takeProfit)
            if abs(mouseY - tpY) <= threshold { return .takeProfit }
            return nil
        }

        enum VisualOrderButton { case confirm, cancel, amountUp, amountDown }

        func hitTestVisualOrderButtons(mouseX: CGFloat, mouseY: CGFloat) -> VisualOrderButton? {
            guard let vo = visualOrder else { return nil }
            let slY = yForPrice(vo.stopLoss)
            let tpY = yForPrice(vo.takeProfit)
            let entryY = yForPrice(vo.entryPrice)
            let bottomY = max(slY, tpY)
            let slotWidth = transform.wrappedValue.candleSlotWidth
            let leftX = CGFloat(vo.startBarIndex) * slotWidth - transform.wrappedValue.xOffset
            let rightX = CGFloat(vo.endBarIndex) * slotWidth - transform.wrappedValue.xOffset + slotWidth
            let midX = (leftX + rightX) / 2

            // Amount +/- buttons
            let lineHeight: CGFloat = 14
            let amountY = entryY - lineHeight * 2.5
            let (minusRect, plusRect) = ChartView.visualOrderAmountButtonRects(midX: midX, amountY: amountY)
            if minusRect.contains(CGPoint(x: mouseX, y: mouseY)) { return .amountDown }
            if plusRect.contains(CGPoint(x: mouseX, y: mouseY)) { return .amountUp }

            // Confirm/Cancel buttons
            let (confirmRect, cancelRect) = ChartView.visualOrderButtonRects(boxRight: rightX, boxBottom: bottomY)
            if confirmRect.contains(CGPoint(x: mouseX, y: mouseY)) { return .confirm }
            if cancelRect.contains(CGPoint(x: mouseX, y: mouseY)) { return .cancel }
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

            // Check visual order buttons first
            if let button = coord.hitTestVisualOrderButtons(mouseX: location.x, mouseY: flippedY) {
                switch button {
                case .confirm: coord.onConfirmVisualOrder?()
                case .cancel: coord.onCancelVisualOrder?()
                case .amountUp: coord.onAdjustVisualOrderAmount?(0.001)
                case .amountDown: coord.onAdjustVisualOrderAmount?(-0.001)
                }
                return
            }

            // Check visual order SL/TP lines
            if let field = coord.hitTestVisualOrderLine(mouseY: flippedY) {
                coord.isDraggingVisualSLTP = true
                coord.visualDragField = field
                coord.crosshair.wrappedValue = nil
                return
            }

            // Check if clicking on an existing position SL/TP line
            let hit = coord.hitTestSLTPLine(mouseY: flippedY)
            if let hit {
                coord.activeDrag = hit
                coord.isDraggingSLTP = true
                coord.crosshair.wrappedValue = nil
                return
            }

            coord.lastDragX = event.locationInWindow.x
            coord.isDraggingSLTP = false
            coord.isDraggingVisualSLTP = false
            coord.crosshair.wrappedValue = nil
        }

        override func mouseUp(with event: NSEvent) {
            guard let coord = coordinator else { return }

            if coord.isDraggingVisualSLTP {
                coord.isDraggingVisualSLTP = false
                coord.visualDragField = nil
                return
            }

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

            if coord.isDraggingVisualSLTP, let field = coord.visualDragField {
                let location = convert(event.locationInWindow, from: nil)
                let flippedY = bounds.height - location.y
                let clampedY = min(max(flippedY, 0), coord.chartHeight)
                let newPrice = coord.priceForY(clampedY)
                switch field {
                case .stopLoss: coord.onUpdateVisualOrderSL?(newPrice)
                case .takeProfit: coord.onUpdateVisualOrderTP?(newPrice)
                }
                return
            }

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

            // Change cursor based on what's under the mouse
            if coord.hitTestVisualOrderButtons(mouseX: location.x, mouseY: flippedY) != nil {
                NSCursor.pointingHand.set()
            } else if coord.hitTestVisualOrderLine(mouseY: flippedY) != nil {
                NSCursor.resizeUpDown.set()
            } else if coord.hitTestSLTPLine(mouseY: flippedY) != nil {
                NSCursor.resizeUpDown.set()
            } else {
                NSCursor.crosshair.set()
            }

            let barIndex = coord.snappedBarIndex(mouseX: location.x)
            coord.crosshair.wrappedValue = CrosshairState(barIndex: barIndex, mouseY: flippedY)
        }

        override func keyDown(with event: NSEvent) {
            guard let coord = coordinator, coord.visualOrder != nil else {
                super.keyDown(with: event)
                return
            }
            switch event.keyCode {
            case 36, 76: // Return, Enter
                coord.onConfirmVisualOrder?()
            case 53: // Escape
                coord.onCancelVisualOrder?()
            default:
                super.keyDown(with: event)
            }
        }

        override func mouseEntered(with event: NSEvent) {}

        override func mouseExited(with event: NSEvent) {
            coordinator?.crosshair.wrappedValue = nil
        }
    }
}
