import Foundation

@Observable
@MainActor
final class AppSettings {
    var port: Int {
        didSet { UserDefaults.standard.set(port, forKey: "serverPort") }
    }

    static let shared = AppSettings()

    private init() {
        let stored = UserDefaults.standard.integer(forKey: "serverPort")
        self.port = stored > 0 ? stored : 8080
    }
}
