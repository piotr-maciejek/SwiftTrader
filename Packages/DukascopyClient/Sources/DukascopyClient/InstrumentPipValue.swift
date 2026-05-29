import Foundation

/// Per-instrument pip value, needed to scale the integer prices in `.bi5` candle records
/// (`price = raw / 10 * pipValue`). For FX the rule is simple: JPY-quoted pairs use 0.01,
/// everything else 0.0001. A small override table covers the non-FX instruments whose pip
/// value doesn't follow that rule. Mirrors the values in JForex's `Instrument` enum.
public enum InstrumentPipValue {
    public static func pipValue(for instrument: String) -> Double {
        let code = instrument.replacingOccurrences(of: "/", with: "").uppercased()
        if let override = overrides[code] { return override }
        if code.count == 6 && code.hasSuffix("JPY") { return 0.01 }
        return 0.0001
    }

    private static let overrides: [String: Double] = [
        "XAGUSD": 0.001,
        "XAUUSD": 0.01,
    ]
}
