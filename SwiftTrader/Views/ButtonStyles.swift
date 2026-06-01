import SwiftUI

// macOS's `.borderless` / `.plain` button styles draw no hover or pressed highlight, so a
// button with a custom static background gives the user no feedback that it's interactive.
// The idiomatic fix is a custom `ButtonStyle`: `configuration.isPressed` supplies the press
// state, and `.onHover` (tracked in a small inner view so `@State` is managed correctly)
// supplies the hover state. The Mac convention is a subtle fill highlight on hover and a
// dim + slight shrink on press — no cursor change.

/// Solid-fill action button (Buy / Sell): keeps the tinted fill but brightens it on hover
/// and dims + shrinks slightly on press. Pass `enabled: false` to render the disabled
/// (gray) treatment — pair with `.disabled(true)` so the action is also blocked.
struct FilledActionButtonStyle: ButtonStyle {
    var fill: Color
    var enabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration, fill: fill, enabled: enabled)
    }

    private struct Label: View {
        let configuration: Configuration
        let fill: Color
        let enabled: Bool
        @State private var hovering = false

        var body: some View {
            let base = enabled ? fill : Color.gray
            let shape = RoundedRectangle(cornerRadius: 4)
            configuration.label
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? .white : .white.opacity(0.6))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background {
                    shape.fill(base).overlay(shape.fill(highlight))
                }
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.10), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { if enabled { hovering = $0 } }
        }

        // Press darkens, hover brightens — a translucent overlay so it reads on any fill.
        private var highlight: Color {
            if configuration.isPressed { return .black.opacity(0.18) }
            return hovering && enabled ? .white.opacity(0.18) : .clear
        }
    }
}

/// Text-only action button (Close / Cancel): keeps the tinted text but adds a faint tinted
/// background pill on hover and dims the text on press.
struct TextActionButtonStyle: ButtonStyle {
    var tint: Color = .red

    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration, tint: tint)
    }

    private struct Label: View {
        let configuration: Configuration
        let tint: Color
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(tint.opacity(configuration.isPressed ? 0.6 : 1))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tint.opacity(hovering ? 0.15 : 0), in: RoundedRectangle(cornerRadius: 4))
                .contentShape(RoundedRectangle(cornerRadius: 4))
                .animation(.easeOut(duration: 0.10), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}
