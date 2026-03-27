import Foundation
import AppKit

/// Executes tool calls from LLM companions against port42 bridge APIs.
/// One instance per conversation (channel or swim channel).
@MainActor
public final class ToolExecutor {
    private weak var appState: AppState?
    private let channelId: String?
    let createdBy: String?

    /// Granted permissions for this conversation (per-companion, per-channel).
    private var grantedPermissions: Set<PortPermission> = []

    /// Pre-grant a permission without prompting the user (used by RemoteToolExecutor for "Always Allow" settings).
    func pregrant(_ perm: PortPermission) {
        grantedPermissions.insert(perm)
    }

    /// Pending permission continuation for async approval flow.
    private var permissionContinuation: CheckedContinuation<Bool, Never>?
    @Published var pendingPermission: PortPermission?

    // Lazy bridge instances
    private lazy var clipboardBridge = ClipboardBridge()
    private lazy var screenBridge = ScreenBridge()
    private lazy var fileBridge = FileBridge()
    private lazy var automationBridge = AutomationBridge()
    private lazy var notificationBridge = NotificationBridge()
    private lazy var browserBridge = BrowserBridge()
    private lazy var audioBridge = AudioBridge()
    private lazy var cameraBridge = CameraBridge()

    /// Output batchers for active terminal bridges (keyed by lowercased port name)
    private static var outputBatchers: [String: OutputBatcher] = [:]

    init(appState: AppState, channelId: String?, createdBy: String? = nil) {
        self.appState = appState
        self.channelId = channelId
        self.createdBy = createdBy
        // Restore previously granted permissions so the user isn't re-prompted
        if let by = createdBy, let cid = channelId {
            self.grantedPermissions = appState.companionPermissions(createdBy: by, channelId: cid)
        }
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
                // Persist now that the set includes the newly granted permission
                if let by = createdBy, let cid = channelId {
                    appState?.saveCompanionPermissions(grantedPermissions, createdBy: by, channelId: cid)
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

    /// Grant the pending permission (called from UI).
    func grantPermission() {
        pendingPermission = nil
        appState?.activeToolExecutor = nil
        permissionContinuation?.resume(returning: true)
        permissionContinuation = nil
        // Persistence happens in execute() after grantedPermissions.insert(perm)
    }

    /// Deny the pending permission (called from UI).
    func denyPermission() {
        pendingPermission = nil
        appState?.activeToolExecutor = nil
        permissionContinuation?.resume(returning: false)
        permissionContinuation = nil
    }

    // MARK: - Permission

    private func requestPermission(_ perm: PortPermission) async -> Bool {
        return await withCheckedContinuation { continuation in
            self.permissionContinuation = continuation
            self.pendingPermission = perm
            // Surface to AppState so the UI can show the prompt
            self.appState?.activeToolExecutor = self
        }
    }

    // MARK: - Terminal Bridge

    /// Bridge all terminal ports already open in this channel/swim at conversation start.
    /// Called by ChannelAgentHandler.start() so output flows without needing terminal_send first.
    func bridgeChannelTerminals() {
        guard let appState, let chId = channelId else { return }
        for panel in appState.portWindows.panels {
            guard panel.channelId == chId else { continue }
            guard let tb = panel.bridge.terminalBridge,
                  let sid = tb.firstActiveSessionId else { continue }
            autoStartOutputBridge(portTitle: panel.title, termBridge: tb, sessionId: sid)
        }
    }

    /// Start routing a terminal port's output into this conversation as messages.
    /// No-op if already bridged. Called automatically on terminal_send success.
    private func autoStartOutputBridge(portTitle: String, termBridge: TerminalBridge, sessionId: String) {
        guard let appState else { return }
        let key = portTitle.lowercased()
        guard !appState.bridgedTerminalNames.contains(key) else { return }
        let chId = channelId ?? appState.currentChannel?.id ?? ""
        guard !chId.isEmpty else { return }
        appState.bridgedTerminalNames.insert(key)
        let batcher = OutputBatcher(portName: portTitle, channelId: chId, companionName: createdBy ?? "bridge", appState: appState)
        Self.outputBatchers[key] = batcher
        termBridge.session(for: sessionId)?.addOutputObserver { [weak batcher] rawOutput in
            Task { @MainActor in
                batcher?.receive(rawOutput)
            }
        }
        // Start the game loop — scoped to the owning companion so only they react
        appState.startTerminalLoop(channelId: chId, portTitle: portTitle, createdBy: createdBy)
        NSLog("[Port42] Auto-bridged terminal '%@' → channel %@", portTitle, chId)
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
            // Always read from swim channel — companion has one inner state
            let swimCreaseId = "swim-\(companionId)"
            let creases = (try? appState.db.fetchCreases(
                companionId: companionId,
                channelId: swimCreaseId,
                limit: limit
            )) ?? []
            if creases.isEmpty {
                return [textBlock("No creases yet. Creases form when a prediction breaks.")]
            }
            let lines = creases.map { c -> String in
                var line = "[\(c.id)] \(c.asPromptText())"
                if c.channelId == nil { line += " (global)" }
                return line
            }
            return [textBlock(lines.joined(separator: "\n"))]

        case "crease_write":
            guard let companionId = createdBy,
                  let content = input["content"] as? String, !content.isEmpty else {
                return [textBlock("Error: crease_write requires 'content'")]
            }
            // Always write to swim channel — companion has one inner state
            let swimWriteId = "swim-\(companionId)"
            let crease = CompanionCrease(
                companionId: companionId,
                channelId: swimWriteId,
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

        case "fold_read":
            // Accept explicit companionId arg (for HTTP callers with no implicit context)
            let resolvedCompanionId = (input["companionId"] as? String) ?? createdBy
            guard let companionId = resolvedCompanionId else {
                return [textBlock("Error: no companion/channel context — pass companionId arg")]
            }
            let swimId = "swim-\(companionId)"
            let cid = channelId ?? swimId
            if let fold = try appState.db.fetchFold(companionId: companionId, channelId: swimId)
                ?? appState.db.fetchFold(companionId: companionId, channelId: cid) {
                return [textBlock(jsonString([
                    "established": fold.established ?? [],
                    "tensions": fold.tensions ?? [],
                    "holding": fold.holding ?? "",
                    "depth": fold.depth
                ] as [String: Any]))]
            } else {
                return [textBlock(jsonString(["established": [], "tensions": [], "holding": "", "depth": 0] as [String: Any]))]
            }

        case "fold_update":
            guard let companionId = createdBy else {
                return [textBlock("Error: no companion context")]
            }
            // Fold always writes to the swim channel — canonical relationship state
            let swimId = "swim-\(companionId)"
            var fold = (try? appState.db.fetchFold(companionId: companionId, channelId: swimId))
                ?? CompanionFold(companionId: companionId, channelId: swimId)
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
            // Position reads from swim (canonical)
            let swimId = "swim-\(companionId)"
            if let pos = try appState.db.fetchPosition(companionId: companionId, channelId: swimId), !pos.isEmpty {
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
            // Position always writes to the swim channel — canonical relationship state
            let swimId = "swim-\(companionId)"
            var pos = (try? appState.db.fetchPosition(companionId: companionId, channelId: swimId))
                ?? CompanionPosition(companionId: companionId, channelId: swimId)
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

        case "channel_current":
            guard let ch = appState.currentChannel else {
                return [textBlock("No channel selected")]
            }
            let members = (try? appState.db.getChannelMembers(channelId: ch.id))?.count ?? 0
            return [textBlock(jsonString(["id": ch.id, "name": ch.name, "memberCount": members]))]

        case "channel_list":
            let channels = appState.channels.map { ["id": $0.id, "name": $0.name] }
            return [textBlock(jsonString(channels))]

        case "companions_list":
            let companions = appState.companions.map { c -> [String: Any] in
                ["id": c.id, "name": c.displayName, "model": c.model ?? "unknown", "trigger": c.trigger.rawValue]
            }
            return [textBlock(jsonString(companions))]

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
            let floating = appState.portWindows.allPorts()
            let inline = appState.inlinePorts().filter { $0.channelId == channelId || channelId == nil }.suffix(5)
            typealias PortInfo = (id: String, title: String, createdBy: String?, capabilities: [String], cwd: String?, status: String, x: CGFloat?, y: CGFloat?)
            let all: [PortInfo] = floating.map { (id: $0.udid, title: $0.title, createdBy: $0.createdBy, capabilities: $0.capabilities, cwd: $0.cwd, status: $0.isBackground ? "docked" : "floating", x: $0.x, y: $0.y) }
                + inline.map { (id: $0.id, title: $0.title, createdBy: $0.createdBy, capabilities: $0.capabilities, cwd: $0.cwd, status: "inline", x: CGFloat?.none, y: CGFloat?.none) }
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
            case "restore", "undock":
                if appState.portWindows.restore(panel.id) {
                    return [textBlock("Restored '\(panel.title)'")]
                } else {
                    return [textBlock("'\(panel.title)' is not docked — use focus to bring it to front")]
                }
            default:
                return [textBlock("Error: unknown action '\(action)'. Use: focus, close, minimize, restore (or undock)")]
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
            return [textBlock("Error: port '\(id)' not found or not active")]

        case "port_patch":
            guard let id = input["id"] as? String,
                  let search = input["search"] as? String,
                  let replace = input["replace"] as? String else {
                return [textBlock("Error: port_patch requires 'id', 'search', and 'replace' parameters")]
            }
            guard let currentHtml = try? appState.db.fetchPortHtml(udid: id) else {
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
            return [textBlock("Error: port '\(id)' not found or not active")]

        case "port_push":
            guard let id = input["id"] as? String else {
                return [textBlock("Error: port_push requires 'id' parameter")]
            }
            let data = input["data"] ?? NSNull()
            guard let webView = appState.portWindows.webViews[id] else {
                return [textBlock("Error: port '\(id)' not found or not active")]
            }
            guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
                  let jsonStr = String(data: jsonData, encoding: .utf8) else {
                return [textBlock("Error: could not serialize data to JSON")]
            }
            _ = try? await webView.evaluateJavaScript(
                "window.dispatchEvent(new CustomEvent('port42:data', {detail: \(jsonStr)}))"
            )
            return [textBlock("Data pushed to port '\(id)'")]

        case "port_exec":
            guard let id = input["id"] as? String,
                  let js = input["js"] as? String else {
                return [textBlock("Error: port_exec requires 'id' and 'js' parameters")]
            }
            guard let webView = appState.portWindows.webViews[id] else {
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
            let chId = input["channel_id"] as? String ?? channelId ?? appState.currentChannel?.id ?? ""
            let msgs = (try? appState.db.getMessages(channelId: chId)) ?? []
            let recent = msgs.suffix(count).map { m -> [String: Any] in
                ["sender": m.senderName, "content": m.content, "timestamp": m.timestamp.timeIntervalSince1970]
            }
            return [textBlock(jsonString(recent))]

        // MARK: Action tools
        case "messages_send":
            guard let text = input["text"] as? String else {
                return [textBlock("Error: missing 'text' parameter")]
            }
            let targetChannel = input["channel_id"] as? String ?? channelId
            appState.sendMessage(content: text, toChannelId: targetChannel)
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
        case "terminal_exec":
            guard let command = input["command"] as? String else {
                return [textBlock("Error: missing 'command' parameter")]
            }
            let cwd = input["cwd"] as? String
            let timeout = min(input["timeout"] as? Int ?? 30, 120)
            let result = await executeCommand(command, cwd: cwd, timeout: timeout)
            return [textBlock(result)]

        case "terminal_send":
            guard let name = input["name"] as? String,
                  let data = input["data"] as? String else {
                return [textBlock("Error: missing 'name' or 'data' parameter")]
            }
            var processed = ToolExecutor.processEscapes(data)
            // Ensure commands are executed — append \r if not already present
            if !processed.hasSuffix("\r") && !processed.hasSuffix("\n") {
                processed += "\r"
            }
            // 1. UDID lookup (preferred — use id from ports_list)
            if let panel = appState.portWindows.findPort(by: name),
               let tb = panel.bridge.terminalBridge {
                let ok = tb.sendToFirst(data: processed)
                if ok, let sid = tb.firstActiveSessionId {
                    autoStartOutputBridge(portTitle: panel.title, termBridge: tb, sessionId: sid)
                }
                return [textBlock(ok ? "Sent to \(panel.title)" : "Error: terminal send failed")]
            }
            // 2. Inline port lookup (port still in chat, not popped out)
            if let bridge = appState.findInlineBridge(by: name),
               let tb = bridge.terminalBridge {
                let ok = tb.sendToFirst(data: processed)
                if ok, let sid = tb.firstActiveSessionId {
                    let inlineTitle = appState.inlinePorts()
                        .first(where: { $0.id == name })?.title ?? name
                    autoStartOutputBridge(portTitle: inlineTitle, termBridge: tb, sessionId: sid)
                }
                return [textBlock(ok ? "Sent to inline port" : "Error: terminal send failed")]
            }
            // 3. Title fuzzy fallback (floating panels)
            if let session = appState.portWindows.terminalSession(forPortNamed: name) {
                let ok = session.bridge.send(sessionId: session.sessionId, data: processed)
                if ok {
                    autoStartOutputBridge(portTitle: name, termBridge: session.bridge, sessionId: session.sessionId)
                }
                return [textBlock(ok ? "Sent to \(name)" : "Error: failed to send to terminal")]
            }
            // 4. Useful error listing available terminal ports (floating + inline)
            let floatingAvail = appState.portWindows.allPorts()
                .filter { $0.capabilities.contains("terminal") }.map { "'\($0.title)' (id: \($0.udid))" }
            let inlineAvail = appState.inlinePorts()
                .filter { $0.capabilities.contains("terminal") }.map { "'\($0.title)' (id: \($0.id), status: inline)" }
            let available = (floatingAvail + inlineAvail).joined(separator: ", ")
            let hint = available.isEmpty
                ? "No ports have active terminal sessions. Create a terminal port first."
                : "Available terminal ports: \(available)"
            return [textBlock("Error: no terminal port found for '\(name)'. \(hint)")]

        case "terminal_list":
            let terminals = appState.portWindows.portsWithTerminals()
            if terminals.isEmpty {
                return [textBlock("No ports have active terminal sessions.")]
            }
            let list = terminals.map { t -> [String: Any] in
                let info: [String: Any] = [
                    "id":           t.portId,
                    "name":         t.name,
                    "sessionId":    t.sessionId,
                    "capabilities": ["terminal"],
                    "createdBy":    t.createdBy ?? "unknown",
                    "bridged":      appState.bridgedTerminalNames.contains(t.name.lowercased())
                ]
                return info
            }
            return [textBlock(jsonString(list))]

        case "terminal_bridge":
            guard let name = input["name"] as? String else {
                return [textBlock("Error: missing 'name' parameter")]
            }
            guard let termSession = appState.portWindows.terminalSession(forPortNamed: name) else {
                return [textBlock("Error: no terminal found for port '\(name)'")]
            }
            if appState.bridgedTerminalNames.contains(name.lowercased()) {
                return [textBlock("Already bridging '\(name)' to this conversation")]
            }
            autoStartOutputBridge(portTitle: name, termBridge: termSession.bridge, sessionId: termSession.sessionId)
            return [textBlock("Bridging '\(name)' output to this conversation")]

        case "terminal_unbridge":
            guard let name = input["name"] as? String else {
                return [textBlock("Error: missing 'name' parameter")]
            }
            let key = name.lowercased()
            if appState.bridgedTerminalNames.remove(key) != nil {
                Self.outputBatchers.removeValue(forKey: key)
                if let chId = channelId { appState.stopTerminalLoop(channelId: chId) }
                NSLog("[Port42] Terminal bridge stopped: %@", name)
                return [textBlock("Stopped bridging '\(name)'")]
            }
            return [textBlock("'\(name)' was not being bridged")]

        // MARK: Filesystem
        case "file_read":
            guard let path = input["path"] as? String else {
                return [textBlock("Error: missing 'path' parameter")]
            }
            let encoding = input["encoding"] as? String ?? "utf8"
            let result = fileBridge.read(path: path, opts: ["encoding": encoding])
            return [textBlock(jsonString(result))]

        case "file_write":
            guard let path = input["path"] as? String,
                  let data = input["data"] as? String else {
                return [textBlock("Error: missing 'path' or 'data' parameter")]
            }
            let encoding = input["encoding"] as? String ?? "utf8"
            let result = fileBridge.write(path: path, data: data, opts: ["encoding": encoding])
            return [textBlock(jsonString(result))]

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
        guard let appState = appState, let channelId = channelId else { return }

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
            channelId: channelId,
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

    /// Execute a shell command synchronously with timeout.
    private func executeCommand(_ command: String, cwd: String?, timeout: Int) async -> String {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]
                if let cwd = cwd {
                    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
                }

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: "Error launching command: \(error.localizedDescription)")
                    return
                }

                // Timeout
                let deadline = DispatchTime.now() + .seconds(timeout)
                DispatchQueue.global().asyncAfter(deadline: deadline) {
                    if process.isRunning {
                        process.terminate()
                    }
                }

                process.waitUntilExit()

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let outStr = String(data: outData, encoding: .utf8) ?? ""
                let errStr = String(data: errData, encoding: .utf8) ?? ""

                let exitCode = process.terminationStatus
                var result = outStr
                if !errStr.isEmpty {
                    result += "\n[stderr]: \(errStr)"
                }
                if exitCode != 0 {
                    result += "\n[exit code: \(exitCode)]"
                }
                // Limit output size
                if result.count > 50_000 {
                    result = String(result.prefix(50_000)) + "\n... (truncated)"
                }
                continuation.resume(returning: result.isEmpty ? "(no output)" : result)
            }
        }
    }
}

// MARK: - Output Batcher

/// Batches terminal output, strips ANSI, and posts to a channel or swim as messages.
@MainActor
final class OutputBatcher {
    private let portName: String
    private let channelId: String
    private let companionName: String
    private weak var appState: AppState?
    private var buffer = ""
    private var flushTimer: Timer?
    private var lastPosted = ""

    init(portName: String, channelId: String, companionName: String, appState: AppState?) {
        self.portName = portName
        self.channelId = channelId
        self.companionName = companionName
        self.appState = appState
    }

    func receive(_ raw: String) {
        buffer += raw
        // Show bridge indicator immediately when data arrives
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.appState?.noteBridgeActivity(channelId: self.channelId, companionName: self.companionName, portName: self.portName)
        }
        // Debounce: flush after 10s of quiet
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.flush()
            }
        }
        // Force flush if buffer gets large
        if buffer.count > 8000 {
            flush()
        }
    }

    private func flush() {
        flushTimer?.invalidate()
        guard !buffer.isEmpty else {
            buffer = ""
            return
        }

        let cleaned = OutputBatcher.stripANSI(buffer)
        buffer = ""

        let trimmed = OutputBatcher.collapseAndFilter(cleaned)
        guard !trimmed.isEmpty else { return }

        // Skip if identical to last posted (avoids repeated prompts)
        guard trimmed != lastPosted else { return }
        lastPosted = trimmed

        // Truncate long output
        let content = trimmed.count > 2000 ? String(trimmed.prefix(2000)) + "\n… (truncated)" : trimmed

        guard let appState else { return }
        // Show bridge-active indicator in chat (silent — no message posted)
        appState.noteBridgeActivity(channelId: channelId, companionName: companionName, portName: portName)
        // Feed cleaned output to the game loop (drives the agent↔terminal loop)
        appState.terminalLoop(for: channelId)?.receiveOutput(content)
    }

    /// Full bridge filter: collapses \r overwrites, drops noise, collapses build phases,
    /// deduplicates, and caps output so 800 lines of noise becomes ~5 lines of signal.
    static func collapseAndFilter(_ str: String) -> String {
        // 1. CR collapse — keep only the last \r segment per visual line
        let rows = str.components(separatedBy: "\n").map { row -> String in
            (row.components(separatedBy: "\r").last ?? row)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2. Drop noise lines, collapse build phases, dedup
        let spinnerChars = CharacterSet(charactersIn: "✻✶✳✽✢·⟡◐◑◒◓⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
        let signalPatterns: [NSRegularExpression] = [
            "error[: ]", "warning[: ]", "fatal[: ]",
            "^build complete", "^build failed", "^failed", "^passed",
            "^error\\[", "undefined symbol", "exited with code",
            "wrote ", "saved ", "created ", "deleted ", "updated ",
            "^\\$\\s", "^>\\s", "^⏺", "file written", "\\.(swift|go|ts|js|py|rs):.*error"
        ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

        func isSignal(_ t: String) -> Bool {
            let range = NSRange(t.startIndex..., in: t)
            return signalPatterns.contains { $0.firstMatch(in: t, range: range) != nil }
        }

        func isNoise(_ t: String) -> Bool {
            guard !t.isEmpty else { return true }
            // Single character
            if t.count == 1 { return true }
            // Only spinner/symbol chars and whitespace
            let nonSpaceScalars = t.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }
            if nonSpaceScalars.allSatisfy({ spinnerChars.contains($0)
                || $0.properties.generalCategory == .otherSymbol
                || $0.properties.generalCategory == .mathSymbol }) { return true }
            // Token counter: optional spinner chars then digits only  e.g. "✻ 1337"
            let stripped = t.unicodeScalars.filter { !spinnerChars.contains($0) && !CharacterSet.whitespaces.contains($0) }
            if stripped.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) { return true }
            // Spinner word pattern: optional glyphs + word ending in "ing…" or "ing..."
            if let r = try? NSRegularExpression(pattern: "^[✻✶✳✽✢·⟡◐◑◒◓⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏\\s]*\\w+ing[…\\.]+\\s*$"),
               r.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil { return true }
            // (thinking)
            if t == "(thinking)" { return true }
            // compiler notes (not warnings/errors)
            if t.hasPrefix("note: ") { return true }
            return false
        }

        // Build phase collapse
        let buildPhasePattern = try? NSRegularExpression(
            pattern: "^(?:\\[\\d+/\\d+\\]\\s+)?(?:Compiling|Linking|Build input file|Merging module|Emitting module)",
            options: .caseInsensitive)

        func buildPhasePrefix(_ t: String) -> String? {
            guard let r = buildPhasePattern,
                  let m = r.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                  let range = Range(m.range, in: t) else { return nil }
            // Normalise to bare verb: "Compiling", "Linking" etc
            let raw = String(t[range]).trimmingCharacters(in: .whitespaces)
            if raw.lowercased().contains("compil") { return "Compiling" }
            if raw.lowercased().contains("link") { return "Linking" }
            if raw.lowercased().contains("emit") { return "Emitting" }
            if raw.lowercased().contains("merg") { return "Merging" }
            return "Building"
        }

        var output: [String] = []
        var seen: Set<String> = []
        var currentPhase: String? = nil
        var phaseCount = 0

        func flushPhase() {
            guard let phase = currentPhase, phaseCount > 0 else { return }
            let summary = phaseCount == 1 ? "\(phase) 1 file…" : "\(phase) \(phaseCount) files…"
            if !seen.contains(summary) {
                output.append(summary)
                seen.insert(summary)
            }
            currentPhase = nil
            phaseCount = 0
        }

        for t in rows {
            guard !isNoise(t) else { continue }

            if let phase = buildPhasePrefix(t) {
                if phase == currentPhase {
                    phaseCount += 1
                } else {
                    flushPhase()
                    currentPhase = phase
                    phaseCount = 1
                }
                continue
            }

            // Non-build-phase line: flush any pending phase summary first
            flushPhase()

            // Dedup within window
            if seen.contains(t) { continue }
            seen.insert(t)
            output.append(t)
        }
        flushPhase()

        // Cap to 60 lines
        let capped = output.count > 60 ? Array(output.suffix(60)) : output
        return capped.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip ANSI escape sequences for clean text.
    static func stripANSI(_ str: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "\\x1b(?:\\[[0-9;?]*[a-zA-Z]|\\].*?(?:\\x07|\\x1b\\\\)|[()][0-9A-Za-z]|[>=<]|\\[\\?[0-9;]*[hl])",
            options: []
        ) else { return str }
        let range = NSRange(str.startIndex..., in: str)
        var result = regex.stringByReplacingMatches(in: str, range: range, withTemplate: "")
        result = result.replacingOccurrences(of: "\r", with: "")
        return result
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
        self.internalExecutor = ToolExecutor(appState: appState, channelId: nil, createdBy: senderName)
    }

    public func execute(method: String, input: [String: Any]) async -> Any {
        // Map dot-notation "terminal.exec" -> underscore "terminal_exec" for ToolExecutor
        let toolName = method.replacingOccurrences(of: ".", with: "_")

        // Pre-grant permissions the user has marked "Always Allow" in Settings
        if let perm = ToolDefinitions.permission(for: toolName) {
            let key: String?
            switch perm {
            case .terminal: key = "remoteAllowTerminal"
            case .filesystem: key = "remoteAllowFS"
            case .screen: key = "remoteAllowScreen"
            default: key = nil
            }
            if let key, UserDefaults.standard.bool(forKey: key) {
                internalExecutor.pregrant(perm)
            }
        }

        // Pass the full JSON input directly — no manual argument mapping needed
        let result = await internalExecutor.execute(name: toolName, input: input)

        if let first = result.first {
            return (first["text"] as? String) ?? first
        }
        return ["error": "empty result"]
    }
}
