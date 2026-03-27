import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var onPortChanged: ((Int) -> Void)?

    @State private var portText: String = ""
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Settings")
                .font(.headline)

            HStack {
                Text("Server port:")
                TextField("8080", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onSubmit { applyPort() }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { applyPort() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 280)
        .onAppear {
            portText = String(settings.port)
        }
    }

    private func applyPort() {
        guard let port = Int(portText), (1...65535).contains(port) else {
            errorMessage = "Enter a valid port (1–65535)"
            return
        }
        errorMessage = nil
        let changed = settings.port != port
        settings.port = port
        if changed {
            onPortChanged?(port)
        }
        dismiss()
    }
}
