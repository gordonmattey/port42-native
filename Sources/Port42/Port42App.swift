import SwiftUI
import AppKit
import Port42Lib
import Sparkle

/// Intercept port42:// URLs at the AppDelegate level so SwiftUI doesn't
/// open a new window for each deep link.
class Port42AppDelegate: NSObject, NSApplicationDelegate {
    /// Sparkle updater controller for automatic + manual update checks
    private(set) var updaterController: SPUStandardUpdaterController!

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // Initialize Sparkle (starts automatic update checks)
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        NSLog("[Port42] Sparkle updater initialized, canCheckForUpdates=%d", updaterController.updater.canCheckForUpdates ? 1 : 0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupCustomCursor()
        NSLog("[Port42] Sparkle feedURL=%@", updaterController.updater.feedURL?.absoluteString ?? "nil")

        // Listen for manual update check requests from settings
        NotificationCenter.default.addObserver(forName: .checkForUpdatesRequested, object: nil, queue: .main) { [weak self] _ in
            NSLog("[Port42] Check for updates requested via notification")
            self?.updaterController.checkForUpdates(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Dismiss SwiftUI sheets (they block termination)
        NotificationCenter.default.post(name: .dismissAllSheets, object: nil)
        // Also dismiss any AppKit-level attached sheets
        for window in NSApp.windows {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
        }
        return .terminateNow
    }

    private func setupCustomCursor() {
        let size = NSSize(width: 24, height: 24)
        let green = NSColor(red: 0.0, green: 1.0, blue: 0.255, alpha: 1.0) // #00FF41
        let image = NSImage(size: size, flipped: false) { rect in
            // Outer glow (stroke only)
            let glowOuter = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
            green.withAlphaComponent(0.1).setStroke()
            glowOuter.lineWidth = 4
            glowOuter.stroke()

            // Inner glow (stroke only)
            let glowInner = NSBezierPath(ovalIn: rect.insetBy(dx: 4.5, dy: 4.5))
            green.withAlphaComponent(0.15).setStroke()
            glowInner.lineWidth = 2
            glowInner.stroke()

            // Circle stroke
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 5, dy: 5))
            green.withAlphaComponent(0.9).setStroke()
            circle.lineWidth = 1.5
            circle.stroke()
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
        Port42Cursor.shared = cursor
        swizzleArrowCursor()
    }

    private func swizzleArrowCursor() {
        guard let originalMethod = class_getClassMethod(NSCursor.self, #selector(getter: NSCursor.arrow)),
              let swizzledMethod = class_getClassMethod(Port42Cursor.self, #selector(Port42Cursor.port42Arrow)) else { return }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else { return }
        NotificationCenter.default.post(name: .handleDeepLink, object: url)
    }
}

class Port42Cursor: NSObject {
    static var shared: NSCursor = NSCursor.arrow

    @objc class func port42Arrow() -> NSCursor {
        return Port42Cursor.shared
    }
}

// MARK: - Sparkle Delegate

extension Port42AppDelegate: SPUUpdaterDelegate {
    /// Gracefully stop gateway before bundle replacement
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        NSLog("[Port42] Sparkle will install update %@, stopping gateway...", item.displayVersionString)
        GatewayProcess.shared.stop()
    }
}

@main
struct Port42App: App {
    @NSApplicationDelegateAdaptor(Port42AppDelegate.self) var delegate
    @StateObject private var appState: AppState

    init() {
        do {
            // Use a separate data directory when running as a test peer
            let subdir = ProcessInfo.processInfo.environment["PORT42_DATA_DIR"] ?? "Port42"
            let db = try DatabaseService(subdirectory: subdir)
            _appState = StateObject(wrappedValue: AppState(db: db))
        } catch {
            fatalError("[Port42] Failed to initialize database: \(error)")
        }

        // Set app icon from bundled .icns
        if let icnsURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: icnsURL) {
            NSApplication.shared.applicationIconImage = icon
        }

        // Preload breakout video so it's ready instantly
        BreakoutVideoPreloader.shared.preload()
    }

    var body: some Scene {
        WindowGroup {
            TransitionRoot(appState: appState, useBreakoutVideo: true)
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 600)
                .background(Port42Theme.bgPrimary)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    NotificationCenter.default.post(name: .checkForUpdatesRequested, object: nil)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Channel") {
                    NotificationCenter.default.post(
                        name: .newChannelRequested, object: nil
                    )
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Quick Switcher") {
                    NotificationCenter.default.post(
                        name: .quickSwitcherRequested, object: nil
                    )
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Help") {
                    NotificationCenter.default.post(
                        name: .helpRequested, object: nil
                    )
                }
                .keyboardShortcut("/", modifiers: .command)
            }
        }
    }
}

