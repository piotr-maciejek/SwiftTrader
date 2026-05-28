import DukascopyClient
import Foundation

/// Saved standalone accounts + the active selection. Account metadata persists in
/// UserDefaults; passwords live in the Keychain as SHA-1 hashes (never plaintext).
@Observable
@MainActor
final class AccountStore {
    private(set) var accounts: [DukascopyAccount]
    var selectedAccountID: UUID? {
        didSet { UserDefaults.standard.set(selectedAccountID?.uuidString, forKey: Self.selectionKey) }
    }

    private let secrets: SecretStore
    private static let accountsKey = "dukascopyAccounts"
    private static let selectionKey = "dukascopySelectedAccountID"

    static let shared = AccountStore()

    init(secrets: SecretStore = KeychainStore()) {
        self.secrets = secrets
        if let data = UserDefaults.standard.data(forKey: Self.accountsKey),
           let decoded = try? JSONDecoder().decode([DukascopyAccount].self, from: data) {
            accounts = decoded
        } else {
            accounts = []
        }
        if let raw = UserDefaults.standard.string(forKey: Self.selectionKey) {
            selectedAccountID = UUID(uuidString: raw)
        }
    }

    var selectedAccount: DukascopyAccount? {
        accounts.first { $0.id == selectedAccountID }
    }

    @discardableResult
    func addAccount(
        label: String, login: String, password: String, environment: DukascopyEnvironment
    ) -> DukascopyAccount {
        let account = DukascopyAccount(label: label, login: login, environment: environment)
        try? secrets.setSecret(AuthCredentialEncoder.hashIdentity(password), for: account.id.uuidString)
        accounts.append(account)
        persistAccounts()
        if selectedAccountID == nil { selectedAccountID = account.id }
        return account
    }

    /// Update metadata, and the password too when a non-nil value is supplied.
    func update(_ account: DukascopyAccount, password: String?) {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[idx] = account
        if let password {
            try? secrets.setSecret(AuthCredentialEncoder.hashIdentity(password), for: account.id.uuidString)
        }
        persistAccounts()
    }

    func removeAccount(_ id: UUID) {
        try? secrets.removeSecret(for: id.uuidString)
        accounts.removeAll { $0.id == id }
        if selectedAccountID == id { selectedAccountID = accounts.first?.id }
        persistAccounts()
    }

    /// Pre-hashed credentials for connecting; nil if the stored secret is missing.
    func credentials(for id: UUID) -> AuthCredentials? {
        guard let account = accounts.first(where: { $0.id == id }),
              let hash = secrets.secret(for: id.uuidString) else { return nil }
        return AuthCredentials(login: account.login, passwordHash: hash)
    }

    private func persistAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.accountsKey)
        }
    }
}
