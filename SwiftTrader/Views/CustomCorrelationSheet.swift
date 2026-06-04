import SwiftUI

/// Create a custom correlation: a name + 2–6 hand-picked pairs. On Create it's saved (synced) and
/// opened as a grid tab. Modeled on `SettingsView` / `StandaloneLoginSheet` (sheet, inline validation,
/// Cancel/Create keyboard shortcuts).
struct CustomCorrelationSheet: View {
    @Bindable var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var selected: Set<String> = []

    private var available: [String] { workspace.availableInstruments.sorted() }
    private var draft: CustomCorrelation { CustomCorrelation(name: name, pairs: Array(selected)) }
    private var maxPairs: Int { CustomCorrelation.pairCountRange.upperBound }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New custom correlation")
                .font(.headline)

            TextField("Name (e.g. Carry basket)", text: $name)
                .textFieldStyle(.roundedBorder)

            Text("Pick 2–\(maxPairs) pairs")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if available.isEmpty {
                        Text("Loading pairs…")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(8)
                    } else {
                        ForEach(available, id: \.self) { instrument in
                            pairToggle(instrument)
                        }
                    }
                }
            }
            .frame(height: 260)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Text("\(selected.count)/\(maxPairs) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func pairToggle(_ instrument: String) -> some View {
        let isOn = selected.contains(instrument)
        // Block selecting beyond the cap, but always allow deselecting.
        let atCap = selected.count >= maxPairs
        return HStack(spacing: 8) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            Text(formatInstrument(instrument))
                .font(.system(size: 12))
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .opacity(!isOn && atCap ? 0.4 : 1.0)
        .onTapGesture {
            if isOn {
                selected.remove(instrument)
            } else if !atCap {
                selected.insert(instrument)
            }
        }
    }

    private func create() {
        workspace.createCustomCorrelation(name: name, pairs: Array(selected))
        dismiss()
    }
}
