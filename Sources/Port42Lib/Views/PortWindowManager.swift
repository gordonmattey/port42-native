import SwiftUI
import AppKit
import WebKit
import Combine

// MARK: - Port Panel

/// Where a port is pinned (GM, 2026-09-27).
public enum PortPin: String, Sendable {
    case none, space, everywhere
}

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
    /// Where this tile sits ON EACH DESKTOP it appears on, keyed by space id.
    ///
    /// A port renders on its home space AND on every space that adopted it (`adoptedSpaceIds`), plus
    /// surfaced foreign chats. It used to carry ONE position, so placing it on one desktop moved it
    /// on the other (GM 2026-08-03: "we shouldn't have this"). An absent key means "not placed on
    /// that desktop yet", which is what makes a newly adopted port get placed there rather than
    /// inheriting a spot chosen somewhere else.
    public var positions: [String: CGPoint] = [:]
    /// Key for a port with no space at all, so the map still has somewhere to put its position.
    static let homelessKey = ""

    /// This tile's position on one desktop. `nil` for the space it has not been placed on.
    public func position(on spaceId: String?) -> CGPoint? {
        positions[pinnedEverywhere ? (self.spaceId ?? Self.homelessKey) : (spaceId ?? self.spaceId ?? Self.homelessKey)]
    }

    public mutating func setPosition(_ p: CGPoint?, on spaceId: String?) {
        let key = pinnedEverywhere ? (self.spaceId ?? Self.homelessKey) : (spaceId ?? self.spaceId ?? Self.homelessKey)
        if let p { positions[key] = p } else { positions.removeValue(forKey: key) }
    }

    /// The HOME-space position: what `posX`/`posY`, `ports.list` and `port.position` report when no
    /// desktop is named. Setting it to nil unplaces the port EVERYWHERE, which is what the birth
    /// paths mean by `position = nil`.
    public var position: CGPoint? {
        get { positions[spaceId ?? Self.homelessKey] }
        set {
            guard let newValue else { positions.removeAll(); return }
            positions[spaceId ?? Self.homelessKey] = newValue
        }
    }
    /// SHELL S3 — z-order among tiled ports on the shell desktop (monotonic; higher = frontmost).
    /// Assigned by `ShellState.focus(_:)`; persisted so a hand-tuned layout restores in order.
    public var z: Int = 0
    /// Port Units Phase 3 — spaces that ADOPTED this port (kept its peek). The port renders on
    /// its home desktop AND every adopter's; persisted, so adoption survives switch + restart.
    public var adoptedSpaceIds: [String] = []
    /// Pinned in its space (GM, 2026-09-27): drawn above every unpinned tile there. The column
    /// predates the shell (the old window's "always on top"), so it is reused, not renamed.
    public var isAlwaysOnTop: Bool = false
    public var pin: PortPin { pinnedEverywhere ? .everywhere : (isAlwaysOnTop ? .space : .none) }
    /// Pinned in every space: the port shows on every desktop, above unpinned tiles, at ONE position
    /// (moving it anywhere moves it everywhere). Implies pinned.
    public var pinnedEverywhere: Bool = false
    public var isBackground: Bool = false
    public var portType: String = "web"
    /// Presentation: "tiled" (a desktop unit), "parked" (a rail chip) or "background" (the desktop
    /// wallpaper). "floating" is RETIRED with classic mode (the v39 migration rewrote legacy rows to
    /// "tiled"), and "inline" with the chat (D11).
    public var presentation: String = "tiled"
    /// This port's slot in its space's park rail (0 = top) while parked; nil otherwise. Persisted
    /// in the `dockOrder` column (nautilus Phase 2 step 3).
    public var railOrder: Int? = nil

    /// A port's status as the API says it (GM, 2026-09-29): "tiled", "running" (off the desktop at full
    /// speed; stored as `isBackground`) or "paused" (off the desktop, slowed; stored as "parked"), or
    /// "background" for the wallpaper. The stored names are older and stay as they are.
    public static func status(isBackground: Bool, presentation: String) -> String {
        if isBackground { return "running" }
        return presentation == "parked" ? "paused" : presentation
    }

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

    /// Capabilities only Port42 can state, because it DERIVES them from what a port is (APP-18).
    /// A port's own list is self-asserted, so a web port claiming "terminal" was listed beside real
    /// terminals, and a caller looking for one could push commands into a page instead.
    static let platformCapabilities: Set<String> = ["terminal"]

    /// Merge stored capabilities with the auto-detected "terminal" capability (a native
    /// `terminal` port). Pure + unit-testable: ensures "terminal" appears exactly once, at front,
    /// and ONLY on a real terminal: a stored claim to a platform capability is dropped, which also
    /// cleans a claim restored from before `port.setCapabilities` refused it.
    static func mergeCapabilities(_ stored: [String], isTerminal: Bool) -> [String] {
        let declared = stored.filter { !platformCapabilities.contains($0) }
        return isTerminal ? ["terminal"] + declared : declared
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

    /// The port whose terminal surface this is, if any.
    func terminalPort(surface: UnsafeMutableRawPointer) -> String? {
        terminalViews.first { id, view in view.surface.map { UnsafeMutableRawPointer($0) } == surface }?.key
    }

    /// Register a hoisted terminal surface for a tiled terminal port (built by AppState, which owns
    /// the controller the surface binds to).
    func storeTerminalView(id: String, view: GhosttyInputView, coordinator: GhosttyTerminalView.Coordinator) {
        terminalViews[id] = view
        terminalCoordinators[id] = coordinator
    }

    /// Type a prefilled line into a terminal port's CLI without submitting it (see
    /// `Coordinator.typePrefill`). The coordinator owns the once-guard.
    func prefillTerminal(id: String, text: String) {
        terminalCoordinators[id]?.typePrefill(text)
    }

    /// Hand the KEYBOARD to a port's live surface. Keyboard-driven focus (⌘` cycling, ⌘↓,
    /// double-click header) never routes through an AppKit click, so the first responder
    /// must be moved by hand — without this, keystrokes keep flowing to the PREVIOUSLY
    /// focused surface. A chat/unhosted unit has no NSView: release the old surface's grip
    /// instead, so typing can't land in a port that's no longer in front.
    /// Deferred one runloop turn: callers fire from inside a SwiftUI update transaction
    /// (zoom onChange / withAnimation), where an immediate makeFirstResponder can be
    /// dropped or beaten by the in-flight view churn. After the turn, ours is the last word.
    /// Which port's surface has the keyboard right now, if any. Used to put the voice indicator on the
    /// port being dictated into rather than in the middle of the desktop: the shell draws it, but it
    /// belongs over the thing that is about to receive the words.
    public func portHoldingKeyboard() -> String? {
        guard let responder = NSApp?.keyWindow?.firstResponder as? NSView else { return nil }
        for panel in panels {
            guard let host = hostView(for: panel.id) else { continue }
            if responder === host || responder.isDescendant(of: host) { return panel.id }
        }
        return nil
    }

    public func focusKeyboard(on id: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let v = self.hostView(for: id), let win = v.window {
                win.makeFirstResponder(v)
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
    /// L2.d.2 input taps, kept alive for WKWebView message routing (like the console/height ones).
    private var inputHandlers: [String: PortInputHandler] = [:]

    /// Navigation delegates kept alive for WKWebView.
    private var navDelegates: [String: PortNavigationBlocker] = [:]
    /// I2 · C3: one per browser port, watching `url` so every navigation counts (not just the
    /// address bar). Retained here for the port's lifetime; freed in `destroyWebView`.
    private var browserURLObservers: [String: PortBrowserURLObserver] = [:]
    /// A browser port's page title, address and loading, for its card (docs/plan-port-state-v1.md).
    private var browserFactsObservers: [String: PortBrowserFactsObserver] = [:]
    /// A browser port's window-level delegate: popups, window.close, a page's alert/confirm/prompt, file
    /// inputs (docs/plan-browser-use.md, Phase 1). Retained here; WebKit holds its UI delegate weakly.
    private var browserUIs: [String: PortBrowserUI] = [:]
    /// A popup follows links freely, as the browser port does.
    private let popupNavigation = PortBrowserNavigation()
    /// The popup a browser port's page opened (an OAuth sign-in, a payment), drawn over the port. One at
    /// a time: a second replaces the first, as a page opening its sign-in again expects.
    @Published public private(set) var browserPopups: [String: WKWebView] = [:]

    /// Where a port that is not on screen is drawn while a companion looks at it or acts on it (browser
    /// use): a window far off every display that never takes a click or the keyboard. Input and a
    /// snapshot need the page to be in a window; this lets a running port, or one on another space's
    /// desktop, be worked on out of sight (Gordon, 2026-09-30). A paused port is not.
    private lazy var offscreenHost: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 900),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = true
        w.hasShadow = false
        return w
    }()

    /// Draw a port's page off screen for a companion, at its tile size. Returns whether it was moved
    /// there, so the caller puts it back.
    @discardableResult
    func hostOffscreen(_ id: String) -> Bool {
        guard let wv = webViews[id], wv.window == nil, let panel = panels.first(where: { $0.id == id }) else { return false }
        wv.removeFromSuperview()
        wv.frame = CGRect(origin: .zero, size: panel.size)
        offscreenHost.setContentSize(panel.size)
        offscreenHost.contentView?.addSubview(wv)
        if !offscreenHost.isVisible { offscreenHost.orderBack(nil) }
        return true
    }

    /// Take a page back out of the off-screen window once the companion is done with it.
    func releaseOffscreen(_ id: String) {
        guard let wv = webViews[id], wv.window === offscreenHost else { return }
        wv.removeFromSuperview()
        if offscreenHost.contentView?.subviews.isEmpty ?? true { offscreenHost.orderOut(nil) }
    }

    /// Close a browser port's popup, from its close button.
    public func closeBrowserPopup(port id: String) {
        guard let popup = browserPopups.removeValue(forKey: id) else { return }
        popup.stopLoading()
        popup.removeFromSuperview()
    }

    /// HIDDEN ports (nautilus Phase 3.2): running, persisted, with their chat and subscriptions, and
    /// on no desktop and in no rail. Stored as `isBackground` (the old "docked"). A person finds them
    /// in ⌘K and in the chrome's hidden count, so nothing runs where they cannot see it.
    public var hiddenPanels: [PortPanel] {
        panels.filter { $0.isBackground }
    }

    /// The hidden (running) ports that belong to a space, in the order the rail shows them: by their slot
    /// (`railOrder`, shared with paused ports, since a port is never both), unslotted ones after.
    public func hiddenPanels(in spaceId: String?) -> [PortPanel] {
        hiddenPanels.filter { $0.spaceId == spaceId }
            .enumerated()
            .sorted { ($0.element.railOrder ?? Int.max, $0.offset) < ($1.element.railOrder ?? Int.max, $1.offset) }
            .map(\.element)
    }

    /// Put a port in the presentation it was created with ("tiled" is where it already is).
    func applyPresentation(_ presentation: String?, to idOrUdid: String) {
        guard let id = panels.first(where: { $0.id == idOrUdid || $0.udid == idOrUdid })?.id else { return }
        switch presentation {
        case "paused", "parked": park(id: id)
        case "running", "hidden": minimize(id)
        default: break
        }
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
            for row in saved { restorePanel(from: row, appState: appState) }
            if !saved.isEmpty {
                p42log("[Port42] Restored %d port panels from database", saved.count)
            }
        } catch {
            p42log("[Port42] Failed to restore port panels: %@", error.localizedDescription)
        }
    }

    /// Bring one saved port back as a live panel: its bridge (with its grants), geometry, layout and
    /// surface. Used at launch for every open port, and by `reopen` for a closed one.
    private func restorePanel(from row: PersistedPortPanel, appState: AnyObject) {
            // I1.4: `row.id` carries the chat port's identity back across a launch. Without it a
            // restored bridge with no creator and no message id would fall to a heap address
            // again, which is exactly the case where a persisted grant needs to be found.
            let bridge = PortBridge(appState: appState, spaceId: row.spaceId, messageId: row.messageId,
                                    createdBy: row.createdBy, stableIdentity: row.id)
            // `row.grantedPermissions` is NOT restored (APP-06). It was a snapshot of the
            // creator's grants, so it brought a revoked grant back with the port at launch.
            // The port's principal is asked live instead; the column is left unread.
            // NAU-02: code written from another machine stays not-the-creator's after a restart.
            // With no restored grants there is nothing for it to clear: it changes who the port
            // authorizes as, and that identity's live grants are what every call is judged on.
            if let who = row.codeChangedBy { bridge.codeChangedBy = who }
            // Per-desktop positions (v46). `positions` is the authority; posX/posY is the
            // home-space projection a pre-v46 row carries, and the fallback when the JSON is
            // missing or unreadable — a restore must never silently unplace a layout.
            var restoredPositions: [String: CGPoint] = [:]
            if let json = row.positions, let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Double]] {
                for (space, p) in obj {
                    if let x = p["x"], let y = p["y"] { restoredPositions[space] = CGPoint(x: x, y: y) }
                }
            }
            if restoredPositions.isEmpty, let x = row.posX, let y = row.posY {
                restoredPositions[row.spaceId ?? PortPanel.homelessKey] = CGPoint(x: x, y: y)
            }
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
                positions: restoredPositions,
                isAlwaysOnTop: row.isAlwaysOnTop,
                isBackground: row.isBackground,
                portType: row.portType
            )
            // SHELL S3 — restore the shell desktop layout: presentation ("tiled"/"parked"/
            // "floating") and z-order. Without this a tiled port restored as "floating" and
            // fell out of the desktop render (which filters presentation == "tiled").
            panel.presentation = row.presentation
            panel.z = row.z
            panel.railOrder = row.dockOrder
            // Phase 3 — restore adoption (kept peeks survive a restart on their adopters).
            panel.pinnedEverywhere = row.pinnedEverywhere
            if let adoptedStr = row.adoptedSpaceIds,
               let data = adoptedStr.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                panel.adoptedSpaceIds = arr
            }
            panels.append(panel)
            // Terminal ports host a Ghostty surface; only web ports get a WKWebView.
            if panel.portType != "terminal" {
                createPortWebView(for: panel)
            } else if panel.portType == "terminal" {
                // A terminal was on a desktop at shutdown — rebuild its controller + hoisted
                // Ghostty surface now so its tile has a live shell to host again. The process
                // itself is gone across a restart, so this relaunches the startup command.
                rebuildTiledTerminal(panel, app: appState)
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
        // Resume is handled by the shim: it injects --resume <id> when this port's deterministic
        // session transcript already exists (else --session-id <id>), so the restored terminal
        // reconnects to its own conversation without --continue (which would conflict with the
        // pinned id and could resume a sibling session). See docs/plan-companion-cwd.md.
        appState.buildTerminalSurface(for: panel, config: config)
    }

    /// Rewrite a terminal port's stored startup command, which is what a restore runs, and save it.
    public func rewriteTerminalStartup(id: String, _ transform: (String) -> String) {
        guard let idx = panels.firstIndex(where: { $0.id == id }),
              var config = panels[idx].terminalConfig else { return }
        let next = transform(config.startupCommand)
        guard next != config.startupCommand else { return }
        config.startupCommand = next
        guard let json = try? String(decoding: JSONEncoder().encode(config), as: UTF8.self) else { return }
        panels[idx].html = json
        persistPanel(id)
    }

    /// Forget a terminal's prefilled first line once it has been sent, so no later launch types it
    /// again. It is a first-run greeting ("hey, i'm gordon. what is this place?") or a brief an agent
    /// left waiting; kept in the saved config, it was typed into every relaunch (2026-09-28).
    public func clearTerminalInitialInput(id: String) {
        guard let idx = panels.firstIndex(where: { $0.id == id }),
              var config = panels[idx].terminalConfig, !config.initialInput.isEmpty else { return }
        config.initialInput = ""
        guard let json = try? String(decoding: JSONEncoder().encode(config), as: UTF8.self) else { return }
        panels[idx].html = json
        persistPanel(id)
    }

    /// Persist a panel to the database and snapshot a version.
    private func persistPanel(_ id: String) {
        guard let db = db, let panel = panels.first(where: { $0.id == id }) else { return }
        do {
            let record = PersistedPortPanel(from: panel)
            try db.savePortPanel(record)
            try db.savePortVersion(portUdid: panel.udid, html: panel.html, createdBy: panel.createdBy)
        } catch {
            p42log("[Port42] Failed to persist port panel: %@", error.localizedDescription)
        }
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
            userTitle: title, size: size ?? ShellPlacement.defaultTileSize)
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
            userTitle: title, size: size ?? ShellPlacement.defaultTileSize)
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
            userTitle: title, size: size ?? ShellPlacement.defaultTileSize)
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

    /// Park a tiled port into the right-edge rail (minimize to a chip). Same webview, no reload —
    /// the parked port is excluded from the desktop render and from `arrange`/`exposé`.
    /// `slot` places it in the rail (0 = top); nil puts it at the bottom.
    public func park(id: String, at slot: Int? = nil) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        let rail = railIds(in: panels[idx].spaceId).filter { $0 != id }
        panels[idx].presentation = "parked"
        panels[idx].bridge.suspendAI()      // stop any in-flight generation the moment it's parked
        renumberRail(Self.railInserting(id, into: rail, at: slot))
    }

    /// Restore a parked port back onto the desktop as a tile (no reload). The rail closes the gap.
    public func unpark(id: String) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        panels[idx].presentation = "tiled"
        panels[idx].railOrder = nil
        persistPanel(id)
        renumberRail(railIds(in: panels[idx].spaceId))
    }

    /// Move a parked port to another slot in its rail.
    public func moveInRail(id: String, to slot: Int) {
        guard let p = panels.first(where: { $0.id == id }), p.presentation == "parked" else { return }
        let rail = railIds(in: p.spaceId).filter { $0 != id }
        renumberRail(Self.railInserting(id, into: rail, at: slot))
    }

    /// The parked ports of a space, top to bottom: by rail order, then by when they were made.
    public func railIds(in spaceId: String?) -> [String] {
        panels.enumerated()
            .filter { $0.element.spaceId == spaceId && $0.element.presentation == "parked" }
            .sorted { ($0.element.railOrder ?? Int.max, $0.offset) < ($1.element.railOrder ?? Int.max, $1.offset) }
            .map(\.element.id)
    }

    /// `ids` with `id` inserted at `slot` (clamped; nil = the end). Pure.
    nonisolated public static func railInserting(_ id: String, into ids: [String], at slot: Int?) -> [String] {
        var out = ids.filter { $0 != id }
        out.insert(id, at: min(max(0, slot ?? out.count), out.count))
        return out
    }

    /// Write 0…n-1 as the rail order of `ids` and persist them.
    private func renumberRail(_ ids: [String]) {
        for (n, id) in ids.enumerated() {
            guard let idx = panels.firstIndex(where: { $0.id == id }) else { continue }
            panels[idx].railOrder = n
            persistPanel(id)
        }
    }

    /// Move a port to a presentation (tiled / background) — a POSITION change only; the render layer
    /// re-parents the hoisted view, never remakes it (unlike a fresh mount, so a shader keeps running).
    /// Unlike `park`, this never suspends the AI: a full-bleed background port stays live. Persists.
    public func setPresentation(id: String, to presentation: String) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        panels[idx].presentation = presentation
        persistPanel(id)
    }

    /// Persist a tile's new geometry after a drag/resize ends, or after placement (hand positions
    /// survive restart). `on` names the DESKTOP the geometry belongs to: the same port can be on two
    /// desktops, and a position chosen on one must not move it on the other. nil = its home space.
    public func updateTileFrame(id: String, position: CGPoint, size: CGSize? = nil, on spaceId: String? = nil) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        panels[idx].setPosition(position, on: spaceId)
        if let size { panels[idx].size = size }
        persistPanel(id)
    }

    /// Pin a port in its space, in every space, or neither (GM, 2026-09-27), then persist.
    public func setPin(id: String, _ pin: PortPin) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        panels[idx].isAlwaysOnTop = pin != .none
        panels[idx].pinnedEverywhere = pin == .everywhere
        persistPanel(id)
    }

    /// Stamp a tiled port frontmost (monotonic z from `ShellState.nextZ()`), then persist.
    public func setZ(id: String, z: Int) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        panels[idx].z = z
        persistPanel(id)
    }

    /// Close a panel by ID.
    public func close(_ id: String) {
        if let panel = panels.first(where: { $0.id == id }) {
            // Release every ongoing resource this port acquired (mic, camera, screen, speech,
            // playback, browser sessions, in-flight generation) BEFORE the webview goes — the
            // close-path teardown for the leak (backlog 0.5).
            panel.bridge.releaseAcquisitions()
            destroyWebView(id)
        }
        // The port is gone, so presence on it is meaningless: drop it (a close, not a release, so
        // no holder check, because the thing being held no longer exists). Without this a
        // closed-and-reopened id could inherit a stale driver.
        //
        // I2 · C2.1 — through the seam's door. `portClosed` forgets presence and the throttle and
        // deliberately NOT the token: the two have opposite lifecycles, and a counter that rewinds
        // would let a token minted against this dead port pass CAS against a live one that reused
        // the id (Spike A, correction 4).
        //
        // BOTH ids, because a panel is addressed by `id` and by `udid` and this close path can be
        // reached with either. Forgetting one and not the other leaves half a stale driver.
        if let panel = panels.first(where: { $0.id == id }) {
            appState?.portInput.portClosed(panel.udid)
        }
        appState?.portInput.portClosed(id)
        appState?.teardownTerminalController(panelId: id)
        // Tear down a hoisted terminal surface (shell tile path). The floating path frees via
        // dismantleNSView; the detached view isn't SwiftUI-managed, so free it explicitly here.
        terminalCoordinators.removeValue(forKey: id)?.teardown()
        terminalViews[id]?.removeFromSuperview()
        terminalViews.removeValue(forKey: id)
        appState?.portStates.forget(port: id)
        // Closing ARCHIVES (nautilus Phase 2 step 2, GM: "we should never close them"): the row
        // stays, marked closed, with its latest state, so `reopen` brings back the same port with
        // the same id. A terminal keeps its live cwd for that. Only `deleteForever` removes it.
        if panels.contains(where: { $0.id == id }) {
            persistPanel(id)
            try? db?.setPortClosed(id: id, at: Date())
        }
        Analytics.shared.portClosed()
        panels.removeAll { $0.id == id }
    }

    /// Reopen a closed port with its id, content, position and chat. A terminal relaunches its
    /// command in its last cwd. Returns false if there is no closed port by that id.
    @discardableResult
    public func reopen(_ idOrUdid: String) -> Bool {
        guard let db, let appState, let id = closedPortId(idOrUdid),
              !panels.contains(where: { $0.id == id }),
              let row = try? db.fetchPortPanel(id: id) else { return false }
        try? db.setPortClosed(id: id, at: nil)
        restorePanel(from: row, appState: appState)
        p42log("[Port42] Reopened port %@", id)
        return true
    }

    /// The closed ports, most recently closed first.
    public func closedPorts() -> [PersistedPortPanel] {
        (try? db?.fetchClosedPortPanels()) ?? []
    }

    /// A closed port's row id, given either of its ids (a caller may hold the udid `ports.list` shows).
    public func closedPortId(_ idOrUdid: String) -> String? {
        closedPorts().first { $0.id == idOrUdid || $0.udid == idOrUdid }?.id
    }

    /// Delete a port for good: close it if open, then remove its record, versions and chat.
    public func deleteForever(_ id: String) {
        if panels.contains(where: { $0.id == id }) { close(id) }
        guard let row = try? db?.fetchPortPanel(id: id) else { return }
        TerminalSessionBootstrap.clearLiveCwd(portId: id)
        try? db?.deletePortForever(id: id, udid: row.udid ?? id)
        appState?.companionWatches.removeAll(portUdid: row.udid ?? id)
        p42log("[Port42] Deleted port %@ for good", id)
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
    ///
    /// Returns whether it found one. It used to return Void, so `port.rename` against a port that
    /// does not exist answered `{"ok": true}` — measured 2026-07-28 while checking error codes. That
    /// is worse than a missing code: a caller is told its write landed when nothing happened, and no
    /// retry or correction is possible because nothing looks wrong.
    @discardableResult
    public func renamePort(id: String, title: String) -> Bool {
        guard let idx = panels.firstIndex(where: { $0.udid == id || $0.id == id }) else { return false }
        panels[idx].userTitle = title
        persistPanel(panels[idx].id)
        return true
    }

    /// Set stored capabilities for a floating panel by UDID.
    public func setCapabilities(id: String, capabilities: [String]) {
        guard let idx = panels.firstIndex(where: { $0.udid == id || $0.id == id }) else { return }
        panels[idx].storedCapabilities = capabilities
        persistPanel(panels[idx].id)
    }

    /// Hide a port (off the desktop and out of the rail, still running). The unit unmounts; the live
    /// view stays in the registry and remounts (repainting) on restore, which shows it again.
    public func minimize(_ id: String, at slot: Int? = nil) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        // Its place among the running cards: where it was dropped, else last (GM, 2026-09-29).
        let running = hiddenPanels(in: panels[idx].spaceId).map(\.id).filter { $0 != id }
        panels[idx].isBackground = true
        renumberRail(Self.railInserting(id, into: running, at: slot))
        if let wv = webViews[id] { PortWebViewFactory.setUnseenTimerThrottling(false, on: wv) }
        panels[idx].bridge.suspendAI()      // backgrounded = off-screen: stop billing the model
        persistPanel(id)
        p42log("[Port42] Port minimized to background: %@", panels[idx].title)
    }

    /// Restore a background port to the desktop. Returns false if the port is not backgrounded.
    @discardableResult
    public func restore(_ id: String) -> Bool {
        guard let idx = panels.firstIndex(where: { $0.id == id }), panels[idx].isBackground else { return false }
        panels[idx].isBackground = false
        panels[idx].railOrder = nil
        renumberRail(hiddenPanels(in: panels[idx].spaceId).map(\.id))
        if let wv = webViews[id] { PortWebViewFactory.setUnseenTimerThrottling(true, on: wv) }
        persistPanel(id)
        p42log("[Port42] Port restored from background: %@", panels[idx].title)
        return true
    }

    /// Stop a port by destroying its webview.
    public func stop(_ id: String) {
        guard let panel = panels.first(where: { $0.id == id }) else { return }
        // Same close-path teardown as close(): release what the port acquired before the webview
        // goes, so a stopped port cannot keep the mic (etc.) running (backlog 0.5).
        panel.bridge.releaseAcquisitions()
        destroyWebView(id)
        p42log("[Port42] Port stopped: %@", panel.title)
    }

    /// Restart a port by reloading its content. Web ports reload the WKWebView; native
    /// terminal ports rebuild the Ghostty surface via a fresh controller.
    public func restart(_ id: String) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        if panels[idx].portType == "terminal" {
            // I2 · C0: this called `makeTerminalController` alone, which is ONE of the five steps
            // that build a terminal surface. It tore the old controller down, made a new one, and
            // never built or bound a surface for it, so the comment above was false and a restarted
            // terminal would have had a controller wired to nothing. It has no callers today, so it
            // was a trap rather than a live defect. Routing it through the factory fixes it.
            if let panel = panels[idx].terminalConfig {
                appState?.buildTerminalSurface(for: panels[idx], config: panel)
            }
        } else {
            destroyWebView(id)
            createPortWebView(for: panels[idx])
        }
        p42log("[Port42] Port restarted: %@", panels[idx].title)
    }

    /// Wait until a port's document has actually loaded, or give up after `timeout`.
    ///
    /// **MEASURED 2026-07-27: `port.create` returned 0.24s before the document existed.** A caller
    /// that created a port and immediately ran `port.exec` against its DOM got `null` — the manual
    /// teaches create-then-write, so a generated port reading its own DOM straight after creating it
    /// silently found nothing. `port.patch` and `port.update` have the same gap, since each replaces
    /// the document and answers before the reload lands.
    ///
    /// Same defect class as the two already fixed today: the response describing a state the effect
    /// has not reached yet. The write's token was the first, the deferred terminal Enter the second.
    ///
    /// Waits on `didFinish` rather than polling `document.readyState`, because that is the real
    /// signal and this codebase has been burned by timers standing in for one. A FAILED load settles
    /// it too: a caller must be released either way, or a bad document hangs the write that made it.
    ///
    /// The timeout is a backstop, not the mechanism. If it ever fires, the caller gets the same
    /// behaviour it had before this existed, which is the honest failure mode.
    @MainActor
    func awaitDocument(_ id: String, timeout: TimeInterval = 3.0) async {
        guard let delegate = navDelegates[id], let wv = webViews[id] else { return }
        // Already loaded and idle: nothing to wait for. Without this, a write to a settled port
        // would wait the full timeout for a `didFinish` that already happened.
        if !wv.isLoading { return }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var resumed = false
            let finish = {
                guard !resumed else { return }        // didFinish + the timeout can both arrive
                resumed = true
                delegate.onDocumentSettled = nil
                cont.resume()
            }
            delegate.onDocumentSettled = finish
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish() }
        }
    }

    /// Reload a registered port's original HTML into the SAME webview (restart-in-place — resets
    /// DOM/JS, re-runs scripts). Unlike `restart`, it does NOT destroy/recreate the webview, so an
    /// inline host showing `webViews[id]` keeps its adopted view (no re-parent needed).
    public func reloadPort(_ id: String) {
        guard let panel = panels.first(where: { $0.id == id }), let wv = webViews[id] else { return }
        let document = PortWebViewFactory.wrapHTML(panel.html)
        wv.loadHTMLString(document, baseURL: URL(string: "http://port42.local/"))
        p42log("[Port42] Port reloaded in place: %@", panel.title)
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
    ///
    /// The UI path (a click in the version list), so it does not await the reload: nobody is holding
    /// a token or about to read the DOM, and blocking a menu action on a load would only make the
    /// click feel slow. The BRIDGE path awaits, because there a caller is answered.
    public func restoreVersion(_ id: String, version: Int) {
        guard let panel = panels.first(where: { $0.id == id }),
              let db = db,
              let html = try? db.fetchPortVersionHtml(udid: panel.udid, version: version) else { return }
        Task { @MainActor in
            await updatePort(idOrTitle: panel.udid, html: html, skipVersionSnapshot: true)
            p42log("[Port42] Port restored to v%d: %@", version, panel.title)
        }
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
    ///
    /// **ASYNC because it AWAITS the reload it triggers.** Replacing the HTML reloads the document,
    /// and this used to answer while that was still in flight: a caller that patched a port and then
    /// read its DOM got the old document or a null. Measured on `create` at 0.24s; `update`,
    /// `patch` and `restore` all share the gap because all three come through here.
    ///
    /// Awaited HERE rather than at the three call sites, for the same reason the token bump lives at
    /// the surface: a fourth document-replacing verb added tomorrow inherits the wait instead of
    /// depending on its author having remembered.
    @discardableResult
    public func updatePort(idOrTitle: String, html: String,
                           skipVersionSnapshot: Bool = false) async -> PortLiveUpdate.Outcome? {
        guard let idx = panels.firstIndex(where: { $0.udid == idOrTitle }) ??
              panels.firstIndex(where: {
                  let l = idOrTitle.lowercased()
                  return $0.title.lowercased() == l || $0.title.lowercased().contains(l)
              }) else {
            return nil
        }

        let panelId = panels[idx].id
        let newTitle = PortPanel.extractTitle(from: html)
        let old = panels[idx].html
        let plan = PortLiveUpdate.plan(old: old, new: html)
        if plan == .unchanged { return .unchanged }   // nothing to show, store or version
        panels[idx].html = html

        // NOT EVERY WRITE RELOADS (GM, 2026-09-26). A reload throws away the page's live state: a
        // paused animation, a drawn canvas, a half-filled form. So a write replaces the document
        // only when nothing less will do: a change confined to <style> is applied in place, and
        // any other change is first offered to the page, which may apply it itself.
        var outcome = PortLiveUpdate.Outcome.reloaded
        if let webView = webViews[panelId] {
            if !webView.isLoading, await applyLive(plan, html: html, to: webView) {
                outcome = plan == .offer ? .handledByPage : .styles
                p42log("[Port42] Port updated live (%@): %@ (%@)", outcome.rawValue, newTitle, panelId)
            } else {
                webView.loadHTMLString(PortWebViewFactory.wrapHTML(html), baseURL: URL(string: "http://port42.local/"))
                p42log("[Port42] Port updated (webview reloaded): %@ (%@)", newTitle, panelId)
            }
        } else {
            p42log("[Port42] Port updated (stored, no webview): %@ (%@)", newTitle, panelId)
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

        // The document is being replaced right now. Answering before it lands is what made
        // patch-then-read return the OLD document.
        if outcome == .reloaded { await awaitDocument(panelId) }
        return outcome
    }

    /// Apply a planned update inside the running page. False means it could not be applied there
    /// and the caller reloads, so a page that does not match what was planned is never half-updated.
    private func applyLive(_ plan: PortLiveUpdate.Plan, html: String, to webView: WKWebView) async -> Bool {
        let result: Any?
        switch plan {
        case .unchanged:
            return true
        case .styles(let css):
            result = try? await webView.callAsyncJavaScript(PortLiveUpdate.stylesJS, arguments: ["css": css],
                                                            in: nil, contentWorld: .page)
        case .offer:
            result = try? await webView.callAsyncJavaScript(PortLiveUpdate.offerJS, arguments: ["html": html],
                                                            in: nil, contentWorld: .page)
        }
        return (result as? Bool) == true
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

    /// Current frame of a port's tile on one desktop (nil if it has no committed position there).
    public func portFrame(by id: String, on spaceId: String? = nil) -> CGRect? {
        guard let panel = findPort(by: id), let pos = panel.position(on: spaceId) else { return nil }
        return CGRect(origin: pos, size: panel.size)
    }

    /// Move a port's tile to the given desktop coordinates.
    public func movePort(id: String, x: CGFloat, y: CGFloat, on spaceId: String? = nil) {
        guard let panel = findPort(by: id) else { return }
        if let idx = panels.firstIndex(where: { $0.id == panel.id }) {
            panels[idx].setPosition(CGPoint(x: x, y: y), on: spaceId)
            persistPanel(panel.id)
        }
    }

    // MARK: - WebView Lifecycle

    /// Create and configure a WKWebView for a panel. Called once per pop-out.
    private func createPortWebView(for panel: PortPanel) {
        let config = PortWebViewFactory.configuration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        // P0 hardening: a browser port shows a foreign site, so it gets no bridge namespace and no
        // bridge handler at all. See PortBridge.attach. (Declared here because the console and
        // height handlers below need the same answer.)
        let foreignSite = panel.portType == "browser"
        panel.bridge.attach(to: config, foreignSite: foreignSite)

        // Console forwarding script
        let consoleScript = WKUserScript(
            source: PortWebViewFactory.consoleJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        let handler = PortConsoleHandler()
        // Capture the ID, NOT `panel`: referencing `panel.id` inside the closure captures the whole
        // struct, and a PortPanel holds its PortBridge — so this closure transitively pinned the
        // bridge for as long as the handler lived (half of the teardown leak below).
        let portId = panel.id
        // The console is filed under the key a READER resolves to, which is not the panel id.
        let consoleKey = PortConsole.key(udid: panel.udid, id: panel.id, messageId: panel.messageId)
        handler.onConsole = { [weak appState] level, msg in
            // Phase L1: a web port's console output → Notify bus (a third producer, after push + terminal).
            appState?.notifyBus.publish(topic: PortNotify.topic(forPortKey: portId),
                                        kind: PortEventKind.console.wire,
                                        payload: .object(["level": .string(level),
                                                          "message": .string(msg)]))
            // RETAIN it too. Publishing reaches whoever was already subscribed; the buffer answers
            // the far more common case, which is someone asking AFTER the thing went wrong. An agent
            // that generated a port does not know to subscribe before the port throws.
            PortConsole.shared.append(portId: consoleKey, level: level, text: msg)
        }
        // Same reasoning as the bridge: on a foreign site this handler is reachable by the site's
        // scripts and already refuses everything via the origin pin. Not attaching it is the same
        // outcome with nothing to regress. (A browser port therefore has no console capture — it had
        // none before either, for the same reason.)
        if !foreignSite {
            config.userContentController.addUserScript(consoleScript)
            config.userContentController.add(handler, name: "portConsole")
            consoleHandlers[panel.id] = handler
        }

        // Viewport tracking script (fires resize events for terminal reflow etc.). Not injected into
        // a foreign site: it exists so a PORT can reflow its own content, and a browser tile is
        // sized by the tile, not by the page.
        if !foreignSite {
            let viewportScript = WKUserScript(
                source: PortWebViewFactory.viewportJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(viewportScript)
        }

        // Step 8: inline height reporting — lets a registry-owned port auto-size when presented
        // inline. Harmless for floating ports (the window drives their size).
        //
        // The third page-world handler, gated for the same reason as the bridge and the console: on
        // a foreign site it already refuses everything via the origin pin, so not attaching it is the
        // same outcome with nothing left to regress. A browser port is never inline anyway.
        let heightHandler = PortHeightHandler(manager: self, portId: panel.id)
        if !foreignSite {
            let heightScript = WKUserScript(
                source: PortWebViewFactory.heightJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(heightScript)
            config.userContentController.add(heightHandler, name: "portHeight")
        }
        heightHandlers[panel.id] = heightHandler

        // RIGHT-OF-WAY (L2.d.2): the human typing or clicking INSIDE a web port is driving it, and
        // none of that reaches the bridge. Reported the same way console and height already are.
        // keydown + pointerdown only: hover is not driving, and scroll is READING — claiming on a
        // scroll would block a companion mid-write exactly while the user watches it work.
        let inputScript = WKUserScript(
            source: """
            (function() {
              var send = function(e) {
                // TRUSTED EVENTS ONLY. A synthetic event — one the port dispatched itself — has
                // isTrusted === false. Without this check a port claims the pen by simulating
                // input: caught live on the onboarding shader, which fires its own pointer events
                // and so held the human's lease forever, locking companions out of a port nobody
                // was touching. It is also the abuse case: a port could impersonate the user to
                // seize right-of-way. Only what the human actually did counts as driving.
                if (!e || e.isTrusted !== true) return;
                try { window.webkit.messageHandlers.portInput.postMessage(1); } catch (err) {}
              };
              window.addEventListener('keydown', send, true);
              window.addEventListener('pointerdown', send, true);
              // `beforeinput` is the third, and it is the one that makes this HONEST (Spike C,
              // measured live 2026-07-26). keydown+pointerdown saw 8 of 11 real content changes.
              // The three it missed were not exotic: DICTATION and IME arrive as composition
              // events, and CONTEXT-MENU PASTE arrives as a paste event — none of them involve a
              // key or a pointer, so the port changed and Port42 had no idea. That is presence
              // lying AND the activity token standing still while the document moves under it.
              //
              // `beforeinput` fired on all 11, seen and missed alike, so one event name covers
              // what two were failing to. It does not REPLACE them: it only fires for editable
              // content, and a canvas/game/shader port is driven by pointers with nothing
              // editable in sight. Three narrow signals, not one clever one.
              window.addEventListener('beforeinput', send, true);
            })();
            """,
            injectionTime: .atDocumentStart, forMainFrameOnly: true)

        // WHICH WORLD THIS LISTENER LIVES IN: an ISOLATED one, for every port type (R7).
        //
        // It used to differ. A browser port ran isolated (C6) because it is a foreign site by
        // construction, and a web port stayed in the PAGE world on the reasoning that its document
        // is served from `port42.local` and its own JS is the legitimate caller of the bridge, with
        // the origin pin making that sound.
        //
        // **MEASURED 2026-07-27, and the reasoning did not survive.** A web port's own JS could
        // simply CALL the handler: `window.webkit.messageHandlers.portInput.postMessage(1)` bumped
        // the port's token and named the human as its driver, with no event involved at all. The
        // origin pin passes, because the origin is genuinely `port42.local` — the caller is the
        // port itself. There was precedent nobody connected: the onboarding shader fired its own
        // pointer events and held the human's presence forever, and the `isTrusted` guard added
        // then only closed the event path, not the door beside it.
        //
        // R7 was planned as "move the human's claim off page-reported `isTrusted`, which a page can
        // shadow". **That threat is not real in WebKit**, measured three ways: shadowing
        // `Event.prototype.isTrusted` changes nothing (WebKit defines `isTrusted` as an OWN property
        // on each event instance), and redefining it on the instance throws — it is non-configurable.
        // The fix is the same one, for the plainer reason: in an isolated world a page cannot SEE
        // the handler, so there is nothing to call and no origin to check.
        //
        // A user script in an isolated world still observes the page's DOM events, which is what
        // makes this cost nothing. Browser ports have run this way since C6.
        let world = WKContentWorld.world(name: "port42.input")
        let inputHandler = PortInputHandler(portUdid: panel.udid) { [weak appState] udid in
            appState?.humanInteracted(with: udid)
        }
        config.userContentController.addUserScript(
            WKUserScript(source: inputScript.source, injectionTime: .atDocumentStart,
                         forMainFrameOnly: true, in: world))
        config.userContentController.add(inputHandler, contentWorld: world, name: "portInput")
        inputHandlers[panel.id] = inputHandler

        // A browser port names Safari in its user agent, or Google's sign-in refuses it as an embedded view.
        if foreignSite { config.applicationNameForUserAgent = BrowserUserAgent.applicationName }
        let webView = FileDropWebView(frame: .zero, configuration: config)
        let isBrowser = panel.portType == "browser"
        // A browser follows links & shows the site's own background; a normal port is locked to its
        // document and drawn transparent over the shell.
        let navDelegate: PortNavigationBlocker = isBrowser ? PortBrowserNavigation() : PortNavigationBlocker()
        webView.navigationDelegate = navDelegate
        navDelegates[panel.id] = navDelegate
        webView.setValue(!isBrowser, forKey: "drawsBackground")
        webView.allowsMagnification = isBrowser
        if isBrowser {
            // I2 · C3 + C6. TWO signals, because neither covers the other: KVO on `url` catches an
            // SPA route change (pushState fires no load), and `didCommit` catches a reload (a load
            // with no URL change). C6 measured the gap: reload counted for nothing.
            let panelId = panel.id
            browserFactsObservers[panel.id] = PortBrowserFactsObserver(webView: webView) { [weak appState] facts in
                DispatchQueue.main.async { appState?.portStates.setBrowser(facts, port: panelId) }
            }
            browserURLObservers[panel.id] = PortBrowserURLObserver(
                webView: webView, portKey: panel.udid) { [weak appState] key, url in
                    appState?.browserNavigated(port: key, to: url)
                }
            (navDelegate as? PortBrowserNavigation)?.onCommitted = { [weak appState, weak webView] in
                guard let url = webView?.url else { return }
                appState?.browserNavigated(port: panel.udid, to: url)
            }
            // Popups (OAuth), window.close, and a page asking the person something.
            let ui = PortBrowserUI()
            ui.onPopup = { [weak self] popup in
                guard let self else { return }
                if let old = self.browserPopups[panelId], old !== popup { old.stopLoading(); old.removeFromSuperview() }
                popup.navigationDelegate = self.popupNavigation
                self.browserPopups[panelId] = popup
            }
            ui.onPopupClosed = { [weak self] closed in
                guard let self, self.browserPopups[panelId] === closed else { return }
                self.closeBrowserPopup(port: panelId)
            }
            webView.uiDelegate = ui
            browserUIs[panel.id] = ui
        }

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
        // A port restored hidden starts with its timers unclamped, as hiding it would have left them.
        if panel.isBackground { PortWebViewFactory.setUnseenTimerThrottling(false, on: webView) }
    }

    /// Clean up a webview and its associated handlers.
    private func destroyWebView(_ id: String) {
        if let wv = webViews[id] {
            // Break the retain cycle (backlog 0.5, the leak's root): WKUserContentController strongly
            // retains its script message handlers, and the "port42" handler IS the PortBridge. Nothing
            // else drops it, so after close the bridge stayed pinned, its deinit never fired, and the
            // deinit-driven device stops never ran. Remove the handler and the injected user scripts
            // so the bridge can dealloc and the deinit backstop can run on the non-close death paths.
            // restart re-runs attach, which re-adds both, so an in-place reload is unaffected.
            let ucc = wv.configuration.userContentController
            // ALL of them, not just "port42": the UCC strongly retains every handler it holds, and
            // "portConsole" / "portHeight" were never removed. The console handler's closure reached
            // the bridge, so the port42 removal alone could not free it while the webview lived (and
            // a WKWebView mid-load outlives its last strong reference).
            ucc.removeAllScriptMessageHandlers()
            ucc.removeAllUserScripts()
            wv.removeFromSuperview()
        }
        webViews.removeValue(forKey: id)
        consoleHandlers.removeValue(forKey: id)
        navDelegates.removeValue(forKey: id)
        closeBrowserPopup(port: id)
        browserUIs.removeValue(forKey: id)
        browserURLObservers.removeValue(forKey: id)
        browserFactsObservers.removeValue(forKey: id)
        heightHandlers.removeValue(forKey: id)
        inputHandlers.removeValue(forKey: id)
        inlineHeights.removeValue(forKey: id)
    }


    // MARK: - Space-Aware Port Visibility

    /// Switch to a new space (the shell desktop renders per-space from `panels`; there are no
    /// windows to hide or show). The space's chat is its own, opened from the top bar.
    public func switchToSpace(_ spaceId: String, spaceName: String) {
        activeSpaceId = spaceId
    }
}

// MARK: - WebView Factory

/// Shared utilities for creating port WKWebViews.
enum PortWebViewFactory {

    /// Wrap port HTML in a full document with theme and CSP. THE one wrapper — both the inline
    /// port view and the desktop tile factory load this document, so the CSP and theme can never
    /// drift between presentations (they once lived as two hand-synced copies). `overflow` is the
    /// single deliberate difference: tiles scroll ("auto"), inline ports self-size ("hidden").
    /// HIDDEN PORTS RUN THEIR TIMERS AT FULL RATE (Phase 3.0 and 3.2, GM 2026-09-26). WebKit clamps a
    /// page it considers unseen to one timer tick a second (measured: a 100 ms producer published
    /// 10/s on screen and 1/s off it). That suits a parked chart, whose drawing should stop, and not a
    /// hidden port, which exists to do background work. So a hidden port's page opts out of the timer
    /// clamp; animation frames still stop. The switch is WebKit's own preference, set only when the
    /// running WebKit has it, so a WebKit without it leaves the port throttled rather than crashing.
    /// Returns whether the preference was there to set.
    @discardableResult
    static func setUnseenTimerThrottling(_ enabled: Bool, on webView: WKWebView) -> Bool {
        let prefs = webView.configuration.preferences
        var applied = false
        for name in ["_setHiddenPageDOMTimerThrottlingEnabled:", "_setPageVisibilityBasedProcessSuppressionEnabled:"] {
            let sel = NSSelectorFromString(name)
            guard prefs.responds(to: sel) else { continue }
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(prefs.method(for: sel), to: Setter.self)(prefs, sel, enabled)
            applied = true
        }
        return applied
    }

    /// ONE WebKit process pool for every port and browser session (2026-09-26). A configuration
    /// with no pool makes its own, and making one sets up a whole WebKit process pool on the main
    /// thread, waiting on a system service as it does: with agents making ports and the system
    /// busy, Dev4's main thread sat in `WebProcessPool::platformInitialize` → `notify_get_state` and
    /// every call timed out (sampled). Each web view still gets its own content process, so a port
    /// that crashes cannot take another with it.
    @MainActor static let sharedProcessPool = WKProcessPool()

    /// A configuration on the shared pool. Every port web view starts from this.
    @MainActor static func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.processPool = sharedProcessPool
        return config
    }

    static func wrapHTML(_ body: String, overflow: String = "auto") -> String {
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
        // The port CSP is strict (default-src 'none'): a CDN script, a remote image, or any
        // fetch/XHR/WebSocket is blocked — and otherwise SILENTLY, so the author sees a blank
        // rectangle with no cause. Surface every violation, so the platform holds itself to the
        // rule it gives authors.
        document.addEventListener('securitypolicyviolation', function(e) {
            console.warn('[port42] Blocked by content security policy: ' + (e.effectiveDirective || e.violatedDirective) + ' -> ' + (e.blockedURI || '(inline)') + '. Ports are self-contained: inline your scripts/styles/assets (no CDN, no remote images), and use port42.rest.call for network. See ports-context.');
        });
        </script>
        <style data-port42>
            :root { --color-accent: #00ff41; }
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                background: #111;
                color: #e0e0e0;
                font-family: "SF Mono", "Fira Code", "Cascadia Code", monospace;
                font-size: 13px;
                line-height: 1.5;
                padding: 12px;
                overflow: \(overflow);
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
        // Forward the page's console to Port42, where the port's chrome shows it (its console
        // icon and panel). The page draws no console of its own (GM, 2026-09-25: the in-page ">"
        // toggle and drawer sat on top of the port's own UI).
        const orig = { log: console.log, error: console.error, warn: console.warn };
        // An Error's message and stack are not enumerable, so JSON.stringify(err) is "{}": a caught
        // error logged with console.error(err) reached Port42 as "{}", and an agent checking the
        // console could not tell what broke (a team run, 2026-09-26). Errors keep their stack, and an
        // object that cannot be stringified (a cycle) falls back to its String form.
        function fmt(a) {
            if (a instanceof Error) {
                const head = (a.name || 'Error') + ': ' + a.message;
                return a.stack ? (a.stack.indexOf(a.message) >= 0 ? a.stack : head + '\\n' + a.stack) : head;
            }
            if (a !== null && typeof a === 'object') {
                try { return JSON.stringify(a); } catch (_) { return String(a); }
            }
            return String(a);
        }
        function forward(level, args) {
            try {
                const msg = Array.from(args).map(fmt).join(' ');
                window.webkit.messageHandlers.portConsole.postMessage({ level: level, message: msg });
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
    /// Phase L1 / roadmap "inspect a port's console via the API": (level, message) → Notify publish.
    var onConsole: (@MainActor (String, String) -> Void)?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Origin-pinned like every other handler. Lower stakes than the bridge (a foreign page could
        // only forge log lines) but the same class of hole, and console output is republished on the
        // port's Notify topic — so an unpinned handler lets a foreign origin write into a stream
        // other ports and companions subscribe to as if it were the port speaking.
        guard PortBridge.isPortOrigin(message) else { return }
        if message.name == "portConsole",
           let body = message.body as? [String: Any],
           let level = body["level"] as? String,
           let msg = body["message"] as? String {
            p42log("[Port42:port:%@] %@", level, msg)
            let cb = onConsole
            Task { @MainActor in cb?(level, msg) }
        }
    }
}

// MARK: - Inline Height Handler (Step 8)

/// Receives `document.body.scrollHeight` from a registry-owned port webview and republishes it on
/// the manager (`inlineHeights[portId]`) so the SwiftUI inline host can size itself. Floating ports
/// ignore the value. Clamped to [40, 600] to match the legacy inline-port sizing.
/// L2.d.2: "the human just acted in this web port". Carries the port's udid so the lease keys on the
/// same id everything else does. Holds a closure, not the manager, so it cannot be a retain path
/// back into app state (the teardown leak that cost a morning).
final class PortInputHandler: NSObject, WKScriptMessageHandler {
    private let portUdid: String
    private let onInput: (String) -> Void

    init(portUdid: String, onInput: @escaping (String) -> Void) {
        self.portUdid = portUdid
        self.onInput = onInput
    }

    /// NO ORIGIN PIN, and its absence is the guarantee rather than a gap (R7).
    ///
    /// This handler used to carry one, because it was registered in the PAGE world for web ports and
    /// a page-world handler is callable by whatever scripts the document runs. A pin is the wrong
    /// tool for that: it asks WHICH SITE is calling, and the answer for a web port's own forged call
    /// is `port42.local`, which passes. Measured — a port called `postMessage` on this handler and
    /// bumped its own token while naming the human as the driver.
    ///
    /// Registered in an isolated `WKContentWorld` instead, for every port type, so the page cannot
    /// reach it at all. There is no foreign sender to exclude because there is no sender but our own
    /// injected listener. Keeping the pin as well would only add a check that can reject the one
    /// legitimate signal, which is exactly what C6 measured happening to every keystroke in a browser
    /// port before isolation.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "portInput" else { return }
        onInput(portUdid)
    }
}

final class PortHeightHandler: NSObject, WKScriptMessageHandler {
    weak var manager: PortWindowManager?
    let portId: String

    init(manager: PortWindowManager, portId: String) {
        self.manager = manager
        self.portId = portId
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard PortBridge.isPortOrigin(message) else { return }   // pinned like the rest
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

/// Keeps a normal web port on its OWN document. A port is one surface, not a browser.
///
/// SECURITY (fixed 2026-07-26). This previously read
/// `navigationType == .other ? .allow : .cancel`, which is the INVERSE of what its own comment
/// claimed. `.other` is what WebKit reports for SCRIPT-INITIATED navigation — precisely the hostile
/// case — while `.linkActivated`, a human clicking, was the case it cancelled. So the policy blocked
/// the user and permitted the page. Live-verified: a port ran `location.href = 'https://example.com'`,
/// the navigation succeeded, and the injected `window.port42` went with it.
///
/// The rule is now an ALLOWLIST OF DESTINATIONS, not a guess from the navigation type. Type-based
/// reasoning is what failed: there is no navigation type that means "safe". Where a navigation is
/// going is a fact; why it was started is an inference.
///
/// This is defence in depth, NOT the primary fix — `PortBridge.isPortOrigin` is, because it holds
/// even if something reaches a foreign document, and it covers browser ports, which must navigate.
class PortNavigationBlocker: NSObject, WKNavigationDelegate {
    /// The port's document finished loading. Fired for a load that SUCCEEDS or FAILS, because a
    /// caller waiting on "is it there yet" must be released either way — a failed load that never
    /// resolved would hang the write that triggered it.
    var onDocumentSettled: (() -> Void)?

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(Self.allows(navigationAction.request.url) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onDocumentSettled?() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onDocumentSettled?()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onDocumentSettled?()
    }

    /// A port may load its own document and nothing else. Pure, so the rule is testable without a
    /// webview — the old one never was, which is part of why it was wrong for so long.
    static func allows(_ url: URL?) -> Bool {
        guard let url else { return true }             // no URL to judge: not a destination change
        if url.absoluteString == "about:blank" { return true }
        return url.host == PortBridge.portOrigin
    }
}

/// A browser port must FOLLOW links (unlike a normal port, which is locked to its own document), so
/// allow every navigation. Subclass so it fits the existing `navDelegates` registry.
final class PortBrowserNavigation: PortNavigationBlocker {
    /// I2 · C6 — set alongside the URL observer, because neither signal covers the other.
    var onCommitted: (() -> Void)?

    override func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }

    /// A document was committed. Measured in C6: a RELOAD replaces the whole document while the URL
    /// stays identical, so KVO on `url` never fires and the reload did not count.
    ///
    /// Spike B concluded `didCommit` was "necessary but not sufficient" and C3 read that as a reason
    /// to use KVO INSTEAD. The measurement corrects the reading: necessary and not sufficient means
    /// use BOTH. KVO catches `pushState` (a URL change with no load); `didCommit` catches a reload
    /// (a load with no URL change). Neither is a superset.
    ///
    /// Double-counting a normal navigation, which fires both, is harmless: the token is a monotonic
    /// counter, not a change log, and only its movement carries meaning.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        onCommitted?()
    }

    /// A page that could not be reached says so, instead of leaving the port blank (GM, 2026-09-27: a
    /// browser port whose local server had stopped showed its chrome and nothing else). Shown under the
    /// failing URL, so the address bar still reads it and Return, or Retry, loads it again.
    override func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        super.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
        let e = error as NSError
        guard e.code != NSURLErrorCancelled else { return }       // a new navigation replaced this one
        let url = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
        webView.loadHTMLString(Self.errorPage(url: url, reason: e.localizedDescription), baseURL: url)
    }

    /// The error page, pure so it can be tested. Everything shown is escaped.
    static func errorPage(url: URL?, reason: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let where_ = esc(url.map { ($0.host ?? $0.absoluteString) + ($0.port.map { ":\($0)" } ?? "") } ?? "this page")
        let local = ["localhost", "127.0.0.1", "::1"].contains(url?.host ?? "")
        let hint = local ? "It is a server on this Mac. Start it again, then press Retry." : "Check the address and your connection, then press Retry."
        let target = esc(url?.absoluteString ?? "")
        return """
        <!doctype html><meta charset="utf-8"><body style="margin:0;height:100vh;display:flex;align-items:center;\
        justify-content:center;background:#0b0f0e;color:#e0e0e0;font:14px ui-monospace,Menlo,monospace">\
        <div style="max-width:32em;padding:24px"><div style="color:#00d4aa;font-weight:bold;margin-bottom:8px">\
        Can't reach \(where_)</div><div style="color:#888;margin-bottom:6px">\(esc(reason))</div>\
        <div style="color:#888;margin-bottom:16px">\(hint)</div>\
        <button onclick="location.href=this.dataset.u" data-u="\(target)" style="font:inherit;color:#0b0f0e;\
        background:#00d4aa;border:0;border-radius:5px;padding:6px 16px;cursor:pointer">Retry</button></div></body>
        """
    }
}

/// I2 · C3 — translator: a browser port went somewhere new.
///
/// **KVO on `url`, not `didCommit`, and Spike B is why.** `didCommit` is necessary but not
/// sufficient: `history.pushState` changes the URL with no document load, so no commit fires and
/// **every SPA route change is invisible**. Verified live in that spike. A single-page app is the
/// common case on the modern web, so committing-only would have counted the minority of navigations
/// and quietly missed the rest.
///
/// What this replaces: the ONLY existing hook was the tile's address bar (`onNavigate`), so typing a
/// URL counted and **back, forward, reload, clicking a link, and any script-initiated navigation did
/// not**. One of roughly six ways a browser port's content changes.
///
/// KNOWN LIMIT, stated because a token that overclaims is worse than one that admits its edge: this
/// sees URL changes, so a same-URL content change (a form POST re-render, an SPA that mutates the DOM
/// without touching the URL) still does not count. Spike B called browser CAS the weakest token and
/// this does not make it the strongest, it makes it honest about most navigations instead of one.
final class PortBrowserURLObserver: NSObject {
    private let portKey: String
    private let onNavigate: (String, URL) -> Void
    private var observation: NSKeyValueObservation?

    init(webView: WKWebView, portKey: String, onNavigate: @escaping (String, URL) -> Void) {
        self.portKey = portKey
        self.onNavigate = onNavigate
        super.init()
        // `.new` still fires for the FIRST set (nil to the start URL), so a browser port's creating
        // load counts as a navigation. Measured, not assumed: a freshly created browser port shows
        // seq=1. That is correct rather than incidental, since the port went from empty to showing a
        // document, which is a content change a stale write should be refused against.
        observation = webView.observe(\.url, options: [.new]) { [weak self] _, change in
            guard let self, let url = change.newValue ?? nil else { return }
            self.onNavigate(self.portKey, url)
        }
    }

    deinit { observation?.invalidate() }
}

/// What a browser port's card says about its page: title, address, and a bar while it loads. Observed,
/// never read from the page.
final class PortBrowserFactsObserver: NSObject {
    private var observations: [NSKeyValueObservation] = []

    init(webView: WKWebView, onChange: @escaping (BrowserFacts) -> Void) {
        super.init()
        let report: (WKWebView) -> Void = { wv in
            onChange(BrowserFacts(title: wv.title, url: wv.url, progress: wv.isLoading ? wv.estimatedProgress : nil))
        }
        observations = [
            webView.observe(\.title, options: [.initial, .new]) { wv, _ in report(wv) },
            webView.observe(\.url, options: [.new]) { wv, _ in report(wv) },
            webView.observe(\.estimatedProgress, options: [.new]) { wv, _ in report(wv) },
            webView.observe(\.isLoading, options: [.new]) { wv, _ in report(wv) },
        ]
    }

    deinit { observations.forEach { $0.invalidate() } }
}

// MARK: - Reusable WebView Host

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

// The second, DEAD permission overlay used to live here (`PortPermissionOverlay`). It had no call
// site: it was the pre-shell window mode's prompt and retired with that mode, while the live card
// is `ShellPermissionOverlay`. Deleted at slice-02 A.3 (touchpoint 2) — a second implementation of
// a consent prompt is exactly the kind of thing that gets edited by mistake and then believed.


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

