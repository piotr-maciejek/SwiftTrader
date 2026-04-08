import Foundation

/// Formats an instrument code like "EURUSD" into "EUR/USD".
func formatInstrument(_ instrument: String) -> String {
    guard instrument.count == 6 else { return instrument }
    let idx = instrument.index(instrument.startIndex, offsetBy: 3)
    return "\(instrument[..<idx])/\(instrument[idx...])"
}

enum CurrencyCorrelation {
    /// Correlation pairs for each currency.
    static let pairs: [String: [String]] = [
        "EUR": ["EURUSD", "EURJPY", "EURGBP", "EURCHF", "EURAUD", "EURCAD"],
        "USD": ["EURUSD", "USDJPY", "GBPUSD", "AUDUSD", "USDCAD", "USDCHF"],
        "GBP": ["GBPUSD", "EURGBP", "GBPJPY", "GBPAUD", "GBPCAD", "GBPCHF"],
        "JPY": ["USDJPY", "EURJPY", "GBPJPY", "AUDJPY", "CADJPY", "CHFJPY"],
        "AUD": ["AUDUSD", "EURAUD", "GBPAUD", "AUDJPY", "AUDCAD", "AUDNZD"],
        "CAD": ["USDCAD", "EURCAD", "GBPCAD", "AUDCAD", "CADJPY", "NZDCAD"],
        "CHF": ["USDCHF", "EURCHF", "GBPCHF", "AUDCHF", "CADCHF", "CHFJPY"],
        "NZD": ["NZDUSD", "EURNZD", "GBPNZD", "NZDJPY", "AUDNZD", "NZDCAD"],
    ]

    /// Extract currency codes from an instrument that have correlation mappings.
    static func currencies(from instrument: String) -> [String] {
        guard instrument.count == 6 else { return [] }
        let base = String(instrument.prefix(3))
        let quote = String(instrument.suffix(3))
        return [base, quote].filter { pairs[$0] != nil }
    }

    /// Returns true if the currency is in the quote position (inverse correlation).
    static func isInverse(currency: String, instrument: String) -> Bool {
        guard instrument.count == 6 else { return false }
        return String(instrument.suffix(3)) == currency
    }
}
