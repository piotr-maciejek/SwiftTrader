import SwiftUI
import AppKit

struct CrosshairState: Equatable {
    let barIndex: Int
    let mouseY: CGFloat
}

struct SLTPLineHit {
    /// Action target: a position's `label`, a pending order's `groupId` (SL/TP) or its `label`/orderId (entry).
    let positionLabel: String
    let field: Field
    let originalPrice: Double
    /// True when the dragged line belongs to a resting pending order (vs an open position).
    var isPending: Bool = false

    enum Field: Equatable { case stopLoss, takeProfit, entry }
}

enum VisualOrderDragField: Equatable { case stopLoss, takeProfit, entry }

struct DragPreviewState: Equatable {
    let positionLabel: String
    let field: SLTPLineHit.Field
    let currentY: CGFloat
    let currentPrice: Double
}

/// Snapshot at drag end; the confirmation dialog acts on this so macOS `confirmationDialog` cannot see
/// stale `dragPreview` / failed lookups. Covers open-position SL/TP, pending-order SL/TP, and the
/// pending-order entry/trigger amend.
struct PendingChartSLTPEdit: Equatable {
    enum Action: Equatable {
        /// Position OR pending-order SL/TP → `onModifyPosition` (label = position.label / pending groupId).
        case protective(label: String, stopLoss: Double, takeProfit: Double)
        /// Pending-order entry/trigger amend → `onModifyPendingEntry` (label = pending order's orderId).
        case entry(label: String, trigger: Double)
    }
    let action: Action
    let confirmationMessage: String
}

struct ChartInteractionView: NSViewRepresentable {
    @Binding var transform: ChartTransform
    let barCount: Int
    let chartWidth: CGFloat
    var onUserDrag: (() -> Void)?
    @Binding var crosshair: CrosshairState?
    var positions: [Position] = []
    var pendingOrders: [PendingOrder] = []
    var onModifyPendingEntry: ((String, Double) -> Void)? = nil
    var chartHeight: CGFloat = 0
    var priceRange: (min: Double, max: Double) = (0, 1)
    @Binding var dragPreview: DragPreviewState?
    @Binding var pendingSLTPEdit: PendingChartSLTPEdit?
    var visualOrder: VisualOrderState? = nil
    var onConfirmVisualOrder: (() -> Void)? = nil
    var onCancelVisualOrder: (() -> Void)? = nil
    var onUpdateVisualOrderSL: ((Double) -> Void)? = nil
    var onUpdateVisualOrderTP: ((Double) -> Void)? = nil
    var onUpdateVisualOrderEntry: ((Double) -> Void)? = nil
    var onAdjustVisualOrderAmount: ((Double) -> Void)? = nil
    var onResetVisualOrderAmount: (() -> Void)? = nil
    /// While true, all visual-order mouse and key interactions are ignored.
    var isSubmittingOrder: Bool = false
    // Drawing-layer wiring
    var barTimes: [Int64] = []
    var drawings: [Drawing] = []
    var drawingTool: DrawingKind? = nil
    var selectedDrawingID: UUID? = nil
    @Binding var inFlightDrawing: Drawing?
    var onCommitDrawing: ((Drawing) -> Void)? = nil
    var onDeleteDrawing: ((UUID) -> Void)? = nil
    var onClearAllDrawings: (() -> Void)? = nil
    var onClearAllDrawingsAcrossCells: (() -> Void)? = nil
    var onSetDrawingTool: ((DrawingKind?) -> Void)? = nil
    var onSelectDrawing: ((UUID?) -> Void)? = nil

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
        context.coordinator.pendingOrders = pendingOrders
        context.coordinator.onModifyPendingEntry = onModifyPendingEntry
        context.coordinator.chartHeight = chartHeight
        context.coordinator.priceRange = priceRange
        context.coordinator.dragPreview = $dragPreview
        context.coordinator.pendingSLTPEdit = $pendingSLTPEdit
        context.coordinator.visualOrder = visualOrder
        context.coordinator.onConfirmVisualOrder = onConfirmVisualOrder
        context.coordinator.onCancelVisualOrder = onCancelVisualOrder
        context.coordinator.onUpdateVisualOrderSL = onUpdateVisualOrderSL
        context.coordinator.onUpdateVisualOrderTP = onUpdateVisualOrderTP
        context.coordinator.onUpdateVisualOrderEntry = onUpdateVisualOrderEntry
        context.coordinator.onAdjustVisualOrderAmount = onAdjustVisualOrderAmount
        context.coordinator.onResetVisualOrderAmount = onResetVisualOrderAmount
        context.coordinator.isSubmittingOrder = isSubmittingOrder
        context.coordinator.barTimes = barTimes
        context.coordinator.drawings = drawings
        context.coordinator.drawingTool = drawingTool
        context.coordinator.selectedDrawingID = selectedDrawingID
        context.coordinator.inFlightDrawing = $inFlightDrawing
        context.coordinator.onCommitDrawing = onCommitDrawing
        context.coordinator.onDeleteDrawing = onDeleteDrawing
        context.coordinator.onClearAllDrawings = onClearAllDrawings
        context.coordinator.onClearAllDrawingsAcrossCells = onClearAllDrawingsAcrossCells
        context.coordinator.onSetDrawingTool = onSetDrawingTool
        context.coordinator.onSelectDrawing = onSelectDrawing
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(transform: $transform, barCount: barCount, chartWidth: chartWidth,
                    onUserDrag: onUserDrag, crosshair: $crosshair, dragPreview: $dragPreview,
                    pendingSLTPEdit: $pendingSLTPEdit, inFlightDrawing: $inFlightDrawing)
    }

    class Coordinator {
        var transform: Binding<ChartTransform>
        var barCount: Int
        var chartWidth: CGFloat
        var lastDragX: CGFloat = 0
        var onUserDrag: (() -> Void)?
        var crosshair: Binding<CrosshairState?>
        var positions: [Position] = []
        var pendingOrders: [PendingOrder] = []
        var onModifyPendingEntry: ((String, Double) -> Void)?
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
        var onUpdateVisualOrderEntry: ((Double) -> Void)?
        var onAdjustVisualOrderAmount: ((Double) -> Void)?
        var onResetVisualOrderAmount: (() -> Void)?
        var isDraggingVisualSLTP = false
        var visualDragField: VisualOrderDragField?
        var isSubmittingOrder: Bool = false

        // Drawing layer
        var barTimes: [Int64] = []
        var drawings: [Drawing] = []
        var drawingTool: DrawingKind?
        var selectedDrawingID: UUID?
        var inFlightDrawing: Binding<Drawing?>
        var onCommitDrawing: ((Drawing) -> Void)?
        var onDeleteDrawing: ((UUID) -> Void)?
        var onClearAllDrawings: (() -> Void)?
        var onClearAllDrawingsAcrossCells: (() -> Void)?
        var onSetDrawingTool: ((DrawingKind?) -> Void)?
        var onSelectDrawing: ((UUID?) -> Void)?
        /// (startTimeMs, startPrice, tool) seeded on drawing mouseDown.
        var inFlightStart: (timeMs: Int64, price: Double, tool: DrawingKind)?
        /// Accumulated polyline vertices while drawing a freehand stroke.
        var inFlightPoints: [DrawingPoint] = []

        init(transform: Binding<ChartTransform>, barCount: Int, chartWidth: CGFloat,
             onUserDrag: (() -> Void)?, crosshair: Binding<CrosshairState?>,
             dragPreview: Binding<DragPreviewState?>,
             pendingSLTPEdit: Binding<PendingChartSLTPEdit?>,
             inFlightDrawing: Binding<Drawing?>) {
            self.transform = transform
            self.barCount = barCount
            self.chartWidth = chartWidth
            self.onUserDrag = onUserDrag
            self.crosshair = crosshair
            self.dragPreview = dragPreview
            self.pendingSLTPEdit = pendingSLTPEdit
            self.inFlightDrawing = inFlightDrawing
        }

        func timeMsForX(_ x: CGFloat) -> Int64 {
            DrawingMath.timeMsForX(x,
                                   barTimes: barTimes,
                                   xOffset: transform.wrappedValue.xOffset,
                                   slotWidth: transform.wrappedValue.candleSlotWidth)
        }

        func xForTimeMs(_ ms: Int64) -> CGFloat {
            DrawingMath.xForTimeMs(ms,
                                   barTimes: barTimes,
                                   xOffset: transform.wrappedValue.xOffset,
                                   slotWidth: transform.wrappedValue.candleSlotWidth)
        }

        func hitTestDrawing(mouseX: CGFloat, mouseY: CGFloat, threshold: CGFloat = 6) -> UUID? {
            let point = CGPoint(x: mouseX, y: mouseY)
            for drawing in drawings {
                if drawing.kind == .freehand, let pts = drawing.points {
                    let screenPts = pts.map { CGPoint(x: xForTimeMs($0.timeMs), y: yForPrice($0.price)) }
                    if DrawingMath.distanceFromPolyline(point: point, points: screenPts) <= threshold {
                        return drawing.id
                    }
                    continue
                }
                let a = CGPoint(x: xForTimeMs(drawing.startTimeMs), y: yForPrice(drawing.startPrice))
                let b = CGPoint(x: xForTimeMs(drawing.endTimeMs), y: yForPrice(drawing.endPrice))
                let d = DrawingMath.distanceFromSegment(point: point, a: a, b: b)
                if d <= threshold { return drawing.id }
            }
            return nil
        }

        func clampOffset(_ offset: CGFloat) -> CGFloat {
            let totalWidth = CGFloat(barCount) * transform.wrappedValue.candleSlotWidth
            let maxOffset = max(0, totalWidth - chartWidth / 2)
            return min(maxOffset, max(0, offset))
        }

        func snappedBarIndex(mouseX: CGFloat) -> Int {
            let slotWidth = transform.wrappedValue.candleSlotWidth
            let rawIndex = (mouseX + transform.wrappedValue.xOffset - slotWidth / 2) / slotWidth
            let rounded = Int(round(rawIndex))
            guard rounded >= 0, rounded < barCount else { return -1 }
            return rounded
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
            // Resting pending orders: entry/trigger (target = orderId), SL/TP (target = groupId).
            for ord in pendingOrders {
                if abs(mouseY - yForPrice(ord.openPrice)) <= threshold {
                    return SLTPLineHit(positionLabel: ord.label, field: .entry,
                                       originalPrice: ord.openPrice, isPending: true)
                }
                if ord.stopLoss != 0, abs(mouseY - yForPrice(ord.stopLoss)) <= threshold {
                    return SLTPLineHit(positionLabel: ord.groupId, field: .stopLoss,
                                       originalPrice: ord.stopLoss, isPending: true)
                }
                if ord.takeProfit != 0, abs(mouseY - yForPrice(ord.takeProfit)) <= threshold {
                    return SLTPLineHit(positionLabel: ord.groupId, field: .takeProfit,
                                       originalPrice: ord.takeProfit, isPending: true)
                }
            }
            return nil
        }

        func hitTestVisualOrderLine(mouseY: CGFloat) -> VisualOrderDragField? {
            guard let vo = visualOrder else { return nil }
            let threshold: CGFloat = 5.0
            let slY = yForPrice(vo.stopLoss)
            if abs(mouseY - slY) <= threshold { return .stopLoss }
            let tpY = yForPrice(vo.takeProfit)
            if abs(mouseY - tpY) <= threshold { return .takeProfit }
            let entryY = yForPrice(vo.entryPrice)
            if abs(mouseY - entryY) <= threshold { return .entry }
            return nil
        }

        enum VisualOrderButton { case confirm, cancel, amountUp, amountDown, amountReset }

        func hitTestVisualOrderButtons(mouseX: CGFloat, mouseY: CGFloat) -> VisualOrderButton? {
            guard let vo = visualOrder else { return nil }
            // Buttons live in a fixed-size control panel — mirror ChartView's geometry.
            let entryY = yForPrice(vo.entryPrice)
            let slY = yForPrice(vo.stopLoss)
            let tpY = yForPrice(vo.takeProfit)
            let slotWidth = transform.wrappedValue.candleSlotWidth
            let leftX = CGFloat(vo.startBarIndex) * slotWidth - transform.wrappedValue.xOffset
            let rightX = CGFloat(vo.endBarIndex) * slotWidth - transform.wrappedValue.xOffset + slotWidth
            let panelRect = ChartView.visualOrderPanelRect(
                boxLeft: leftX, boxRight: rightX, entryY: entryY,
                boxTopY: min(slY, tpY), boxBottomY: max(slY, tpY), isBuy: vo.direction == "BUY",
                chartWidth: chartWidth, chartHeight: chartHeight
            )
            let midX = panelRect.midX
            let amountY = ChartView.visualOrderPanelAmountY(panelRect: panelRect)

            // Amount +/- buttons — hit-test only when incognito is off (matches draw gate).
            // Mouse events arrive on the main thread, so AppSettings.shared (MainActor) is safe.
            let isIncognito = MainActor.assumeIsolated { AppSettings.shared.incognitoMode }
            if !isIncognito {
                let (minusRect, plusRect) = ChartView.visualOrderAmountButtonRects(midX: midX, amountY: amountY)
                if minusRect.contains(CGPoint(x: mouseX, y: mouseY)) { return .amountDown }
                if plusRect.contains(CGPoint(x: mouseX, y: mouseY)) { return .amountUp }

                let amountLabelRect = ChartView.visualOrderAmountLabelRect(midX: midX, amountY: amountY)
                if amountLabelRect.contains(CGPoint(x: mouseX, y: mouseY)) { return .amountReset }
            }

            let buttonsRight = ChartView.visualOrderPanelButtonsRight(panelRect: panelRect)
            let buttonsBottom = ChartView.visualOrderPanelButtonsBottom(panelRect: panelRect)
            let (confirmRect, cancelRect) = ChartView.visualOrderButtonRects(boxRight: buttonsRight, boxBottom: buttonsBottom)
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

            // Option+scroll → vertical zoom (mirrors the price-axis drag). Up = zoom in.
            // Zoom is around the chart's vertical center, not the cursor.
            if event.modifierFlags.contains(.option) {
                let factor = exp(Double(event.scrollingDeltaY) * 0.01)
                let newScale = max(0.1, min(20, coord.transform.wrappedValue.yScale * factor))
                coord.transform.wrappedValue.yScale = newScale
                return
            }

            // Horizontal scroll — the Logitech MX Master thumb wheel, or a trackpad two-finger swipe —
            // pans the chart left/right. Pick the dominant axis so the MAIN wheel still zooms (deltaY)
            // and the THUMB wheel pans (deltaX). Sign mirrors the drag handler; the delta already
            // honors the system's natural-scroll setting.
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
                let sensitivity: CGFloat = 3.0
                coord.transform.wrappedValue.xOffset = coord.clampOffset(
                    coord.transform.wrappedValue.xOffset - event.scrollingDeltaX * sensitivity
                )
                coord.onUserDrag?()
                return
            }

            let zoomDelta = event.scrollingDeltaY * 0.02
            let oldScale = coord.transform.wrappedValue.xScale
            let newScale = max(0.3, min(5.0, oldScale + zoomDelta))
            let ratio = newScale / oldScale
            // Anchor the zoom at the cursor so the bar under the mouse stays under
            // the mouse — otherwise zoom pinned to the right edge drifts the view
            // forward on each scroll, eventually snapping to the live end.
            let location = convert(event.locationInWindow, from: nil)
            let mouseX = min(max(location.x, 0), coord.chartWidth)
            let anchor = coord.transform.wrappedValue.xOffset + mouseX

            coord.transform.wrappedValue.xScale = newScale
            coord.transform.wrappedValue.xOffset = coord.clampOffset(anchor * ratio - mouseX)
            // Re-evaluate autoScroll and left-edge loadEarlier the same way a drag does.
            coord.onUserDrag?()
        }

        override func mouseDown(with event: NSEvent) {
            guard let coord = coordinator else { return }
            let location = convert(event.locationInWindow, from: nil)
            let flippedY = bounds.height - location.y

            // Drawing-tool active: place start anchor and seed the in-flight preview.
            // Suppresses every other interaction while the user is drawing.
            if let tool = coord.drawingTool {
                let startPrice = coord.priceForY(min(max(flippedY, 0), coord.chartHeight))
                let startTimeMs = coord.timeMsForX(location.x)
                coord.inFlightStart = (timeMs: startTimeMs, price: startPrice, tool: tool)
                if tool == .freehand {
                    coord.inFlightPoints = [DrawingPoint(timeMs: startTimeMs, price: startPrice)]
                    coord.inFlightDrawing.wrappedValue = Drawing(
                        kind: .freehand,
                        startTimeMs: startTimeMs, startPrice: startPrice,
                        endTimeMs: startTimeMs, endPrice: startPrice,
                        points: coord.inFlightPoints
                    )
                } else {
                    coord.inFlightDrawing.wrappedValue = Drawing(
                        kind: tool,
                        startTimeMs: startTimeMs, startPrice: startPrice,
                        endTimeMs: startTimeMs, endPrice: startPrice
                    )
                }
                coord.crosshair.wrappedValue = nil
                return
            }

            // Check visual order buttons first. Swallow clicks while a submit is in flight
            // so users cannot fire confirm/cancel/amount mutations on a frozen box.
            if let button = coord.hitTestVisualOrderButtons(mouseX: location.x, mouseY: flippedY) {
                if coord.isSubmittingOrder { return }
                switch button {
                case .confirm: coord.onConfirmVisualOrder?()
                case .cancel: coord.onCancelVisualOrder?()
                case .amountUp: coord.onAdjustVisualOrderAmount?(0.001)
                case .amountDown: coord.onAdjustVisualOrderAmount?(-0.001)
                case .amountReset: coord.onResetVisualOrderAmount?()
                }
                return
            }

            // Check visual order SL/TP lines
            if let field = coord.hitTestVisualOrderLine(mouseY: flippedY) {
                if coord.isSubmittingOrder { return }
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

            // Select an existing drawing if the click lands close enough to one.
            if let id = coord.hitTestDrawing(mouseX: location.x, mouseY: flippedY) {
                coord.onSelectDrawing?(id)
                coord.crosshair.wrappedValue = nil
                return
            }
            // Empty-space click deselects.
            if coord.selectedDrawingID != nil {
                coord.onSelectDrawing?(nil)
            }

            coord.lastDragX = event.locationInWindow.x
            coord.isDraggingSLTP = false
            coord.isDraggingVisualSLTP = false
            coord.crosshair.wrappedValue = nil
        }

        override func mouseUp(with event: NSEvent) {
            guard let coord = coordinator else { return }

            if let start = coord.inFlightStart {
                let location = convert(event.locationInWindow, from: nil)
                let flippedY = bounds.height - location.y
                let endPrice = coord.priceForY(min(max(flippedY, 0), coord.chartHeight))
                let endTimeMs = coord.timeMsForX(location.x)

                if start.tool == .freehand {
                    // Commit only a real stroke: ≥2 vertices spanning some screen distance.
                    let pts = coord.inFlightPoints
                    if pts.count >= 2 {
                        let xs = pts.map { coord.xForTimeMs($0.timeMs) }
                        let ys = pts.map { coord.yForPrice($0.price) }
                        let span = max((xs.max() ?? 0) - (xs.min() ?? 0),
                                       (ys.max() ?? 0) - (ys.min() ?? 0))
                        if span >= 3 {
                            let drawing = Drawing(
                                kind: .freehand,
                                startTimeMs: pts.first!.timeMs, startPrice: pts.first!.price,
                                endTimeMs: pts.last!.timeMs, endPrice: pts.last!.price,
                                points: pts
                            )
                            coord.onCommitDrawing?(drawing)
                        }
                    }
                    coord.inFlightPoints = []
                    coord.inFlightStart = nil
                    coord.inFlightDrawing.wrappedValue = nil
                    coord.onSetDrawingTool?(nil)
                    return
                }

                // Discard zero-length attempts (likely an accidental click).
                let dxPixels = abs(coord.xForTimeMs(endTimeMs) - coord.xForTimeMs(start.timeMs))
                if dxPixels >= 3 {
                    let drawing = Drawing(
                        kind: start.tool,
                        startTimeMs: start.timeMs, startPrice: start.price,
                        endTimeMs: endTimeMs, endPrice: endPrice
                    )
                    coord.onCommitDrawing?(drawing)
                }
                coord.inFlightStart = nil
                coord.inFlightDrawing.wrappedValue = nil
                // Auto-exit tool after one commit. User can press L/A again to continue.
                coord.onSetDrawingTool?(nil)
                return
            }

            if coord.isDraggingVisualSLTP {
                coord.isDraggingVisualSLTP = false
                coord.visualDragField = nil
                return
            }

            if coord.isDraggingSLTP {
                let hit = coord.activeDrag
                coord.activeDrag = nil
                coord.isDraggingSLTP = false
                if let preview = coord.dragPreview.wrappedValue, let hit {
                    let priceStr = String(format: "%.5f", preview.currentPrice)
                    func sltpEdit(label: String, sl: Double, tp: Double) {
                        let newSL = preview.field == .stopLoss ? preview.currentPrice : sl
                        let newTP = preview.field == .takeProfit ? preview.currentPrice : tp
                        coord.pendingSLTPEdit.wrappedValue = PendingChartSLTPEdit(
                            action: .protective(label: label, stopLoss: newSL, takeProfit: newTP),
                            confirmationMessage: "Move \(preview.field == .stopLoss ? "SL" : "TP") to \(priceStr)?")
                    }
                    if hit.field == .entry {
                        // Pending-order entry/trigger amend (label = the pending order's orderId).
                        coord.pendingSLTPEdit.wrappedValue = PendingChartSLTPEdit(
                            action: .entry(label: hit.positionLabel, trigger: preview.currentPrice),
                            confirmationMessage: "Move entry to \(priceStr)?")
                    } else if hit.isPending,
                              let ord = coord.pendingOrders.first(where: { $0.groupId == hit.positionLabel }) {
                        sltpEdit(label: hit.positionLabel, sl: ord.stopLoss, tp: ord.takeProfit)
                    } else if let pos = coord.positions.first(where: { $0.label == hit.positionLabel }) {
                        sltpEdit(label: pos.label, sl: pos.stopLoss, tp: pos.takeProfit)
                    } else {
                        coord.dragPreview.wrappedValue = nil
                    }
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

            if let start = coord.inFlightStart {
                let location = convert(event.locationInWindow, from: nil)
                let flippedY = bounds.height - location.y
                let clampedY = min(max(flippedY, 0), coord.chartHeight)
                let endPrice = coord.priceForY(clampedY)
                let endTimeMs = coord.timeMsForX(location.x)

                if start.tool == .freehand {
                    // Sample: only append once the cursor has moved ≥2px in screen
                    // space from the last vertex, so dense drag events don't bloat
                    // the polyline.
                    if let last = coord.inFlightPoints.last {
                        let lastX = coord.xForTimeMs(last.timeMs)
                        let lastY = coord.yForPrice(last.price)
                        if abs(location.x - lastX) < 2 && abs(clampedY - lastY) < 2 { return }
                    }
                    coord.inFlightPoints.append(DrawingPoint(timeMs: endTimeMs, price: endPrice))
                    coord.inFlightDrawing.wrappedValue = Drawing(
                        kind: .freehand,
                        startTimeMs: start.timeMs, startPrice: start.price,
                        endTimeMs: endTimeMs, endPrice: endPrice,
                        points: coord.inFlightPoints
                    )
                    return
                }

                coord.inFlightDrawing.wrappedValue = Drawing(
                    kind: start.tool,
                    startTimeMs: start.timeMs, startPrice: start.price,
                    endTimeMs: endTimeMs, endPrice: endPrice
                )
                return
            }

            if coord.isDraggingVisualSLTP, let field = coord.visualDragField {
                let location = convert(event.locationInWindow, from: nil)
                let flippedY = bounds.height - location.y
                let clampedY = min(max(flippedY, 0), coord.chartHeight)
                let newPrice = coord.priceForY(clampedY)
                switch field {
                case .stopLoss: coord.onUpdateVisualOrderSL?(newPrice)
                case .takeProfit: coord.onUpdateVisualOrderTP?(newPrice)
                case .entry: coord.onUpdateVisualOrderEntry?(newPrice)
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
            if barIndex < 0 {
                coord.crosshair.wrappedValue = nil
            } else {
                coord.crosshair.wrappedValue = CrosshairState(barIndex: barIndex, mouseY: flippedY)
            }
        }

        override func keyDown(with event: NSEvent) {
            guard let coord = coordinator else {
                super.keyDown(with: event)
                return
            }

            // ⌥D (Option+D): clear drawings across every cell of the active
            // correlation/MTF tab. Handled before the no-modifier gate below
            // because Option is in the blocking-modifier set there.
            if event.keyCode == 2,
               event.modifierFlags.contains(.option),
               !event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.control) {
                coord.onClearAllDrawingsAcrossCells?()
                return
            }

            // Drawing shortcuts are only active when no command-key modifier is held,
            // so app-level Cmd+L / Cmd+A bindings still propagate. Shift IS allowed
            // because Shift+Delete is the "clear all" gesture.
            let blockingModifiers = event.modifierFlags.intersection([.command, .option, .control])
            if blockingModifiers.isEmpty {
                let isShift = event.modifierFlags.contains(.shift)
                switch event.keyCode {
                case 0:  // A → line tool
                    coord.onSetDrawingTool?(.line)
                    return
                case 1:  // S → arrow tool
                    coord.onSetDrawingTool?(.arrow)
                    return
                case 3:  // F → freehand tool
                    coord.onSetDrawingTool?(.freehand)
                    return
                case 53: // Escape
                    if coord.drawingTool != nil {
                        coord.onSetDrawingTool?(nil)
                        coord.inFlightStart = nil
                        coord.inFlightPoints = []
                        coord.inFlightDrawing.wrappedValue = nil
                        return
                    }
                    if coord.selectedDrawingID != nil {
                        coord.onSelectDrawing?(nil)
                        return
                    }
                    // fall through to visual-order Esc handling below
                case 2, 51, 117: // D / Backspace / forward-Delete
                    if isShift {
                        coord.onClearAllDrawings?()
                        return
                    }
                    if let id = coord.selectedDrawingID {
                        coord.onDeleteDrawing?(id)
                        coord.onSelectDrawing?(nil)
                        return
                    }
                default:
                    break
                }
            }

            // Existing visual-order handling.
            guard coord.visualOrder != nil else {
                super.keyDown(with: event)
                return
            }
            if coord.isSubmittingOrder { return }
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
