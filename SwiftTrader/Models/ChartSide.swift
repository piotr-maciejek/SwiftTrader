import Foundation
import DukascopyClient

/// Which side of the market a chart's candles (and on-demand history) are built from. Per-chart,
/// persisted in `ChartTabState`. The raw values are the stable tokens used in cache keys / on-disk
/// filenames, so don't rename them.
enum ChartSide: String, Codable, Sendable, Hashable, CaseIterable {
    case bid = "BID"
    case ask = "ASK"

    /// The wire-layer side passed to `DukascopySession` history/candle fetches.
    var offerSide: OfferSide { self == .bid ? .bid : .ask }

    var label: String { rawValue }
    var toggled: ChartSide { self == .bid ? .ask : .bid }
}
