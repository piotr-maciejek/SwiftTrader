import SwiftUI

struct ChartView: View {
    let bars: [CandleBar]
    @Binding var transform: ChartTransform
    var onChartWidthChanged: ((CGFloat) -> Void)?
    var onUserDrag: (() -> Void)?
    var showSessions: Bool = true
    var currentPeriod: String = "FIFTEEN_MINS"
    var showVolume: Bool = true
    var showVolumeMA: Bool = true
    var volumeMA: EMALine = EMALine(period: 20, color: .cyan)
    var showEMA: Bool = true
    var emaConfigs: [EMALine] = []
    var positions: [Position] = []
    var currentInstrument: String = ""
    var showATR: Bool = true
    var atrPeriod: Int = 14
    var atrPips: Double?
    var todayATRPercent: Double?
    var onModifyPosition: ((String, Double, Double) -> Void)? = nil
    var visualOrder: VisualOrderState? = nil
    var onConfirmVisualOrder: (() -> Void)? = nil
    var onCancelVisualOrder: (() -> Void)? = nil
    var onUpdateVisualOrderSL: ((Double) -> Void)? = nil
    var onUpdateVisualOrderTP: ((Double) -> Void)? = nil
    var onAdjustVisualOrderAmount: ((Double) -> Void)? = nil
    var onResetVisualOrderAmount: (() -> Void)? = nil
    var accountEquity: Double? = nil
    /// True while a submit is in flight — disables visual-order interactions and dims the box.
    var isSubmittingOrder: Bool = false
    @State private var crosshair: CrosshairState? = nil
    @State private var dragPreview: DragPreviewState? = nil
    @State private var pendingSLTPEdit: PendingChartSLTPEdit? = nil

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
                    }

                    // Price axis and time axis drawn unclipped so they render in their reserved areas
                    drawPriceAxis(context: &context, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange)
                    drawCurrentPriceLabel(context: &context, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange)
                    drawSLTPLabels(context: &context, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange)
                    drawTimeAxis(context: &context, chartWidth: chartWidth, chartHeight: chartHeight, visibleRange: visibleRange)
                    if let ch = crosshair, !bars.isEmpty {
                        drawCrosshairLabels(context: &context, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange, crosshair: ch)
                    }
                    if showATR, let pips = atrPips, let percent = todayATRPercent {
                        drawATROverlay(context: &context, chartWidth: chartWidth, atrPeriod: atrPeriod, atrPips: pips, todayPercent: percent)
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
                        chartHeight: chartHeight,
                        priceRange: priceRange(for: visibleBarRange(chartWidth: chartWidth)),
                        dragPreview: $dragPreview,
                        pendingSLTPEdit: $pendingSLTPEdit,
                        visualOrder: visualOrder,
                        onConfirmVisualOrder: onConfirmVisualOrder,
                        onCancelVisualOrder: onCancelVisualOrder,
                        onUpdateVisualOrderSL: onUpdateVisualOrderSL,
                        onUpdateVisualOrderTP: onUpdateVisualOrderTP,
                        onAdjustVisualOrderAmount: onAdjustVisualOrderAmount,
                        onResetVisualOrderAmount: onResetVisualOrderAmount,
                        isSubmittingOrder: isSubmittingOrder
                    )
                    .frame(width: chartWidth, height: chartHeight + volumeHeight)
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
                        if let edit = pendingSLTPEdit {
                            onModifyPosition?(edit.label, edit.stopLoss, edit.takeProfit)
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
                .onAppear {
                    onChartWidthChanged?(chartWidth)
                }
                .onChange(of: chartWidth) { _, newWidth in
                    onChartWidthChanged?(newWidth)
                }
            }
        }
    }

    // MARK: - Visible range calculation

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
        // Include visual order SL/TP so they're always visible
        if let vo = visualOrder {
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
        return (lo - padding, hi + padding)
    }

    // MARK: - Coordinate mapping

    private func xForBar(index: Int) -> CGFloat {
        CGFloat(index) * transform.candleSlotWidth - transform.xOffset + transform.candleSlotWidth / 2
    }

    private func yForPrice(_ price: Double, chartHeight: CGFloat, priceRange: (min: Double, max: Double)) -> CGFloat {
        let normalized = (price - priceRange.min) / (priceRange.max - priceRange.min)
        return chartHeight * (1 - CGFloat(normalized))
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

    private func drawCurrentPriceLine(context: inout GraphicsContext, chartWidth: CGFloat, chartHeight: CGFloat, priceRange: (min: Double, max: Double)) {
        guard let lastBar = bars.last else { return }
        let y = yForPrice(lastBar.close, chartHeight: chartHeight, priceRange: priceRange)
        guard y >= 0 && y <= chartHeight else { return }

        var path = Path()
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: chartWidth, y: y))
        context.stroke(
            path,
            with: .color(currentPriceColor),
            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
        )
    }

    /// Draws the current price label in the price axis area (called unclipped).
    private func drawCurrentPriceLabel(context: inout GraphicsContext, chartWidth: CGFloat, chartHeight: CGFloat, priceRange: (min: Double, max: Double)) {
        guard let lastBar = bars.last else { return }
        let price = lastBar.close
        let y = yForPrice(price, chartHeight: chartHeight, priceRange: priceRange)
        guard y >= 0 && y <= chartHeight else { return }

        let label = Text(String(format: "%.5f", price))
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
        context.fill(
            Path(roundedRect: pillRect, cornerRadius: 3),
            with: .color(currentPriceColor)
        )
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

    private static let crosshairTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func priceForY(_ y: CGFloat, chartHeight: CGFloat, priceRange: (min: Double, max: Double)) -> Double {
        let normalized = 1.0 - Double(y / chartHeight)
        return priceRange.min + normalized * (priceRange.max - priceRange.min)
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
        let timeStr = Self.crosshairTimeFormatter.string(from: bar.date)
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
        let color: Color = preview.field == .stopLoss ? bearishColor : bullishColor
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

    // MARK: - ATR overlay

    private func drawATROverlay(
        context: inout GraphicsContext,
        chartWidth: CGFloat,
        atrPeriod: Int,
        atrPips: Double,
        todayPercent: Double
    ) {
        let text = String(format: "ATR(%d): %.1f pips  |  Today: %.0f%%", atrPeriod, atrPips, todayPercent)
        let resolved = context.resolve(
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.secondary.opacity(0.8))
        )
        let size = resolved.measure(in: CGSize(width: chartWidth, height: .infinity))
        // Top-left corner with padding
        context.draw(resolved, at: CGPoint(x: 8, y: 8), anchor: .topLeading)
        _ = size // suppress unused warning
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

        // Entry price line (solid blue)
        var entryPath = Path()
        entryPath.move(to: CGPoint(x: leftX, y: entryY))
        entryPath.addLine(to: CGPoint(x: rightX, y: entryY))
        context.stroke(entryPath, with: .color(currentPriceColor),
                       style: StrokeStyle(lineWidth: 1))

        // Info text
        let midX = (leftX + rightX) / 2
        let textStyle = Font.system(size: 10, weight: .medium, design: .monospaced)

        let amountSuffix = order.isAmountOverridden ? " (M)" : ""
        let standardLots = order.amount * 10
        let amountText = String(format: "%g lots%@", standardLots, amountSuffix)
        let riskMoney = order.amount * abs(order.entryPrice - order.stopLoss) * 1_000_000
        var riskMoneyText = String(format: "Risk  %.0f", riskMoney)
        if let eq = accountEquity, eq > 0 {
            riskMoneyText += String(format: "  (%.1f%%)", (riskMoney / eq) * 100)
        }
        let rrText = String(format: "R:R  %.1f", order.riskRewardRatio)
        let riskText = String(format: "Risk  %.1f pips", order.riskPips)
        let rewardText = String(format: "Reward  %.1f pips", order.rewardPips)

        let lineHeight: CGFloat = 14
        let textBlockY = entryY - lineHeight * 2.5

        // Amount row with +/- buttons
        let amountY = textBlockY
        let resolvedAmount = context.resolve(Text(amountText).font(textStyle).foregroundStyle(.white.opacity(0.9)))
        let amountSize = resolvedAmount.measure(in: CGSize(width: 200, height: 20))
        context.draw(resolvedAmount, at: CGPoint(x: midX - amountSize.width / 2, y: amountY), anchor: .topLeading)

        let (minusRect, plusRect) = Self.visualOrderAmountButtonRects(midX: midX, amountY: amountY)
        context.fill(Path(roundedRect: minusRect, cornerRadius: 3), with: .color(.white.opacity(0.15)))
        let minusSymbol = context.resolve(Text("\u{2212}").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.8)))
        context.draw(minusSymbol, at: CGPoint(x: minusRect.midX, y: minusRect.midY), anchor: .center)
        context.fill(Path(roundedRect: plusRect, cornerRadius: 3), with: .color(.white.opacity(0.15)))
        let plusSymbol = context.resolve(Text("+").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.8)))
        context.draw(plusSymbol, at: CGPoint(x: plusRect.midX, y: plusRect.midY), anchor: .center)

        var infoLines: [(String, Color)] = [
            (rrText, .white.opacity(0.8)),
            (riskText, .white.opacity(0.8)),
            (rewardText, .white.opacity(0.8)),
            (riskMoneyText, .white.opacity(0.8)),
        ]
        if order.isMarginCapped {
            infoLines.append(("margin limited", Color.orange))
        }
        for (i, (text, color)) in infoLines.enumerated() {
            let y = textBlockY + CGFloat(i + 1) * lineHeight
            let resolved = context.resolve(Text(text).font(textStyle).foregroundStyle(color))
            let textSize = resolved.measure(in: CGSize(width: 200, height: 20))
            context.draw(resolved, at: CGPoint(x: midX - textSize.width / 2, y: y), anchor: .topLeading)
        }

        // Confirm / Cancel buttons
        let (confirmRect, cancelRect) = Self.visualOrderButtonRects(boxRight: rightX, boxBottom: bottomY)

        // Confirm button (green). If a submit is in flight, render a spinner-style progress ring instead of the checkmark.
        context.fill(Path(roundedRect: confirmRect, cornerRadius: 4),
                     with: .color(bullishColor.opacity(0.8 * alpha)))
        if isSubmitting {
            let dots = context.resolve(Text("\u{2026}").font(.system(size: 14, weight: .bold)).foregroundStyle(.white))
            context.draw(dots, at: CGPoint(x: confirmRect.midX, y: confirmRect.midY), anchor: .center)
        } else {
            let checkmark = context.resolve(Text("\u{2713}").font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
            context.draw(checkmark, at: CGPoint(x: confirmRect.midX, y: confirmRect.midY), anchor: .center)
        }

        // Cancel button (red)
        context.fill(Path(roundedRect: cancelRect, cornerRadius: 4),
                     with: .color(bearishColor.opacity(0.8 * alpha)))
        let xmark = context.resolve(Text("\u{2717}").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(alpha)))
        context.draw(xmark, at: CGPoint(x: cancelRect.midX, y: cancelRect.midY), anchor: .center)

        // SL/TP price labels on right side of box
        let labelFont = Font.system(size: 9, weight: .medium, design: .monospaced)
        let decimalPlaces = order.instrument.contains("JPY") ? 3 : 5
        let slLabel = context.resolve(Text(String(format: "SL %.\(decimalPlaces)f", order.stopLoss))
            .font(labelFont).foregroundStyle(bearishColor))
        context.draw(slLabel, at: CGPoint(x: rightX + 4, y: slY), anchor: .leading)

        let tpLabel = context.resolve(Text(String(format: "TP %.\(decimalPlaces)f", order.takeProfit))
            .font(labelFont).foregroundStyle(bullishColor))
        context.draw(tpLabel, at: CGPoint(x: rightX + 4, y: tpY), anchor: .leading)
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

