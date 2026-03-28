import SwiftUI

struct ChartView: View {
    let bars: [CandleBar]
    @Binding var transform: ChartTransform
    var onChartWidthChanged: ((CGFloat) -> Void)?
    var onUserDrag: (() -> Void)?

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
            let chartHeight = geo.size.height - timeAxisHeight

            ZStack(alignment: .topLeading) {
                // Main chart canvas
                Canvas { context, size in
                    let visibleRange = visibleBarRange(chartWidth: chartWidth)
                    let priceRange = priceRange(for: visibleRange)

                    // Clip chart content so candles/grid don't bleed into the price axis
                    let chartClip = Path(CGRect(x: 0, y: 0, width: chartWidth, height: chartHeight))
                    var chartContext = context
                    chartContext.clip(to: chartClip)

                    drawGrid(context: &chartContext, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange)
                    drawCandles(context: &chartContext, chartWidth: chartWidth, chartHeight: chartHeight, visibleRange: visibleRange, priceRange: priceRange)
                    drawCurrentPriceLine(context: &chartContext, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange)

                    // Price axis and time axis drawn unclipped so they render in their reserved areas
                    drawPriceAxis(context: &context, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange)
                    drawCurrentPriceLabel(context: &context, chartWidth: chartWidth, chartHeight: chartHeight, priceRange: priceRange)
                    drawTimeAxis(context: &context, chartWidth: chartWidth, chartHeight: chartHeight, visibleRange: visibleRange)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .overlay(alignment: .topLeading) {
                    ChartInteractionView(
                        transform: $transform,
                        barCount: bars.count,
                        chartWidth: chartWidth,
                        onUserDrag: onUserDrag
                    )
                    .frame(width: chartWidth, height: chartHeight)
                }
                .onAppear {
                    onChartWidthChanged?(chartWidth)
                    let totalWidth = CGFloat(bars.count) * transform.candleSlotWidth
                    if totalWidth > chartWidth {
                        transform.xOffset = totalWidth - chartWidth
                    }
                }
                .onChange(of: chartWidth) { _, newWidth in
                    onChartWidthChanged?(newWidth)
                }
            }
        }
    }

    // MARK: - Visible range calculation

    private func visibleBarRange(chartWidth: CGFloat) -> Range<Int> {
        guard !bars.isEmpty else { return 0..<0 }
        let slotWidth = transform.candleSlotWidth
        let startIndex = max(0, Int(floor(transform.xOffset / slotWidth)))
        let endIndex = min(bars.count, Int(ceil((transform.xOffset + chartWidth) / slotWidth)) + 1)
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
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd MMM yy"
        let calendar = Calendar.current

        // Show a time label roughly every 80px
        let step = max(1, Int(80 / transform.candleSlotWidth))

        var lastDay: Int?
        for i in stride(from: visibleRange.lowerBound, to: visibleRange.upperBound, by: step) {
            let x = xForBar(index: i)
            guard x > 0 && x < chartWidth else { continue }

            let date = bars[i].date
            let day = calendar.component(.day, from: date)
            let dayChanged = lastDay != nil && day != lastDay
            lastDay = day

            if dayChanged {
                // Show date on top, time below
                let dateLine = Text(dateFormatter.string(from: date))
                    .font(.system(size: 8, design: .monospaced))
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
    }

    // MARK: - Helpers

    private func niceGridStep(span: Double, targetLines: Int) -> Double {
        let rough = span / Double(targetLines)
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
