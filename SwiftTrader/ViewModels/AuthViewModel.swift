import SwiftUI

@Observable
@MainActor
final class AuthViewModel {
    enum Phase {
        case checking
        case pinRequired
        case connecting
        case ready
        case failed(String)
    }

    var phase: Phase = .checking
    var captchaImageData: Data?
    var pin: String = ""

    private var authService: AuthService

    init(port: Int) {
        self.authService = AuthService(
            baseURL: URL(string: "http://localhost:\(port)")!)
    }

    func updatePort(_ port: Int) {
        self.authService = AuthService(
            baseURL: URL(string: "http://localhost:\(port)")!)
        pin = ""
        captchaImageData = nil
        Task { await start() }
    }

    func start() async {
        phase = .checking
        while true {
            do {
                let status = try await authService.fetchStatus()
                if !status.liveMode || status.state == "CONNECTED" {
                    phase = .ready
                    return
                }
                if status.state == "AWAITING_PIN" {
                    let imageData = try await authService.fetchCaptchaImage()
                    captchaImageData = imageData
                    phase = .pinRequired
                    return
                }
                if status.state == "FAILED" {
                    phase = .failed("Connection failed. Waiting for retry...")
                }
            } catch {
                // Server not up yet
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func submitPin() async {
        guard !pin.isEmpty else { return }
        phase = .connecting
        do {
            try await authService.submitPin(pin)
            // Poll until CONNECTED or need new PIN
            while true {
                try? await Task.sleep(for: .seconds(1))
                let status = try await authService.fetchStatus()
                if status.state == "CONNECTED" {
                    phase = .ready
                    return
                }
                if status.state == "AWAITING_PIN" {
                    // Wrong PIN — server retried with new captcha
                    let imageData = try await authService.fetchCaptchaImage()
                    captchaImageData = imageData
                    pin = ""
                    phase = .failed("Wrong PIN. Please try again.")
                    // Short delay then show PIN entry
                    try? await Task.sleep(for: .seconds(1))
                    phase = .pinRequired
                    return
                }
                if status.state == "FAILED" {
                    phase = .failed("Connection failed. Retrying...")
                    await start()
                    return
                }
            }
        } catch {
            phase = .failed("Failed to submit PIN: \(error.localizedDescription)")
        }
    }
}
