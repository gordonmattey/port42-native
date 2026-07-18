import Foundation
import AppKit
import WebKit

/// Executes tool calls from LLM companions against port42 bridge APIs.
/// One instance per conversation (space or swim space).
@MainActor
public final class ToolExecutor {
    private weak var appState: AppState?
    private let spaceId: String?
    let createdBy: String?
    /// Display name of the caller (for message attribution); nil for anonymous/remote callers.
    let createdByName: String?
    /// True when this executor runs an in-app companion composing a chat reply. Routes
    /// `port_create({type:"web"})` to an inline port; external/remote executors (inChat=false) open a
    /// desktop tile instead. See AppState.createPort.
    let inChat: Bool

    /// Granted permissions for this conversation (per-companion, per-space).
    private var grantedPermissions: Set<PortPermission> = []

    /// Pre-grant a permission without prompting the user (used by RemoteToolExecutor for "Always Allow" settings).
    func pregrant(_ perm: PortPermission) {
        grantedPermissions.insert(perm)
    }


    // Lazy bridge instances
    private lazy var clipboardBridge = ClipboardBridge()
    private lazy var screenBridge = ScreenBridge()
    private lazy var fileBridge = FileBridge()
    private lazy var automationBridge = AutomationBridge()
    private lazy var notificationBridge = NotificationBridge()
    private lazy var browserBridge = BrowserBridge()
    private lazy var audioBridge = AudioBridge()
    private lazy var cameraBridge = CameraBridge()

    init(appState: AppState, spaceId: String?, createdBy: String? = nil,
         createdByName: String? = nil, inChat: Bool = false) {
        self.appState = appState
        self.spaceId = spaceId
        self.createdBy = createdBy
        self.createdByName = createdByName
        self.inChat = inChat
        // Restore previously granted permissions so the user isn't re-prompted. spaceId nil = a
        // spaceless caller (the gateway) → its global grant, which never restored before.
        if let by = createdBy {
            self.grantedPermissions = appState.companionPermissions(createdBy: by, spaceId: spaceId)
        }
    }

    /// Resolve a port's WKWebView by ID — checks desktop/docked ports first, then inline ports.
    private func resolvePortWebView(id: String) -> WKWebView? {
        if let wv = appState?.portWindows.webViews[id] { return wv }
        if let bridge = appState?.findInlineBridge(by: id) { return bridge.webView }
        return nil
    }

    /// Resolve an inline port's HTML from message content.
    private func resolveInlinePortHtml(id: String) -> String? {
        guard let appState = appState,
              let bridge = appState.findInlineBridge(by: id),
              let mid = bridge.messageId,
              let msg = appState.messages.first(where: { $0.id == mid }),
              let html = extractPortHtml(from: msg.content) else { return nil }
        return html
    }

    private func extractPortHtml(from content: String) -> String? {
        guard let start = content.range(of: "```port\n"),
              let end = content.range(of: "\n```", range: start.upperBound..<content.endIndex) else { return nil }
        return String(content[start.upperBound..<end.lowerBound])
    }

    /// Execute a tool and return the result as content blocks for the Anthropic API.
    /// Returns an array of content blocks (text or image).
    func execute(name: String, input: [String: Any]) async -> [[String: Any]] {
        NSLog("[Port42] ToolExecutor: executing %@", name)
        if let perm = ToolDefinitions.permission(for: name) {
            if !grantedPermissions.contains(perm) {
                NSLog("[Port42] ToolExecutor: requesting %@ permission for %@", perm.rawValue, name)
                let granted = await requestPermission(perm)
                if !granted {
                    NSLog("[Port42] ToolExecutor: %@ permission denied for %@", perm.rawValue, name)
                    return [["type": "text", "text": "Permission denied: \(perm.rawValue)"]]
                }
                grantedPermissions.insert(perm)
                // Persist now that the set includes the newly granted permission. spaceId may be
                // nil (the gateway) — that persists globally for the caller now, instead of not at
                // all.
                if let by = createdBy {
                    appState?.saveCompanionPermissions(grantedPermissions, createdBy: by, spaceId: spaceId)
                }
                NSLog("[Port42] ToolExecutor: %@ permission granted for %@", perm.rawValue, name)
            }
        }

        do {
            let result = try await executeImpl(name: name, input: input)
            return result
        } catch {
            return [["type": "text", "text": "Error: \(error.localizedDescription)"]]
        }
    }

    // MARK: - Permission

    /// How this caller identifies itself on the permission card. For the gateway
    /// (`RemoteToolExecutor`) `spaceId` is nil — it isn't in a space — so its grant is global to
    /// that caller rather than unpersistable, which is what nil used to mean.
    private var requester: PermissionRequester {
        PermissionRequester(
            id: createdBy ?? "anonymous-tool-caller",
            displayName: createdByName ?? createdBy ?? "a companion",
            spaceId: spaceId,
            createdBy: createdBy
        )
    }

    /// Ask via the one coordinator. This executor holds no continuation, so concurrent asks
    /// coalesce instead of clobbering each other — three gateway calls in ten seconds used to leak
    /// all three waiters (verified 2026-07-16).
    private func requestPermission(_ perm: PortPermission) async -> Bool {
        guard let appState else { return false }
        return await appState.permissions.request(perm, from: requester)
    }

    // MARK: - Relationship-memory space resolution (D4: memory is space-scoped)

    /// The space relationship memory READS from for this call: the current space, or the
    /// companion's DM when headless (no current space). nil if neither resolves.
    private func memReadSpaceId(_ companionId: String) -> String? {
        if let sid = spaceId { return sid }
        guard let db = appState?.db else { return nil }
        return (try? db.directSpaceId(companionId: companionId)) ?? nil
    }

    /// Write variant: ensure the companion's DM exists when there's no current space.
    private func memWriteSpaceId(_ companionId: String) -> String? {
        if let sid = spaceId { return sid }
        guard let db = appState?.db else { return nil }
        return (try? db.getOrCreateDirectSpaceId(companionId: companionId)) ?? nil
    }

    // MARK: - Tool Execution

    private func executeImpl(name: String, input: [String: Any]) async throws -> [[String: Any]] {
        guard let appState else {
            return [["type": "text", "text": "Error: app state unavailable"]]
        }

        switch name {

        // MARK: Relationship tools (creases + folds)

        case "crease_read":
            guard let companionId = createdBy else {
                return [textBlock("Error: no companion context")]
            }
            let limit = input["limit"] as? Int ?? 8
            // D4: read from the current space (DM when headless) — memory is space-scoped.
            let creaseReadSpaceId = memReadSpaceId(companionId)
            let creases = (try? appState.db.fetchCreases(
                companionId: companionId,
                spaceId: creaseReadSpaceId,
                limit: limit
            )) ?? []
            if creases.isEmpty {
                return [textBlock("No creases yet. Creases form when a prediction breaks.")]
            }
            let lines = creases.map { c -> String in
                var line = "[\(c.id)] \(c.asPromptText())"
                if c.spaceId == nil { line += " (global)" }
                return line
            }
            return [textBlock(lines.joined(separator: "\n"))]

        case "crease_write":
            guard let companionId = createdBy,
                  let content = input["content"] as? String, !content.isEmpty else {
                return [textBlock("Error: crease_write requires 'content'")]
            }
            // D4: write to the current space (DM when headless) — memory is space-scoped.
            let crease = CompanionCrease(
                companionId: companionId,
                spaceId: memWriteSpaceId(companionId),
                content: content,
                prediction: input["prediction"] as? String,
                actual: input["actual"] as? String
            )
            try appState.db.saveCrease(crease)
            return [textBlock(jsonString(["id": crease.id, "ok": true]))]

        case "crease_touch":
            guard let id = input["id"] as? String else {
                return [textBlock("Error: crease_touch requires 'id'")]
            }
            try appState.db.touchCrease(id: id)
            return [textBlock("ok")]

        case "crease_forget":
            guard let id = input["id"] as? String else {
                return [textBlock("Error: crease_forget requires 'id'")]
            }
            try appState.db.deleteCrease(id: id)
            return [textBlock("ok")]

        case "engrave_read":
            guard let companionId = createdBy else {
                return [textBlock("Error: no companion context")]
            }
            let limit = input["limit"] as? Int ?? 8
            let engReadSpaceId = memReadSpaceId(companionId)
            let engravings = (try? appState.db.fetchEngravings(
                companionId: companionId,
                spaceId: engReadSpaceId,
                limit: limit
            )) ?? []
            if engravings.isEmpty {
                return [textBlock("No engravings yet. Engravings form when you learn something about their world.")]
            }
            let lines = engravings.map { e -> String in
                var line = "[\(e.id)] \(e.asPromptText())"
                if e.spaceId == nil { line += " (global)" }
                return line
            }
            return [textBlock(lines.joined(separator: "\n"))]

        case "engrave_write":
            guard let companionId = createdBy,
                  let content = input["content"] as? String, !content.isEmpty else {
                return [textBlock("Error: engrave_write requires 'content'")]
            }
            let engraving = CompanionEngraving(
                companionId: companionId,
                spaceId: memWriteSpaceId(companionId),
                content: content,
                category: input["category"] as? String
            )
            try appState.db.saveEngraving(engraving)
            return [textBlock(jsonString(["id": engraving.id, "ok": true]))]

        case "engrave_touch":
            guard let id = input["id"] as? String else {
                return [textBlock("Error: engrave_touch requires 'id'")]
            }
            try appState.db.touchEngraving(id: id)
            return [textBlock("ok")]

        case "engrave_forget":
            guard let id = input["id"] as? String else {
                return [textBlock("Error: engrave_forget requires 'id'")]
            }
            try appState.db.deleteEngraving(id: id)
            return [textBlock("ok")]

        case "fold_read":
            // Accept explicit companionId arg (for HTTP callers with no implicit context)
            let resolvedCompanionId = (input["companionId"] as? String) ?? createdBy
            guard let companionId = resolvedCompanionId else {
                return [textBlock("Error: no companion/space context — pass companionId arg")]
            }
            // D4: read fold for the current space (DM when headless).
            let emptyFold = [textBlock(jsonString(["established": [], "tensions": [], "holding": "", "depth": 0] as [String: Any]))]
            guard let foldReadSpaceId = memReadSpaceId(companionId) else { return emptyFold }
            if let fold = try appState.db.fetchFold(companionId: companionId, spaceId: foldReadSpaceId) {
                return [textBlock(jsonString([
                    "established": fold.established ?? [],
                    "tensions": fold.tensions ?? [],
                    "holding": fold.holding ?? "",
                    "depth": fold.depth
                ] as [String: Any]))]
            } else {
                return emptyFold
            }

        case "fold_update":
            guard let companionId = createdBy else {
                return [textBlock("Error: no companion context")]
            }
            // D4: fold writes to the current space (DM when headless).
            guard let foldSpaceId = memWriteSpaceId(companionId) else {
                return [textBlock("Error: no space context for fold")]
            }
            var fold = (try? appState.db.fetchFold(companionId: companionId, spaceId: foldSpaceId))
                ?? CompanionFold(companionId: companionId, spaceId: foldSpaceId)
            if let est = input["established"] as? [String] { fold.established = est }
            if let ten = input["tensions"] as? [String] { fold.tensions = ten }
            if let h = input["holding"] as? String { fold.holding = h.isEmpty ? nil : h }
            if let delta = input["depthDelta"] as? Int { fold.depth = max(0, fold.depth + delta) }
            fold.updatedAt = Date()
            try appState.db.saveFold(fold)
            return [textBlock("ok")]

        case "position_read":
            let resolvedPositionCompanionId = (input["companionId"] as? String) ?? createdBy
            guard let companionId = resolvedPositionCompanionId else {
                return [textBlock("Error: no companion context — pass companionId arg")]
            }
            // D4: position reads from the current space (DM when headless).
            guard let posReadSpaceId = memReadSpaceId(companionId) else {
                return [textBlock("No position formed yet.")]
            }
            if let pos = try appState.db.fetchPosition(companionId: companionId, spaceId: posReadSpaceId), !pos.isEmpty {
                return [textBlock(jsonString([
                    "read": pos.read ?? "",
                    "stance": pos.stance ?? "",
                    "watching": pos.watching ?? [],
                    "confidence": pos.confidence
                ] as [String: Any]))]
            } else {
                return [textBlock("No position formed yet.")]
            }

        case "position_set":
            guard let companionId = createdBy else {
                return [textBlock("Error: no companion context")]
            }
            guard let read = input["read"] as? String, !read.isEmpty else {
                return [textBlock("Error: position_set requires 'read'")]
            }
            // D4: position writes to the current space (DM when headless).
            guard let posSpaceId = memWriteSpaceId(companionId) else {
                return [textBlock("Error: no space context for position")]
            }
            var pos = (try? appState.db.fetchPosition(companionId: companionId, spaceId: posSpaceId))
                ?? CompanionPosition(companionId: companionId, spaceId: posSpaceId)
            pos.read = read
            if let stance = input["stance"] as? String { pos.stance = stance.isEmpty ? nil : stance }
            if let watching = input["watching"] as? [String] { pos.watching = watching.isEmpty ? nil : watching }
            pos.updatedAt = Date()
            try appState.db.savePosition(pos)
            return [textBlock("ok")]

        // MARK: Info tools
        case "user_get":
            guard let user = appState.currentUser else {
                return [textBlock("No user signed in")]
            }
            return [textBlock(jsonString(["id": user.id, "displayName": user.displayName]))]

        case "space_current":
            // Optional space_id lets a caller inspect ANY space — e.g. a terminal companion
            // querying its own space (PORT42_SPACE_ID), which is usually not the UI's current one.
            let sid = input["space_id"] as? String
            guard let ch = (sid.flatMap { id in appState.spaces.first(where: { $0.id == id }) } ?? appState.currentSpace) else {
                return [textBlock("No space selected")]
            }
            let list = (try? appState.db.getSpaceMembers(spaceId: ch.id)) ?? []
            let members = list.map { Port42Members.dict($0) }
            return [textBlock(jsonString([
                "id": ch.id, "name": ch.name, "type": ch.type,
                "memberCount": list.count, "members": members
            ]))]

        case "space_list":
            let spaces = appState.spaces.map { ["id": $0.id, "name": $0.name] }
            return [textBlock(jsonString(spaces))]

        case "companions_list":
            // Optional space_id filters the global roster to companions assigned to that space.
            let companions = Port42Members.companions(appState: appState, spaceId: input["space_id"] as? String)
            let out = companions.map { c -> [String: Any] in
                ["id": c.id, "name": c.displayName, "model": c.model ?? "unknown", "trigger": c.trigger.rawValue]
            }
            return [textBlock(jsonString(out))]

        case "companions_get":
            guard let id = input["id"] as? String,
                  let c = appState.companions.first(where: { $0.id == id }) else {
                return [textBlock("Companion not found")]
            }
            return [textBlock(jsonString([
                "id": c.id, "name": c.displayName,
                "model": c.model ?? "unknown",
                "systemPrompt": c.systemPrompt ?? ""
            ]))]

        // MARK: Ports
        case "ports_list":
            let filterCaps = (input["capabilities"] as? [String]) ?? []
            let registered = appState.portWindows.allPorts()
            let inline = appState.inlinePorts().filter { $0.spaceId == spaceId || spaceId == nil }.suffix(5)
            typealias PortInfo = (id: String, title: String, createdBy: String?, capabilities: [String], cwd: String?, status: String, x: CGFloat?, y: CGFloat?, surfaceBound: Bool?)
            // surfaceBound (what terminal_list used to report) comes from the live controller; only
            // terminal ports have one, so non-terminals carry nil and omit the field.
            let all: [PortInfo] = registered.map { (id: $0.udid, title: $0.title, createdBy: $0.createdBy, capabilities: $0.capabilities, cwd: $0.cwd, status: $0.isBackground ? "docked" : $0.presentation, x: $0.x, y: $0.y, surfaceBound: appState.terminalControllers[$0.udid]?.isSurfaceBound) }
                + inline.map { (id: $0.id, title: $0.title, createdBy: $0.createdBy, capabilities: $0.capabilities, cwd: $0.cwd, status: "inline", x: CGFloat?.none, y: CGFloat?.none, surfaceBound: Bool?.none) }
            let filtered = filterCaps.isEmpty ? all : all.filter { p in
                filterCaps.allSatisfy { p.capabilities.contains($0) }
            }
            if filtered.isEmpty {
                let msg = filterCaps.isEmpty ? "No active ports." : "No ports with capabilities: \(filterCaps.joined(separator: ", "))"
                return [textBlock(msg)]
            }
            let lines = filtered.map { p -> String in
                let capsStr = p.capabilities.isEmpty ? "[]" : "[" + p.capabilities.joined(separator: ", ") + "]"
                let creator = p.createdBy ?? "unknown"
                var line = "title: \(p.title)\nid: \(p.id)\ncapabilities: \(capsStr)\nstatus: \(p.status)\ncreatedBy: \(creator)"
                if let cwd = p.cwd { line += "\ncwd: \(cwd)" }
                if let surfaceBound = p.surfaceBound { line += "\nsurfaceBound: \(surfaceBound)" }
                if let x = p.x, let y = p.y { line += "\nposition: (\(Int(x)), \(Int(y)))" }
                return line
            }
            let header = "\(lines.count) port\(lines.count == 1 ? "" : "s"):"
            return [textBlock(header + "\n\n" + lines.joined(separator: "\n\n"))]

        case "port_rename":
            guard let id = input["id"] as? String,
                  let title = input["title"] as? String, !title.isEmpty else {
                return [textBlock("Error: missing 'id' or 'title'")]
            }
            appState.portWindows.renamePort(id: id, title: title)
            if let bridge = appState.findInlineBridge(by: id) {
                bridge.title = title
            }
            return [textBlock("Renamed port '\(id)' to '\(title)'")]

        case "port_move":
            guard let id = input["id"] as? String,
                  let xd = input["x"] as? Double,
                  let yd = input["y"] as? Double else {
                return [textBlock("Error: missing 'id', 'x', or 'y'")]
            }
            guard appState.portWindows.findPort(by: id) != nil else {
                return [textBlock("Error: no port found for '\(id)'")]
            }
            let x = CGFloat(xd), y = CGFloat(yd)
            appState.portWindows.movePort(id: id, x: x, y: y)
            return [textBlock("Moved port to (\(Int(x)), \(Int(y)))")]

        case "screen_info":
            let displays = NSScreen.screens.map { screen -> String in
                let f = screen.frame
                let v = screen.visibleFrame
                let main = screen == NSScreen.main ? " [main]" : ""
                return "size: \(Int(f.width))×\(Int(f.height)) at (\(Int(f.origin.x)), \(Int(f.origin.y)))\(main)\nvisible: \(Int(v.width))×\(Int(v.height)) at (\(Int(v.origin.x)), \(Int(v.origin.y)))"
            }
            return [textBlock(displays.enumerated().map { i, d in "Display \(i+1):\n\(d)" }.joined(separator: "\n\n"))]

        case "port_manage":
            guard let id = input["id"] as? String,
                  let action = input["action"] as? String else {
                return [textBlock("Error: missing 'id' or 'action' parameter")]
            }
            // Check inline port — support "undock" to pop out
            if appState.portWindows.findPort(by: id) == nil {
                if let bridge = appState.findInlineBridge(by: id), action == "undock" || action == "restore" {
                    if let mid = bridge.messageId,
                       let msg = appState.messages.first(where: { $0.id == mid }),
                       let html = extractPortHtml(from: msg.content) {
                        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
                        let bounds = window?.contentView?.bounds.size ?? CGSize(width: 800, height: 600)
                        appState.portWindows.popOut(html: html, bridge: bridge, spaceId: bridge.spaceId, createdBy: bridge.createdBy, messageId: mid, in: bounds)
                        return [textBlock("Popped out inline port '\(id)'")]
                    }
                }
                return [textBlock("Error: no port found for '\(id)'"
                    + (appState.findInlineBridge(by: id) != nil ? " (inline port — only 'undock' is supported)" : ""))]
            }
            guard let panel = appState.portWindows.findPort(by: id) else {
                return [textBlock("Error: no port found for '\(id)'")]
            }
            switch action {
            case "focus":
                appState.portWindows.bringToFront(panel.id)
                return [textBlock("Focused '\(panel.title)'")]
            case "close":
                appState.portWindows.close(panel.id)
                return [textBlock("Closed '\(panel.title)'")]
            case "minimize", "dock":
                appState.portWindows.minimize(panel.id)
                return [textBlock("Docked '\(panel.title)'")]
            case "background":
                appState.shell?.setBackgroundPort(id: panel.udid)
                return [textBlock("Set '\(panel.title)' as the shell background")]
            case "unbackground":
                appState.shell?.setBackgroundPort(id: nil)
                return [textBlock("Cleared the background — ambient dreamscape returns")]
            case "restore", "undock":
                // Undock on a registry inline port pops it out — its live webview becomes a
                // desktop tile (no reload; a tile IS the port's window).
                if panel.presentation == "inline" {
                    let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
                    let bounds = window?.contentView?.bounds.size ?? CGSize(width: 800, height: 600)
                    appState.portWindows.undockInline(id: panel.id, in: bounds)
                    return [textBlock("Popped out '\(panel.title)'")]
                }
                if appState.portWindows.restore(panel.id) {
                    return [textBlock("Restored '\(panel.title)'")]
                } else {
                    return [textBlock("'\(panel.title)' is not docked — use focus to bring it to front")]
                }
            default:
                return [textBlock("Error: unknown action '\(action)'. Use: focus, close, minimize, restore, background, unbackground")]
            }

        case "port_update":
            guard let id = input["id"] as? String,
                  let html = input["html"] as? String else {
                return [textBlock("Error: missing 'id' or 'html' parameter")]
            }
            let updated = appState.portWindows.updatePort(idOrTitle: id, html: html)
            if updated {
                Analytics.shared.portUpdated()
                return [textBlock("Port updated")]
            }
            // Fallback: inline port — reload webView with new HTML
            if let webView = appState.findInlineBridge(by: id)?.webView {
                let wrapped = PortWebViewFactory.wrapHTML(html)
                webView.loadHTMLString(wrapped, baseURL: URL(string: "http://port42.local/"))
                Analytics.shared.portUpdated()
                return [textBlock("Port updated (inline)")]
            }
            let available = appState.portWindows.allPorts().map(\.title).joined(separator: ", ")
            let hint = available.isEmpty ? "No active ports." : "Available: \(available)"
            return [textBlock("Error: no port found for '\(id)'. \(hint)")]

        case "port_get_html":
            guard let id = input["id"] as? String else {
                return [textBlock("Error: missing 'id' parameter")]
            }
            if let version = input["version"] as? Int {
                if let html = try? appState.db.fetchPortVersionHtml(udid: id, version: version) {
                    return [textBlock(html)]
                }
                return [textBlock("Error: no version \(version) found for port '\(id)'")]
            }
            if let html = try? appState.db.fetchPortHtml(udid: id) {
                return [textBlock(html)]
            }
            // Fallback: inline port — extract HTML from message content
            if let html = resolveInlinePortHtml(id: id) {
                return [textBlock(html)]
            }
            return [textBlock("Error: no port found for id '\(id)'")]

        case "port_restore":
            guard let id = input["id"] as? String,
                  let version = input["version"] as? Int else {
                return [textBlock("Error: port_restore requires 'id' and 'version' parameters")]
            }
            guard let html = try? appState.db.fetchPortVersionHtml(udid: id, version: version) else {
                return [textBlock("Error: no version \(version) found for port '\(id)'")]
            }
            let restored = appState.portWindows.updatePort(idOrTitle: id, html: html)
            if restored {
                Analytics.shared.portUpdated()
                return [textBlock("Restored port '\(id)' to version \(version)")]
            }
            // Fallback: inline port
            if let webView = appState.findInlineBridge(by: id)?.webView {
                let wrapped = PortWebViewFactory.wrapHTML(html)
                webView.loadHTMLString(wrapped, baseURL: URL(string: "http://port42.local/"))
                Analytics.shared.portUpdated()
                return [textBlock("Restored port '\(id)' to version \(version) (inline)")]
            }
            return [textBlock("Error: port '\(id)' not found or not active")]

        case "port_patch":
            guard let id = input["id"] as? String,
                  let search = input["search"] as? String,
                  let replace = input["replace"] as? String else {
                return [textBlock("Error: port_patch requires 'id', 'search', and 'replace' parameters")]
            }
            // Try floating/docked first, then inline
            let currentHtml: String
            if let html = try? appState.db.fetchPortHtml(udid: id) {
                currentHtml = html
            } else if let html = resolveInlinePortHtml(id: id) {
                currentHtml = html
            } else {
                return [textBlock("Error: no port found for id '\(id)'")]
            }
            guard currentHtml.contains(search) else {
                return [textBlock("Error: search string not found in port '\(id)' — call port_get_html to read the current HTML and copy the exact string to replace")]
            }
            let patched = currentHtml.replacingOccurrences(of: search, with: replace)
            let applied = appState.portWindows.updatePort(idOrTitle: id, html: patched)
            if applied {
                Analytics.shared.portUpdated()
                return [textBlock("Patch applied to port '\(id)'")]
            }
            // Fallback: inline port
            if let webView = appState.findInlineBridge(by: id)?.webView {
                let wrapped = PortWebViewFactory.wrapHTML(patched)
                webView.loadHTMLString(wrapped, baseURL: URL(string: "http://port42.local/"))
                Analytics.shared.portUpdated()
                return [textBlock("Patch applied to port '\(id)' (inline)")]
            }
            return [textBlock("Error: port '\(id)' not found or not active")]

        case "port_push":
            // One type-dispatched verb: a terminal id gets a RAW, non-arming inject (caller supplies
            // its own newline); a web id gets a port42:data CustomEvent.
            guard let id = input["id"] as? String else {
                return [textBlock("Error: port_push requires 'id' parameter")]
            }
            let data = input["data"] ?? NSNull()
            let controller = appState.resolveTerminalController(idOrName: id)
            let webView = resolvePortWebView(id: id)
            switch PortPushRoute.classify(isTerminal: controller != nil, isWeb: webView != nil) {
            case .terminal:
                let str = (data as? String) ?? jsonString(data)
                guard controller!.sendRaw(str) else {
                    return [textBlock("Error: terminal '\(id)' has no live surface")]
                }
                return [textBlock("Sent to \(controller!.config.companionName)")]
            case .web:
                guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
                      let jsonStr = String(data: jsonData, encoding: .utf8) else {
                    return [textBlock("Error: could not serialize data to JSON")]
                }
                _ = try? await webView!.evaluateJavaScript(
                    "window.dispatchEvent(new CustomEvent('port42:data', {detail: \(jsonStr)}))"
                )
                return [textBlock("Data pushed to port '\(id)'")]
            case .notFound:
                return [textBlock("Error: port '\(id)' not found or not active")]
            }

        case "port_exec":
            guard let id = input["id"] as? String,
                  let js = input["js"] as? String else {
                return [textBlock("Error: port_exec requires 'id' and 'js' parameters")]
            }
            guard let webView = resolvePortWebView(id: id) else {
                return [textBlock("Error: port '\(id)' not found or not active")]
            }
            do {
                let result = try await webView.evaluateJavaScript(js)
                if result is NSNull || result == nil {
                    return [textBlock("OK (no return value)")]
                }
                if let str = result as? String { return [textBlock(str)] }
                if let num = result as? NSNumber { return [textBlock("\(num)")] }
                if let data = try? JSONSerialization.data(withJSONObject: result!),
                   let str = String(data: data, encoding: .utf8) {
                    return [textBlock(str)]
                }
                return [textBlock("\(result!)")]
            } catch {
                return [textBlock("Error executing JS: \(error.localizedDescription)")]
            }

        case "port_history":
            guard let id = input["id"] as? String else {
                return [textBlock("Error: missing 'id' parameter")]
            }
            let versions = (try? appState.db.fetchPortVersions(portUdid: id)) ?? []
            if versions.isEmpty {
                return [textBlock("No version history for port '\(id)'")]
            }
            let lines = versions.map { v -> String in
                let ts = ISO8601DateFormatter().string(from: v.createdAt)
                let author = v.createdBy ?? "unknown"
                return "version: \(v.version)\ncreatedBy: \(author)\ncreatedAt: \(ts)"
            }
            return [textBlock("\(versions.count) version\(versions.count == 1 ? "" : "s"):\n\n" + lines.joined(separator: "\n\n"))]

        case "messages_recent":
            let count = min(input["count"] as? Int ?? 20, 100)
            let chId = input["space_id"] as? String ?? spaceId ?? appState.currentSpace?.id ?? ""
            let topicFilter = input["topic"] as? String ?? "chat"
            let msgs = (try? appState.db.getMessages(spaceId: chId, topic: topicFilter)) ?? []
            let recent = msgs.suffix(count).map { m -> [String: Any] in
                ["sender": m.senderName, "content": m.content, "timestamp": m.timestamp.timeIntervalSince1970]
            }
            return [textBlock(jsonString(recent))]

        case "bus_read":
            guard let topic = input["topic"] as? String else {
                return [textBlock("Error: missing 'topic' parameter")]
            }
            let limit = min(input["limit"] as? Int ?? 20, 100)
            let busSpaceId = input["space_id"] as? String ?? spaceId ?? appState.currentSpace?.id ?? ""
            let msgs = (try? appState.db.getMessages(spaceId: busSpaceId, topic: topic)) ?? []
            let recent = msgs.suffix(limit).map { m -> [String: Any] in
                ["sender": m.senderName, "content": m.content, "timestamp": m.timestamp.timeIntervalSince1970, "topic": m.topic]
            }
            return [textBlock(jsonString(recent))]

        // MARK: Action tools
        case "bus_publish":
            guard let topic = input["topic"] as? String,
                  let payload = input["payload"] as? String else {
                return [textBlock("Error: missing 'topic' or 'payload' parameter")]
            }
            let busSpaceId = input["space_id"] as? String ?? spaceId ?? appState.currentSpace?.id ?? ""
            let senderName: String
            if let cid = createdBy, let agent = appState.companions.first(where: { $0.id == cid }) {
                senderName = agent.displayName
            } else {
                senderName = appState.currentUser?.displayName ?? "agent"
            }
            appState.publishToBus(spaceId: busSpaceId, topic: topic, payload: payload, senderName: senderName)
            return [textBlock(jsonString(["ok": true, "topic": topic]))]

        case "messages_send":
            guard let text = input["text"] as? String else {
                return [textBlock("Error: missing 'text' parameter")]
            }
            let targetSpaceId = input["space_id"] as? String ?? spaceId
            let overrideName = input["senderName"] as? String ?? input["sender_name"] as? String
            if let name = overrideName, !name.isEmpty {
                appState.sendMessageAsNamedAgent(content: text, senderName: name, toSpaceId: targetSpaceId)
            } else {
                appState.sendMessage(content: text, toSpaceId: targetSpaceId)
            }
            return [textBlock(jsonString(["ok": true]))]

        case "storage_get":
            guard let key = input["key"] as? String else {
                return [textBlock("Error: missing 'key' parameter")]
            }
            let scope = "tool"
            let creatorId = appState.currentUser?.id ?? "system"
            let value = try? appState.db.getPortStorage(key: key, scope: scope, creatorId: creatorId)
            return [textBlock(jsonString(["key": key, "value": value ?? "null"]))]

        case "storage_set":
            guard let key = input["key"] as? String,
                  let value = input["value"] as? String else {
                return [textBlock("Error: missing 'key' or 'value' parameter")]
            }
            let scope = "tool"
            let creatorId = appState.currentUser?.id ?? "system"
            try? appState.db.setPortStorage(key: key, value: value, scope: scope, creatorId: creatorId)
            return [textBlock(jsonString(["ok": true]))]

        case "storage_delete":
            guard let key = input["key"] as? String else {
                return [textBlock("Error: missing 'key' parameter")]
            }
            let scope = "tool"
            let creatorId = appState.currentUser?.id ?? "system"
            try? appState.db.deletePortStorage(key: key, scope: scope, creatorId: creatorId)
            return [textBlock(jsonString(["ok": true]))]

        case "storage_list":
            let scope = "tool"
            let creatorId = appState.currentUser?.id ?? "system"
            let keys = (try? appState.db.listPortStorageKeys(scope: scope, creatorId: creatorId)) ?? []
            return [textBlock(jsonString(keys))]

        // MARK: Clipboard
        case "clipboard_read":
            let result = clipboardBridge.read()
            if let type = result["type"] as? String, type == "image",
               let data = result["data"] as? String {
                return [imageBlock(base64: data, mediaType: "image/png")]
            }
            return [textBlock(jsonString(result))]

        case "clipboard_write":
            guard let text = input["text"] as? String else {
                return [textBlock("Error: missing 'text' parameter")]
            }
            let result = clipboardBridge.write([text])
            return [textBlock(jsonString(result))]

        // MARK: Screen
        case "screen_capture":
            let scale = input["scale"] as? Double ?? 1.0
            let result = await screenBridge.capture(opts: ["scale": scale, "includeSelf": false])
            if let base64 = result["image"] as? String {
                postCapture(base64PNG: base64, type: "screen")
                return [imageBlock(base64: base64, mediaType: "image/png")]
            }
            return [textBlock(jsonString(result))]

        case "screen_windows":
            let result = await screenBridge.windows()
            return [textBlock(jsonString(result))]

        case "camera_capture":
            let result = await cameraBridge.capture(opts: [:])
            if let base64 = result["image"] as? String {
                postCapture(base64PNG: base64, type: "camera")
                return [imageBlock(base64: base64, mediaType: "image/png")]
            }
            return [textBlock(jsonString(result))]

        // MARK: Terminal
        // MARK: Ports
        case "port_create":
            // Uniform creation primitive (web | terminal). `presentation` routes the web port:
            // "inline" (default) → an inline chat port; "tiled" → a shell desktop tile. Terminals
            // are always a native window + card. Ungated.
            let sid = input["space_id"] as? String ?? spaceId ?? appState.currentSpace?.id ?? ""
            let result = appState.createPort(
                type: input["type"] as? String,
                title: input["title"] as? String,
                html: input["html"] as? String,
                command: input["command"] as? String,
                args: input["args"] as? [String] ?? [],
                cwd: input["cwd"] as? String,
                systemPrompt: input["systemPrompt"] as? String,
                env: input["env"] as? [String: String] ?? [:],
                spaceId: sid, createdBy: createdBy, createdByName: createdByName,
                presentation: input["presentation"] as? String)   // nil → mode default (shell: tiled)
            return [textBlock(jsonString(result))]

        case "terminal_exec":
            guard let command = input["command"] as? String else {
                return [textBlock("Error: missing 'command' parameter")]
            }
            let cwd = input["cwd"] as? String
            let timeout = min(input["timeout"] as? Int ?? 30, 120)
            let result = await ShellExec.run(command, cwd: cwd, timeout: timeout)
            return [textBlock(result)]

        // MARK: Filesystem
        case "file_read":
            guard let path = input["path"] as? String else {
                return [textBlock("Error: missing 'path' parameter")]
            }
            let encoding = input["encoding"] as? String ?? "utf8"
            if !path.hasPrefix("/") {
                let resolved = resolveFilePath(path)
                do {
                    if encoding == "base64" {
                        let bytes = try Data(contentsOf: URL(fileURLWithPath: resolved))
                        return [textBlock(jsonString(["data": bytes.base64EncodedString()]))]
                    } else {
                        let text = try String(contentsOfFile: resolved, encoding: .utf8)
                        return [textBlock(jsonString(["data": text]))]
                    }
                } catch {
                    return [textBlock(jsonString(["error": error.localizedDescription]))]
                }
            }
            let result = fileBridge.read(path: path, opts: ["encoding": encoding])
            return [textBlock(jsonString(result))]

        case "file_write":
            guard let path = input["path"] as? String,
                  let data = input["data"] as? String else {
                return [textBlock("Error: missing 'path' or 'data' parameter")]
            }
            let encoding = input["encoding"] as? String ?? "utf8"
            if !path.hasPrefix("/") {
                let resolved = resolveFilePath(path)
                let dir = (resolved as NSString).deletingLastPathComponent
                do {
                    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    if encoding == "base64", let bytes = Data(base64Encoded: data) {
                        try bytes.write(to: URL(fileURLWithPath: resolved))
                    } else {
                        try data.write(toFile: resolved, atomically: true, encoding: .utf8)
                    }
                    return [textBlock(jsonString(["ok": true]))]
                } catch {
                    return [textBlock(jsonString(["error": error.localizedDescription]))]
                }
            }
            let result = fileBridge.write(path: path, data: data, opts: ["encoding": encoding])
            return [textBlock(jsonString(result))]

        case "file_list":
            guard let path = input["path"] as? String else {
                return [textBlock("Error: missing 'path' parameter")]
            }
            guard !path.hasPrefix("/") else {
                return [textBlock("Error: file_list only supports relative paths within Port42 data directory")]
            }
            let resolved = resolveFilePath(path)
            do {
                let items = try FileManager.default.contentsOfDirectory(atPath: resolved)
                return [textBlock(jsonString(["items": items.sorted()]))]
            } catch {
                return [textBlock(jsonString(["error": error.localizedDescription]))]
            }

        case "file_mkdir":
            guard let path = input["path"] as? String else {
                return [textBlock("Error: missing 'path' parameter")]
            }
            guard !path.hasPrefix("/") else {
                return [textBlock("Error: file_mkdir only supports relative paths within Port42 data directory")]
            }
            let resolved = resolveFilePath(path)
            do {
                try FileManager.default.createDirectory(atPath: resolved, withIntermediateDirectories: true)
                return [textBlock(jsonString(["ok": true]))]
            } catch {
                return [textBlock(jsonString(["error": error.localizedDescription]))]
            }

        // MARK: Automation
        case "run_applescript":
            guard let source = input["source"] as? String else {
                return [textBlock("Error: missing 'source' parameter")]
            }
            let timeout = input["timeout"] as? Int ?? 30
            let result = await automationBridge.runAppleScript(source: source, opts: ["timeout": timeout])
            return [textBlock(jsonString(result))]

        case "run_jxa":
            guard let source = input["source"] as? String else {
                return [textBlock("Error: missing 'source' parameter")]
            }
            let timeout = input["timeout"] as? Int ?? 30
            let result = await automationBridge.runJXA(source: source, opts: ["timeout": timeout])
            return [textBlock(jsonString(result))]

        // MARK: REST
        case "rest_call":
            guard let url = input["url"] as? String,
                  let parsed = URL(string: url) else {
                return [textBlock("Error: rest_call requires a valid 'url'")]
            }

            // Secret scoping: check companion has access
            if let secretName = input["secret"] as? String {
                if let companionId = createdBy,
                   let agent = appState.companions.first(where: { $0.id == companionId }) {
                    let allowed = agent.secretNames ?? []
                    if !allowed.contains(secretName) {
                        return [textBlock("Error: companion does not have access to secret '\(secretName)'. Grant it in companion settings.")]
                    }
                }
            }

            let method = (input["method"] as? String ?? "GET").uppercased()
            let timeoutMs = min(input["timeout"] as? Int ?? 30000, 120000)

            var request = URLRequest(url: parsed)
            request.httpMethod = method
            request.timeoutInterval = TimeInterval(timeoutMs) / 1000.0

            // Custom headers
            if let headers = input["headers"] as? [String: String] {
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }

            // Body
            if let body = input["body"] as? String {
                request.httpBody = body.data(using: .utf8)
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            }

            // Secret injection — the companion never sees the raw credential
            if let secretName = input["secret"] as? String {
                if let (headerName, headerValue) = Port42AuthStore.shared.resolveSecretHeader(name: secretName) {
                    request.setValue(headerValue, forHTTPHeaderField: headerName)
                } else {
                    return [textBlock("Error: secret '\(secretName)' not found. Add it in Settings > Secrets.")]
                }
            }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let httpResponse = response as? HTTPURLResponse
                let statusCode = httpResponse?.statusCode ?? 0

                // Build response
                var result: [String: Any] = ["status": statusCode]

                // Response headers (selected useful ones)
                if let headers = httpResponse?.allHeaderFields as? [String: String] {
                    var filtered: [String: String] = [:]
                    for key in ["content-type", "x-request-id", "x-ratelimit-remaining", "retry-after", "location"] {
                        if let v = headers.first(where: { $0.key.lowercased() == key })?.value {
                            filtered[key] = v
                        }
                    }
                    if !filtered.isEmpty { result["headers"] = filtered }
                }

                // Body — auto-parse JSON
                let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type") ?? ""
                if contentType.contains("json"), let json = try? JSONSerialization.jsonObject(with: data) {
                    result["body"] = json
                } else if let text = String(data: data, encoding: .utf8) {
                    // Truncate very large text responses
                    result["body"] = text.count > 50000 ? String(text.prefix(50000)) + "\n...(truncated)" : text
                }

                return [textBlock(jsonString(result))]
            } catch {
                return [textBlock(jsonString(["status": 0, "error": error.localizedDescription]))]
            }

        // MARK: Browser
        case "browser_open":
            guard let url = input["url"] as? String else {
                return [textBlock("Error: missing 'url' parameter")]
            }
            let result = await browserBridge.open(url: url, opts: [:])
            return [textBlock(jsonString(result))]

        case "browser_text":
            guard let sessionId = input["sessionId"] as? String else {
                return [textBlock("Error: missing 'sessionId' parameter")]
            }
            let selector = input["selector"] as? String
            let opts: [String: Any] = selector.map { ["selector": $0] } ?? [:]
            let result = await browserBridge.text(sessionId: sessionId, opts: opts)
            return [textBlock(jsonString(result))]

        case "browser_capture":
            guard let sessionId = input["sessionId"] as? String else {
                return [textBlock("Error: missing 'sessionId' parameter")]
            }
            let result = await browserBridge.capture(sessionId: sessionId, opts: [:])
            if let base64 = result["image"] as? String {
                return [imageBlock(base64: base64, mediaType: "image/png")]
            }
            return [textBlock(jsonString(result))]

        case "browser_close":
            guard let sessionId = input["sessionId"] as? String else {
                return [textBlock("Error: missing 'sessionId' parameter")]
            }
            let result = browserBridge.close(sessionId: sessionId)
            return [textBlock(jsonString(result))]

        // MARK: Notifications
        case "notify_send":
            guard let title = input["title"] as? String,
                  let body = input["body"] as? String else {
                return [textBlock("Error: missing 'title' or 'body' parameter")]
            }
            let _ = await notificationBridge.send(title: title, body: body, opts: [:])
            return [textBlock(jsonString(["ok": true]))]

        // MARK: Audio
        case "audio_speak":
            guard let text = input["text"] as? String else {
                return [textBlock("Error: missing 'text' parameter")]
            }
            let rate = input["rate"] as? Double
            let opts: [String: Any] = rate.map { ["rate": $0] } ?? [:]
            let result = await audioBridge.speak(text: text, opts: opts)
            return [textBlock(jsonString(result))]

        default:
            return [textBlock("Unknown tool: \(name)")]
        }
    }

    // MARK: - KB path helpers

    private var port42DataDir: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("Port42").path
    }

    /// Resolve a file path. Relative paths are scoped to the Port42 data directory.
    /// Absolute paths are returned unchanged (handled by FileBridge).
    private func resolveFilePath(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        return (port42DataDir as NSString).appendingPathComponent(path)
    }

    // MARK: - Escape Processing

    /// Process escape sequences in a string so they become real bytes.
    /// Converts \n, \r, \t, \x03 (ctrl-c), \x04 (ctrl-d), etc.
    static func processEscapes(_ str: String) -> String {
        var result = ""
        var chars = str.makeIterator()
        while let c = chars.next() {
            if c == "\\" {
                guard let next = chars.next() else {
                    result.append(c)
                    break
                }
                switch next {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\\": result.append("\\")
                case "x":
                    // Parse hex: \x03, \x1b, etc.
                    var hex = ""
                    if let h1 = chars.next() { hex.append(h1) }
                    if let h2 = chars.next() { hex.append(h2) }
                    if let byte = UInt8(hex, radix: 16) {
                        result.append(Character(UnicodeScalar(byte)))
                    } else {
                        result.append("\\x")
                        result.append(hex)
                    }
                default:
                    result.append(c)
                    result.append(next)
                }
            } else {
                result.append(c)
            }
        }
        return result
    }

    // MARK: - Capture Persistence

    private func postCapture(base64PNG: String, type: String) {
        guard let appState = appState, let spaceId = spaceId else { return }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let capturesDir = appSupport.appendingPathComponent("Port42/captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: capturesDir, withIntermediateDirectories: true)

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let stamp = fmt.string(from: Date())
        let companion = (createdBy ?? "companion")
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        let filename = "\(stamp)-\(companion)-\(type).png"
        let fileURL = capturesDir.appendingPathComponent(filename)

        if let data = Data(base64Encoded: base64PNG) {
            try? data.write(to: fileURL)
        }

        let msg = Message.create(
            spaceId: spaceId,
            senderId: createdBy ?? "system",
            senderName: createdBy ?? "system",
            content: "[capture:\(type):\(fileURL.path)]",
            senderType: "system"
        )
        do {
            try appState.db.saveMessage(msg)
        } catch {
            NSLog("[Port42] Failed to save capture message: %@", error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func textBlock(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    private func imageBlock(base64: String, mediaType: String) -> [String: Any] {
        [
            "type": "image",
            "source": [
                "type": "base64",
                "media_type": mediaType,
                "data": base64
            ]
        ]
    }

    private func jsonString(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return String(describing: value)
    }

}

// MARK: - Remote Tool Executor

/// Specialized executor for remote RPC calls (CLIs, OpenClaw).
/// Includes "Always Allow" permission bypasses from global settings.
@MainActor
public final class RemoteToolExecutor: ObservableObject {
    private weak var appState: AppState?
    private let senderId: String
    private let senderName: String
    
    /// Internal executor used for actual logic and permission prompts
    private let internalExecutor: ToolExecutor

    public init(appState: AppState, senderId: String, senderName: String) {
        self.appState = appState
        self.senderId = senderId
        self.senderName = senderName
        self.internalExecutor = ToolExecutor(appState: appState, spaceId: nil, createdBy: senderName)
    }

    public func execute(method: String, input: [String: Any]) async -> Any {
        // Resolve the incoming name to canonical: a dotted name IS canonical (`port.getHtml`,
        // `ports.list`); a snake tool name maps through ToolNaming. This is what makes both spellings
        // reach the same method and kills the `port.getHtml` → Unknown-tool class.
        let canonical = method.contains(".") ? method : (ToolNaming.canonical(fromTool: method) ?? method)

        // "Always Allow" settings become pre-grants for the registry path (and the old path below).
        var pregrant: Set<PortPermission> = []
        for (key, perm): (String, PortPermission) in [("remoteAllowTerminal", .terminal),
                                                       ("remoteAllowFS", .filesystem),
                                                       ("remoteAllowScreen", .screen)] {
            if UserDefaults.standard.bool(forKey: key) { pregrant.insert(perm) }
        }

        // Registry-first (Phase 2): the unified path serves every extracted method, identically for
        // JS / tool-use / gateway. Anything not yet extracted (the live-only families) falls through
        // to the old switch below, unchanged.
        if let appState, appState.bridgeHandles(canonical) {
            let principal = Principal(id: senderId, displayName: senderName, spaceId: nil, kind: .peer)
            do {
                let value = try await appState.runBridgeMethod(canonical, principal: principal,
                                                               args: BridgeArgs(input), pregrant: pregrant)
                return value.toJSONObject()
            } catch let e as BridgeError {
                return e.toJSONObject()
            } catch {
                return ["error": error.localizedDescription]
            }
        }

        // Old path (live-only families not yet extracted).
        let toolName = method.replacingOccurrences(of: ".", with: "_")
        for perm in pregrant { internalExecutor.pregrant(perm) }
        let result = await internalExecutor.execute(name: toolName, input: input)
        if let first = result.first {
            return (first["text"] as? String) ?? first
        }
        return ["error": "empty result"]
    }
}
