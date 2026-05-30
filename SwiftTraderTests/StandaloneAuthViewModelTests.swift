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
}
