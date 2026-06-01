import DukascopyClient
import Foundation
import Testing
@testable import SwiftTrader

/// Exercises the PIN continuation bridge in `StandaloneAuthViewModel` — the handoff
/// between the session's async `pinProvider` callback and the SwiftUI sheet — without
/// a live Dukascopy session.
@MainActor
@Suite("StandaloneAuthViewModel PIN bridge")
struct StandaloneAuthViewModelTests {

    private func challenge() -> PinChallenge {
        PinChallenge(captcha: Data([0x89, 0x50, 0x4E, 0x47]), captchaId: "CAPTCHA-1")
    }

    /// Spin the main actor until `condition` holds (or a bounded number of yields
    /// elapse), so we can observe the suspended `requestPin` publishing its state.
    private func wait(until condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
    }

    @Test("requestPin publishes the captcha and flips to .pinRequired; submitPin resumes with the typed PIN")
    func submitResumesWithPin() async throws {
        let vm = StandaloneAuthViewModel()
        let task = Task { try await vm.requestPin(challenge()) }

        await wait(until: { vm.phase == .pinRequired })
        #expect(vm.phase == .pinRequired)
        #expect(vm.captchaImageData == Data([0x89, 0x50, 0x4E, 0x47]))

        vm.pin = "4815"
        vm.submitPin()

        let result = try await task.value
        #expect(result == "4815")
        #expect(vm.phase == .connecting)
    }

    @Test("submitPin with an empty PIN does nothing (stays suspended)")
    func submitEmptyIsNoOp() async throws {
        let vm = StandaloneAuthViewModel()
        let task = Task { try await vm.requestPin(challenge()) }
        await wait(until: { vm.phase == .pinRequired })

        vm.pin = ""
        vm.submitPin()
        // Still awaiting input — phase unchanged.
        #expect(vm.phase == .pinRequired)

        // Now submit a real value so the task can finish and we don't leak it.
        vm.pin = "0000"
        vm.submitPin()
        _ = try await task.value
    }

    @Test("cancelPin resumes the continuation by throwing pinCancelled")
    func cancelThrows() async {
        let vm = StandaloneAuthViewModel()
        let task = Task { () -> Result<String, Error> in
            do { return .success(try await vm.requestPin(challenge())) }
            catch { return .failure(error) }
        }
        await wait(until: { vm.phase == .pinRequired })

        vm.cancelPin()

        let outcome = await task.value
        switch outcome {
        case .success: Issue.record("expected cancel to throw")
        case .failure(let error):
            #expect(error is AuthError)
            if case AuthError.pinCancelled = error {} else {
                Issue.record("expected .pinCancelled, got \(error)")
            }
        }
    }

    @Test("a session failure while ready flips phase to .failed (re-opening the login gate)")
    func sessionFailureFlipsToFailed() {
        let vm = StandaloneAuthViewModel()
        vm.phase = .ready
        vm.handleSessionFailure("read: connection reset")
        if case .failed(let msg) = vm.phase {
            #expect(msg.contains("read: connection reset"))
        } else {
            Issue.record("expected .failed, got \(vm.phase)")
        }
        #expect(vm.session == nil)
    }

    @Test("a session failure is ignored unless we're in .ready (no spurious gate after disconnect)")
    func sessionFailureIgnoredWhenNotReady() {
        let vm = StandaloneAuthViewModel()
        vm.phase = .idle
        vm.handleSessionFailure("late event")
        #expect(vm.phase == .idle)
    }

    @Test("connectOrSwitch tears down a ready session when a different account is selected")
    func switchDisconnectsFirst() async {
        let vm = StandaloneAuthViewModel()  // backed by AccountStore.shared
        let store = AccountStore.shared
        let saved = store.selectedAccountID
        defer { store.selectedAccountID = saved }

        // Pretend we're connected, then "select" an account id the store doesn't hold.
        // connectedAccountID is nil (no real connect), so it differs from the selection,
        // forcing the switch branch: disconnect() runs, then connectSelected() lands on
        // .idle via its missing-account guard. A plain connectSelected() would instead
        // have returned immediately at its `phase == .ready` guard, leaving phase == .ready.
        vm.phase = .ready
        store.selectedAccountID = UUID()
        await vm.connectOrSwitch()

        #expect(vm.phase == .idle)
        #expect(vm.session == nil)
    }
}

/// `AccountStore` no longer swallows Keychain write failures — they surface via
/// `lastSaveError` so the UI can warn instead of persisting an account that can't connect.
@MainActor
@Suite("AccountStore credential persistence")
struct AccountStoreCredentialTests {
    private struct ThrowingSecretStore: SecretStore {
        func setSecret(_ secret: String, for key: String) throws {
            throw KeychainError.unexpectedStatus(-25299)
        }
        func secret(for key: String) -> String? { nil }
        func removeSecret(for key: String) throws {}
    }

    private final class InMemorySecretStore: SecretStore, @unchecked Sendable {
        private var store: [String: String] = [:]
        func setSecret(_ secret: String, for key: String) throws { store[key] = secret }
        func secret(for key: String) -> String? { store[key] }
        func removeSecret(for key: String) throws { store[key] = nil }
    }

    @Test("a failed Keychain write surfaces via lastSaveError")
    func failureSurfaces() {
        let store = AccountStore(secrets: ThrowingSecretStore())
        let account = store.addAccount(label: "Demo", login: "123", password: "pw", environment: .demo)
        defer { store.removeAccount(account.id) }
        #expect(store.lastSaveError != nil)
    }

    @Test("a successful Keychain write leaves lastSaveError nil")
    func successClears() {
        let store = AccountStore(secrets: InMemorySecretStore())
        let account = store.addAccount(label: "Demo", login: "123", password: "pw", environment: .demo)
        defer { store.removeAccount(account.id) }
        #expect(store.lastSaveError == nil)
    }
}
