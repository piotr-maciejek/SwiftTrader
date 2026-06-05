import SwiftUI

struct ChartView: View {
    /// Darker background used behind the main chart and non-inverse correlation cells.
    /// Inverse correlation cells keep their distinct purple-tint marker.
    static let chartBackground = Color(red: 0.08, green: 0.08, blue: 0.10)

    let bars: [CandleBar]
    @Binding var transform: ChartTransform
    var onChartWidthChanged: ((CGFloat) -> Void)?
    var onUserDrag: (() -> Void)?
    /// Tapped by the bottom-right "scroll to latest" button to jump back to the live edge. Nil hides
    /// the button. Present in every context (main + grid cells) since each owns its own transform.
    var onScrollToLiveEdge: (() -> Void)?
    var showSessions: Bool = true
    var currentPeriod: String = "FIFTEEN_MINS"
    var showVolume: Bool = true
    var showVolumeMA: Bool = true
    var volumeMA: EMALine = EMALine(period: 20, color: .cyan)
    var showEMA: Bool = true
    var emaConfigs: [EMALine] = []
    var positions: [Position] = []
    var pendingOrders: [PendingOrder] = []
    var currentInstrument: String = ""
    var showATR: Bool = true
    var atrPeriod: Int = 14
    var atrPips: Double?
    var todayATRPercent: Double?
    var onModifyPosition: ((String, Double, Double) -> Void)? = nil
    var onModifyPendingEntry: ((String, Double) -> Void)? = nil
    var visualOrder: VisualOrderState? = nil
    var onConfirmVisualOrder: (() -> Void)? = nil
    var onCancelVisualOrder: (() -> Void)? = nil
    var onUpdateVisualOrderSL: ((Double) -> Void)? = nil
    var onUpdateVisualOrderTP: ((Double) -> Void)? = nil
    var onUpdateVisualOrderEntry: ((Double) -> Void)? = nil
    var onAdjustVisualOrderAmount: ((Double) -> Void)? = nil
    var onResetVisualOrderAmount: (() -> Void)? = nil
    var accountEquity: Double? = nil
    /// Live bid-ask spread (price units) for the visual order's instrument. Padded into
    /// the displayed risk so the % matches the realized loss after the broker takes spread.
    var visualOrderSpread: Double = 0
    /// Show the live Bid / Ask / Spread readout under the ATR overlay. On for the main chart;
    /// off for the dense correlation / multi-timeframe grid cells.
    var showQuote: Bool = false
    /// Which side the candles represent — so the quote readout + bid/ask lines compute the opposite side.
    var chartSide: ChartSide = .bid
    /// When true, draw both the live bid and ask as moving lines (instead of the single current-price line).
    var showBidAskLines: Bool = false
    /// True while a submit is in flight — disables visual-order interactions and dims the box.
    var isSubmittingOrder: Bool = false
    /// Externally-driven cursor time (UTC ms). When set and there's no local
    /// hover, draws a ghost vertical crosshair at the bar containing that time.
    /// Used by the multi-TF view to sync cursor across cells.
    var externalCursorTime: Int64? = nil
    /// Called when the local hover crosshair moves. Receives the time of the
    /// bar under the cursor, or nil when the cursor leaves the chart.
    var onCursorChange: ((Int64?) -> Void)? = nil
    // Drawing layer
    var drawings: [Drawing] = []
    var drawingTool: DrawingKind? = nil
    var selectedDrawingID: UUID? = nil
    var onCommitDrawing: ((Drawing) -> Void)? = nil
    var onDeleteDrawing: ((UUID) -> Void)? = nil
    var onClearAllDrawings: (() -> Void)? = nil
    var onClearAllDrawingsAcrossCells: (() -> Void)? = nil
    var onSetDrawingTool: ((DrawingKind?) -> Void)? = nil
    var onSelectDrawing: ((UUID?) -> Void)? = nil
    @State private var crosshair: CrosshairState? = nil
    @State private var dragPreview: DragPreviewState? = nil
    @State private var pendingSLTPEdit: PendingChartSLTPEdit? = nil
    @State private var inFlightDrawing: Drawing? = nil
    /// Captures `transform.yScale` at the start of a price-axis drag so the gesture's
    /// cumulative translation can scale relative to that snapshot, not the live value.
    @State private var yZoomDragStartScale: Double? = nil

    private var incognitoMode: Bool { AppSettings.shared.incognitoMode }

    // Layout constants
    private let priceAxisWidth: CGFloat = 70
    private let timeAxisHeight: CGFloat = 24
    private let pricePaddingPercent: Double = 0.05

    // Colors
    private let bullishColor = Color(red: 0.15, green: 0.65, blue: 0.60)   // #26A69A
    private let bearishColor = Color(red: 0.94, green: 0.33, blue: 0.31)   // #EF5350
    private let gridColor = Color.gray.opacity(0.2)
    private let axisTextColor = Color.secondary
    private let currentPriceColor = Color(red: 0.2, green: 0.6, blue: 1.0) // bright blue

    var body: some View {
        GeometryReader { geo in
            let chartWidth = geo.size.width - priceAxisWidth
            let totalHeight = geo.size.height - timeAxisHeight
            let volumeHeight: CGFloat = showVolume ? totalHeight * 0.2 : 0
            let chartHeight = totalHeight - volumeHeight

            ZStack(alignment: .topLeading) {
                // Main chart canvas
                Canvas { context, size in
                    let visibleRange = visibleBarRange(chartWidth: chartWidth)
                    let priceRange = priceRange(for: visibleRange)

                    // Clip chart content so candles/grid don't bleed into the price axis
                    let chartClip = Path(CGRect(x: 0, y: 0, width: chartWidth, height: chartHeight + volumeHeight))
                    var chartContext = context
                    chartContext.clip(to: chartClip)

                    drawGrid(context: &chartContext, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange)
                    if showSessions, !["FOUR_HOURS", "DAILY", "WEEKLY"].contains(currentPeriod) {
                        drawSessionOverlays(context: &chartContext, chartWidth: chartWidth, chartHeight: chartHeight, visibleRange: visibleRange, priceRange: priceRange)
                    }
                    drawWeekendSeparators(context: &chartContext, chartWidth: chartWidth, chartHeight: chartHeight, volumeHeight: volumeHeight, visibleRange: visibleRange)
                    drawCandles(context: &chartContext, chartWidth: chartWidth, chartHeight: chartHeight, visibleRange: visibleRange, priceRange: priceRange)
                    drawCurrentPriceLine(context: &chartContext, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange)
                    drawSLTPLines(context: &chartContext, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange)
                    drawPendingOrderLines(context: &chartContext, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange)
                    drawUserDrawings(context: &chartContext, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange)
                    if let inflight = inFlightDrawing {
                        drawSingleDrawing(context: &chartContext, drawing: inflight, isSelected: false, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange)
                    }
                    if let vo = visualOrder {
                        drawVisualOrderBox(context: &chartContext, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange, order: vo, isSubmitting: isSubmittingOrder)
                    }
                    if let preview = dragPreview {
                        drawDragPreviewLine(context: &chartContext, chartWidth: chartWidth, chartHeight: chartHeight, preview: preview)
                    }
                    if showEMA && !emaConfigs.isEmpty {
                        drawEMALines(context: &chartContext, chartHeight: chartHeight, priceRange: priceRange, visibleRange: visibleRange)
                    }
                    if showVolume {
                        drawVolumeBars(context: &chartContext, chartWidth: chartWidth, chartHeight: chartHeight, volumeHeight: volumeHeight, visibleRange: visibleRange)
                        if showVolumeMA {
                            let maxVol = visibleRange.reduce(0.0) { max($0, bars[$1].volume) }
                            drawVolumeSMALine(context: &chartContext, chartHeight: chartHeight, volumeHeight: volumeHeight, maxVol: maxVol, visibleRange: visibleRange)
                        }
                    }
                    if let ch = crosshair, !bars.isEmpty {
                        drawCrosshairLines(context: &chartContext, chartWidth: chartWidth, chartHeight: chartHeight, volumeHeight: volumeHeight, crosshair: ch)
                    } else if let idx = ghostBarIndex(), !bars.isEmpty {
                        drawGhostCrosshair(context: &chartContext, barIndex: idx, chartHeight: chartHeight, volumeHeight: volumeHeight)
                    }

                    // Price axis and time axis drawn unclipped so they render in their reserved areas
                    drawPriceAxis(context: &context, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange)
                    drawCurrentPriceLabel(context: &context, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange)
                    drawSLTPLabels(context: &context, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange)
                    drawPendingOrderLabels(context: &context, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange)
                    drawTimeAxis(context: &context, chartWidth: chartWidth, chartHeight: chartHeight, visibleRange: visibleRange)
                    if let ch = crosshair, !bars.isEmpty {
                        drawCrosshairLabels(context: &context, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange, crosshair: ch)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .overlay(alignment: .topLeading) {
                    ChartInteractionView(
                        transform: $transform,
                        barCount: bars.count,
                        chartWidth: chartWidth,
                        onUserDrag: onUserDrag,
                        crosshair: $crosshair,
                        positions: relevantPositions,
                        pendingOrders: relevantPendingOrders,
                        onModifyPendingEntry: onModifyPendingEntry,
                        chartHeight: chartHeight,
                        priceRange: priceRange(for: visibleBarRange(chartWidth: chartWidth)),
                        dragPreview: $dragPreview,
                        pendingSLTPEdit: $pendingSLTPEdit,
                        visualOrder: visualOrder,
                        onConfirmVisualOrder: onConfirmVisualOrder,
                        onCancelVisualOrder: onCancelVisualOrder,
                        onUpdateVisualOrderSL: onUpdateVisualOrderSL,
                        onUpdateVisualOrderTP: onUpdateVisualOrderTP,
                        onUpdateVisualOrderEntry: onUpdateVisualOrderEntry,
                        onAdjustVisualOrderAmount: onAdjustVisualOrderAmount,
                        onResetVisualOrderAmount: onResetVisualOrderAmount,
                        isSubmittingOrder: isSubmittingOrder,
                        barTimes: bars.map(\.time),
                        drawings: drawings,
                        drawingTool: drawingTool,
                        selectedDrawingID: selectedDrawingID,
                        inFlightDrawing: $inFlightDrawing,
                        onCommitDrawing: onCommitDrawing,
                        onDeleteDrawing: onDeleteDrawing,
                        onClearAllDrawings: onClearAllDrawings,
                        onClearAllDrawingsAcrossCells: onClearAllDrawingsAcrossCells,
                        onSetDrawingTool: onSetDrawingTool,
                        onSelectDrawing: onSelectDrawing
                    )
                    .frame(width: chartWidth, height: chartHeight + volumeHeight)
                }
                .overlay(alignment: .topLeading) {
                    // Price-axis gesture surface: drag vertically to zoom Y, double-click
                    // to reset. Sits over the price-axis column on the right; doesn't catch
                    // any other chart interactions. Drag minimumDistance=3 so stationary
                    // clicks pass through to the tap gesture below.
                    Color.clear
                        .frame(width: priceAxisWidth, height: chartHeight + volumeHeight)
                        .contentShape(Rectangle())
                        .offset(x: chartWidth)
                        .gesture(
                            DragGesture(minimumDistance: 3)
                                .onChanged { value in
                                    if yZoomDragStartScale == nil {
                                        yZoomDragStartScale = transform.yScale
                                    }
                                    let factor = exp(-Double(value.translation.height) * 0.005)
                                    let start = yZoomDragStartScale ?? 1.0
                                    transform.yScale = max(0.1, min(20, start * factor))
                                }
                                .onEnded { _ in yZoomDragStartScale = nil }
                        )
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                transform.yScale = 1.0
                                transform.yOffset = 0
                            }
                        )
                }
                .confirmationDialog(
                    "Adjust order",
                    isPresented: Binding(
                        get: { pendingSLTPEdit != nil },
                        set: { if !$0 { pendingSLTPEdit = nil; dragPreview = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Confirm") {
                        switch pendingSLTPEdit?.action {
                        case .protective(let label, let sl, let tp):
                            onModifyPosition?(label, sl, tp)
                        case .entry(let label, let trigger):
                            onModifyPendingEntry?(label, trigger)
                        case nil:
                            break
                        }
                        pendingSLTPEdit = nil
                        dragPreview = nil
                    }
                    Button("Cancel", role: .cancel) {
                        pendingSLTPEdit = nil
                        dragPreview = nil
                    }
                } message: {
                    Text(pendingSLTPEdit?.confirmationMessage ?? "")
                }
                // The view owns the one-time live-edge snap, because only it has the reliably
                // correct cell width (the view-model's delivered width is missed for grid cells
                // across tab switches). `snapOnceToLiveEdge` is gated by
                // `transform.hasAutoScrolledToEnd`, so it positions exactly once per loaded
                // dataset and then leaves the scroll alone — a manual scroll-back survives live
                // ticks and tab switches. Three triggers, all idempotent via the guard, cover
                // the first valid (width + bars) moment however it arrives:
                //   • the guard flipping false (first display, or `scrollToEnd()` on reload)
                //   • bars loading after the guard was cleared
                //   • the cell's width settling
                .onChange(of: transform.hasAutoScrolledToEnd, initial: true) { _, _ in
                    snapOnceToLiveEdge(chartWidth: chartWidth)
                }
                .onChange(of: bars.last?.time) { _, _ in
                    snapOnceToLiveEdge(chartWidth: chartWidth)
                }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width - priceAxisWidth
                } action: { newWidth in
                    onChartWidthChanged?(newWidth)
                    snapOnceToLiveEdge(chartWidth: newWidth)
                }
                .onChange(of: crosshair) { _, newCrosshair in
                    let time: Int64? = newCrosshair.flatMap { ch in
                        guard ch.barIndex >= 0, ch.barIndex < bars.count else { return nil }
                        return Int64(bars[ch.barIndex].date.timeIntervalSince1970 * 1000)
                    }
                    onCursorChange?(time)
                }

                VStack(alignment: .leading, spacing: 4) {
                    if showATR, let pips = atrPips, let percent = todayATRPercent {
                        atrOverlay(atrPeriod: atrPeriod, atrPips: pips, todayPercent: percent)
                    }
                    if showQuote, let close = bars.last?.close, close > 0 {
                        quoteOverlay(close: close, spread: visualOrderSpread, instrument: currentInstrument)
                    }
                    if let ch = crosshair,
                       ch.barIndex >= 0, ch.barIndex < bars.count {
                        ohlcOverlay(bar: bars[ch.barIndex])
                    }
                }
                .padding(.leading, 8)
                .padding(.top, 6)

                // "Scroll to latest" — last child so it's topmost and hit-testable above the Canvas
                // gestures. Inset clear of the price axis (right) and time axis (bottom); the same
                // inset scales cleanly to small grid cells.
                if let onScrollToLiveEdge {
                    Button(action: onScrollToLiveEdge) {
                        Image(systemName: "arrow.right.to.line")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(Color.black.opacity(0.55))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help("Scroll to latest")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, priceAxisWidth + 8)
                    .padding(.bottom, timeAxisHeight + 8)
                }
            }
        }
    }

    @ViewBuilder
    private func ohlcOverlay(bar: CandleBar) -> some View {
        let color = bar.isBullish ? bullishColor : bearishColor
        let change = bar.close - bar.open
        let changePct = bar.open != 0 ? (change / bar.open) * 100 : 0
        HStack(spacing: 10) {
            Text(Self.ohlcTimeFormatter.string(from: bar.date))
                .foregroundColor(.secondary)
            ohlcField(label: "O", value: bar.open, color: color)
            ohlcField(label: "H", value: bar.high, color: color)
            ohlcField(label: "L", value: bar.low, color: color)
            ohlcField(label: "C", value: bar.close, color: color)
            Text(String(format: "%+.5f (%+.2f%%)", change, changePct))
                .foregroundColor(color)
            if bar.partial {
                Text("LIVE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.orange)
                    .cornerRadius(3)
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.55))
        .cornerRadius(4)
    }

    @ViewBuilder
    private func atrOverlay(atrPeriod: Int, atrPips: Double, todayPercent: Double) -> some View {
        Text(String(format: "ATR(%d): %.1f pips  |  Today: %.0f%%", atrPeriod, atrPips, todayPercent))
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.55))
            .cornerRadius(4)
    }

    /// Live bid & ask from the candle `close` + live `spread`, given which side the candles are.
    /// In BID mode the close IS the bid (ask = close + spread); in ASK mode the close IS the ask
    /// (bid = close − spread). Pure → the single source of truth for the readout + the chart lines.
    static func bidAsk(close: Double, spread: Double, side: ChartSide) -> (bid: Double, ask: Double) {
        let s = max(0, spread)
        return side == .bid ? (bid: close, ask: close + s) : (bid: close - s, ask: close)
    }

    /// Formats the live quote line shown under the ATR overlay. Pure → unit-testable. `close` is the
    /// live bar close (bid or ask depending on `side`); spread is shown in pips (`—` when there's no
    /// live spread yet, e.g. market closed / pre-first-tick). JPY pairs use 3 decimals, others 5.
    static func quoteReadout(close: Double, spread: Double, side: ChartSide, instrument: String) -> String {
        let dec = instrument.contains("JPY") ? 3 : 5
        let q = bidAsk(close: close, spread: spread, side: side)
        let spr = spread > 0
            ? String(format: "%.1fp", spread * PnLConverter.pipFactor(for: instrument))
            : "—"
        return String(format: "Bid %.\(dec)f   Ask %.\(dec)f   Spr %@", q.bid, q.ask, spr)
    }

    @ViewBuilder
    private func quoteOverlay(close: Double, spread: Double, instrument: String) -> some View {
        Text(Self.quoteReadout(close: close, spread: spread, side: chartSide, instrument: instrument))
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.55))
            .cornerRadius(4)
    }

    @ViewBuilder
    private func ohlcField(label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(label).foregroundColor(.secondary)
            Text(String(format: "%.5f", value)).foregroundColor(color)
        }
    }

    private static let ohlcTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = .current
        return f
    }()

    // MARK: - Visible range calculation

    /// Fraction of the viewport left empty to the right of the newest candle when first
    /// positioned at the live edge — a small breathing gap so the last bar isn't flush
    /// against the price axis.
    static let rightMarginFraction: CGFloat = 0.10

    /// The `xOffset` that puts the newest bar at the right with `rightMarginFraction` of the
    /// viewport empty beyond it. `max(0, …)` keeps a chart shorter than the viewport left-
    /// anchored. Pure math, so it's unit-testable.
    static func liveEdgeOffset(barCount: Int, slotWidth: CGFloat, chartWidth: CGFloat) -> CGFloat {
        let totalContentWidth = CGFloat(barCount) * slotWidth
        return max(0, totalContentWidth - chartWidth * (1 - rightMarginFraction))
    }

    /// Position the chart at the live edge exactly once per loaded dataset. Gated by
    /// `transform.hasAutoScrolledToEnd` so it never runs again — manual scrolling and tab
    /// switches keep whatever the user left. Uses the live geometry `chartWidth`, the only
    /// reliably-correct width, so grid cells (correlation / multi-timeframe) position right
    /// even when the view-model never received a width.
    private func snapOnceToLiveEdge(chartWidth: CGFloat) {
        guard !transform.hasAutoScrolledToEnd, chartWidth > 0, !bars.isEmpty else { return }
        transform.xOffset = Self.liveEdgeOffset(
            barCount: bars.count, slotWidth: transform.candleSlotWidth, chartWidth: chartWidth
        )
        transform.hasAutoScrolledToEnd = true
    }

    private func visibleBarRange(chartWidth: CGFloat) -> Range<Int> {
        guard !bars.isEmpty, chartWidth > 0 else { return 0..<0 }
        let slotWidth = transform.candleSlotWidth
        let startIndex = max(0, Int(floor(transform.xOffset / slotWidth)))
        let endIndex = min(bars.count, Int(ceil((transform.xOffset + chartWidth) / slotWidth)) + 1)
        guard startIndex < endIndex else { return 0..<0 }
        return startIndex..<endIndex
    }

    private func priceRange(for range: Range<Int>) -> (min: Double, max: Double) {
        guard !range.isEmpty else { return (0, 1) }
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        for i in range {
            lo = min(lo, bars[i].low)
            hi = max(hi, bars[i].high)
        }
        // Default: fold visual order SL/TP into the range so they're always visible.
        // Skipped when the user has manually zoomed Y — they're explicitly choosing
        // what to see, and including a far-away TP would defeat the zoom.
        if !transform.hasManualYTransform, let vo = visualOrder {
            lo = min(lo, min(vo.stopLoss, vo.takeProfit))
            hi = max(hi, max(vo.stopLoss, vo.takeProfit))
        }
        // Ensure a minimum spread so grid/axis math never divides by zero
        if hi - lo < 1e-8 {
            let mid = (hi + lo) / 2
            lo = mid - 0.0005
            hi = mid + 0.0005
        }
        let padding = (hi - lo) * pricePaddingPercent
        let baseLo = lo - padding
        let baseHi = hi + padding
        if !transform.hasManualYTransform {
            return (baseLo, baseHi)
        }
        // Manual Y zoom: scale the range around its center, then pan by yOffset.
        let center = (baseLo + baseHi) / 2 + transform.yOffset
        let span = (baseHi - baseLo) / transform.yScale
        return (center - span / 2, center + span / 2)
    }

    // MARK: - Coordinate mapping

    private func xForBar(index: Int) -> CGFloat {
        CGFloat(index) * transform.candleSlotWidth - transform.xOffset + transform.candleSlotWidth / 2
    }

    private func yForPrice(_ price: Double, chartHeight: CGFloat, priceRange: (min: Double, max: Double)) -> CGFloat {
        let normalized = (price - priceRange.min) / (priceRange.max - priceRange.min)
        return chartHeight * (1 - CGFloat(normalized))
    }

    private func xForTimeMs(_ ms: Int64) -> CGFloat {
        DrawingMath.xForTimeMs(ms,
                               barTimes: bars.map(\.time),
                               xOffset: transform.xOffset,
                               slotWidth: transform.candleSlotWidth)
    }

    // MARK: - Drawing

    private func drawCandles(context: inout GraphicsContext, chartWidth: CGFloat, chartHeight: CGFloat, visibleRange: Range<Int>, priceRange: (min: Double, max: Double)) {
        let bodyWidth = transform.candleBodyWidth

        for i in visibleRange {
            let bar = bars[i]
            let centerX = xForBar(index: i)
            let color = bar.isBullish ? bullishColor : bearishColor

            let highY = yForPrice(bar.high, chartHeight: chartHeight, priceRange: priceRange)
            let lowY = yForPrice(bar.low, chartHeight: chartHeight, priceRange: priceRange)
            let openY = yForPrice(bar.open, chartHeight: chartHeight, priceRange: priceRange)
            let closeY = yForPrice(bar.close, chartHeight: chartHeight, priceRange: priceRange)

            // Wick
            var wickPath = Path()
            wickPath.move(to: CGPoint(x: centerX, y: highY))
            wickPath.addLine(to: CGPoint(x: centerX, y: lowY))
            context.stroke(wickPath, with: .color(color), lineWidth: 1)

            // Body
            let bodyTop = min(openY, closeY)
            let bodyHeight = max(abs(openY - closeY), 1) // minimum 1px
            let bodyRect = CGRect(
                x: centerX - bodyWidth / 2,
                y: bodyTop,
                width: bodyWidth,
                height: bodyHeight
            )
            context.fill(Path(bodyRect), with: .color(color))
        }
    }

    /// Distinct color for the ask line/pill when both bid & ask are shown (bid keeps `currentPriceColor`).
    private let askLineColor = Color(red: 0.95, green: 0.55, blue: 0.25) // orange

    private func drawCurrentPriceLine(context: inout GraphicsContext, chartWidth: CGFloat, chartHeight: CGFloat, priceRange: (min: Double, max: Double)) {
        guard let close = bars.last?.close, close > 0 else { return }
        if showBidAskLines {
            let q = Self.bidAsk(close: close, spread: visualOrderSpread, side: chartSide)
            drawPriceLine(context: &context, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange, price: q.bid, color: currentPriceColor)
            drawPriceLine(context: &context, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange, price: q.ask, color: askLineColor)
        } else {
            drawPriceLine(context: &context, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange, price: close, color: currentPriceColor)
        }
    }

    private func drawPriceLine(context: inout GraphicsContext, chartWidth: CGFloat, chartHeight: CGFloat, priceRange: (min: Double, max: Double), price: Double, color: Color) {
        guard price > 0 else { return }
        let y = yForPrice(price, chartHeight: chartHeight, priceRange: priceRange)
        guard y >= 0 && y <= chartHeight else { return }
        var path = Path()
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: chartWidth, y: y))
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    }

    /// Draws the current-price label(s) in the price axis area (called unclipped). One pill normally,
    /// a bid + ask pill when `showBidAskLines`.
    private func drawCurrentPriceLabel(context: inout GraphicsContext, chartWidth: CGFloat, chartHeight: CGFloat, priceRange: (min: Double, max: Double)) {
        guard let close = bars.last?.close, close > 0 else { return }
        if showBidAskLines {
            let q = Self.bidAsk(close: close, spread: visualOrderSpread, side: chartSide)
            drawPriceLabel(context: &context, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange, price: q.bid, color: currentPriceColor)
            drawPriceLabel(context: &context, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange, price: q.ask, color: askLineColor)
        } else {
            drawPriceLabel(context: &context, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange, price: close, color: currentPriceColor)
        }
    }

    private func drawPriceLabel(context: inout GraphicsContext, chartWidth: CGFloat, chartHeight: CGFloat, priceRange: (min: Double, max: Double), price: Double, color: Color) {
        guard price > 0 else { return }
        let y = yForPrice(price, chartHeight: chartHeight, priceRange: priceRange)
        guard y >= 0 && y <= chartHeight else { return }
        let dec = currentInstrument.contains("JPY") ? 3 : 5
        let label = Text(String(format: "%.\(dec)f", price))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(.white)
        let resolved = context.resolve(label)
        let labelSize = resolved.measure(in: CGSize(width: 200, height: 20))
        let pillRect = CGRect(
            x: chartWidth + 2,
            y: y - labelSize.height / 2 - 2,
            width: labelSize.width + 8,
            height: labelSize.height + 4
        )
        context.fill(Path(roundedRect: pillRect, cornerRadius: 3), with: .color(color))
        context.draw(resolved, at: CGPoint(x: chartWidth + 6, y: y), anchor: .leading)
    }

    private func drawGrid(context: inout GraphicsContext, chartWidth: CGFloat, chartHeight: CGFloat, priceRange: (min: Double, max: Double)) {
        // Horizontal grid lines (price levels)
        let priceSpan = priceRange.max - priceRange.min
        let gridStep = niceGridStep(span: priceSpan, targetLines: 6)
        let firstPrice = ceil(priceRange.min / gridStep) * gridStep

        var price = firstPrice
        while price < priceRange.max {
            let y = yForPrice(price, chartHeight: chartHeight, priceRange: priceRange)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: chartWidth, y: y))
            context.stroke(path, with: .color(gridColor), lineWidth: 0.5)
            price += gridStep
        }
    }

    private func drawPriceAxis(context: inout GraphicsContext, chartWidth: CGFloat, chartHeight: CGFloat, priceRange: (min: Double, max: Double)) {
        let priceSpan = priceRange.max - priceRange.min
        let gridStep = niceGridStep(span: priceSpan, targetLines: 6)
        let firstPrice = ceil(priceRange.min / gridStep) * gridStep
        let decimals = max(0, Int(-log10(gridStep)) + 1)
        let format = "%.\(max(decimals, 4))f"

        var price = firstPrice
        while price < priceRange.max {
            let y = yForPrice(price, chartHeight: chartHeight, priceRange: priceRange)
            let text = Text(String(format: format, price))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(axisTextColor)
            let resolved = context.resolve(text)
            context.draw(resolved, at: CGPoint(x: chartWidth + 6, y: y), anchor: .leading)
            price += gridStep
        }
    }

    private func drawTimeAxis(context: inout GraphicsContext, chartWidth: CGFloat, chartHeight: CGFloat, visibleRange: Range<Int>) {
        guard !visibleRange.isEmpty else { return }

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        timeFormatter.timeZone = .current
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd MMM"
        dateFormatter.timeZone = .current

        // Show a time label roughly every 80px
        let step = max(1, Int(80 / transform.candleSlotWidth))

        var lastDay: Int?
        for i in stride(from: visibleRange.lowerBound, to: visibleRange.upperBound, by: step) {
            let x = xForBar(index: i)
            guard x > 0 && x < chartWidth else { continue }

            let date = bars[i].date
            let day = Calendar.current.component(.day, from: date)
            let dayChanged = lastDay != nil && day != lastDay
            lastDay = day

            if dayChanged {
                // Show date on top, time below
                let dateLine = Text(dateFormatter.string(from: date))
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(axisTextColor)
                let timeLine = Text(timeFormatter.string(from: date))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(axisTextColor)
                context.draw(context.resolve(dateLine), at: CGPoint(x: x, y: chartHeight + 3), anchor: .top)
                context.draw(context.resolve(timeLine), at: CGPoint(x: x, y: chartHeight + 14), anchor: .top)
            } else {
                let text = Text(timeFormatter.string(from: date))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(axisTextColor)
                context.draw(context.resolve(text), at: CGPoint(x: x, y: chartHeight + 6), anchor: .top)
            }
        }

        // Draw weekend gap labels directly at weekend boundaries
        for i in visibleRange.lowerBound..<(visibleRange.upperBound - 1) {
            let gap = bars[i + 1].time - bars[i].time
            guard gap > 24 * 60 * 60 * 1000 else { continue }
            let x1 = xForBar(index: i)
            let x2 = xForBar(index: i + 1)
            let midX = (x1 + x2) / 2
            guard midX > 0, midX < chartWidth else { continue }

            let label = Text("wknd")
                .font(.system(size: 7, design: .monospaced))
                .foregroundColor(Color.gray.opacity(0.5))
            context.draw(context.resolve(label), at: CGPoint(x: midX, y: chartHeight + 8), anchor: .top)
        }
    }

    /// Draw subtle weekend separators — a thin vertical gap with a dashed line
    /// between Friday's close and Sunday's open so the user can see where weekends are.
    private func drawWeekendSeparators(
        context: inout GraphicsContext,
        chartWidth: CGFloat,
        chartHeight: CGFloat,
        volumeHeight: CGFloat,
        visibleRange: Range<Int>
    ) {
        guard visibleRange.count > 1 else { return }
        let calendar = Calendar.current
        let totalHeight = chartHeight + volumeHeight
        let gapColor = Color.gray.opacity(0.25)

        for i in visibleRange.lowerBound..<(visibleRange.upperBound - 1) {
            let gap = bars[i + 1].time - bars[i].time
            // Weekend gap: > 24 hours between consecutive bars
            guard gap > 24 * 60 * 60 * 1000 else { continue }

            // Dashed vertical line at the midpoint between the two bars
            let x1 = xForBar(index: i)
            let x2 = xForBar(index: i + 1)
            let midX = (x1 + x2) / 2
            guard midX > 0, midX < chartWidth else { continue }

            var path = Path()
            path.move(to: CGPoint(x: midX, y: 0))
            path.addLine(to: CGPoint(x: midX, y: totalHeight))
            context.stroke(
                path,
                with: .color(gapColor),
                style: StrokeStyle(lineWidth: 0.5, dash: [4, 3])
            )
        }
    }

    private func drawSessionOverlays(
        context: inout GraphicsContext,
        chartWidth: CGFloat,
        chartHeight: CGFloat,
        visibleRange: Range<Int>,
        priceRange: (min: Double, max: Double)
    ) {
        let sessionRects = SessionCalculator.sessions(for: bars, visibleRange: visibleRange)
        let dashStyle = StrokeStyle(lineWidth: 0.5, dash: [3, 2])

        for rect in sessionRects {
            let leftX = xForBar(index: rect.startBarIndex) - transform.candleSlotWidth / 2
            let rightX = xForBar(index: rect.endBarIndex) + transform.candleSlotWidth / 2
            let topY = yForPrice(rect.highPrice, chartHeight: chartHeight, priceRange: priceRange)
            let bottomY = yForPrice(rect.lowPrice, chartHeight: chartHeight, priceRange: priceRange)

            guard rightX > 0 && leftX < chartWidth else { continue }

            let sessionPath = Path(CGRect(
                x: leftX, y: topY,
                width: rightX - leftX, height: bottomY - topY
            ))
            context.fill(sessionPath, with: .color(rect.session.color))
            context.stroke(sessionPath, with: .color(rect.session.color.opacity(3.0)), lineWidth: 0.5)

            // Exchange open/close dashed lines
            let lineColor = rect.session.color.opacity(4.0)
            if let openIdx = rect.exchangeOpenBarIndex {
                let x = xForBar(index: openIdx)
                var path = Path()
                path.move(to: CGPoint(x: x, y: topY))
                path.addLine(to: CGPoint(x: x, y: bottomY))
                context.stroke(path, with: .color(lineColor), style: dashStyle)
            }
            if let closeIdx = rect.exchangeCloseBarIndex {
                let x = xForBar(index: closeIdx)
                var path = Path()
                path.move(to: CGPoint(x: x, y: topY))
                path.addLine(to: CGPoint(x: x, y: bottomY))
                context.stroke(path, with: .color(lineColor), style: dashStyle)
            }

            let label = Text(rect.session.name)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(rect.session.color.opacity(10.0))
            let resolved = context.resolve(label)
            let labelX = max(leftX + 4, 4)
            context.draw(resolved, at: CGPoint(x: labelX, y: topY + 2), anchor: .topLeading)
        }
    }

    // MARK: - Crosshair

    private static func crosshairTimeFormatter(for period: String) -> DateFormatter {
        let f = DateFormatter()
        switch period {
        case "DAILY", "WEEKLY": f.dateFormat = "dd MMM yyyy"
        case "FOUR_HOURS":      f.dateFormat = "dd MMM HH:mm"
        default:                f.dateFormat = "HH:mm"
        }
        return f
    }

    private func priceForY(_ y: CGFloat, chartHeight: CGFloat, priceRange: (min: Double, max: Double)) -> Double {
        let normalized = 1.0 - Double(y / chartHeight)
        return priceRange.min + normalized * (priceRange.max - priceRange.min)
    }

    /// Last bar whose start time is ≤ the external cursor time. Used to position
    /// the synced ghost crosshair on a chart whose period differs from the
    /// originating chart's. Returns nil if no external time is set, the local
    /// crosshair is active, or no bars precede the cursor.
    private func ghostBarIndex() -> Int? {
        guard crosshair == nil, let time = externalCursorTime, !bars.isEmpty else { return nil }
        return bars.lastIndex { Int64($0.date.timeIntervalSince1970 * 1000) <= time }
    }

    private func drawGhostCrosshair(
        context: inout GraphicsContext,
        barIndex: Int,
        chartHeight: CGFloat,
        volumeHeight: CGFloat
    ) {
        let snappedX = xForBar(index: barIndex)
        var path = Path()
        path.move(to: CGPoint(x: snappedX, y: 0))
        path.addLine(to: CGPoint(x: snappedX, y: chartHeight + volumeHeight))
        context.stroke(
            path,
            with: .color(Color.white.opacity(0.35)),
            style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])
        )
    }

    private func drawCrosshairLines(
        context: inout GraphicsContext,
        chartWidth: CGFloat,
        chartHeight: CGFloat,
        volumeHeight: CGFloat = 0,
        crosshair: CrosshairState
    ) {
        guard crosshair.barIndex >= 0, crosshair.barIndex < bars.count else { return }
        let color = Color.white.opacity(0.6)
        let style = StrokeStyle(lineWidth: 0.5, dash: [4, 3])
        let clampedY = min(max(crosshair.mouseY, 0), chartHeight)
        let snappedX = xForBar(index: crosshair.barIndex)

        // Vertical line (snapped to candle center, extends through volume area)
        var vPath = Path()
        vPath.move(to: CGPoint(x: snappedX, y: 0))
        vPath.addLine(to: CGPoint(x: snappedX, y: chartHeight + volumeHeight))
        context.stroke(vPath, with: .color(color), style: style)

        // Horizontal line (follows mouse, candle area only)
        var hPath = Path()
        hPath.move(to: CGPoint(x: 0, y: clampedY))
        hPath.addLine(to: CGPoint(x: chartWidth, y: clampedY))
        context.stroke(hPath, with: .color(color), style: style)
    }

    private func drawCrosshairLabels(
        context: inout GraphicsContext,
        chartWidth: CGFloat,
        chartHeight: CGFloat,
        priceRange: (min: Double, max: Double),
        crosshair: CrosshairState
    ) {
        guard crosshair.barIndex >= 0, crosshair.barIndex < bars.count else { return }
        let pillColor = Color.gray
        let clampedY = min(max(crosshair.mouseY, 0), chartHeight)

        // Price label on right axis
        let price = priceForY(clampedY, chartHeight: chartHeight, priceRange: priceRange)
        let priceText = Text(String(format: "%.5f", price))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(.white)
        let resolvedPrice = context.resolve(priceText)
        let priceSize = resolvedPrice.measure(in: CGSize(width: 200, height: 20))
        let pricePill = CGRect(
            x: chartWidth + 2,
            y: clampedY - priceSize.height / 2 - 2,
            width: priceSize.width + 8,
            height: priceSize.height + 4
        )
        context.fill(Path(roundedRect: pricePill, cornerRadius: 3), with: .color(pillColor))
        context.draw(resolvedPrice, at: CGPoint(x: chartWidth + 6, y: clampedY), anchor: .leading)

        // Time label on bottom axis
        let bar = bars[crosshair.barIndex]
        let timeStr = Self.crosshairTimeFormatter(for: currentPeriod).string(from: bar.date)
        let timeText = Text(timeStr)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundColor(.white)
        let resolvedTime = context.resolve(timeText)
        let timeSize = resolvedTime.measure(in: CGSize(width: 200, height: 20))
        let snappedX = xForBar(index: crosshair.barIndex)
        let timePill = CGRect(
            x: snappedX - timeSize.width / 2 - 4,
            y: chartHeight + 2,
            width: timeSize.width + 8,
            height: timeSize.height + 4
        )
        context.fill(Path(roundedRect: timePill, cornerRadius: 3), with: .color(pillColor))
        context.draw(resolvedTime, at: CGPoint(x: snappedX, y: chartHeight + 4 + timeSize.height / 2), anchor: .center)
    }

    // MARK: - SL/TP Lines

    private var relevantPositions: [Position] {
        positions.filter { $0.instrument == currentInstrument }
    }

    private func drawSLTPLines(context: inout GraphicsContext, chartWidth: CGFloat,
                                chartHeight: CGFloat, priceRange: (min: Double, max: Double)) {
        for position in relevantPositions {
            if position.stopLoss != 0 {
                let y = yForPrice(position.stopLoss, chartHeight: chartHeight, priceRange: priceRange)
                if y >= 0 && y <= chartHeight {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: chartWidth, y: y))
                    context.stroke(path, with: .color(bearishColor),
                                   style: StrokeStyle(lineWidth: 1, dash: [6, 3]))
                }
            }
            if position.takeProfit != 0 {
                let y = yForPrice(position.takeProfit, chartHeight: chartHeight, priceRange: priceRange)
                if y >= 0 && y <= chartHeight {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: chartWidth, y: y))
                    context.stroke(path, with: .color(bullishColor),
                                   style: StrokeStyle(lineWidth: 1, dash: [6, 3]))
                }
            }
        }
    }

    private func drawDragPreviewLine(context: inout GraphicsContext, chartWidth: CGFloat,
                                      chartHeight: CGFloat, preview: DragPreviewState) {
        let color: Color
        switch preview.field {
        case .stopLoss: color = bearishColor
        case .takeProfit: color = bullishColor
        case .entry: color = pendingEntryColor
        }
        var path = Path()
        path.move(to: CGPoint(x: 0, y: preview.currentY))
        path.addLine(to: CGPoint(x: chartWidth, y: preview.currentY))
        context.stroke(path, with: .color(color.opacity(0.6)),
                       style: StrokeStyle(lineWidth: 2, dash: [4, 2]))
    }

    private func drawSLTPLabels(context: inout GraphicsContext, chartWidth: CGFloat,
                                 chartHeight: CGFloat, priceRange: (min: Double, max: Double)) {
        for position in relevantPositions {
            for (price, color, tag) in [
                (position.stopLoss, bearishColor, "SL"),
                (position.takeProfit, bullishColor, "TP"),
            ] where price != 0 {
                let y = yForPrice(price, chartHeight: chartHeight, priceRange: priceRange)
                guard y >= 0 && y <= chartHeight else { continue }

                let label = Text("\(tag) \(String(format: "%.5f", price))")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                let resolved = context.resolve(label)
                let labelSize = resolved.measure(in: CGSize(width: 200, height: 20))

                let pillRect = CGRect(
                    x: chartWidth + 2,
                    y: y - labelSize.height / 2 - 2,
                    width: labelSize.width + 8,
                    height: labelSize.height + 4
                )
                context.fill(Path(roundedRect: pillRect, cornerRadius: 3), with: .color(color))
                context.draw(resolved, at: CGPoint(x: chartWidth + 6, y: y), anchor: .leading)
            }
        }
    }

    // MARK: - Pending Orders

    private var relevantPendingOrders: [PendingOrder] {
        pendingOrders.filter { $0.instrument == currentInstrument }
    }

    private let pendingEntryColor = Color(red: 0.95, green: 0.75, blue: 0.25) // amber

    private func drawPendingOrderLines(context: inout GraphicsContext, chartWidth: CGFloat,
                                        chartHeight: CGFloat, priceRange: (min: Double, max: Double)) {
        for order in relevantPendingOrders {
            // Entry trigger line
            let entryY = yForPrice(order.openPrice, chartHeight: chartHeight, priceRange: priceRange)
            if entryY >= 0 && entryY <= chartHeight {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: entryY))
                path.addLine(to: CGPoint(x: chartWidth, y: entryY))
                context.stroke(path, with: .color(pendingEntryColor),
                               style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if order.stopLoss != 0 {
                let y = yForPrice(order.stopLoss, chartHeight: chartHeight, priceRange: priceRange)
                if y >= 0 && y <= chartHeight {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: chartWidth, y: y))
                    context.stroke(path, with: .color(bearishColor.opacity(0.7)),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            if order.takeProfit != 0 {
                let y = yForPrice(order.takeProfit, chartHeight: chartHeight, priceRange: priceRange)
                if y >= 0 && y <= chartHeight {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: chartWidth, y: y))
                    context.stroke(path, with: .color(bullishColor.opacity(0.7)),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
        }
    }

    private func drawPendingOrderLabels(context: inout GraphicsContext, chartWidth: CGFloat,
                                         chartHeight: CGFloat, priceRange: (min: Double, max: Double)) {
        for order in relevantPendingOrders {
            let typeTag = order.orderType.replacingOccurrences(of: "_", with: " ")
            for (price, color, tag) in [
                (order.openPrice, pendingEntryColor, typeTag),
                (order.stopLoss, bearishColor, "SL"),
                (order.takeProfit, bullishColor, "TP"),
            ] where price != 0 {
                let y = yForPrice(price, chartHeight: chartHeight, priceRange: priceRange)
                guard y >= 0 && y <= chartHeight else { continue }

                let label = Text("\(tag) \(String(format: "%.5f", price))")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                let resolved = context.resolve(label)
                let labelSize = resolved.measure(in: CGSize(width: 200, height: 20))

                let pillRect = CGRect(
                    x: chartWidth + 2,
                    y: y - labelSize.height / 2 - 2,
                    width: labelSize.width + 8,
                    height: labelSize.height + 4
                )
                context.fill(Path(roundedRect: pillRect, cornerRadius: 3), with: .color(color))
                context.draw(resolved, at: CGPoint(x: chartWidth + 6, y: y), anchor: .leading)
            }
        }
    }

    // MARK: - User drawings

    private let drawingDefaultColor = Color.white.opacity(0.9)
    private let drawingSelectedColor = Color.yellow

    private func drawUserDrawings(context: inout GraphicsContext, chartWidth: CGFloat,
                                   chartHeight: CGFloat, priceRange: (min: Double, max: Double)) {
        for drawing in drawings {
            let isSelected = drawing.id == selectedDrawingID
            drawSingleDrawing(context: &context, drawing: drawing, isSelected: isSelected,
                              chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange)
        }
    }

    private func drawSingleDrawing(context: inout GraphicsContext, drawing: Drawing,
                                    isSelected: Bool, chartWidth: CGFloat,
                                    chartHeight: CGFloat, priceRange: (min: Double, max: Double)) {
        guard !bars.isEmpty else { return }

        // Freehand: stroke the captured polyline. Covers the in-flight preview too.
        if drawing.kind == .freehand, let pts = drawing.points, pts.count > 1 {
            let screenPts = pts.map { point in
                CGPoint(x: xForTimeMs(point.timeMs),
                        y: yForPrice(point.price, chartHeight: chartHeight, priceRange: priceRange))
            }
            let minX = screenPts.map(\.x).min() ?? 0
            let maxX = screenPts.map(\.x).max() ?? 0
            if minX > chartWidth || maxX < 0 { return }

            let color = isSelected ? drawingSelectedColor : drawingDefaultColor
            let lineWidth: CGFloat = isSelected ? 2.5 : 1.5
            var path = Path()
            path.move(to: screenPts[0])
            for pt in screenPts.dropFirst() { path.addLine(to: pt) }
            context.stroke(path, with: .color(color), lineWidth: lineWidth)
            return
        }

        let p1 = CGPoint(x: xForTimeMs(drawing.startTimeMs),
                         y: yForPrice(drawing.startPrice, chartHeight: chartHeight, priceRange: priceRange))
        let p2 = CGPoint(x: xForTimeMs(drawing.endTimeMs),
                         y: yForPrice(drawing.endPrice, chartHeight: chartHeight, priceRange: priceRange))
        // Cheap culling: segment entirely off the right of the chart.
        if min(p1.x, p2.x) > chartWidth { return }
        if max(p1.x, p2.x) < 0 { return }

        let color = isSelected ? drawingSelectedColor : drawingDefaultColor
        let lineWidth: CGFloat = isSelected ? 2.5 : 1.5

        var path = Path()
        path.move(to: p1)
        path.addLine(to: p2)
        context.stroke(path, with: .color(color), lineWidth: lineWidth)

        if drawing.kind == .arrow {
            let (tipL, tipR) = DrawingMath.arrowHeadTips(from: p1, to: p2, length: 10)
            var head = Path()
            head.move(to: p2); head.addLine(to: tipL)
            head.move(to: p2); head.addLine(to: tipR)
            context.stroke(head, with: .color(color), lineWidth: lineWidth)
        }
    }

    // MARK: - EMA

    private func computeEMA(period: Int) -> [Double] {
        guard !bars.isEmpty else { return [] }
        let k = 2.0 / Double(period + 1)
        var ema = [Double](repeating: 0, count: bars.count)
        ema[0] = bars[0].close
        for i in 1..<bars.count {
            ema[i] = bars[i].close * k + ema[i - 1] * (1 - k)
        }
        return ema
    }

    private func drawEMALines(
        context: inout GraphicsContext,
        chartHeight: CGFloat,
        priceRange: (min: Double, max: Double),
        visibleRange: Range<Int>
    ) {
        for config in emaConfigs {
            let values = computeEMA(period: config.period)
            guard values.count > 1 else { continue }

            var path = Path()
            let start = visibleRange.lowerBound
            let end = visibleRange.upperBound

            for i in start..<end {
                let x = xForBar(index: i)
                let y = yForPrice(values[i], chartHeight: chartHeight, priceRange: priceRange)
                if i == start { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(config.color), lineWidth: 1.5)
        }
    }

    // MARK: - Volume

    private func drawVolumeBars(
        context: inout GraphicsContext,
        chartWidth: CGFloat,
        chartHeight: CGFloat,
        volumeHeight: CGFloat,
        visibleRange: Range<Int>
    ) {
        guard !visibleRange.isEmpty, volumeHeight > 0 else { return }

        // Separator line between candle area and volume pane
        var sepPath = Path()
        sepPath.move(to: CGPoint(x: 0, y: chartHeight))
        sepPath.addLine(to: CGPoint(x: chartWidth, y: chartHeight))
        context.stroke(sepPath, with: .color(gridColor), lineWidth: 0.5)

        // Find max volume for scaling
        var maxVol = 0.0
        for i in visibleRange {
            maxVol = max(maxVol, bars[i].volume)
        }
        guard maxVol > 0 else { return }

        let bodyWidth = transform.candleBodyWidth
        let volumeBottom = chartHeight + volumeHeight

        for i in visibleRange {
            let bar = bars[i]
            let centerX = xForBar(index: i)
            let barHeight = CGFloat(bar.volume / maxVol) * (volumeHeight - 2) // 2px top padding
            let color = bar.isBullish ? bullishColor.opacity(0.4) : bearishColor.opacity(0.4)

            let rect = CGRect(
                x: centerX - bodyWidth / 2,
                y: volumeBottom - barHeight,
                width: bodyWidth,
                height: barHeight
            )
            context.fill(Path(rect), with: .color(color))
        }
    }

    // MARK: - Volume SMA

    private func computeVolumeSMA(period: Int) -> [Double] {
        guard !bars.isEmpty else { return [] }
        var sma = [Double](repeating: 0, count: bars.count)
        var runningSum = 0.0
        for i in 0..<bars.count {
            runningSum += bars[i].volume
            if i >= period {
                runningSum -= bars[i - period].volume
                sma[i] = runningSum / Double(period)
            } else {
                sma[i] = runningSum / Double(i + 1)
            }
        }
        return sma
    }

    private func drawVolumeSMALine(
        context: inout GraphicsContext,
        chartHeight: CGFloat,
        volumeHeight: CGFloat,
        maxVol: Double,
        visibleRange: Range<Int>
    ) {
        guard maxVol > 0 else { return }
        let values = computeVolumeSMA(period: volumeMA.period)
        guard values.count > 1 else { return }

        let volumeBottom = chartHeight + volumeHeight
        var path = Path()

        for i in visibleRange {
            let x = xForBar(index: i)
            let y = volumeBottom - CGFloat(values[i] / maxVol) * (volumeHeight - 2)
            if i == visibleRange.lowerBound { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.stroke(path, with: .color(volumeMA.color), lineWidth: 1.5)
    }

    // MARK: - Visual Order Box

    /// Fixed-size control panel for amount / R:R / risk text / Confirm-Cancel. Width and
    /// height are pixel-fixed so the internal layout never squishes when the price-based
    /// box is shallow. Anchored horizontally to the box midX and vertically into the TP
    /// zone (above entry for BUY, below for SELL), clamped to chart bounds so it never
    /// disappears off-screen. May extend beyond the box's chart-rendered border — the
    /// panel is a sticker on top of the box, not a sub-rect of it.
    static let visualOrderPanelWidth: CGFloat = 180
    static let visualOrderPanelHeight: CGFloat = 140

    /// Default: panel BESIDE the box on the right (the empty future area, ahead of the live
    /// bar), vertically centred on the entry line — clears both the candles and the SL/TP
    /// zones. When there's no room on the right (box near the chart edge), drop it onto the
    /// RISK side instead of back over the candles: BELOW the box for a BUY (TP/green is above),
    /// ABOVE for a SELL — flipping if the preferred side has no room, clamping as a last resort.
    static func visualOrderPanelRect(boxLeft: CGFloat, boxRight: CGFloat, entryY: CGFloat,
                                     boxTopY: CGFloat, boxBottomY: CGFloat, isBuy: Bool,
                                     chartWidth: CGFloat, chartHeight: CGFloat) -> CGRect {
        let width = visualOrderPanelWidth
        let height = visualOrderPanelHeight
        let gap: CGFloat = 8
        func clampY(_ y: CGFloat) -> CGFloat { max(4, min(chartHeight - height - 4, y)) }
        func fitsY(_ y: CGFloat) -> Bool { y >= 4 && y + height <= chartHeight - 4 }

        // Preferred: to the right of the box.
        let rightX = boxRight + gap
        if rightX + width <= chartWidth - 4 {
            return CGRect(x: rightX, y: clampY(entryY - height / 2), width: width, height: height)
        }

        // Fallback: on the risk side, anchored to the box's left edge (just past the newest
        // candle), clamped on-screen.
        let x = max(4, min(chartWidth - width - 4, boxLeft))
        let belowY = boxBottomY + gap
        let aboveY = boxTopY - gap - height
        let y: CGFloat = isBuy
            ? (fitsY(belowY) ? belowY : (fitsY(aboveY) ? aboveY : clampY(belowY)))
            : (fitsY(aboveY) ? aboveY : (fitsY(belowY) ? belowY : clampY(aboveY)))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Y-coordinate for the amount row (and ± buttons) inside the panel.
    static func visualOrderPanelAmountY(panelRect: CGRect) -> CGFloat {
        panelRect.minY + 12
    }

    /// `boxRight` to pass into `visualOrderButtonRects` so Confirm/Cancel land
    /// inside the panel's bottom-right corner.
    static func visualOrderPanelButtonsRight(panelRect: CGRect) -> CGFloat {
        panelRect.maxX - 2
    }

    /// `boxBottom` to pass into `visualOrderButtonRects` so the button row anchors
    /// to the panel's bottom edge.
    static func visualOrderPanelButtonsBottom(panelRect: CGRect) -> CGFloat {
        panelRect.maxY - 4
    }

    /// Button rect positions for visual order confirm/cancel — shared between drawing and hit-testing.
    static func visualOrderButtonRects(boxRight: CGFloat, boxBottom: CGFloat) -> (confirm: CGRect, cancel: CGRect) {
        let bw: CGFloat = 28
        let bh: CGFloat = 22
        let margin: CGFloat = 6
        let confirmRect = CGRect(x: boxRight - margin - bw * 2 - 4, y: boxBottom - margin - bh, width: bw, height: bh)
        let cancelRect = CGRect(x: boxRight - margin - bw, y: boxBottom - margin - bh, width: bw, height: bh)
        return (confirmRect, cancelRect)
    }

    /// Hit rect for the amount label text — tapping resets to auto-calculated size.
    static func visualOrderAmountLabelRect(midX: CGFloat, amountY: CGFloat) -> CGRect {
        CGRect(x: midX - 50, y: amountY - 1, width: 100, height: 16)
    }

    /// Button rect positions for visual order amount +/- — shared between drawing and hit-testing.
    static func visualOrderAmountButtonRects(midX: CGFloat, amountY: CGFloat) -> (minus: CGRect, plus: CGRect) {
        let bw: CGFloat = 20
        let bh: CGFloat = 16
        let spacing: CGFloat = 52
        let minusRect = CGRect(x: midX - spacing - bw, y: amountY - 1, width: bw, height: bh)
        let plusRect = CGRect(x: midX + spacing, y: amountY - 1, width: bw, height: bh)
        return (minusRect, plusRect)
    }

    private func drawVisualOrderBox(context: inout GraphicsContext, chartWidth: CGFloat,
                                     chartHeight: CGFloat, priceRange: (min: Double, max: Double),
                                     order: VisualOrderState, isSubmitting: Bool) {
        // Dim everything while a submit is in flight to signal the box is non-interactive.
        let alpha: Double = isSubmitting ? 0.4 : 1.0
        let slY = yForPrice(order.stopLoss, chartHeight: chartHeight, priceRange: priceRange)
        let tpY = yForPrice(order.takeProfit, chartHeight: chartHeight, priceRange: priceRange)
        let entryY = yForPrice(order.entryPrice, chartHeight: chartHeight, priceRange: priceRange)

        let leftX = xForBar(index: order.startBarIndex) - transform.candleSlotWidth / 2
        let rightX = xForBar(index: order.endBarIndex) + transform.candleSlotWidth / 2
        let topY = min(slY, tpY)
        let bottomY = max(slY, tpY)

        // Split background: green for TP zone, red for SL zone
        let isBuy = order.direction == "BUY"
        let tpZoneTop = isBuy ? topY : entryY
        let tpZoneBottom = isBuy ? entryY : bottomY
        let slZoneTop = isBuy ? entryY : topY
        let slZoneBottom = isBuy ? bottomY : entryY

        // TP zone (green)
        let tpRect = CGRect(x: leftX, y: tpZoneTop, width: rightX - leftX, height: tpZoneBottom - tpZoneTop)
        context.fill(Path(tpRect), with: .color(bullishColor.opacity(0.10)))

        // SL zone (red)
        let slRect = CGRect(x: leftX, y: slZoneTop, width: rightX - leftX, height: slZoneBottom - slZoneTop)
        context.fill(Path(slRect), with: .color(bearishColor.opacity(0.10)))

        // Box border
        let boxRect = CGRect(x: leftX, y: topY, width: rightX - leftX, height: bottomY - topY)
        context.stroke(Path(boxRect), with: .color(.white.opacity(0.3)),
                       style: StrokeStyle(lineWidth: 1))

        // SL line (full chart width)
        var slPath = Path()
        slPath.move(to: CGPoint(x: 0, y: slY))
        slPath.addLine(to: CGPoint(x: chartWidth, y: slY))
        context.stroke(slPath, with: .color(bearishColor),
                       style: StrokeStyle(lineWidth: 2, dash: [6, 3]))

        // TP line (full chart width)
        var tpPath = Path()
        tpPath.move(to: CGPoint(x: 0, y: tpY))
        tpPath.addLine(to: CGPoint(x: chartWidth, y: tpY))
        context.stroke(tpPath, with: .color(bullishColor),
                       style: StrokeStyle(lineWidth: 2, dash: [6, 3]))

        // Entry price line — thicker and full-width when user has dragged it off market,
        // so the pending-order entry is as visible as SL/TP.
        var entryPath = Path()
        if order.isEntryOverridden {
            entryPath.move(to: CGPoint(x: 0, y: entryY))
            entryPath.addLine(to: CGPoint(x: chartWidth, y: entryY))
            context.stroke(entryPath, with: .color(currentPriceColor),
                           style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
        } else {
            entryPath.move(to: CGPoint(x: leftX, y: entryY))
            entryPath.addLine(to: CGPoint(x: rightX, y: entryY))
            context.stroke(entryPath, with: .color(currentPriceColor),
                           style: StrokeStyle(lineWidth: 1))
        }

        // Fixed-size control panel — sits beside the box (right-preferred). Computed before
        // the SL/TP labels so the labels can be placed on the OPPOSITE side and never hide
        // behind the panel.
        let panelRect = Self.visualOrderPanelRect(
            boxLeft: leftX, boxRight: rightX, entryY: entryY,
            boxTopY: topY, boxBottomY: bottomY, isBuy: isBuy,
            chartWidth: chartWidth, chartHeight: chartHeight
        )

        // SL/TP price labels sit on the dashed lines at the box edge, on the side AWAY from
        // the panel (panel right → labels left, and vice versa) so they're always legible.
        let panelOnRight = panelRect.minX >= rightX
        let labelFont = Font.system(size: 9, weight: .medium, design: .monospaced)
        let decimalPlaces = order.instrument.contains("JPY") ? 3 : 5
        let labelX = panelOnRight ? leftX - 4 : rightX + 4
        let labelAnchor: UnitPoint = panelOnRight ? .trailing : .leading
        let slLabel = context.resolve(Text(String(format: "SL %.\(decimalPlaces)f", order.stopLoss))
            .font(labelFont).foregroundStyle(bearishColor))
        context.draw(slLabel, at: CGPoint(x: labelX, y: slY), anchor: labelAnchor)

        let tpLabel = context.resolve(Text(String(format: "TP %.\(decimalPlaces)f", order.takeProfit))
            .font(labelFont).foregroundStyle(bullishColor))
        context.draw(tpLabel, at: CGPoint(x: labelX, y: tpY), anchor: labelAnchor)

        context.fill(Path(roundedRect: panelRect, cornerRadius: 5),
                     with: .color(.black.opacity(0.78 * alpha)))
        context.stroke(Path(roundedRect: panelRect, cornerRadius: 5),
                       with: .color(.white.opacity(0.2 * alpha)),
                       style: StrokeStyle(lineWidth: 1))

        let textStyle = Font.system(size: 10, weight: .medium, design: .monospaced)
        let panelMidX = panelRect.midX
        let amountY = Self.visualOrderPanelAmountY(panelRect: panelRect)

        let amountSuffix = order.isAmountOverridden ? " (M)" : ""
        let standardLots = order.amount * 10
        let amountText = String(format: "%g lots%@", standardLots, amountSuffix)
        if !incognitoMode {
            let resolvedAmount = context.resolve(Text(amountText).font(textStyle).foregroundStyle(.white.opacity(0.9 * alpha)))
            let amountSize = resolvedAmount.measure(in: CGSize(width: 200, height: 20))
            context.draw(resolvedAmount, at: CGPoint(x: panelMidX - amountSize.width / 2, y: amountY), anchor: .topLeading)

            let (minusRect, plusRect) = Self.visualOrderAmountButtonRects(midX: panelMidX, amountY: amountY)
            context.fill(Path(roundedRect: minusRect, cornerRadius: 3), with: .color(.white.opacity(0.15 * alpha)))
            let minusSymbol = context.resolve(Text("\u{2212}").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.8 * alpha)))
            context.draw(minusSymbol, at: CGPoint(x: minusRect.midX, y: minusRect.midY), anchor: .center)
            context.fill(Path(roundedRect: plusRect, cornerRadius: 3), with: .color(.white.opacity(0.15 * alpha)))
            let plusSymbol = context.resolve(Text("+").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.8 * alpha)))
            context.draw(plusSymbol, at: CGPoint(x: plusRect.midX, y: plusRect.midY), anchor: .center)
        }

        let realizedDistance = abs(order.entryPrice - order.stopLoss) + max(0, visualOrderSpread)
        let riskMoney = order.amount * realizedDistance * 1_000_000
        var riskMoneyText = String(format: "Risk  %.0f", riskMoney)
        if let eq = accountEquity, eq > 0 {
            riskMoneyText += String(format: "  (%.1f%%)", (riskMoney / eq) * 100)
        }
        var infoLines: [(String, Color)] = [
            (String(format: "R:R  %.1f", order.riskRewardRatio(spread: visualOrderSpread)), .white.opacity(0.8 * alpha)),
            (String(format: "Risk  %.1f pips", order.riskPips), .white.opacity(0.8 * alpha)),
            (String(format: "Reward  %.1f pips", order.rewardPips), .white.opacity(0.8 * alpha)),
        ]
        if !incognitoMode {
            infoLines.append((riskMoneyText, .white.opacity(0.8 * alpha)))
        }
        if order.isEntryOverridden {
            let typeLabel = order.orderType.replacingOccurrences(of: "_", with: " ")
            let entryText = String(
                format: "%@  %.\(order.instrument.contains("JPY") ? 3 : 5)f  (%+.1f pips)",
                typeLabel, order.entryPrice, order.entryOffsetPips)
            infoLines.append((entryText, Color.orange.opacity(alpha)))
        }
        if order.isMarginCapped && !incognitoMode {
            infoLines.append(("margin limited", Color.orange.opacity(alpha)))
        }
        let lineHeight: CGFloat = 14
        let infoStartY = amountY + 20
        for (i, (text, color)) in infoLines.enumerated() {
            let y = infoStartY + CGFloat(i) * lineHeight
            let resolved = context.resolve(Text(text).font(textStyle).foregroundStyle(color))
            let textSize = resolved.measure(in: CGSize(width: 200, height: 20))
            context.draw(resolved, at: CGPoint(x: panelMidX - textSize.width / 2, y: y), anchor: .topLeading)
        }

        // Confirm / Cancel — bottom-right of panel.
        let buttonsRight = Self.visualOrderPanelButtonsRight(panelRect: panelRect)
        let buttonsBottom = Self.visualOrderPanelButtonsBottom(panelRect: panelRect)
        let (confirmRect, cancelRect) = Self.visualOrderButtonRects(boxRight: buttonsRight, boxBottom: buttonsBottom)

        context.fill(Path(roundedRect: confirmRect, cornerRadius: 4),
                     with: .color(bullishColor.opacity(0.8 * alpha)))
        if isSubmitting {
            let dots = context.resolve(Text("\u{2026}").font(.system(size: 14, weight: .bold)).foregroundStyle(.white))
            context.draw(dots, at: CGPoint(x: confirmRect.midX, y: confirmRect.midY), anchor: .center)
        } else {
            let checkmark = context.resolve(Text("\u{2713}").font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
            context.draw(checkmark, at: CGPoint(x: confirmRect.midX, y: confirmRect.midY), anchor: .center)
        }

        context.fill(Path(roundedRect: cancelRect, cornerRadius: 4),
                     with: .color(bearishColor.opacity(0.8 * alpha)))
        let xmark = context.resolve(Text("\u{2717}").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(alpha)))
        context.draw(xmark, at: CGPoint(x: cancelRect.midX, y: cancelRect.midY), anchor: .center)
    }

    // MARK: - Helpers

    private func niceGridStep(span: Double, targetLines: Int) -> Double {
        let rough = span / Double(targetLines)
        guard rough > 1e-15 else { return 0.0001 }
        let magnitude = pow(10, floor(log10(rough)))
        let residual = rough / magnitude
        let nice: Double
        if residual <= 1.5 { nice = 1 }
        else if residual <= 3.5 { nice = 2 }
        else if residual <= 7.5 { nice = 5 }
        else { nice = 10 }
        return nice * magnitude
    }
}

