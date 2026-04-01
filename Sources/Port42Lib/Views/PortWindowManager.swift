import SwiftUI
import AppKit
import WebKit

// MARK: - Port Panel

/// A port that has been popped out of the inline message stream.
public struct PortPanel: Identifiable {
    public let id: String
    public let udid: String
    public var html: String
    public let bridge: PortBridge
    public let channelId: String?
    public let createdBy: String?
    public let messageId: String?
    /// User-set title. Takes priority over HTML <title> extraction.
    public var userTitle: String?
    /// Capabilities declared by the port via port42.port.setCapabilities([...]).
    public var storedCapabilities: [String] = []
    public var size: CGSize
    public var position: CGPoint?
    public var isAlwaysOnTop: Bool = false
    public var isBackground: Bool = false

    /// Resolved display title: userTitle > HTML <title> > "port"
    public var title: String {
        if let ut = userTitle, !ut.isEmpty { return ut }
        return PortPanel.extractTitle(from: html)
    }

    /// Extract title from HTML <title> tag, fallback to "port"
    static func extractTitle(from html: String) -> String {
        if let start = html.range(of: "<title>"),
           let end = html.range(of: "</title>"),
           start.upperBound < end.lowerBound {
            let title = String(html[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return "port"
    }

    /// Extract version from HTML <meta name="version" content="..."> tag, returns nil if absent.
    static func extractVersion(from html: String) -> String? {
        guard let metaRange = html.range(of: #"<meta\s+name="version"\s+content=""#, options: .regularExpression) else { return nil }
        let after = html[metaRange.upperBound...]
        guard let end = after.range(of: "\"") else { return nil }
        let v = String(after[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
}

// MARK: - Port Window Manager

/// Manages popped-out and docked port panels.
/// Floating panels use native NSPanel windows for zero-lag dragging.
/// WKWebViews are created once and reparented between docked/floating states.
@MainActor
public final class PortWindowManager: ObservableObject {

    @Published public var panels: [PortPanel] = []

    /// Panel IDs where the mouse is currently hovering (drives title bar visibility).
    @Published public var hoveredPanels: Set<String> = []

    /// Database for persisting port panel state across restarts.
    private weak var db: DatabaseService?

    /// When true, window close events skip DB cleanup (app is quitting).
    /// nonisolated(unsafe): written synchronously on .main queue in willTerminate before windows close.
    private nonisolated(unsafe) var isTerminating = false

    /// Native windows for floating panels, keyed by panel ID.
    private var windows: [String: NSPanel] = [:]

    /// Persistent WKWebViews, keyed by panel ID. Created once, reparented on dock/undock.
    public var webViews: [String: WKWebView] = [:]

    /// Console handler kept alive for WKWebView message routing.
    private var consoleHandlers: [String: PortConsoleHandler] = [:]

    /// Navigation delegates kept alive for WKWebView.
    private var navDelegates: [String: PortNavigationBlocker] = [:]

    /// Panels running in the background (hidden but alive).
    public var backgroundPanels: [PortPanel] {
        panels.filter { $0.isBackground }
    }

    /// Set database reference for persistence.
    public func setDatabase(_ db: DatabaseService) {
        self.db = db
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isTerminating = true
        }
    }

    /// Restore persisted port panels from the database after app launch.
    public func restoreFromDB(appState: AnyObject) {
        guard let db = db else { return }
        do {
            let saved = try db.fetchPortPanels()
            for row in saved {
                let bridge = PortBridge(appState: appState, channelId: row.channelId, messageId: row.messageId, createdBy: row.createdBy)
                // Restore previously granted permissions so the user isn't re-prompted
                if let permsStr = row.grantedPermissions {
                    let perms = Set(permsStr.split(separator: ",").compactMap { PortPermission(rawValue: String($0)) })
                    bridge.grantedPermissions = perms
                }
                let pos: CGPoint? = (row.posX != nil && row.posY != nil)
                    ? CGPoint(x: row.posX!, y: row.posY!) : nil
                let restoredCaps: [String]
                if let capStr = row.capabilities,
                   let data = capStr.data(using: .utf8),
                   let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                    restoredCaps = arr
                } else {
                    restoredCaps = []
                }
                let panel = PortPanel(
                    id: row.id,
                    udid: row.udid ?? row.id,
                    html: row.html,
                    bridge: bridge,
                    channelId: row.channelId,
                    createdBy: row.createdBy,
                    messageId: row.messageId,
                    userTitle: row.userTitle,
                    storedCapabilities: restoredCaps,
                    size: CGSize(width: row.width, height: row.height),
                    position: pos,
                    isAlwaysOnTop: row.isAlwaysOnTop,
                    isBackground: row.isBackground
                )
                panels.append(panel)
                createPortWebView(for: panel)

                // Floating windows are NOT created here; they appear after
                // the lock screen dismisses via showRestoredFloatingPanels().
            }
            if !saved.isEmpty {
                NSLog("[Port42] Restored %d port panels from database", saved.count)
            }
        } catch {
            NSLog("[Port42] Failed to restore port panels: %@", error.localizedDescription)
        }
    }

    /// Create floating windows for any restored panels that don't have windows yet.
    /// Called at the same moment as the main window frame restore, so everything appears together.
    public func showRestoredFloatingPanels() {
        for panel in panels where !panel.isBackground && windows[panel.id] == nil {
            NSLog("[Port42] Creating restored window for: %@", panel.title)
            let bounds = NSApp.keyWindow?.contentView?.bounds.size ?? CGSize(width: 800, height: 600)
            createWindow(for: panel, in: bounds)
        }
    }

    /// Hide all floating panel windows (when lock screen or dreamscape shows).
    public func hideFloatingPanels() {
        for (id, window) in windows {
            if let nsPanel = window as? PortNSPanel {
                nsPanel.onClose = nil
                nsPanel.close()
            }
            windows.removeValue(forKey: id)
            // Keep the panel and webview alive, just remove the window
            webViews[id]?.removeFromSuperview()
        }
    }

    /// Persist permissions for a bridge after a grant, so they survive restart.
    public func persistPermissions(for bridge: PortBridge) {
        if let panel = panels.first(where: { $0.bridge === bridge }) {
            persistPanel(panel.id)
        }
    }

    /// Persist a panel to the database and snapshot a version.
    private func persistPanel(_ id: String) {
        guard let db = db, let panel = panels.first(where: { $0.id == id }) else { return }
        do {
            let record = PersistedPortPanel(from: panel)
            try db.savePortPanel(record)
            try db.savePortVersion(portUdid: panel.udid, html: panel.html, createdBy: panel.createdBy)
        } catch {
            NSLog("[Port42] Failed to persist port panel: %@", error.localizedDescription)
        }
    }

    /// Remove a panel from the database.
    private func unpersistPanel(_ id: String) {
        guard let db = db else { return }
        do {
            try db.deletePortPanel(id)
        } catch {
            NSLog("[Port42] Failed to delete port panel: %@", error.localizedDescription)
        }
    }

    /// Pop a port out from inline into a floating panel.
    @discardableResult
    public func popOut(html: String, bridge: PortBridge, channelId: String?, createdBy: String?, messageId: String?, title: String? = nil, in bounds: CGSize) -> String {
        // Check for existing panel from the same message and update it
        if let idx = panels.firstIndex(where: { $0.messageId == messageId && messageId != nil }) {
            let existingId = panels[idx].id
            let existingUdid = panels[idx].udid
            let wasBackground = panels[idx].isBackground
            panels[idx] = PortPanel(
                id: existingId,
                udid: existingUdid,
                html: html,
                bridge: bridge,
                channelId: channelId,
                createdBy: createdBy,
                messageId: messageId,
                userTitle: title ?? panels[idx].userTitle,
                storedCapabilities: panels[idx].storedCapabilities,
                size: panels[idx].size,
                position: panels[idx].position,
                isAlwaysOnTop: panels[idx].isAlwaysOnTop,
                isBackground: wasBackground
            )
            // Recreate webview with new HTML content
            destroyWebView(existingId)
            createPortWebView(for: panels[idx])
            persistPanel(existingId)
            // If backgrounded, restore it since new content was created
            if wasBackground {
                panels[idx].isBackground = false
                persistPanel(existingId)
                createWindowForExistingPanel(panels[idx])
            } else if let window = windows[existingId] {
                updateWindowContent(window, panel: panels[idx])
                window.makeKeyAndOrderFront(nil)
            }
            return existingId
        }

        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let w: CGFloat = screen.width * 0.4
        let h: CGFloat = screen.height * 0.4

        let newUdid = UUID().uuidString
        let panel = PortPanel(
            id: newUdid,
            udid: newUdid,
            html: html,
            bridge: bridge,
            channelId: channelId,
            createdBy: createdBy,
            messageId: messageId,
            userTitle: title,
            size: CGSize(width: w, height: h)
        )
        panels.append(panel)

        // Create the WKWebView once
        createPortWebView(for: panel)
        persistPanel(panel.id)

        // Create native floating window
        createWindow(for: panel, in: bounds)
        Analytics.shared.portPoppedOut()
        return newUdid
    }

    /// Close a panel with confirmation dialog. Used by the UI close button.
    public func closeWithConfirmation(_ id: String) {
        guard let window = windows[id] else { close(id); return }
        let alert = NSAlert()
        alert.messageText = "Close this port?"
        alert.informativeText = "The port and any running processes will be stopped."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.close(id)
            }
        }
    }

    /// Close a panel by ID.
    public func close(_ id: String) {
        if let window = windows[id] as? PortNSPanel {
            window.onClose = nil
            window.close()
        }
        windows.removeValue(forKey: id)
        destroyWebView(id)
        unpersistPanel(id)
        Analytics.shared.portClosed()
        panels.removeAll { $0.id == id }
    }

    /// Resize a panel.
    public func resize(_ id: String, to size: CGSize) {
        if let idx = panels.firstIndex(where: { $0.id == id }) {
            panels[idx].size = CGSize(
                width: max(200, size.width),
                height: max(150, size.height)
            )
        }
    }

    /// Rename a floating panel by message ID (called when inline port sets title via bridge).
    public func renamePort(byMessageId mid: String, title: String) {
        guard let idx = panels.firstIndex(where: { $0.messageId == mid }) else { return }
        panels[idx].userTitle = title
        persistPanel(panels[idx].id)
    }

    /// Rename a floating panel by panel UDID.
    public func renamePort(id: String, title: String) {
        guard let idx = panels.firstIndex(where: { $0.udid == id || $0.id == id }) else { return }
        panels[idx].userTitle = title
        persistPanel(panels[idx].id)
    }

    /// Set stored capabilities for a floating panel by UDID.
    public func setCapabilities(id: String, capabilities: [String]) {
        guard let idx = panels.firstIndex(where: { $0.udid == id || $0.id == id }) else { return }
        panels[idx].storedCapabilities = capabilities
        persistPanel(panels[idx].id)
    }

    /// Toggle always-on-top for a floating panel.
    public func toggleAlwaysOnTop(_ id: String) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        panels[idx].isAlwaysOnTop.toggle()
        let pinned = panels[idx].isAlwaysOnTop
        if let window = windows[id] {
            window.level = pinned ? .floating : .normal
        }
    }

    /// Send a port to the background (hidden but still running).
    public func minimize(_ id: String) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }

        // Hide the window but keep webview alive
        if let window = windows[id] as? PortNSPanel {
            window.onClose = nil
            window.close()
        }
        windows.removeValue(forKey: id)
        webViews[id]?.removeFromSuperview()

        panels[idx].isBackground = true
        persistPanel(id)
        NSLog("[Port42] Port minimized to background: %@", panels[idx].title)
    }

    /// Restore a background port to a floating window. Returns false if the port is not backgrounded.
    @discardableResult
    public func restore(_ id: String) -> Bool {
        guard let idx = panels.firstIndex(where: { $0.id == id }), panels[idx].isBackground else { return false }
        panels[idx].isBackground = false
        persistPanel(id)

        // Recreate the floating window
        createWindowForExistingPanel(panels[idx])
        NSLog("[Port42] Port restored from background: %@", panels[idx].title)
        return true
    }

    /// Stop a port by destroying its webview (keeps window open).
    public func stop(_ id: String) {
        guard panels.contains(where: { $0.id == id }) else { return }
        destroyWebView(id)
        if let window = windows[id], let panel = panels.first(where: { $0.id == id }) {
            updateWindowContent(window, panel: panel)
        }
        NSLog("[Port42] Port stopped: %@", panels.first(where: { $0.id == id })?.title ?? id)
    }

    /// Restart a port by reloading its HTML content.
    public func restart(_ id: String) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        destroyWebView(id)
        createPortWebView(for: panels[idx])
        if let window = windows[id] {
            updateWindowContent(window, panel: panels[idx])
        }
        NSLog("[Port42] Port restarted: %@", panels[idx].title)
    }

    /// Lightweight version history for UI display (no HTML blobs).
    public func fetchVersionSummaries(_ id: String) -> [PortVersionSummary] {
        guard let panel = panels.first(where: { $0.id == id }),
              let db = db else { return [] }
        return (try? db.fetchPortVersionSummaries(portUdid: panel.udid)) ?? []
    }

    /// Restore a port to a specific version from its history (no new version snapshot).
    public func restoreVersion(_ id: String, version: Int) {
        guard let panel = panels.first(where: { $0.id == id }),
              let db = db,
              let html = try? db.fetchPortVersionHtml(udid: panel.udid, version: version) else { return }
        _ = updatePort(idOrTitle: panel.udid, html: html, skipVersionSnapshot: true)
        NSLog("[Port42] Port restored to v%d: %@", version, panel.title)
    }

    /// Bring a floating panel to front and make it key.
    public func bringToFront(_ id: String) {
        windows[id]?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Terminal Lookup

    /// Find a port's terminal session by port title (case-insensitive).
    /// Returns the terminal bridge and first active session ID.
    public func terminalSession(forPortNamed name: String) -> (bridge: TerminalBridge, sessionId: String)? {
        let lowered = name.lowercased()
        for panel in panels {
            if panel.title.lowercased() == lowered || panel.title.lowercased().contains(lowered) {
                if let tb = panel.bridge.terminalBridge, let sid = tb.firstActiveSessionId {
                    return (bridge: tb, sessionId: sid)
                }
            }
        }
        return nil
    }

    /// List all ports that have active terminal sessions.
    public func portsWithTerminals() -> [(name: String, portId: String, sessionId: String, createdBy: String?)] {
        var result: [(name: String, portId: String, sessionId: String, createdBy: String?)] = []
        for panel in panels {
            if let tb = panel.bridge.terminalBridge {
                for sid in tb.activeSessionIds {
                    result.append((name: panel.title, portId: panel.udid, sessionId: sid, createdBy: panel.createdBy))
                }
            }
        }
        return result
    }

    // MARK: - Port Update

    /// Find a port by UDID or title (case-insensitive).
    public func findPort(by idOrTitle: String) -> PortPanel? {
        // Try UDID first
        if let panel = panels.first(where: { $0.udid == idOrTitle }) {
            return panel
        }
        // Fall back to title match
        let lowered = idOrTitle.lowercased()
        return panels.first(where: { $0.title.lowercased() == lowered || $0.title.lowercased().contains(lowered) })
    }

    /// Update a port's HTML by UDID or title. Works for windowed and minimized ports.
    /// Returns true if the port was found and updated.
    public func updatePort(idOrTitle: String, html: String, skipVersionSnapshot: Bool = false) -> Bool {
        guard let idx = panels.firstIndex(where: { $0.udid == idOrTitle }) ??
              panels.firstIndex(where: {
                  let l = idOrTitle.lowercased()
                  return $0.title.lowercased() == l || $0.title.lowercased().contains(l)
              }) else {
            return false
        }

        let panelId = panels[idx].id
        let newTitle = PortPanel.extractTitle(from: html)
        panels[idx].html = html

        // Update the webview if it exists
        if let webView = webViews[panelId] {
            let wrappedHTML = PortWebViewFactory.wrapHTML(html)
            webView.loadHTMLString(wrappedHTML, baseURL: URL(string: "http://port42.local/"))
            NSLog("[Port42] Port updated (webview reloaded): %@ (%@)", newTitle, panelId)
        } else {
            NSLog("[Port42] Port updated (stored, no webview): %@ (%@)", newTitle, panelId)
        }

        // Persist to database and optionally snapshot version
        if let db = db {
            var record = PersistedPortPanel(from: panels[idx])
            record.html = html
            record.title = newTitle
            try? db.savePortPanel(record)
            if !skipVersionSnapshot {
                try? db.savePortVersion(portUdid: panels[idx].udid, html: html, createdBy: panels[idx].createdBy)
            }
        }

        return true
    }

    /// List all ports (for ports_list tool).
    public func allPorts() -> [(udid: String, title: String, createdBy: String?, capabilities: [String], cwd: String?, isBackground: Bool, x: CGFloat?, y: CGFloat?)] {
        panels.map { panel in
            let tb = panel.bridge.terminalBridge
            let hasTerminal = tb?.firstActiveSessionId != nil
            var caps = panel.storedCapabilities
            if hasTerminal, !caps.contains("terminal") { caps.insert("terminal", at: 0) }
            let cwd = hasTerminal ? tb?.firstActiveSessionCwd : nil
            let origin = windows[panel.id]?.frame.origin ?? panel.position
            return (udid: panel.udid, title: panel.title, createdBy: panel.createdBy, capabilities: caps, cwd: cwd, isBackground: panel.isBackground, x: origin?.x, y: origin?.y)
        }
    }

    /// Current frame of a floating port window (nil if docked or not found).
    public func portFrame(by id: String) -> CGRect? {
        guard let panel = findPort(by: id) else { return nil }
        return windows[panel.id]?.frame
    }

    /// Move a floating port window to the given screen coordinates.
    public func movePort(id: String, x: CGFloat, y: CGFloat) {
        guard let panel = findPort(by: id) else { return }
        windows[panel.id]?.setFrameOrigin(NSPoint(x: x, y: y))
        if let idx = panels.firstIndex(where: { $0.id == panel.id }) {
            panels[idx].position = CGPoint(x: x, y: y)
            persistPanel(panel.id)
        }
    }

    // MARK: - WebView Lifecycle

    /// Create and configure a WKWebView for a panel. Called once per pop-out.
    private func createPortWebView(for panel: PortPanel) {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        // Attach bridge (injects port42.* namespace)
        panel.bridge.attach(to: config)

        // Console forwarding script
        let consoleScript = WKUserScript(
            source: PortWebViewFactory.consoleJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        let handler = PortConsoleHandler()
        config.userContentController.addUserScript(consoleScript)
        config.userContentController.add(handler, name: "portConsole")
        consoleHandlers[panel.id] = handler

        // Viewport tracking script (fires resize events for terminal reflow etc.)
        let viewportScript = WKUserScript(
            source: PortWebViewFactory.viewportJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(viewportScript)

        let webView = WKWebView(frame: .zero, configuration: config)
        let navDelegate = PortNavigationBlocker()
        webView.navigationDelegate = navDelegate
        navDelegates[panel.id] = navDelegate
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false

        // Give bridge a reference to the webview for callbacks
        panel.bridge.setWebView(webView)

        // Load content
        let document = PortWebViewFactory.wrapHTML(panel.html)
        webView.loadHTMLString(document, baseURL: URL(string: "http://port42.local/"))

        webViews[panel.id] = webView
    }

    /// Clean up a webview and its associated handlers.
    private func destroyWebView(_ id: String) {
        webViews[id]?.removeFromSuperview()
        webViews.removeValue(forKey: id)
        consoleHandlers.removeValue(forKey: id)
        navDelegates.removeValue(forKey: id)
    }

    // MARK: - Native Window Management

    private func createWindow(for panel: PortPanel, in bounds: CGSize) {
        var windowFrame: CGRect
        if let pos = panel.position {
            // Restore saved position
            windowFrame = CGRect(origin: pos, size: panel.size)
        } else {
            // Position relative to the main window
            let offset = CGFloat(windows.count % 5) * 24
            windowFrame = CGRect(x: 100 + offset, y: 100 + offset, width: panel.size.width, height: panel.size.height)
            if let mainWindow = NSApp.keyWindow {
                let mainFrame = mainWindow.frame
                windowFrame.origin.x = mainFrame.midX - panel.size.width / 2 + offset
                windowFrame.origin.y = mainFrame.midY - panel.size.height / 2 - offset
            }
        }

        let window = PortNSPanel(
            contentRect: windowFrame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = false
        window.level = panel.isAlwaysOnTop ? .floating : .normal
        window.isReleasedWhenClosed = false
        window.animationBehavior = .utilityWindow
        window.minSize = NSSize(width: 100, height: 50)
        window.backgroundColor = NSColor(Port42Theme.bgPrimary)

        let panelId = panel.id
        window.onClose = { [weak self] in
            self?.panelWindowClosed(panelId)
        }
        window.hoverHandler = { [weak self] hovering in
            if hovering {
                self?.hoveredPanels.insert(panelId)
                self?.windows[panelId]?.makeKeyAndOrderFront(nil)
            } else {
                self?.hoveredPanels.remove(panelId)
            }
        }

        // Observe move/resize to persist position
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in self?.windowFrameChanged(panelId) } }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in self?.windowFrameChanged(panelId) } }

        updateWindowContent(window, panel: panel)
        // Install hover tracking AFTER contentView is set by updateWindowContent
        window.installHoverTracking()

        windows[panel.id] = window
        window.makeKeyAndOrderFront(nil)
    }

    private func windowFrameChanged(_ id: String) {
        guard let window = windows[id],
              let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        let frame = window.frame
        panels[idx].size = frame.size
        panels[idx].position = frame.origin
        persistPanel(id)
    }

    private func createWindowForExistingPanel(_ panel: PortPanel) {
        guard windows[panel.id] == nil else { return }
        let bounds = NSApp.keyWindow?.contentView?.bounds.size ?? CGSize(width: 800, height: 600)
        createWindow(for: panel, in: bounds)
    }

    private func updateWindowContent(_ window: NSPanel, panel: PortPanel) {
        let contentView = PortPanelContentView(
            panel: panel,
            manager: self
        )
        let hv = NSHostingView(rootView: contentView)
        hv.sizingOptions = []  // prevent content changes from ever resizing the window
        window.contentView = hv
    }

    private func panelWindowClosed(_ id: String) {
        windows.removeValue(forKey: id)
        destroyWebView(id)
        if !isTerminating {
            unpersistPanel(id)
        }
        panels.removeAll { $0.id == id }
    }
}

// MARK: - WebView Factory

/// Shared utilities for creating port WKWebViews.
enum PortWebViewFactory {

    /// Wrap port HTML in a full document with theme and CSP.
    static func wrapHTML(_ body: String) -> String {
        let moduleBody = body
            .replacingOccurrences(of: "<script>", with: "<script type=\"module\">")

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy"
              content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:;">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                background: #111;
                color: #e0e0e0;
                font-family: "SF Mono", "Fira Code", "Cascadia Code", monospace;
                font-size: 13px;
                line-height: 1.5;
                padding: 12px;
                overflow: auto;
            }
            a { color: #00ff41; }
            button, input, select, textarea {
                font-family: inherit;
                font-size: inherit;
                color: #e0e0e0;
                background: #1a1a1a;
                border: 1px solid #333;
                border-radius: 4px;
                padding: 6px 10px;
                outline: none;
            }
            button {
                cursor: pointer;
                background: #00ff41;
                color: #0a0a0a;
                border: none;
                font-weight: 600;
                padding: 6px 14px;
            }
            button:hover { opacity: 0.85; }
            input:focus, textarea:focus { border-color: #00ff41; }
            ::-webkit-scrollbar { width: 6px; }
            ::-webkit-scrollbar-track { background: transparent; }
            ::-webkit-scrollbar-thumb { background: #333; border-radius: 3px; }
        </style>
        </head>
        <body>
        \(moduleBody)
        </body>
        </html>
        """
    }

    /// Console forwarding JS injected at document start.
    static let consoleJS = """
    (function() {
        const orig = { log: console.log, error: console.error, warn: console.warn };
        let _console = null;
        let _consoleLog = null;
        let _toggle = null;
        const _colors = { log: '#888', warn: '#ffaa00', error: '#ff4444' };
        let _hasError = false;

        function ensureConsole() {
            if (_console) return;
            _console = document.createElement('div');
            _console.style.cssText = 'position:fixed;bottom:0;left:0;right:0;z-index:99999;background:#0a0a0a;border-top:1px solid #333;font-size:10px;font-family:monospace;display:none;flex-direction:column;max-height:40%;';
            const header = document.createElement('div');
            header.style.cssText = 'display:flex;justify-content:space-between;padding:3px 8px;background:#111;border-bottom:1px solid #222;color:#555;cursor:pointer;';
            header.innerHTML = '<span>console</span><span>\\u2715</span>';
            header.onclick = function() { _console.style.display = 'none'; };
            _consoleLog = document.createElement('div');
            _consoleLog.style.cssText = 'overflow-y:auto;padding:4px 8px;flex:1;';
            _console.appendChild(header);
            _console.appendChild(_consoleLog);
            document.body.appendChild(_console);

            _toggle = document.createElement('div');
            _toggle.style.cssText = 'position:fixed;bottom:4px;right:4px;z-index:99998;width:16px;height:16px;border-radius:3px;background:#222;border:1px solid #333;cursor:pointer;display:flex;align-items:center;justify-content:center;font-size:8px;color:#555;';
            _toggle.textContent = '>';
            _toggle.onclick = function() {
                const vis = _console.style.display === 'flex';
                _console.style.display = vis ? 'none' : 'flex';
            };
            document.body.appendChild(_toggle);
        }

        function appendLine(level, msg) {
            ensureConsole();
            const line = document.createElement('div');
            line.style.cssText = 'padding:1px 0;color:' + _colors[level] + ';word-break:break-all;';
            line.textContent = (level === 'log' ? '' : level + ': ') + msg;
            _consoleLog.appendChild(line);
            _consoleLog.scrollTop = _consoleLog.scrollHeight;
            if (level === 'error' && !_hasError) {
                _hasError = true;
                _toggle.style.borderColor = '#ff4444';
                _toggle.style.color = '#ff4444';
                _console.style.display = 'flex';
            }
        }

        function forward(level, args) {
            try {
                const msg = Array.from(args).map(a => typeof a === 'object' ? JSON.stringify(a) : String(a)).join(' ');
                window.webkit.messageHandlers.portConsole.postMessage({ level: level, message: msg });
                appendLine(level, msg);
            } catch(e) {}
        }
        console.log = function() { forward('log', arguments); orig.log.apply(console, arguments); };
        console.error = function() { forward('error', arguments); orig.error.apply(console, arguments); };
        console.warn = function() { forward('warn', arguments); orig.warn.apply(console, arguments); };
        window.addEventListener('error', function(e) {
            forward('error', [e.message + ' at ' + (e.filename || '') + ':' + (e.lineno || '')]);
        });
        window.addEventListener('unhandledrejection', function(e) {
            forward('error', ['Unhandled promise rejection: ' + (e.reason || '')]);
        });
    })();
    """

    /// Viewport tracking JS injected at document end.
    /// Updates CSS custom properties and fires viewport.resize events on window resize.
    static let viewportJS = """
    (function() {
        function updateViewport() {
            const w = document.documentElement.clientWidth;
            const h = document.documentElement.clientHeight;
            document.documentElement.style.setProperty('--port-width', w + 'px');
            document.documentElement.style.setProperty('--port-height', h + 'px');
            if (window.port42 && window.port42.viewport) {
                window.port42.viewport.width = w;
                window.port42.viewport.height = h;
            }
            if (window.__port42_listeners && window.__port42_listeners['viewport.resize']) {
                window.__port42_listeners['viewport.resize']({ width: w, height: h });
            }
        }
        window.addEventListener('load', updateViewport);
        window.addEventListener('resize', updateViewport);
        new ResizeObserver(updateViewport).observe(document.body);
        setTimeout(updateViewport, 100);
    })();
    """
}

// MARK: - Console Handler

/// Receives console.log/error/warn from port WKWebViews.
class PortConsoleHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "portConsole",
           let body = message.body as? [String: Any],
           let level = body["level"] as? String,
           let msg = body["message"] as? String {
            NSLog("[Port42:port:%@] %@", level, msg)
        }
    }
}

// MARK: - Navigation Blocker

/// Blocks all navigation except initial load (sandbox).
class PortNavigationBlocker: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
    }
}

// MARK: - Reusable WebView Host

/// NSViewRepresentable that reparents an existing WKWebView into a container.
/// The WKWebView is NOT recreated, just moved between view hierarchies.
struct PortWebViewHost: NSViewRepresentable {
    let webView: WKWebView
    let bridge: PortBridge

    func makeNSView(context: Context) -> NSView {
        let container = PortWebViewContainer()
        container.bridge = bridge
        webView.removeFromSuperview()
        container.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        // Unregister WKWebView's AppKit-level drag types so file drops
        // reach the container instead of being swallowed by WebKit.
        // HTML5 drag-and-drop inside the webview (e.g. xterm.js) is unaffected.
        webView.unregisterDraggedTypes()
        container.registerForDraggedTypes([.fileURL])
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Don't reclaim the webview if it moved to another container (dock/undock reparenting)
    }
}

// MARK: - Native Panel Window

/// NSPanel subclass with close callback and custom drag region.
/// Also owns the window-level hover tracking area so mouseEntered/mouseExited
/// fire reliably regardless of key window status — bypasses hitTest entirely.
class PortNSPanel: NSPanel {
    var onClose: (() -> Void)?
    var hoverHandler: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override var canBecomeKey: Bool {
        // Yield to sheets/modals — don't steal focus from settings, add companion, etc.
        let mainWindow = NSApp.windows.first(where: { !($0 is NSPanel) && $0.isVisible })
        if mainWindow?.sheets.isEmpty == false { return false }
        return true
    }

    override func close() {
        onClose?()
        super.close()
    }

    /// Add tracking area to contentView with self (the NSPanel) as owner.
    /// NSPanel is an NSResponder so it receives mouseEntered/mouseExited directly —
    /// no hitTest involvement, works for non-key windows with .activeAlways.
    func installHoverTracking() {
        guard let cv = contentView else { return }
        if let old = hoverTrackingArea { cv.removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        cv.addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hoverHandler?(true)
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hoverHandler?(false)
        super.mouseExited(with: event)
    }

    // Prevent Escape from closing the panel (default NSPanel behaviour)
    override func cancelOperation(_ sender: Any?) {}
}

// MARK: - Panel Content View (rendered inside NSPanel)

struct PortPanelContentView: View {
    let panel: PortPanel
    @ObservedObject var manager: PortWindowManager
    @State private var showCode = false
    @State private var pendingPerm: PortPermission?
    @State private var nsWindow: NSWindow? = nil
    @State private var isKeyWindow = false
    @State private var showBar = false
    @State private var showVersions = false
    @State private var hideTask: DispatchWorkItem? = nil

    private var isHovered: Bool { manager.hoveredPanels.contains(panel.id) }

    /// Show the title bar then schedule it to hide after `duration` seconds.
    private func flashBar(for duration: Double = 2.5) {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { showBar = true }
        let task = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.4)) { showBar = false }
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Content fills edge to edge
            if showCode {
                ScrollView(.vertical) {
                    Text(panel.html)
                        .font(Port42Theme.mono(12))
                        .foregroundColor(Port42Theme.textSecondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let webView = manager.webViews[panel.id] {
                PortWebViewHost(webView: webView, bridge: panel.bridge)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Always-present invisible drag strip — drag works even when title bar is hidden
            VStack(spacing: 0) {
                PortDragArea()
                    .frame(height: 36)
                    .allowsHitTesting(true)
                Spacer()
            }

            // Title bar overlay — timed flash on hover/focus, always on for code view
            if showBar || showCode || showVersions {
                VStack(alignment: .leading, spacing: 0) {
                    PortPanelTitleBar(panel: panel, manager: manager, showCode: $showCode, showVersions: $showVersions)
                    if showVersions {
                        HStack {
                            PortVersionDropdown(panel: panel, manager: manager, isPresented: $showVersions)
                                .transition(.opacity)
                            Spacer()
                        }
                    }
                    Spacer()
                }
                .transition(.opacity)
            }

            // Inline permission overlay
            if let perm = pendingPerm {
                PortPermissionOverlay(
                    permission: perm,
                    createdBy: panel.createdBy,
                    onAllow: { panel.bridge.grantPermission() },
                    onDeny: { panel.bridge.denyPermission() }
                )
            }

            // Window border glow: bright when key, dim when hovering, off otherwise
            Rectangle()
                .stroke(Port42Theme.accent.opacity(isKeyWindow ? 0.6 : isHovered ? 0.3 : 0), lineWidth: 1)
                .shadow(color: Port42Theme.accent.opacity(isKeyWindow ? 0.5 : isHovered ? 0.2 : 0), radius: isKeyWindow ? 12 : 8)
                .shadow(color: Port42Theme.accent.opacity(isKeyWindow ? 0.3 : 0), radius: 24)
                .animation(.easeInOut(duration: 0.25), value: isKeyWindow)
                .animation(.easeInOut(duration: 0.3), value: isHovered)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Port42Theme.bgPrimary)
        .ignoresSafeArea()
        .background(WindowRefAccessor { w in nsWindow = w })
        .onAppear {
            flashBar(for: 2.0)
        }
        .onChange(of: manager.hoveredPanels.contains(panel.id)) { _, hovered in
            if hovered {
                flashBar()
            } else if !showVersions {
                hideTask?.cancel()
                withAnimation(.easeInOut(duration: 0.3)) { showBar = false }
            }
        }
        .onChange(of: showVersions) { _, showing in
            if !showing && !manager.hoveredPanels.contains(panel.id) {
                withAnimation(.easeInOut(duration: 0.3)) { showBar = false }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if let w = nsWindow, note.object as? NSWindow == w {
                isKeyWindow = true
                flashBar(for: 1.5)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if let w = nsWindow, note.object as? NSWindow == w { isKeyWindow = false }
        }
        .onReceive(panel.bridge.$pendingPermission) { perm in
            pendingPerm = perm
        }
    }
}

/// Grabs the NSWindow from the SwiftUI view hierarchy without consuming any space or events.
struct WindowRefAccessor: NSViewRepresentable {
    let callback: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { self.callback(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { self.callback(nsView.window) }
    }
}

// MARK: - Permission Overlay

/// Inline permission prompt rendered directly in the view hierarchy.
/// Unlike confirmationDialog (which requires key window status to present as a sheet),
/// this always renders reliably regardless of window state.
/// Unified permission prompt used for both port JS and tool-use paths.
/// Renders inline in the view hierarchy (avoids confirmationDialog key-window issues).
struct PortPermissionOverlay: View {
    let permission: PortPermission
    var createdBy: String? = nil
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)

            VStack(spacing: 16) {
                if let name = createdBy {
                    Text(name)
                        .font(Port42Theme.monoBold(12))
                        .foregroundStyle(Port42Theme.accent)
                }

                Image(systemName: permission.iconName)
                    .font(.system(size: 28))
                    .foregroundStyle(Port42Theme.accent)

                Text(permission.permissionDescription.title)
                    .font(Port42Theme.monoBold(14))
                    .foregroundStyle(Port42Theme.textPrimary)

                Text(permission.permissionDescription.message)
                    .font(Port42Theme.mono(12))
                    .foregroundStyle(Port42Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button(action: onDeny) {
                        Text("Deny")
                            .font(Port42Theme.mono(12))
                            .foregroundStyle(Port42Theme.textSecondary)
                            .frame(width: 80, height: 28)
                            .background(Port42Theme.bgSecondary)
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Port42Theme.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    Button(action: onAllow) {
                        Text("Allow")
                            .font(Port42Theme.mono(12))
                            .fontWeight(.medium)
                            .foregroundStyle(.black)
                            .frame(width: 80, height: 28)
                            .background(Port42Theme.accent)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Port42Theme.bgPrimary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Port42Theme.border, lineWidth: 1)
                    )
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Panel Title Bar

struct PortPanelTitleBar: View {
    let panel: PortPanel
    @ObservedObject var manager: PortWindowManager
    @Binding var showCode: Bool
    @State private var versionHovered = false
    @Binding var showVersions: Bool

    /// Always read the live panel from manager so rename/title updates reflect immediately.
    private var livePanel: PortPanel {
        manager.panels.first(where: { $0.id == panel.id }) ?? panel
    }

    var body: some View {
        HStack(spacing: 8) {
            // Draggable title area (padded to clear macOS traffic light buttons)
            HStack(spacing: 8) {
                Image(systemName: "circle")
                    .font(.system(size: 8))
                    .foregroundStyle(Port42Theme.accent)
                Text(livePanel.title)
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .lineLimit(1)
                if let creator = livePanel.createdBy {
                    Text("·")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary)
                    Text(creator)
                        .font(Port42Theme.mono(10))
                        .foregroundStyle(Port42Theme.textSecondary)
                        .lineLimit(1)
                }
                if let version = PortPanel.extractVersion(from: livePanel.html) {
                    Text("·")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary)
                    Text("v\(version)")
                        .font(Port42Theme.mono(10))
                        .foregroundStyle(versionHovered ? Port42Theme.accent : Port42Theme.textSecondary.opacity(0.6))
                        .onHover { hovering in
                            versionHovered = hovering
                            if hovering { showVersions = true }
                        }
                }
                Spacer()
            }
            .background(PortDragArea())

            // Buttons (not draggable) — mode-dependent
            if showCode {
                Button(action: { showCode = false }) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Port42Theme.accent)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Run port")
            } else {
                Button(action: { showCode = true }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Port42Theme.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Stop")

                Button(action: { manager.restart(panel.id) }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(Port42Theme.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Restart")

                Button(action: { showCode = true }) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(Port42Theme.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("View source")
            }

            Button(action: { manager.toggleAlwaysOnTop(panel.id) }) {
                Image(systemName: livePanel.isAlwaysOnTop ? "pin.fill" : "pin")
                    .font(.system(size: 10))
                    .foregroundStyle(livePanel.isAlwaysOnTop ? Port42Theme.accent : Port42Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(livePanel.isAlwaysOnTop ? "Unpin" : "Always on top")

            Button(action: { manager.minimize(panel.id) }) {
                Image(systemName: "minus")
                    .font(.system(size: 10))
                    .foregroundStyle(Port42Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Background")

            Button(action: { manager.closeWithConfirmation(panel.id) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(Port42Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Port42Theme.bgSecondary)
    }
}

// MARK: - Version Dropdown

struct PortVersionDropdown: View {
    let panel: PortPanel
    let manager: PortWindowManager
    @Binding var isPresented: Bool
    @State private var versions: [PortVersionSummary] = []
    @State private var hoveredId: Int64?

    private var currentMetaVersion: String? {
        PortPanel.extractVersion(from: panel.html)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if versions.isEmpty {
                Text("No version history")
                    .font(Port42Theme.mono(10))
                    .foregroundStyle(Port42Theme.textSecondary)
                    .padding(10)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(versions, id: \.id) { ver in
                            let isCurrent = ver.displayVersion == currentMetaVersion
                                || (currentMetaVersion == nil && ver.id == versions.first?.id)
                            Button(action: {
                                if !isCurrent {
                                    manager.restoreVersion(panel.id, version: ver.version)
                                }
                                isPresented = false
                            }) {
                                HStack(spacing: 8) {
                                    Text("v\(ver.displayVersion)")
                                        .font(Port42Theme.monoBold(11))
                                        .foregroundStyle(isCurrent ? Port42Theme.accent : Port42Theme.textPrimary)
                                    if let by = ver.createdBy {
                                        Text(by)
                                            .font(Port42Theme.mono(10))
                                            .foregroundStyle(Port42Theme.textSecondary)
                                            .lineLimit(1)
                                    }
                                    if let saves = ver.saveCount, saves > 1 {
                                        Text("\(saves) saves")
                                            .font(Port42Theme.mono(9))
                                            .foregroundStyle(Port42Theme.textSecondary.opacity(0.4))
                                    }
                                    Spacer()
                                    Text(timeAgo(ver.createdAt))
                                        .font(Port42Theme.mono(9))
                                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.6))
                                    if isCurrent {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9))
                                            .foregroundStyle(Port42Theme.accent)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(
                                isCurrent ? Port42Theme.accent.opacity(0.08) :
                                hoveredId == ver.id ? Port42Theme.accent.opacity(0.12) : Color.clear
                            )
                            .onHover { h in hoveredId = h ? ver.id : nil }
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .frame(width: 260)
        .background(Port42Theme.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.4), radius: 8)
        .padding(.leading, 10)
        .onHover { hovering in
            if !hovering {
                withAnimation(.easeInOut(duration: 0.15)) { isPresented = false }
            }
        }
        .onAppear {
            versions = manager.fetchVersionSummaries(panel.id)
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}

// MARK: - WebView Container (preserves first responder on click)

/// NSView container that ensures clicks inside the webview don't trigger
/// app-level focus changes. Accepts first mouse so clicks go through
/// without a focus-first click.
class PortWebViewContainer: NSView {
    private var lastSize: NSSize = .zero
    weak var bridge: PortBridge?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Let the webview handle clicks directly
        super.mouseDown(with: event)
        // Ensure the webview stays first responder
        if let webView = subviews.first {
            window?.makeFirstResponder(webView)
        }
    }

    override func layout() {
        super.layout()
        let size = bounds.size
        guard size.width > 0 && size.height > 0 && size != lastSize else { return }
        lastSize = size
        // WKWebView doesn't reliably fire JS window.resize on frame changes via Auto Layout.
        // Dispatch it from native so existing viewportJS listeners pick it up.
        if let webView = subviews.first as? WKWebView {
            webView.evaluateJavaScript("window.dispatchEvent(new Event('resize'))") { _, _ in }
        }
    }

    // MARK: - File Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty,
              let bridge = bridge else { return false }

        let files: [[String: Any]] = urls.map { url in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return [
                "path": url.path,
                "name": url.lastPathComponent,
                "size": (attrs?[.size] as? Int) ?? 0,
                "isDirectory": (attrs?[.type] as? FileAttributeType) == .typeDirectory
            ]
        }

        Task { @MainActor in
            await bridge.handleFileDrop(files)
        }
        return true
    }
}

// MARK: - Drag Area (makes region draggable by window)

/// NSView that enables window dragging when used as background.
struct PortDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = PortDragNSView()
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

class PortDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.set()
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.openHand.set()
    }
}
