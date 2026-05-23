import SwiftUI

struct ShortcutsPopover: View {
    private struct Row: Identifiable {
        let id = UUID()
        let label: String
        let keys: String
    }

    private let groups: [(title: String, rows: [Row])] = [
        ("Tabs", [
            Row(label: "New Tab", keys: "⌘T"),
            Row(label: "Close Tab", keys: "⌘W"),
            Row(label: "Move Tab Left / Right", keys: "⌘⌃← / ⌘⌃→"),
            Row(label: "Longer / Shorter Timeframe", keys: "⌘⌃↑ / ⌘⌃↓"),
        ]),
        ("Panels", [
            Row(label: "Toggle Bottom Panel", keys: "⇧⌘Y"),
            Row(label: "Toggle Right Panel", keys: "⌥⌘0"),
        ]),
        ("Drawing (chart focused)", [
            Row(label: "Line tool", keys: "A"),
            Row(label: "Arrow tool", keys: "S"),
            Row(label: "Delete selected drawing", keys: "D / ⌫"),
            Row(label: "Clear all drawings (this chart)", keys: "⇧D / ⇧⌫"),
            Row(label: "Clear all drawings (every cell)", keys: "⌥D"),
            Row(label: "Exit tool / clear selection", keys: "Esc"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Shortcuts")
                .font(.system(size: 13, weight: .semibold))

            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    ForEach(group.rows) { row in
                        HStack {
                            Text(row.label)
                                .font(.system(size: 11))
                            Spacer(minLength: 24)
                            Text(row.keys)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}
