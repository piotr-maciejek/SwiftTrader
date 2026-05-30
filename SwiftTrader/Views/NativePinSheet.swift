import SwiftUI

/// Standalone-mode captcha PIN entry, mirroring server mode's `PinEntrySheet` but
/// bound to `StandaloneAuthViewModel`. Shown when a LIVE account on a non-whitelisted
/// IP requires a captcha PIN to complete the native SRP6 auth.
struct NativePinSheet: View {
    @Bindable var auth: StandaloneAuthViewModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Dukascopy LIVE Authentication")
                .font(.headline)

            if let data = auth.captchaImageData,
               let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 280)
                    .border(Color.secondary.opacity(0.3))
            }

            TextField("Enter PIN from image", text: $auth.pin)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { auth.submitPin() }

            HStack(spacing: 12) {
                Button("Cancel") { auth.cancelPin() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { auth.submitPin() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(auth.pin.isEmpty)
            }

            if case .connecting = auth.phase {
                ProgressView("Connecting…")
                    .controlSize(.small)
            }

            if let error = auth.pinError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(width: 340)
    }
}
