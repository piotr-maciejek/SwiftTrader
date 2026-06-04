import Foundation

/// Persists the user's saved custom-correlation definitions, synced across the user's Macs via iCloud.
/// Mirrors `WorkspaceStateService`'s hybrid strategy (write to both `NSUbiquitousKeyValueStore` and
/// `UserDefaults`, read cloud-first, fall back silently when iCloud is unavailable) and adds
/// `PositionMetadataStore`'s external-change observer so another machine's add/delete reflects live.
///
/// A single GLOBAL key (not account-scoped): a custom correlation is a desktop preference, the same on
/// every machine regardless of which trading account is connected — like the workspace layout.
@MainActor
final class CustomCorrelationStore {
    /// Fired on the main actor whenever the list changes — local `add`/`delete` or an external iCloud
    /// sync — so the owner can republish to the sidebar.
    var onChange: (([CustomCorrelation]) -> Void)?

    /// Cap to stay well under the iCloud KV per-key limit (~64 KB). Far more than anyone needs.
    static let maxRecords = 50

    private let key = "customCorrelations"
    private let defaults: UserDefaults
    private let cloudEnabled: Bool
    /// Set once in `init`, read once in `deinit` — no race, so `nonisolated(unsafe)` lets the
    /// nonisolated `deinit` remove the (non-Sendable) observer token under Swift 6 concurrency.
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    private var cloudStore: NSUbiquitousKeyValueStore? {
        cloudEnabled ? .default : nil
    }

    /// `defaults`/`cloudEnabled` are injectable so tests exercise the UserDefaults path with iCloud
    /// off (and without touching the user's real stores).
    init(defaults: UserDefaults = .standard, cloudEnabled: Bool = true) {
        self.defaults = defaults
        self.cloudEnabled = cloudEnabled
        cloudStore?.synchronize()
        if cloudEnabled {
            observer = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: NSUbiquitousKeyValueStore.default, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleExternalChange() }
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Public API

    /// The saved correlations (cloud-first).
    func all() -> [CustomCorrelation] { readStored() }

    /// Append (or replace by id) into the freshest stored list, prune to the cap, persist + publish.
    /// Reading the freshest stored list (not an in-memory cache) keeps two machines from clobbering
    /// each other when they add disjoint correlations.
    func add(_ correlation: CustomCorrelation) {
        var list = readStored()
        list.removeAll { $0.id == correlation.id }
        list.append(correlation)
        if list.count > Self.maxRecords { list.removeFirst(list.count - Self.maxRecords) }
        write(list)
    }

    func delete(id: UUID) {
        var list = readStored()
        list.removeAll { $0.id == id }
        write(list)
    }

    // MARK: - Persistence

    private func readStored() -> [CustomCorrelation] {
        let data = cloudStore?.data(forKey: key) ?? defaults.data(forKey: key)
        guard let data, let list = try? JSONDecoder().decode([CustomCorrelation].self, from: data)
        else { return [] }
        return list
    }

    private func write(_ list: [CustomCorrelation]) {
        guard shouldPersist, let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: key)
        cloudStore?.set(data, forKey: key)
        cloudStore?.synchronize()
        onChange?(list)
    }

    /// Under xctest, only persist when a test injected a non-standard suite — so the production
    /// `.standard` + iCloud path can never clobber the user's real data from a test run.
    private var shouldPersist: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return defaults !== UserDefaults.standard
        }
        return true
    }

    private func handleExternalChange() {
        onChange?(readStored())
    }
}
