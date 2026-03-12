import SwiftUI
import AppKit
import Port42Lib

@main
struct Port42B: App {
    @StateObject private var appState: AppState

    init() {
        do {
            let db = try DatabaseService(subdirectory: "Port42B")
            _appState = StateObject(wrappedValue: AppState(db: db))
        } catch {
            fatalError("[Port42B] Failed to initialize database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            TransitionRoot(appState: appState, useBreakoutVideo: false)
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 600)
                .background(Port42Theme.bgPrimary)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Channel") {
                    NotificationCenter.default.post(name: .newChannelRequested, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Quick Switcher") {
                    NotificationCenter.default.post(name: .quickSwitcherRequested, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }
    }
}

