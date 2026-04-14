import Foundation

/// Global FX turnover weights used to sort tabs by how actively a pair or currency
/// is traded. Shares come from the BIS Triennial Central Bank Survey (April 2025).
enum FXVolumeRank {
    /// Per-currency share of global FX turnover (percent). Sums to ~200% because
    /// every trade has two sides.
    static let currencyShare: [String: Double] = [
        "USD": 89.2,
        "EUR": 28.9,
        "JPY": 16.8,
        "GBP": 10.2,
        "CHF":  6.4,
        "AUD":  6.1,
        "CAD":  5.8,
        "NZD":  1.5,
    ]

    /// Rank of a currency. Higher = more actively traded. Unknown codes rank 0.
    static func rank(currency: String) -> Double {
        currencyShare[currency] ?? 0
    }

    /// Rank of a 6-char instrument like "EURUSD". Derived from the product of
    /// its two legs' currency shares — a good proxy for pair turnover that also
    /// degrades gracefully for crosses BIS does not publish explicitly.
    static func rank(pair: String) -> Double {
        guard pair.count == 6 else { return 0 }
        let base = String(pair.prefix(3))
        let quote = String(pair.suffix(3))
        guard let b = currencyShare[base], let q = currencyShare[quote] else { return 0 }
        return b * q
    }
}
