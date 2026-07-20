import SwiftUI
import AppKit
import WebKit
import Combine

// MARK: - Port Panel

/// A port that has been popped out of the inline message stream.
public struct PortPanel: Identifiable {
    public let id: String
    public let udid: String
    public var html: String
    public let bridge: PortBridge
    /// The space this port is native to. Mutable for `move` (re-homing — the facade verb);
    /// everything else treats it as fixed at creation.
    public var spaceId: String?
    public let createdBy: String?
    public let messageId: String?
    /// User-set title. Takes priority over HTML <title> extraction.
    public var userTitle: String?
    /// Capabilities declared by the port via port42.port.setCapabilities([...]).
    public var storedCapabilities: [String] = []
    public var size: CGSize
    public var position: CGPoint?
    /// SHELL S3 — z-order among tiled ports on the shell desktop (monotonic; higher = frontmost).
    /// Assigned by `ShellState.focus(_:)`; persisted so a hand-tuned layout restores in order.
    public var z: Int = 0
    /// Port Units Phase 3 — spaces that ADOPTED this port (kept its peek). The port renders on
    /// its home desktop AND every adopter's; persisted, so adoption survives switch + restart.
    public var adoptedSpaceIds: [String] = []
    public var isAlwaysOnTop: Bool = false
    public var isBackground: Bool = false
    public var portType: String = "web"
    public var isChatPort: Bool = false
    /// Presentation: "tiled" (a desktop unit), "parked" (a rail chip), or "inline" (hosted in
    /// a chat `[port:id]` card; session-only, never persisted). "floating" is RETIRED with
    /// classic mode — the v39 migration rewrote any legacy rows to "tiled".
    public var presentation: String = "tiled"
    /// For an inline port, the id of the chat message whose `[port:id]` card (or `` ```port ``
    /// fence) anchors it. Lets dock-back return the webview to its inline host.
    public var anchorMessageId: String? = nil

    /// Resolved display title: userTitle > HTML <title> > "port"
    public var title: String {
        if let ut = userTitle, !ut.isEmpty { return ut }
        return PortPanel.extractTitle(from: html)
    }

    /// For native terminal ports, the `html` field holds a JSON-encoded `TerminalPortConfig`
    /// (not HTML). Decode it; nil for any non-terminal port.
    var terminalConfig: TerminalPortConfig? {
        guard portType == "terminal" else { return nil }
        return try? JSONDecoder().decode(TerminalPortConfig.self, from: Data(html.utf8))
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

    /// Merge stored capabilities with the auto-detected "terminal" capability (a native
    /// `terminal` port). Pure + unit-testable: ensures "terminal" appears exactly once, at front.
    static func mergeCapabilities(_ stored: [String], isTerminal: Bool) -> [String] {
        guard isTerminal, !stored.contains("terminal") else { return stored }
        return ["terminal"] + stored
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
/// Every port renders as a unit on the shell desktop (no OS windows).
/// WKWebViews are created once and reparented between docked/floating states.
@MainActor
public final class PortWindowManager: ObservableObject {

    @Published public var panels: [PortPanel] = []

    /// Panel IDs where the mouse is currently hovering (drives title bar visibility).

    /// Database for persisting port panel state across restarts.
    private weak var db: DatabaseService?

    /// AppState reference for injecting environment into chat port content views.
    public weak var appState: AppState?

    /// Currently active space ID for port visibility management.
    public var activeSpaceId: String? = nil

    /// Persistent WKWebViews, keyed by panel ID. Created once; a port's unit hosts it.
    public var webViews: [String: WKWebView] = [:]

    /// Fires when a TILED port is created (web/terminal/browser), so the shell can raise a §8b
    /// notification for one born in another space (a port from elsewhere peeking in).
    public let portCreated = PassthroughSubject<(id: String, spaceId: String?, title: String), Never>()

    /// Persistent Ghostty terminal views (shell tile path), keyed by panel ID. Same idea as
    /// `webViews`: created once, re-parented between tile/focus/park with no reload. The paired
    /// Coordinator owns the surface teardown, run on port close.
    var terminalViews: [String: GhosttyInputView] = [:]
    var terminalCoordinators: [String: GhosttyTerminalView.Coordinator] = [:]

    /// The persistent NSView backing a port, whatever its type — the one thing a shell tile needs to
    /// host any port uniformly (web → its WKWebView, terminal → its Ghostty surface view). Chat ports
    /// are pure SwiftUI and return nil (the tile renders `ChatView` for those).
    public func hostView(for id: String) -> NSView? {
        if let wv = webViews[id] { return wv }
        return terminalViews[id]
    }

    /// Register a hoisted terminal surface for a tiled terminal port (built by AppState, which owns
    /// the controller the surface binds to).
    func storeTerminalView(id: String, view: GhosttyInputView, coordinator: GhosttyTerminalView.Coordinator) {
        terminalViews[id] = view
        terminalCoordinators[id] = coordinator
    }

    /// Hand the KEYBOARD to a port's live surface. Keyboard-driven focus (⌘` cycling, ⌘↓,
    /// double-click header) never routes through an AppKit click, so the first responder
    /// must be moved by hand — without this, keystrokes keep flowing to the PREVIOUSLY
    /// focused surface. A chat/unhosted unit has no NSView: release the old surface's grip
    /// instead, so typing can't land in a port that's no longer in front.
    /// Deferred one runloop turn: callers fire from inside a SwiftUI update transaction
    /// (zoom onChange / withAnimation), where an immediate makeFirstResponder can be
    /// dropped or beaten by the in-flight view churn. After the turn, ours is the last word.
    public func focusKeyboard(on id: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let v = self.hostView(for: id), let win = v.window {
                win.makeFirstResponder(v)
            } else if let panel = self.panels.first(where: { $0.id == id }), panel.isChatPort {
                // The chat unit is pure SwiftUI — focus its input FIELD via the existing
                // focusChatInput listener (scoped by spaceId so only THIS chat's field grabs).
                NotificationCenter.default.post(name: .focusChatInput, object: panel.spaceId)
            } else if let win = NSApp?.keyWindow {   // NSApp is nil headless (tests)
                win.makeFirstResponder(nil)
            }
        }
    }

    /// Step 8: reported content height for inline-presented ports, keyed by panel ID. Drives the
    /// SwiftUI inline host's frame so a registry-owned port auto-sizes like the legacy inline view.
    /// Floating ports ignore this (the window drives their size).
    @Published public var inlineHeights: [String: CGFloat] = [:]

    /// Console handler kept alive for WKWebView message routing.
    private var consoleHandlers: [String: PortConsoleHandler] = [:]

    /// Inline height handlers kept alive for WKWebView message routing (Step 8).
    private var heightHandlers: [String: PortHeightHandler] = [:]

    /// Navigation delegates kept alive for WKWebView.
    private var navDelegates: [String: PortNavigationBlocker] = [:]

    /// Panels running in the background (hidden but alive).
    public var backgroundPanels: [PortPanel] {
        panels.filter { $0.isBackground }
    }

    /// Set database reference for persistence.
    public func setDatabase(_ db: DatabaseService) {
        self.db = db
    }

    /// Restore persisted port panels from the database after app launch.
    public func restoreFromDB(appState: AnyObject) {
        guard let db = db else { return }
        do {
            let saved = try db.fetchPortPanels()
            for row in saved {
                let bridge = PortBridge(appState: appState, spaceId: row.spaceId, messageId: row.messageId, createdBy: row.createdBy)
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
                var panel = PortPanel(
                    id: row.id,
                    udid: row.udid ?? row.id,
                    html: row.html,
                    bridge: bridge,
                    spaceId: row.spaceId,
                    createdBy: row.createdBy,
                    messageId: row.messageId,
                    userTitle: row.userTitle,
                    storedCapabilities: restoredCaps,
                    size: CGSize(width: row.width, height: row.height),
                    position: pos,
                    isAlwaysOnTop: row.isAlwaysOnTop,
                    isBackground: row.isBackground,
                    portType: row.portType,
                    isChatPort: row.isChatPort
                )
                // SHELL S3 — restore the shell desktop layout: presentation ("tiled"/"parked"/
                // "floating") and z-order. Without this a tiled port restored as "floating" and
                // fell out of the desktop render (which filters presentation == "tiled").
                panel.presentation = row.presentation
                panel.z = row.z
                // Phase 3 — restore adoption (kept peeks survive a restart on their adopters).
                if let adoptedStr = row.adoptedSpaceIds,
                   let data = adoptedStr.data(using: .utf8),
                   let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                    panel.adoptedSpaceIds = arr
                }
                panels.append(panel)
                // Chat ports render ChatView; terminal ports host a Ghostty surface —
                // only web ports get a WKWebView.
                if !panel.isChatPort && panel.portType != "terminal" {
                    createPortWebView(for: panel)
                } else if panel.portType == "terminal" {
                    // A terminal was on a desktop at shutdown — rebuild its controller + hoisted
                    // Ghostty surface now so its tile has a live shell to host again. The process
                    // itself is gone across a restart, so this relaunches the startup command.
                    rebuildTiledTerminal(panel, app: appState)
                }
            }
            if !saved.isEmpty {
                NSLog("[Port42] Restored %d port panels from database", saved.count)
            }
        } catch {
            NSLog("[Port42] Failed to restore port panels: %@", error.localizedDescription)
        }
    }

    /// Rebuild a tiled/parked terminal's controller + hoisted Ghostty surface after a restart, and
    /// register the view so the shell tile can host it (mirrors the spawn path).
    private func rebuildTiledTerminal(_ panel: PortPanel, app: AnyObject) {
        guard let appState = app as? AppState, var config = panel.terminalConfig else { return }
        // Reopen where the user actually WAS: the shell reported its live cwd on every cd
        // (PORT42_CWD_FILE); the spawn cwd is only the fallback.
        if let liveCwd = TerminalSessionBootstrap.savedLiveCwd(portId: panel.id) {
            config.cwd = liveCwd
        }
        // A claude terminal resumes its most recent conversation in that cwd instead of
        // starting cold (falls back to a fresh session when there's nothing to continue).
        if config.startupCommand == "claude" {
            config.startupCommand = "claude --continue || claude"
        }
        guard let controller = appState.makeTerminalController(for: panel) else { return }
        let built = GhosttyTerminalView.makeDetached(
            config: config, env: controller.env,
            onTee: { controller.receiveTee($0) },
            onInject: { controller.bindSurface($0) })
        storeTerminalView(id: panel.id, view: built.view, coordinator: built.coordinator)
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
        // Step 8: inline-presented ports are session-only — they re-register from their anchor
        // message each session, so they must never land a DB row (else they'd restore as orphan
        // floating windows). Promotion to "floating" persists normally.
        guard panel.presentation != "inline" else { return }
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
    public func popOut(html: String, bridge: PortBridge, spaceId: String?, createdBy: String?, messageId: String?, title: String? = nil, portType: String = "web", in bounds: CGSize) -> String {
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
                spaceId: spaceId,
                createdBy: createdBy,
                messageId: messageId,
                userTitle: title ?? panels[idx].userTitle,
                storedCapabilities: panels[idx].storedCapabilities,
                size: panels[idx].size,
                position: panels[idx].position,
                isAlwaysOnTop: panels[idx].isAlwaysOnTop,
                isBackground: wasBackground,
                portType: panels[idx].portType,
                isChatPort: panels[idx].isChatPort
            )
            // Recreate webview with new content — skipped for native terminal ports,
            // which host a Ghostty surface (no WKWebView).
            if panels[idx].portType != "terminal" {
                destroyWebView(existingId)
                createPortWebView(for: panels[idx])
            }
            // If backgrounded, restore it since new content was created
            if wasBackground { panels[idx].isBackground = false }
            persistPanel(existingId)
            bringToFront(existingId)
            return existingId
        }

        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let w: CGFloat = screen.width * 0.4
        let h: CGFloat = screen.height * 0.4

        let newUdid = UUID().uuidString
        var panel = PortPanel(
            id: newUdid,
            udid: newUdid,
            html: html,
            bridge: bridge,
            spaceId: spaceId,
            createdBy: createdBy,
            messageId: messageId,
            userTitle: title,
            size: CGSize(width: w, height: h)
        )
        panel.portType = portType
        panel.presentation = "tiled"                      // pop-out lands on the desktop
        panel.position = nil                              // arrange places it
        panels.append(panel)

        // Native terminal ports host a Ghostty surface, not a WKWebView.
        if portType != "terminal" {
            createPortWebView(for: panel)
        }
        persistPanel(panel.id)
        portCreated.send((id: panel.id, spaceId: spaceId, title: panel.title))
        Analytics.shared.portPoppedOut()
        return newUdid
    }

    // MARK: - Inline Ports (Step 8)

    /// Register (or reuse) a session-only inline-presented port. Creates ONE registry-owned
    /// WKWebView and an inline `PortPanel` — but never a window and never a DB row. Idempotent
    /// by id: a re-render (or scroll-back) returns the existing port untouched, preserving its
    /// DOM/JS state. The same registered port is later re-parented into a floating window by
    /// `undockInline` with no reload. Returns the port's bridge (for permission/event
    /// observation by the inline host), or nil if AppState is gone.
    @discardableResult
    public func registerInlinePort(id: String, html: String, spaceId: String?, createdBy: String?,
                                   title: String?, anchorMessageId: String?) -> PortBridge? {
        if let existing = panels.first(where: { $0.id == id }) {
            return existing.bridge
        }
        guard let appState = appState else { return nil }
        let resolvedTitle = (title?.isEmpty == false) ? title : PortPanel.extractTitle(from: html)
        // bridge.messageId == the port's own derived id, matching the legacy inline path's
        // permission-cache key (registerPortBridge caches by messageId). `anchorMessageId` (the
        // host chat message) is tracked separately on the panel for re-render / dock-back.
        let bridge = PortBridge(appState: appState, spaceId: spaceId, messageId: id,
                                createdBy: createdBy, title: resolvedTitle)
        var panel = PortPanel(
            id: id, udid: id, html: html, bridge: bridge,
            spaceId: spaceId, createdBy: createdBy, messageId: id,
            userTitle: title, size: CGSize(width: 100, height: 100))
        panel.portType = "web"
        panel.presentation = "inline"
        panel.anchorMessageId = anchorMessageId
        panels.append(panel)
        createPortWebView(for: panel)
        // Deliberately NOT persisted: inline ports re-register from their anchor each session.
        return bridge
    }

    /// SHELL — S2.2: register a desktop TILE. A tiled port is a registry-owned webview composited on
    /// the shell desktop (`ShellView`), positioned by `position` (arrange picks the spot when nil) —
    /// NOT a chat message (unlike an inline port). It is the same registered entity as any port and
    /// re-parents with no reload between tiled / floating / parked. (Persistence of tiled panels
    /// lands with the S3 `z` migration.)
    @discardableResult
    public func registerTiledPort(id: String, html: String, spaceId: String?, createdBy: String?,
                                  title: String?, position: CGPoint?, size: CGSize? = nil) -> PortBridge? {
        if let existing = panels.first(where: { $0.id == id }) {
            return existing.bridge
        }
        guard let appState = appState else { return nil }
        let resolvedTitle = (title?.isEmpty == false) ? title : PortPanel.extractTitle(from: html)
        let bridge = PortBridge(appState: appState, spaceId: spaceId, messageId: id,
                                createdBy: createdBy, title: resolvedTitle)
        var panel = PortPanel(
            id: id, udid: id, html: html, bridge: bridge,
            spaceId: spaceId, createdBy: createdBy, messageId: id,
            userTitle: title, size: size ?? CGSize(width: 360, height: 260))
        panel.portType = "web"
        panel.presentation = "tiled"
        panel.position = position
        panels.append(panel)
        createPortWebView(for: panel)
        persistPanel(id)                       // SHELL S3 — tiled ports persist (survive restart)
        portCreated.send((id: id, spaceId: spaceId, title: resolvedTitle ?? "port"))
        return bridge
    }

    /// Create a TILED terminal port (shell path) — a panel only, no window, no webview. The caller
    /// (AppState) then builds the controller + hoisted Ghostty surface and calls `storeTerminalView`.
    /// This is the terminal twin of `registerTiledPort`: a terminal is a port; a port is a tile.
    func addTiledTerminalPanel(configJSON: String, spaceId: String?, createdBy: String?,
                               title: String, size: CGSize? = nil) -> String {
        guard let appState = appState else { return "" }
        let id = UUID().uuidString
        let bridge = PortBridge(appState: appState, spaceId: spaceId, messageId: id, createdBy: createdBy)
        var panel = PortPanel(
            id: id, udid: id, html: configJSON, bridge: bridge,
            spaceId: spaceId, createdBy: createdBy, messageId: id,
            userTitle: title, size: size ?? CGSize(width: 520, height: 380))
        panel.portType = "terminal"
        panel.presentation = "tiled"
        panel.position = nil                    // let arrange place it
        panels.append(panel)
        persistPanel(id)
        portCreated.send((id: id, spaceId: spaceId, title: title))
        return id
    }

    /// Create a TILED browser port — an embedded WKWebView navigated to a real URL (not an iframe, so
    /// framing-blocked sites still load). `html` carries the start URL. A web port at heart: it uses
    /// the same registry webview, just with permissive navigation.
    func addTiledBrowserPanel(url: String, spaceId: String?, createdBy: String?,
                              title: String, size: CGSize? = nil) -> String {
        guard let appState = appState else { return "" }
        let id = UUID().uuidString
        let bridge = PortBridge(appState: appState, spaceId: spaceId, messageId: id, createdBy: createdBy)
        var panel = PortPanel(
            id: id, udid: id, html: url, bridge: bridge,
            spaceId: spaceId, createdBy: createdBy, messageId: id,
            userTitle: title, size: size ?? CGSize(width: 900, height: 640))
        panel.portType = "browser"
        panel.presentation = "tiled"
        panel.position = nil
        panels.append(panel)
        createPortWebView(for: panel)
        persistPanel(id)
        portCreated.send((id: id, spaceId: spaceId, title: title))
        return id
    }

    /// Turn address-bar text into a loadable URL: pass through http(s), assume https for a bare
    /// domain, else DuckDuckGo search. Empty → the start page.
    static func normalizedBrowserURL(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "https://duckduckgo.com" }
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return s }
        if !s.contains(" "), s.contains(".") { return "https://" + s }
        let q = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
        return "https://duckduckgo.com/?q=" + q
    }

    /// Step 8: undock an inline port — give it its own window. A tile IS a port's window:
    /// the port lands on its space's desktop; the desktop's count-change arrange places it.
    public func undockInline(id: String, in bounds: CGSize) {
        guard let idx = panels.firstIndex(where: { $0.id == id }),
              panels[idx].presentation == "inline" else {
            bringToFront(id)
            return
        }
        // Give it a real size now that it owns a surface (it was created at 100×100).
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        if panels[idx].size.width < 200 || panels[idx].size.height < 150 {
            panels[idx].size = CGSize(width: screen.width * 0.4, height: screen.height * 0.4)
        }
        panels[idx].presentation = "tiled"
        panels[idx].position = nil                    // let arrange place it
        persistPanel(id)                              // now a desktop tile → persisted
        Analytics.shared.portPoppedOut()
    }

    // MARK: - SHELL port verbs (tiled ↔ parked; the SAME view, no reload, no floating)

    /// Re-home a port to another space (the facade's `move`, plan §3): only `spaceId` changes —
    /// presentation, geometry, and the live view are untouched. `spaceId` is a stored column,
    /// so the move survives restart with no extra persistence machinery. Native beats adopted:
    /// the new home is stripped from the adopters (other adopters keep it).
    public func move(id: String, toSpace spaceId: String) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        panels[idx].spaceId = spaceId
        panels[idx].bridge.spaceId = spaceId   // API calls/permissions attribute to the new home
        panels[idx].adoptedSpaceIds.removeAll { $0 == spaceId }
        persistPanel(id)
    }

    /// Phase 3 — ADOPT a foreign port onto a space's desktop (keep a peek): persisted on the
    /// panel, so it survives space-switch and restart. Idempotent; a port's own home is never
    /// an adopter (native beats adopted).
    public func adopt(id: String, into spaceId: String) {
        guard let idx = panels.firstIndex(where: { $0.id == id }),
              panels[idx].spaceId != spaceId,
              !panels[idx].adoptedSpaceIds.contains(spaceId) else { return }
        panels[idx].adoptedSpaceIds.append(spaceId)
        persistPanel(id)
    }

    /// Phase 3 — DETACH an adopted port from a space's desktop (✕ on the tile): drop the
    /// adoption and persist. The port lives on in its home space and any other adopters.
    public func unadopt(id: String, from spaceId: String) {
        guard let idx = panels.firstIndex(where: { $0.id == id }),
              panels[idx].adoptedSpaceIds.contains(spaceId) else { return }
        panels[idx].adoptedSpaceIds.removeAll { $0 == spaceId }
        persistPanel(id)
    }

    /// Phase 3 — the ports a space's desktop stages (the facade's `ports(in:)`): its native
    /// panels plus every panel adopted into it. Background panels excluded.
    public func panels(in spaceId: String) -> [PortPanel] {
        panels.filter { !$0.isBackground
            && ($0.spaceId == spaceId || $0.adoptedSpaceIds.contains(spaceId)) }
    }

    /// SHELL: make sure a space's `isChatPort` panel is a desktop tile with a visible slot
    /// (legacy rows could carry an off-screen classic-layout position; parked stays parked).
    public func ensureChatTiled(spaceId: String) {
        guard let idx = panels.firstIndex(where: { $0.isChatPort && $0.spaceId == spaceId }),
              panels[idx].presentation != "parked" else { return }
        if panels[idx].presentation != "tiled" {
            panels[idx].presentation = "tiled"
            persistPanel(panels[idx].id)
        }
    }

    /// Park a tiled port into the right-edge rail (minimize to a chip). Same webview, no reload —
    /// the parked port is excluded from the desktop render and from `arrange`/`exposé`.
    public func park(id: String) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        panels[idx].presentation = "parked"
        panels[idx].bridge.suspendAI()      // stop any in-flight generation the moment it's parked
        persistPanel(id)
    }

    /// SHELL: bring a space's chat back onto the desktop as a tile from any state (parked, popped-out
    /// floating, already tiled — or DELETED). The dock's "chat" button uses this; it's how a
    /// closed/parked chat is reopened, and it RE-CREATES the chat port if you deleted them all.
    public func revealChat(spaceId: String, spaceName: String) {
        if !panels.contains(where: { $0.isChatPort && $0.spaceId == spaceId }) {
            ensureChatPort(spaceId: spaceId, spaceName: spaceName)   // gone entirely → make a fresh one
        }
        guard let idx = panels.firstIndex(where: { $0.isChatPort && $0.spaceId == spaceId }) else { return }
        panels[idx].presentation = "tiled"
        persistPanel(panels[idx].id)
    }

    /// Restore a parked port back onto the desktop as a tile (no reload).
    public func unpark(id: String) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        panels[idx].presentation = "tiled"
        persistPanel(id)
    }

    /// Persist a tile's new geometry after a drag/resize ends (the shell desktop is the layout
    /// authority; hand positions survive restart). No-op for a port that isn't tiled/floating.
    public func updateTileFrame(id: String, position: CGPoint, size: CGSize? = nil) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        panels[idx].position = position
        if let size { panels[idx].size = size }
        persistPanel(id)
    }

    /// Stamp a tiled port frontmost (monotonic z from `ShellState.nextZ()`), then persist.
    public func setZ(id: String, z: Int) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        panels[idx].z = z
        persistPanel(id)
    }

    /// Close a panel (the shell's ✕ affordances confirm by gesture, not a dialog).
    public func closeWithConfirmation(_ id: String) {
        close(id)
    }

    /// Close a panel by ID.
    public func close(_ id: String) {
        if let panel = panels.first(where: { $0.id == id }), !panel.isChatPort {
            destroyWebView(id)
        }
        appState?.teardownTerminalController(panelId: id)
        // Tear down a hoisted terminal surface (shell tile path). The floating path frees via
        // dismantleNSView; the detached view isn't SwiftUI-managed, so free it explicitly here.
        terminalCoordinators.removeValue(forKey: id)?.teardown()
        terminalViews[id]?.removeFromSuperview()
        terminalViews.removeValue(forKey: id)
        TerminalSessionBootstrap.clearLiveCwd(portId: id)   // a closed port forgets its cwd
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

    /// Toggle always-on-top for a panel (kept as a stored flag; the shell's z-sort may use it).
    public func toggleAlwaysOnTop(_ id: String) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        panels[idx].isAlwaysOnTop.toggle()
    }

    /// Send a port to the background (off the desktop, still running). The unit unmounts —
    /// the live view stays in the registry and remounts (repainting) on restore.
    public func minimize(_ id: String) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        panels[idx].isBackground = true
        panels[idx].bridge.suspendAI()      // backgrounded = off-screen: stop billing the model
        persistPanel(id)
        NSLog("[Port42] Port minimized to background: %@", panels[idx].title)
    }

    /// Restore a background port to the desktop. Returns false if the port is not backgrounded.
    @discardableResult
    public func restore(_ id: String) -> Bool {
        guard let idx = panels.firstIndex(where: { $0.id == id }), panels[idx].isBackground else { return false }
        panels[idx].isBackground = false
        persistPanel(id)
        NSLog("[Port42] Port restored from background: %@", panels[idx].title)
        return true
    }

    /// Stop a port by destroying its webview.
    public func stop(_ id: String) {
        guard panels.contains(where: { $0.id == id }) else { return }
        destroyWebView(id)
        NSLog("[Port42] Port stopped: %@", panels.first(where: { $0.id == id })?.title ?? id)
    }

    /// Restart a port by reloading its content. Web ports reload the WKWebView; native
    /// terminal ports rebuild the Ghostty surface via a fresh controller.
    public func restart(_ id: String) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        if panels[idx].portType == "terminal" {
            appState?.makeTerminalController(for: panels[idx])
        } else {
            destroyWebView(id)
            createPortWebView(for: panels[idx])
        }
        NSLog("[Port42] Port restarted: %@", panels[idx].title)
    }

    /// Reload a registered port's original HTML into the SAME webview (restart-in-place — resets
    /// DOM/JS, re-runs scripts). Unlike `restart`, it does NOT destroy/recreate the webview, so an
    /// inline host showing `webViews[id]` keeps its adopted view (no re-parent needed).
    public func reloadPort(_ id: String) {
        guard let panel = panels.first(where: { $0.id == id }), let wv = webViews[id] else { return }
        let document = PortWebViewFactory.wrapHTML(panel.html)
        wv.loadHTMLString(document, baseURL: URL(string: "http://port42.local/"))
        NSLog("[Port42] Port reloaded in place: %@", panel.title)
    }

    /// Lightweight version history for UI display (no HTML blobs). Grouped by `<meta>` version.
    public func fetchVersionSummaries(_ id: String) -> [PortVersionSummary] {
        guard let panel = panels.first(where: { $0.id == id }),
              let db = db else { return [] }
        return (try? db.fetchPortVersionSummaries(portUdid: panel.udid)) ?? []
    }

    /// Every individual save (ungrouped, no HTML blobs) — the drill-down under the grouped view.
    public func fetchSaveList(_ id: String) -> [PortVersionSummary] {
        guard let panel = panels.first(where: { $0.id == id }),
              let db = db else { return [] }
        return (try? db.fetchPortSaveList(portUdid: panel.udid)) ?? []
    }

    /// Restore a port to a specific version from its history (no new version snapshot).
    public func restoreVersion(_ id: String, version: Int) {
        guard let panel = panels.first(where: { $0.id == id }),
              let db = db,
              let html = try? db.fetchPortVersionHtml(udid: panel.udid, version: version) else { return }
        _ = updatePort(idOrTitle: panel.udid, html: html, skipVersionSnapshot: true)
        NSLog("[Port42] Port restored to v%d: %@", version, panel.title)
    }

    /// Raise a panel to the top of the desktop z-order (the shell's ForEach paints by z).
    public func bringToFront(_ id: String) {
        let top = (panels.map(\.z).max() ?? 0) + 1
        setZ(id: id, z: top)
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
    public func allPorts() -> [(udid: String, title: String, createdBy: String?, capabilities: [String], cwd: String?, isBackground: Bool, presentation: String, spaceId: String?, x: CGFloat?, y: CGFloat?)] {
        panels.map { panel in
            // A native `terminal` port advertises the "terminal" capability. (cwd has no native
            // equivalent yet — see summer2026-todo "native terminal output-streaming bridge".)
            let caps = PortPanel.mergeCapabilities(panel.storedCapabilities,
                                                   isTerminal: panel.portType == "terminal")
            let origin = panel.position
            return (udid: panel.udid, title: panel.title, createdBy: panel.createdBy, capabilities: caps, cwd: nil, isBackground: panel.isBackground, presentation: panel.presentation, spaceId: panel.spaceId, x: origin?.x, y: origin?.y)
        }
    }

    /// Current frame of a port's tile (nil if it has no committed position yet).
    public func portFrame(by id: String) -> CGRect? {
        guard let panel = findPort(by: id), let pos = panel.position else { return nil }
        return CGRect(origin: pos, size: panel.size)
    }

    /// Move a port's tile to the given desktop coordinates.
    public func movePort(id: String, x: CGFloat, y: CGFloat) {
        guard let panel = findPort(by: id) else { return }
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

        // Step 8: inline height reporting — lets a registry-owned port auto-size when presented
        // inline. Harmless for floating ports (the window drives their size).
        let heightScript = WKUserScript(
            source: PortWebViewFactory.heightJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(heightScript)
        let heightHandler = PortHeightHandler(manager: self, portId: panel.id)
        config.userContentController.add(heightHandler, name: "portHeight")
        heightHandlers[panel.id] = heightHandler

        let webView = FileDropWebView(frame: .zero, configuration: config)
        let isBrowser = panel.portType == "browser"
        // A browser follows links & shows the site's own background; a normal port is locked to its
        // document and drawn transparent over the shell.
        let navDelegate: PortNavigationBlocker = isBrowser ? PortBrowserNavigation() : PortNavigationBlocker()
        webView.navigationDelegate = navDelegate
        navDelegates[panel.id] = navDelegate
        webView.setValue(!isBrowser, forKey: "drawsBackground")
        webView.allowsMagnification = isBrowser

        // Give bridge a reference to the webview for callbacks
        panel.bridge.setWebView(webView)
        webView.dropBridge = panel.bridge  // Step 5c: handle file drops onto this floating port

        // Load content: a browser navigates to a real URL (panel.html carries it); every other web
        // port loads its HTML document.
        if isBrowser, let url = URL(string: PortWindowManager.normalizedBrowserURL(panel.html)) {
            webView.load(URLRequest(url: url))
        } else {
            let document = PortWebViewFactory.wrapHTML(panel.html)
            webView.loadHTMLString(document, baseURL: URL(string: "http://port42.local/"))
        }

        webViews[panel.id] = webView
    }

    /// Clean up a webview and its associated handlers.
    private func destroyWebView(_ id: String) {
        webViews[id]?.removeFromSuperview()
        webViews.removeValue(forKey: id)
        consoleHandlers.removeValue(forKey: id)
        navDelegates.removeValue(forKey: id)
        heightHandlers.removeValue(forKey: id)
        inlineHeights.removeValue(forKey: id)
    }


    // MARK: - Space-Aware Port Visibility

    /// Switch to a new space: track it and make sure its chat port record exists (the shell
    /// desktop renders per-space from `panels` — there are no windows to hide/show).
    public func switchToSpace(_ spaceId: String, spaceName: String) {
        activeSpaceId = spaceId
        ensureChatPort(spaceId: spaceId, spaceName: spaceName)
    }

    /// Ensure a chat port record exists for the space (record only; the shell tiles it).
    private func ensureChatPort(spaceId: String, spaceName: String) {
        guard let appState = appState else { return }
        guard !panels.contains(where: { $0.isChatPort && $0.spaceId == spaceId }) else { return }
        let newId = UUID().uuidString
        let bridge = PortBridge(appState: appState, spaceId: spaceId, messageId: nil, createdBy: nil)
        // A visible default; `ensureChatTiled`/arrange position it on the shell desktop.
        let size = CGSize(width: 520, height: 420)
        let position: CGPoint? = nil
        var panel = PortPanel(
            id: newId,
            udid: newId,
            html: "",
            bridge: bridge,
            spaceId: spaceId,
            createdBy: nil,
            messageId: nil,
            userTitle: "chat",
            size: size,
            position: position
        )
        panel.portType = "chat"
        panel.isChatPort = true
        panels.append(panel)
        persistPanel(panel.id)
        NSLog("[Port42] Registered chat port for space: %@", spaceName)
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
        <script>
        // Teaching hint (classic script, not a module): port scripts run as ES modules, so inline
        // onclick attributes cannot see module-scope functions. When that exact failure fires,
        // say so with the fix, instead of a bare "Can't find variable".
        window.addEventListener('error', function(e) {
            if (e.message && (e.message.indexOf("Can't find variable") !== -1 || e.message.indexOf('is not defined') !== -1)) {
                console.warn('[port42] Port scripts are ES modules: top-level functions are module-scoped, so inline onclick cannot reach them. Attach handlers with addEventListener or expose with window.fn = fn.');
            }
        });
        </script>
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
        var lw = -1, lh = -1, scheduled = false;
        function updateViewport() {
            scheduled = false;
            const w = document.documentElement.clientWidth;
            const h = document.documentElement.clientHeight;
            if (w === lw && h === lh) return;   // no change → don't re-write CSS vars / re-fire listeners
            lw = w; lh = h;
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
        function schedule() {   // coalesce observer bursts into one update per frame (see heightJS)
            if (scheduled) return;
            scheduled = true;
            requestAnimationFrame(updateViewport);
        }
        window.addEventListener('load', schedule);
        window.addEventListener('resize', schedule);
        new ResizeObserver(schedule).observe(document.body);
        setTimeout(schedule, 100);
    })();
    """

    /// Inline height reporting JS (Step 8). Posts document.body.scrollHeight to the native
    /// `portHeight` handler so an inline-presented port auto-sizes.
    ///
    /// ROOT-CAUSE HARDENING (hang fix): a naive `ResizeObserver(reportHeight)` posts synchronously on
    /// every layout, and each post changes the SwiftUI `.frame(height:)` → re-lays-out the webview →
    /// fires the observer again, unthrottled. In a chat `LazyVStack` that re-measures every row, a port
    /// whose height has no stable ≤1px fixed point (scrollbar hysteresis, %/vh content, sub-pixel
    /// reflow) drives an unbounded synchronous layout loop → main-thread hang. Three guards break it:
    ///   1. coalesce a burst of observer callbacks into ONE measure per animation frame (rAF);
    ///   2. only post when the rounded height actually changed (a settled port goes silent);
    ///   3. lock out A-B-A oscillation to the taller state, so scrollbar hysteresis can't flip forever.
    static let heightJS = """
    (function() {
        var lastH = -1, prevH = -2, scheduled = false, locked = false;
        function measure() {
            scheduled = false;
            var h = Math.ceil(document.body.scrollHeight);
            if (locked) {
                if (h <= lastH + 1) return;   // ignore hysteresis shrink; only grow past the lock
                locked = false;               // genuinely taller now → resume normal reporting
            }
            if (Math.abs(h - lastH) <= 1) return;             // settled → silent
            if (Math.abs(h - prevH) <= 1) { h = Math.max(h, lastH); locked = true; }  // A-B-A → lock taller
            prevH = lastH; lastH = h;
            try { window.webkit.messageHandlers.portHeight.postMessage(h); } catch(e) {}
        }
        function schedule() {
            if (scheduled) return;
            scheduled = true;
            requestAnimationFrame(measure);
        }
        window.addEventListener('load', function() {
            schedule();
            new ResizeObserver(schedule).observe(document.body);
        });
        setTimeout(schedule, 100);
        setTimeout(schedule, 500);
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

// MARK: - Inline Height Handler (Step 8)

/// Receives `document.body.scrollHeight` from a registry-owned port webview and republishes it on
/// the manager (`inlineHeights[portId]`) so the SwiftUI inline host can size itself. Floating ports
/// ignore the value. Clamped to [40, 600] to match the legacy inline-port sizing.
final class PortHeightHandler: NSObject, WKScriptMessageHandler {
    weak var manager: PortWindowManager?
    let portId: String

    init(manager: PortWindowManager, portId: String) {
        self.manager = manager
        self.portId = portId
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "portHeight", let h = message.body as? CGFloat else { return }
        let clamped = min(max(h, 40), 600)
        let id = portId
        Task { @MainActor [weak manager] in
            guard let manager else { return }
            if abs((manager.inlineHeights[id] ?? -1) - clamped) > 1 {
                manager.inlineHeights[id] = clamped
            }
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

/// A browser port must FOLLOW links (unlike a normal port, which is locked to its own document), so
/// allow every navigation. Subclass so it fits the existing `navDelegates` registry.
final class PortBrowserNavigation: PortNavigationBlocker {
    override func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
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
        // File drops are handled by FileDropWebView itself (Step 5c) — see PortView.swift.
        // (The old unregisterDraggedTypes()/container approach made the webview refuse drops.)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Don't reclaim the webview if it moved to another container (dock/undock reparenting)
    }
}

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

    // File drops are handled by FileDropWebView (the webview subview), not the container.
}

