import Foundation

enum LoadingStage: Equatable {
    case connecting
    case loadingHistory(attempt: Int)
    case loadingEarlier
    case refreshing
}

struct LoadingStatus: Equatable {
    let stage: LoadingStage
    let message: String
    let detail: String?
    let lastError: String?

    static func connecting() -> LoadingStatus {
        LoadingStatus(
            stage: .connecting,
            message: "Connecting to server…",
            detail: "Waiting for localhost. Is jforex-server running?",
            lastError: nil
        )
    }

    static func loadingHistory(
        attempt: Int, period: String, rebucketing: Bool,
        coldCache: Bool, lastError: String?
    ) -> LoadingStatus {
        let message = attempt == 1 ? "Loading chart data…" : "Retrying (attempt \(attempt))…"
        let detail = historyDetail(period: period, rebucketing: rebucketing, coldCache: coldCache)
        return LoadingStatus(stage: .loadingHistory(attempt: attempt), message: message,
                             detail: detail, lastError: lastError)
    }

    static func refreshing() -> LoadingStatus {
        LoadingStatus(
            stage: .refreshing, message: "Refreshing cache…",
            detail: "Clearing server-side CDN cache and reloading.", lastError: nil
        )
    }

    private static func historyDetail(period: String, rebucketing: Bool, coldCache: Bool) -> String? {
        guard coldCache else { return nil }
        if rebucketing && period == "DAILY" {
            return "Fetching 6000 1H bars from Dukascopy — first load is slow while the server populates its CDN cache."
        }
        if rebucketing && period == "FOUR_HOURS" {
            return "Fetching 2000 1H bars from Dukascopy for aggregation."
        }
        return nil
    }
}
