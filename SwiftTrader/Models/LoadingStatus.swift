import Foundation

enum LoadingStage: Equatable {
    case connecting
    case loadingHistory(attempt: Int)
    case loadingEarlier
    case refreshing
    case reconnectingServer
    case exhausted(reason: ExhaustionReason)
}

enum ExhaustionReason: Equatable {
    case serverUnreachable
    case historyUnavailable
    case liveFeedDisconnected
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

    static func reconnectingServer() -> LoadingStatus {
        LoadingStatus(
            stage: .reconnectingServer,
            message: "Reconnecting server…",
            detail: "Asking jforex-server to drop its Dukascopy session and reconnect.",
            lastError: nil
        )
    }

    static func exhausted(_ reason: ExhaustionReason, lastError: String?) -> LoadingStatus {
        let (message, detail): (String, String) = switch reason {
        case .serverUnreachable:
            ("Can't reach jforex-server",
             "Tried 5 times. Is the server running on this port?")
        case .historyUnavailable:
            ("History unavailable",
             "The server is up but isn't returning bars. It may need a force reconnect.")
        case .liveFeedDisconnected:
            ("Live feed disconnected",
             "Lost the WebSocket and couldn't recover. Force reconnect or retry.")
        }
        return LoadingStatus(
            stage: .exhausted(reason: reason),
            message: message, detail: detail, lastError: lastError
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
