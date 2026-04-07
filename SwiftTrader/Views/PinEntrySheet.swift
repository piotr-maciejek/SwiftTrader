import SwiftUI

struct PinEntrySheet: View {
    @Bindable var auth: AuthViewModel

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
                .onSubmit { Task { await auth.submitPin() } }

            Button("Connect") { Task { await auth.submitPin() } }
                .buttonStyle(.borderedProminent)
                .disabled(auth.pin.isEmpty)

            if case .connecting = auth.phase {
                ProgressView("Connecting...")
                    .controlSize(.small)
            }

            if case .failed(let message) = auth.phase {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(width: 340)
    }
}
