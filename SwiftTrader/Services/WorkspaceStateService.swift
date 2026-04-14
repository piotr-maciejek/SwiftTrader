import Foundation

@MainActor
final class WorkspaceStateService {
    static let shared = WorkspaceStateService()

    private let key = "workspaceState"

    /// NSUbiquitousKeyValueStore for iCloud sync.
    /// Requires iCloud entitlement + paid Apple Developer account.
    /// When unavailable, falls back to UserDefaults only.
    private var cloudStore: NSUbiquitousKeyValueStore? {
        // iCloud KV store works even without entitlement on some setups,
        // but may silently fail. We write to both and read cloud-first.
        NSUbiquitousKeyValueStore.default
    }

    private init() {
        cloudStore?.synchronize()
    }

    func save(_ state: WorkspaceState) {
        // Skip persistence under xctest so unit tests can't clobber the user's
        // real workspace via the shared singleton.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(state)
        } catch {
            print("WorkspaceStateService: failed to encode state: \(error)")
            return
        }
        UserDefaults.standard.set(data, forKey: key)
        cloudStore?.set(data, forKey: key)
        cloudStore?.synchronize()
    }

    func load() -> WorkspaceState? {
        let data = cloudStore?.data(forKey: key)
            ?? UserDefaults.standard.data(forKey: key)
        guard let data else { return nil }
        return try? JSONDecoder().decode(WorkspaceState.self, from: data)
    }
}
