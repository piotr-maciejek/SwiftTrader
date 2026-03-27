import SwiftUI
import AppKit

/// Invisible helper view that installs a local event monitor to detect
/// double-clicks on the title bar and toggle window zoom (maximize),
/// matching the Chrome behavior regardless of the user's system setting.
struct WindowAccessor: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.install(for: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    class Coordinator {
        private var monitor: Any?

        func install(for window: NSWindow) {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
                guard event.clickCount == 2,
                      let eventWindow = event.window,
                      eventWindow === window else {
                    return event
                }
                let titleBarHeight = eventWindow.frame.height - eventWindow.contentLayoutRect.height
                let clickY = eventWindow.frame.height - event.locationInWindow.y
                if clickY <= titleBarHeight {
                    eventWindow.zoom(nil)
                }
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
