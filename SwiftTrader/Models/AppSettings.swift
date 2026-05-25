import Foundation

enum PairsGroupingMode: String, CaseIterable, Codable {
    case alphabetical
    case byCurrency
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
    }
}
