import DukascopyClient
import Foundation

/// Drives the native (standalone) connection for the selected account, mirroring the
/// server-mode `AuthViewModel` phase model so `ContentView` can gate the workspace
/// the same way. The connected `DukascopySession` is handed to the market-data
/// coordinator once `phase == .ready`.
///
/// LIVE accounts on a non-whitelisted IP require a captcha PIN. The session calls
/// back through a `pinProvider` closure mid-connect; this VM bridges that callback
/// to SwiftUI by publishing the captcha image, flipping to `.pinRequired`, and
/// suspending on a continuation that `submitPin()` / `cancelPin()` resume.
@Observable
@MainActor
final class StandaloneAuthViewModel {
    enum Phase: Equatable {
        case idle          // no account selected, or not yet connected
        case connecting
        case pinRequired   // captcha/PIN challenge awaiting user input
        case ready
        case failed(String)
    }

    var phase: Phase = .idle
    private(set) var session: DukascopySession?

    /// The account the current session is connected as. Lets `connectOrSwitch()` detect a
    /// voluntary account change while already connected so it can tear down first.
    private(set) var connectedAccountID: UUID?

    /// The captcha PNG to display while `phase == .pinRequired`.
    var captchaImageData: Data?
    /// The PIN the user is typing into the sheet.
    var pin: String = ""
    /// Non-nil after a rejected PIN, to message the user on the re-prompt.
    private(set) var pinError: String?

    /// Resumed by `submitPin()` (with the typed PIN) or `cancelPin()` (throwing).
    private var pinContinuation: CheckedContinuation<String, Error>?

    /// Watches the live session's state stream so a mid-session transport failure flips
    /// `phase` back to `.failed` (re-opening the login gate) instead of leaving a dead
    /// session wired to a "ready" workspace.
    private var stateObserver: Task<Void, Never>?

    private let accounts: AccountStore

    init(accounts: AccountStore = .shared) {
        self.accounts = accounts
    }

    var hasSelectedAccount: Bool { accounts.selectedAccount != nil }

    /// Connect the selected account, switching away from a live session first if the user
    /// picked a *different* account while already connected. Reconnecting the same account
    /// stays a no-op (so re-opening the login sheet and hitting Connect does nothing). On a
    /// switch, `disconnect()` closes the old session (phase → `.idle`) so the workspace
    /// re-attaches the new one via the usual `.ready` transition.
    func connectOrSwitch() async {
        if phase == .ready, accounts.selectedAccountID != connectedAccountID {
            await disconnect()
        }
        await connectSelected()
    }

    /// Connect the currently selected account. No-op while connecting or already ready.
    /// On a wrong PIN the loop rebuilds the session and re-prompts with a fresh captcha
    /// (captcha ids are single-use), mirroring server mode's retry.
    func connectSelected() async {
        if phase == .connecting || phase == .pinRequired || phase == .ready { return }
        guard let account = accounts.selectedAccount,
              let creds = accounts.credentials(for: account.id) else {
            phase = .idle
            return
        }
        phase = .connecting
        pinError = nil

        while true {
            let session = DukascopySession(
                environment: account.environment,
                credentials: creds,
                pinProvider: { [weak self] challenge in
                    guard let self else { throw AuthError.pinCancelled }
                    return try await self.requestPin(challenge)
                }
            )
            do {
                try await session.connect()
                self.session = session
                connectedAccountID = account.id
                pinError = nil
                phase = .ready
                observeSessionState(session)
                return
            } catch AuthError.badPin {
                // Wrong PIN — the captcha is now spent. Loop to fetch a fresh one.
                pinError = "Incorrect PIN — please try again."
                phase = .connecting
                continue
            } catch AuthError.pinCancelled {
                phase = .idle
                return
            } catch {
                phase = .failed(String(describing: error))
                return
            }
        }
    }

    /// Invoked (off the main actor) by the session's `pinProvider`. Publishes the
    /// captcha, flips to `.pinRequired`, and suspends until the user acts.
    /// Internal (not private) so the continuation bridge is unit-testable.
    func requestPin(_ challenge: PinChallenge) async throws -> String {
        captchaImageData = challenge.captcha
        pin = ""
        phase = .pinRequired
        return try await withCheckedThrowingContinuation { continuation in
            self.pinContinuation = continuation
        }
    }

    /// User submitted the PIN from the sheet.
    func submitPin() {
        guard let continuation = pinContinuation, !pin.isEmpty else { return }
        pinContinuation = nil
        phase = .connecting
        continuation.resume(returning: pin)
    }

    /// User dismissed the PIN sheet without submitting.
    func cancelPin() {
        guard let continuation = pinContinuation else { return }
        pinContinuation = nil
        continuation.resume(throwing: AuthError.pinCancelled)
        // `connectSelected`'s catch lands the phase on `.idle`.
    }

    /// Tear down the current session (e.g. before switching accounts).
    func disconnect() async {
        stateObserver?.cancel()
        stateObserver = nil
        if let session { await session.close() }
        session = nil
        connectedAccountID = nil
        phase = .idle
    }

    /// Observe `session`'s state stream; a `.failed` transition (transport death, server
    /// kick, idle timeout) flips `phase` to `.failed` and drops the dead session so the
    /// connect gate / login sheet reappears and `connectSelected()` can run again.
    /// Transient `.disconnected` (emitted mid-`reconnect()` during a watchdog rebuild) is
    /// ignored — only a terminal `.failed` surfaces to the user.
    private func observeSessionState(_ session: DukascopySession) {
        stateObserver?.cancel()
        stateObserver = Task { [weak self] in
            for await state in await session.stateStream() {
                if case .failed(let reason) = state {
                    self?.handleSessionFailure(reason)
                    return
                }
            }
        }
    }

    /// Internal (not private) so the failure-recovery transition is unit-testable.
    func handleSessionFailure(_ reason: String) {
        // Ignore if we've already moved on (manual disconnect, or a re-connect in flight).
        guard phase == .ready else { return }
        phase = .failed("Connection lost: \(reason)")
        session = nil
        connectedAccountID = nil
    }
}
