import Foundation

enum PairsGroupingMode: String, CaseIterable, Codable {
    case alphabetical
    case byCurrency
}

/// Where market data comes from. Picked at launch; switching requires a restart
/// so subscriptions aren't torn down and rebuilt against a different backend mid-flight.
enum DataProviderMode: String, CaseIterable, Codable {
    /// jforex-server over HTTP/WebSocket (the trusted default).
    case server
    /// Native Swift Dukascopy client, no JVM. Read-only; orders still route via server.
    case native

    var label: String {
        switch self {
        case .server: return "Server"
        case .native: return "Standalone (experimental, read-only)"
        }
    }
}

@Observable
@MainActor
final class AppSettings {
    var port: Int {
        didSet { UserDefaults.standard.set(port, forKey: "serverPort") }
    }

    var clientSideRebucketing: Bool {
        didSet { UserDefaults.standard.set(clientSideRebucketing, forKey: "clientSideRebucketing") }
    }

    var pairsGroupingMode: PairsGroupingMode {
        didSet { UserDefaults.standard.set(pairsGroupingMode.rawValue, forKey: "pairsGroupingMode") }
    }

    var incognitoMode: Bool {
        didSet { UserDefaults.standard.set(incognitoMode, forKey: "incognitoMode") }
    }

    var dataProvider: DataProviderMode {
        didSet { UserDefaults.standard.set(dataProvider.rawValue, forKey: "dataProvider") }
    }

    static let shared = AppSettings()

    private init() {
        let stored = UserDefaults.standard.integer(forKey: "serverPort")
        self.port = stored > 0 ? stored : 8080
        // Default ON — use object(forKey:) so an explicit OFF from the user isn't
        // overwritten by the default.
        self.clientSideRebucketing = (UserDefaults.standard.object(forKey: "clientSideRebucketing") as? Bool) ?? true
        let raw = UserDefaults.standard.string(forKey: "pairsGroupingMode")
        self.pairsGroupingMode = raw.flatMap(PairsGroupingMode.init(rawValue:)) ?? .alphabetical
        self.incognitoMode = (UserDefaults.standard.object(forKey: "incognitoMode") as? Bool) ?? false
        let provider = UserDefaults.standard.string(forKey: "dataProvider")
        self.dataProvider = provider.flatMap(DataProviderMode.init(rawValue:)) ?? .server
    }
}
