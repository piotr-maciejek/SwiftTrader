import Foundation

/// A user-defined correlation screen: 2–6 hand-picked pairs under a name. Saved and synced across the
/// user's Macs via `CustomCorrelationStore` — a desktop preference (like the workspace), the same on
/// every machine regardless of the trading account.
struct CustomCorrelation: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    /// Slashless instruments, e.g. "EURUSD". 2…6, unique (see `isValid`).
    var pairs: [String]

    init(id: UUID = UUID(), name: String, pairs: [String]) {
        self.id = id
        self.name = name
        self.pairs = pairs
    }

    /// Allowed pair-count range for a custom correlation grid.
    static let pairCountRange = 2...6

    /// A non-empty name plus a valid pair set (2…6, no duplicates). Drives the create sheet's
    /// Create-enabled guard. Pure → unit-testable.
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Self.pairCountRange.contains(pairs.count)
            && Set(pairs).count == pairs.count
    }
}
