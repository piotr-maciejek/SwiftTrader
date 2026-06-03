import Foundation

/// Persists per-position `PositionMetadata` (initial SL + press-time price) keyed per account,
/// synced across the user's Macs via iCloud — so a trade opened on one machine shows its R-multiple
/// and slippage on another. Mirrors `WorkspaceStateService`'s hybrid strategy: write to both
/// `NSUbiquitousKeyValueStore` (iCloud) and `UserDefaults`, read cloud-first, fall back silently
/// when iCloud is unavailable.
///
/// `upsert` merges into the freshest stored dict (not the in-memory cache) so two machines writing
/// disjoint positions don't clobber each other, and an external-change observer republishes when
/// another machine's write syncs in.
@MainActor
final class PositionMetadataStore {
    /// Fired (on the main actor) whenever the cache changes — local `upsert`, `reload`, or an
    /// external iCloud sync — so the owner can republish to the UI.
    var onChange: (([String: PositionMetadata]) -> Void)?

    /// Cap per account to stay under the iCloud KV per-key limit (~64 KB): one record is ~250 B of
    /// JSON, so 200 ≈ 50 KB. Oldest (by open time) are pruned first.
    static let maxRecords = 200

    private var cache: [String: PositionMetadata] = [:]
    private var loadedKey: String?

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

    /// Load the dict for `accountID` into the cache and publish it. Call on connect / account switch.
    @discardableResult
    func reload(accountID: UUID?) -> [String: PositionMetadata] {
        let key = Self.key(for: accountID)
        loadedKey = key
        cache = readStored(key: key)
        onChange?(cache)
        return cache
    }

    /// The cached dict for `accountID` (reloads if a different account was last loaded).
    func all(accountID: UUID?) -> [String: PositionMetadata] {
        let key = Self.key(for: accountID)
        if loadedKey != key { return reload(accountID: accountID) }
        return cache
    }

    /// Merge one record into the freshest stored dict (cloud-first), prune, persist to both stores,
    /// and publish.
    func upsert(_ meta: PositionMetadata, accountID: UUID?) {
        let key = Self.key(for: accountID)
        var dict = readStored(key: key)
        dict[meta.positionId] = meta
        dict = Self.prune(dict, max: Self.maxRecords)
        write(dict, key: key)
        loadedKey = key
        cache = dict
        onChange?(cache)
    }

    // MARK: - Persistence

    private func readStored(key: String) -> [String: PositionMetadata] {
        let data = cloudStore?.data(forKey: key) ?? defaults.data(forKey: key)
        guard let data,
              let dict = try? JSONDecoder().decode([String: PositionMetadata].self, from: data)
        else { return [:] }
        return dict
    }

    private func write(_ dict: [String: PositionMetadata], key: String) {
        guard shouldPersist, let data = try? JSONEncoder().encode(dict) else { return }
        defaults.set(data, forKey: key)
        cloudStore?.set(data, forKey: key)
        cloudStore?.synchronize()
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
        guard let loadedKey else { return }
        cache = readStored(key: loadedKey)
        onChange?(cache)
    }

    // MARK: - Helpers

    static func key(for accountID: UUID?) -> String {
        "positionMeta-\(accountID?.uuidString ?? "default")"
    }

    /// Keep the newest `max` records (by open time, falling back to submit time when the fill time
    /// isn't known yet). Pure + nonisolated so it's unit-testable without any store.
    nonisolated static func prune(_ dict: [String: PositionMetadata], max: Int) -> [String: PositionMetadata] {
        guard dict.count > max else { return dict }
        let kept = dict.values
            .sorted { ($0.openTimeMs == 0 ? $0.submitTimeMs : $0.openTimeMs)
                    > ($1.openTimeMs == 0 ? $1.submitTimeMs : $1.openTimeMs) }
            .prefix(max)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.positionId, $0) })
    }
}
