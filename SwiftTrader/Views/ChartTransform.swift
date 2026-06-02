import Foundation

struct ChartTransform: Equatable {
    var xOffset: CGFloat = 0      // Horizontal scroll position (pixels)
    var xScale: CGFloat = 1.0     // Horizontal zoom (1.0 = default)
    /// Vertical zoom (1.0 = auto-fit including SL/TP). Greater than 1 zooms in on candles
    /// and drops the SL/TP from priceRange — they may scroll out of view. Adjusted by
    /// dragging the price axis; reset to 1 with double-click.
    var yScale: Double = 1.0
    /// Price-units offset from the candle center, applied only when yScale != 1.
    /// Reserved for a future axis-pan gesture; defaults to 0.
    var yOffset: Double = 0

    /// One-shot guard: the view snaps `xOffset` to the live edge the first time it can
    /// measure the chart (real cell width), then sets this true and never auto-positions
    /// again — so a manual scroll is preserved across live ticks and tab switches. Reset to
    /// false (via `scrollToEnd()` / a transform reset) only when a fresh dataset loads.
    var hasAutoScrolledToEnd = false

    // Base candle width at scale 1.0
    private let baseCandleWidth: CGFloat = 10

    var candleSlotWidth: CGFloat {
        baseCandleWidth * xScale
    }

    var candleBodyWidth: CGFloat {
        candleSlotWidth * 0.6
    }

    /// True once the user has manually adjusted vertical zoom/pan.
    var hasManualYTransform: Bool {
        yScale != 1.0 || yOffset != 0
    }
}
