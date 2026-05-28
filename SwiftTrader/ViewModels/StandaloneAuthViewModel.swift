import DukascopyClient
import Foundation

/// Drives the native (standalone) connection for the selected account, mirroring the
/// server-mode `AuthViewModel` phase model so `ContentView` can gate the workspace
/// the same way. The connected `DukascopySession` is handed to the market-data
/// coordinator once `phase == .ready`.
@Observable
@MainActor
final class StandaloneAuthViewModel {
    enum Phase: Equatable {
        case idle          // no account selected, or not yet connected
        case connecting
        case pinRequired   // captcha/PIN challenge (slice D)
        case ready
        case failed(String)
    }

    var phase: Phase = .idle
    private(set) var session: DukascopySession?

    private let accounts: AccountStore

    init(accounts: AccountStore = .shared) {
        self.accounts = accounts
    }

    var hasSelectedAccount: Bool { accounts.selectedAccount != nil }

    /// Connect the currently selected account. No-op while connecting or already ready.
    func connectSelected() async {
        if phase == .connecting || phase == .ready { return }
        guard let account = accounts.selectedAccount,
              let creds = accounts.credentials(for: account.id) else {
            phase = .idle
            return
        }
        phase = .connecting
        let session = DukascopySession(environment: account.environment, credentials: creds)
        do {
            try await session.connect()
            self.session = session
            phase = .ready
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    /// Tear down the current session (e.g. before switching accounts).
    func disconnect() async {
        if let session { await session.close() }
        session = nil
        phase = .idle
    }
}
