import SwiftUI

@main
struct SwiftTraderApp: App {
    @FocusedValue(\.workspace) var workspace

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1200, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") {
                    workspace?.addTab()
                }
                .keyboardShortcut("t")

                Button("Close Tab") {
                    if let ws = workspace, let id = ws.selectedTabID {
                        if ws.tabs.count > 1 {
                            ws.closeTab(id)
                        } else {
                            NSApp.keyWindow?.close()
                        }
                    }
                }
                .keyboardShortcut("w")
            }

            CommandMenu("Tabs") {
                Button("Move Tab Left") {
                    workspace?.moveSelectedTab(offset: -1)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])

                Button("Move Tab Right") {
                    workspace?.moveSelectedTab(offset: 1)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])

                Button("Longer Timeframe") {
                    workspace?.cycleSelectedTabPeriod(offset: 1)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])

                Button("Shorter Timeframe") {
                    workspace?.cycleSelectedTabPeriod(offset: -1)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
            }

            CommandMenu("Panels") {
                Button(workspace?.showBottomPanel == true ? "Hide Bottom Panel" : "Show Bottom Panel") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        workspace?.showBottomPanel.toggle()
                    }
                }
                .keyboardShortcut("y", modifiers: [.command, .shift])

                Button(workspace?.showRightPanel == true ? "Hide Right Panel" : "Show Right Panel") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        workspace?.showRightPanel.toggle()
                    }
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
            }
        }
    }
}
