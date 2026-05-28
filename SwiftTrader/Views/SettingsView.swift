import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var onPortChanged: ((Int) -> Void)?
    var onRebucketingChanged: (() -> Void)?

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

            Toggle(isOn: Binding(
                get: { settings.clientSideRebucketing },
                set: { newValue in
                    let changed = newValue != settings.clientSideRebucketing
                    settings.clientSideRebucketing = newValue
                    if changed { onRebucketingChanged?() }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Client-side 4H/DAILY aggregation")
                    Text("Aggregate from 1H bars with NY-close alignment. Removes the spurious Sunday daily bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            Toggle(isOn: $settings.incognitoMode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Incognito mode (hide balances)")
                    Text("Hides account balance, equity, P&L, and lot sizes for demo recordings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 2) {
                Picker("Market data", selection: $settings.dataProvider) {
                    ForEach(DataProviderMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                Text("Standalone talks to Dukascopy directly (no jforex-server). Takes effect after restarting the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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
        .frame(width: 320)
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
