import Foundation

struct ChartTransform: Equatable {
    var xOffset: CGFloat = 0      // Horizontal scroll position (pixels)
    var xScale: CGFloat = 1.0     // Zoom level (1.0 = default)

    // Base candle width at scale 1.0
    private let baseCandleWidth: CGFloat = 10

    var candleSlotWidth: CGFloat {
        baseCandleWidth * xScale
    }

    var candleBodyWidth: CGFloat {
        candleSlotWidth * 0.6
    }
}
