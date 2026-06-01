import Foundation

/// Converts a position's raw price move into pips and account-currency money.
///
/// Account-currency-agnostic (demo PLN, live EUR, …): per-position P&L is computed
/// in the pair's quote currency, then converted to the account currency using mid
/// rates derived from the live tick stream. When no cross rate is available (e.g. a
/// PLN cross we don't subscribe to) it falls back to the quote-currency value — the
/// account *equity* (from the account message, already in account currency with
/// unrealized P&L baked in) remains the authoritative money figure.
enum PnLConverter {
    static func pipFactor(for instrument: String) -> Double {
        instrument.contains("JPY") ? 100 : 10_000
    }

    /// `instrument` slashless ("EURUSD"); `amountUnits` the position size in units;
    /// `rates` maps slashless instrument → mid price (from live ticks).
    static func compute(
        side: String, openPrice: Double, markPrice: Double, amountUnits: Double,
        instrument: String, accountCurrency: String, rates: [String: Double]
    ) -> (pips: Double, money: Double) {
        let dir = side == "BUY" ? 1.0 : -1.0
        let delta = (markPrice - openPrice) * dir
        let pips = delta * pipFactor(for: instrument)
        let pnlQuote = delta * amountUnits
        let quoteCcy = String(instrument.suffix(3)).uppercased()
        let money: Double
        if let rate = rate(from: quoteCcy, to: accountCurrency.uppercased(), rates: rates) {
            money = pnlQuote * rate
        } else {
            money = pnlQuote   // fallback — quote-ccy value; equity is authoritative
        }
        return (pips, money)
    }

    /// Conversion rate quote→account using slashless rate keys (direct or inverse).
    static func rate(from quote: String, to acct: String, rates: [String: Double]) -> Double? {
        if quote == acct { return 1 }
        if let direct = rates["\(quote)\(acct)"] { return direct }                       // QUOTE/ACCT
        if let inverse = rates["\(acct)\(quote)"], inverse != 0 { return 1 / inverse }    // ACCT/QUOTE
        return nil
    }
}
