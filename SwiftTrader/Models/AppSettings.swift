import Foundation

@Observable
@MainActor
final class AppSettings {
    var port: Int {
        didSet { UserDefaults.standard.set(port, forKey: "serverPort") }
    }

    var clientSideRebucketing: Bool {
        didSet { UserDefaults.standard.set(clientSideRebucketing, forKey: "clientSideRebucketing") }
    }

    static let shared = AppSettings()

    private init() {
        let stored = UserDefaults.standard.integer(forKey: "serverPort")
        self.port = stored > 0 ? stored : 8080
        // Default ON — use object(forKey:) so an explicit OFF from the user isn't
        // overwritten by the default.
        self.clientSideRebucketing = (UserDefaults.standard.object(forKey: "clientSideRebucketing") as? Bool) ?? true
    }
}
