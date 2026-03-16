import SwiftUI
import AppKit
import WebKit

// MARK: - Port Panel

/// A port that has been popped out of the inline message stream.
public struct PortPanel: Identifiable {
    public let id: String
    public let html: String
    public let bridge: PortBridge
    public let channelId: String?
    public let createdBy: String?
    public let messageId: String?
    public let title: String
    public var size: CGSize
    public var position: CGPoint?
    public var isAlwaysOnTop: Bool = false
    public var isBackground: Bool = false

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
}

// MARK: - Port Window Manager

/// Manages popped-out and docked port panels.
/// Floating panels use native NSPanel windows for zero-lag dragging.
/// WKWebViews are created once and reparented between docked/floating states.
@MainActor
public final class PortWindowManager: ObservableObject {

    @Published public var panels: [PortPanel] = []

    /// Database for persisting port panel state across restarts.
    private weak var db: DatabaseService?

    /// When true, window close events skip DB cleanup (app is quitting).
    private var isTerminating = false

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
                let panel = PortPanel(
                    id: row.id,
                    html: row.html,
                    bridge: bridge,
                    channelId: row.channelId,
                    createdBy: row.createdBy,
                    messageId: row.messageId,
                    title: row.title,
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
    /// Called after the lock screen dismisses, with a brief delay for the transition.
    public func showRestoredFloatingPanels() {
        NSLog("[Port42] showRestoredFloatingPanels: %d total panels", panels.count)
        for p in panels {
            let px = p.position.map { String(Int($0.x)) } ?? "nil"
            let py = p.position.map { String(Int($0.y)) } ?? "nil"
            NSLog("[Port42]   panel=%@ bg=%@ hasWindow=%@ pos=(%@,%@)",
                  p.title, p.isBackground ? "Y" : "N",
                  windows[p.id] != nil ? "Y" : "N", px, py)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self else { return }
            for panel in self.panels where !panel.isBackground && self.windows[panel.id] == nil {
                NSLog("[Port42] Creating restored window for: %@", panel.title)
                let bounds = NSApp.keyWindow?.contentView?.bounds.size ?? CGSize(width: 800, height: 600)
                self.createWindow(for: panel, in: bounds)
            }
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

    /// Persist a panel to the database.
    private func persistPanel(_ id: String) {
        guard let db = db, let panel = panels.first(where: { $0.id == id }) else {
            NSLog("[Port42] persistPanel: SKIP id=%@ db=%@ found=%@", id, db == nil ? "nil" : "ok", panels.contains(where: { $0.id == id }) ? "yes" : "no")
            return
        }
        do {
            let record = PersistedPortPanel(from: panel)
            NSLog("[Port42] persistPanel: id=%@ title=%@ pos=(%@,%@) perms=%@",
                  id, panel.title,
                  record.posX.map { String($0) } ?? "nil",
                  record.posY.map { String($0) } ?? "nil",
                  record.grantedPermissions ?? "none")
            try db.savePortPanel(record)
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
    public func popOut(html: String, bridge: PortBridge, channelId: String?, createdBy: String?, messageId: String?, in bounds: CGSize) {
        // Check for existing panel from the same message and update it
        if let idx = panels.firstIndex(where: { $0.messageId == messageId && messageId != nil }) {
            let existingId = panels[idx].id
            let wasBackground = panels[idx].isBackground
            panels[idx] = PortPanel(
                id: existingId,
                html: html,
                bridge: bridge,
                channelId: channelId,
                createdBy: createdBy,
                messageId: messageId,
                title: PortPanel.extractTitle(from: html),
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
            return
        }

        let title = PortPanel.extractTitle(from: html)
        let w: CGFloat = min(400, bounds.width * 0.45)
        let h: CGFloat = min(350, bounds.height * 0.5)

        let panel = PortPanel(
            id: UUID().uuidString,
            html: html,
            bridge: bridge,
            channelId: channelId,
            createdBy: createdBy,
            messageId: messageId,
            title: title,
            size: CGSize(width: w, height: h)
        )
        panels.append(panel)

        // Create the WKWebView once
        createPortWebView(for: panel)
        persistPanel(panel.id)

        // Create native floating window
        createWindow(for: panel, in: bounds)
        Analytics.shared.portPoppedOut()
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

    /// Restore a background port to a floating window.
    public func restore(_ id: String) {
        guard let idx = panels.firstIndex(where: { $0.id == id }), panels[idx].isBackground else { return }
        panels[idx].isBackground = false
        persistPanel(id)

        // Recreate the floating window
        createWindowForExistingPanel(panels[idx])
        NSLog("[Port42] Port restored from background: %@", panels[idx].title)
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

    /// Bring a floating panel to front and make it key.
    public func bringToFront(_ id: String) {
        windows[id]?.makeKeyAndOrderFront(nil)
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

        // Observe move/resize to persist position
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
        ) { [weak self] _ in self?.windowFrameChanged(panelId) }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in self?.windowFrameChanged(panelId) }

        updateWindowContent(window, panel: panel)

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
        window.contentView = NSHostingView(rootView: contentView)
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
                overflow: hidden;
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

    func makeNSView(context: Context) -> NSView {
        let container = PortWebViewContainer()
        webView.removeFromSuperview()
        container.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Don't reclaim the webview if it moved to another container (dock/undock reparenting)
    }
}

// MARK: - Native Panel Window

/// NSPanel subclass with close callback and custom drag region.
class PortNSPanel: NSPanel {
    var onClose: (() -> Void)?

    override func close() {
        onClose?()
        super.close()
    }

}

// MARK: - Panel Content View (rendered inside NSPanel)

struct PortPanelContentView: View {
    let panel: PortPanel
    let manager: PortWindowManager
    @State private var showCode = false
    @State private var pendingPerm: PortPermission?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Custom title bar (draggable)
                PortPanelTitleBar(panel: panel, manager: manager, showCode: $showCode)

                if showCode {
                    ScrollView(.vertical) {
                        Text(panel.html)
                            .font(Port42Theme.mono(12))
                            .foregroundColor(Port42Theme.textSecondary)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if let webView = manager.webViews[panel.id] {
                    PortWebViewHost(webView: webView)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            // Inline permission overlay (no dependency on window key status)
            if let perm = pendingPerm {
                PortPermissionOverlay(
                    permission: perm,
                    onAllow: { panel.bridge.grantPermission() },
                    onDeny: { panel.bridge.denyPermission() }
                )
            }
        }
        .background(Port42Theme.bgPrimary)
        .ignoresSafeArea()
        .onReceive(panel.bridge.$pendingPermission) { perm in
            pendingPerm = perm
        }
    }
}

// MARK: - Permission Overlay

/// Inline permission prompt rendered directly in the view hierarchy.
/// Unlike confirmationDialog (which requires key window status to present as a sheet),
/// this always renders reliably regardless of window state.
struct PortPermissionOverlay: View {
    let permission: PortPermission
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Text(permission.permissionDescription.title)
                    .font(Port42Theme.mono(14))
                    .fontWeight(.semibold)
                    .foregroundStyle(Port42Theme.textPrimary)

                Text(permission.permissionDescription.message)
                    .font(Port42Theme.mono(11))
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
    }
}

// MARK: - Panel Title Bar

struct PortPanelTitleBar: View {
    let panel: PortPanel
    let manager: PortWindowManager
    @Binding var showCode: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Draggable title area (padded to clear macOS traffic light buttons)
            HStack(spacing: 8) {
                Image(systemName: "circle")
                    .font(.system(size: 8))
                    .foregroundStyle(Port42Theme.accent)
                Text(panel.title)
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .lineLimit(1)
                if let creator = panel.createdBy {
                    Text("·")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary)
                    Text(creator)
                        .font(Port42Theme.mono(10))
                        .foregroundStyle(Port42Theme.textSecondary)
                        .lineLimit(1)
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
                Image(systemName: panel.isAlwaysOnTop ? "pin.fill" : "pin")
                    .font(.system(size: 10))
                    .foregroundStyle(panel.isAlwaysOnTop ? Port42Theme.accent : Port42Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(panel.isAlwaysOnTop ? "Unpin" : "Always on top")

            Button(action: { manager.minimize(panel.id) }) {
                Image(systemName: "minus")
                    .font(.system(size: 10))
                    .foregroundStyle(Port42Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Background")

            Button(action: { manager.close(panel.id) }) {
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

// MARK: - WebView Container (preserves first responder on click)

/// NSView container that ensures clicks inside the webview don't trigger
/// app-level focus changes. Accepts first mouse so clicks go through
/// without a focus-first click.
class PortWebViewContainer: NSView {
    private var lastSize: NSSize = .zero

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
}
