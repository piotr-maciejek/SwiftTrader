import DukascopyClient
import Foundation

/// A saved Dukascopy account for standalone mode. The password is never stored
/// here — only its SHA-1 hash, kept in the Keychain keyed by `id`.
struct DukascopyAccount: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var label: String
    var login: String
    var environment: DukascopyEnvironment

    init(id: UUID = UUID(), label: String, login: String, environment: DukascopyEnvironment) {
        self.id = id
        self.label = label
        self.login = login
        self.environment = environment
    }
}
