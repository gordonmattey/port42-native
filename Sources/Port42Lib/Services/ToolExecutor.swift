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
            // Floating + docked panels
            let floating = appState.portWindows.allPorts()
            // Inline ports (rendered in chat, not yet popped out) — scoped to this channel, last 5
            let inline = appState.inlinePorts().filter { $0.channelId == channelId || channelId == nil }.suffix(5)
            // Merge into uniform shape
            typealias PortInfo = (id: String, title: String, createdBy: String?, hasTerminal: Bool, status: String)
            let all: [PortInfo] = floating.map { (id: $0.udid, title: $0.title, createdBy: $0.createdBy, hasTerminal: $0.hasTerminal, status: $0.isBackground ? "docked" : "floating") }
                + inline.map { (id: $0.id, title: $0.title, createdBy: $0.createdBy, hasTerminal: $0.hasTerminal, status: "inline") }
            let filtered = filterCaps.isEmpty ? all : all.filter { p in
                filterCaps.allSatisfy { cap in cap == "terminal" ? p.hasTerminal : false }
            }
            if filtered.isEmpty {
                let msg = filterCaps.isEmpty ? "No active ports." : "No ports with capabilities: \(filterCaps.joined(separator: ", "))"
                return [textBlock(msg)]
            }
            let lines = filtered.map { p -> String in
                var caps: [String] = []
                if p.hasTerminal { caps.append("terminal") }
                let capsStr = caps.isEmpty ? "[]" : "[" + caps.joined(separator: ", ") + "]"
                let creator = p.createdBy ?? "unknown"
                return "title: \(p.title)\nid: \(p.id)\ncapabilities: \(capsStr)\nstatus: \(p.status)\ncreatedBy: \(creator)"
            }
            let header = "\(lines.count) port\(lines.count == 1 ? "" : "s"):"
            return [textBlock(header + "\n\n" + lines.joined(separator: "\n\n"))]

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
            if let html = try? appState.db.fetchPortHtml(udid: id) {
                return [textBlock(html)]
            }
            return [textBlock("Error: no port found for id '\(id)'")]

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
            let chId = channelId ?? appState.currentChannel?.id ?? ""
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
            let chId = channelId ?? appState.currentChannel?.id ?? ""
            guard let user = appState.currentUser else {
                return [textBlock("Error: no user")]
            }
            let msg = Message(
                id: UUID().uuidString, channelId: chId,
                senderId: user.id, senderName: user.displayName,
                senderType: "human", content: text,
                timestamp: Date(), replyToId: nil,
                syncStatus: "local", createdAt: Date()
            )
            try appState.db.saveMessage(msg)
            appState.sync.sendMessage(msg)
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
                return [imageBlock(base64: base64, mediaType: "image/png")]
            }
            return [textBlock(jsonString(result))]

        case "screen_windows":
            let result = await screenBridge.windows()
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
                    autoStartOutputBridge(portTitle: bridge.messageId ?? name, termBridge: tb, sessionId: sid)
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
                .filter(\.hasTerminal).map { "'\($0.title)' (id: \($0.udid))" }
            let inlineAvail = appState.inlinePorts()
                .filter(\.hasTerminal).map { "'\($0.title)' (id: \($0.id), status: inline)" }
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

    /// Collapse \r overwrites (simulate terminal line rewriting) then filter noise lines.
    static func collapseAndFilter(_ str: String) -> String {
        // Simulate carriage-return overwrites: split into \n-separated rows,
        // within each row keep only the last \r-segment (final written state).
        let rows = str.components(separatedBy: "\n")
        let collapsed = rows.map { row -> String in
            // CR resets the current line; keep only what was last written
            let segments = row.components(separatedBy: "\r")
            return segments.last ?? row
        }

        // Filter out noise lines produced by CLI spinners / progress animations
        let meaningful = collapsed.filter { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return false }
            // Pure spinner chars: lines whose non-space scalars are all symbols/misc
            if t.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .otherSymbol
                || $0.properties.generalCategory == .mathSymbol
                || CharacterSet.whitespaces.contains($0) }) { return false }
            // Single-char lines (spinner tick) or tiny numeric-only frames
            if t.count <= 2, t.unicodeScalars.allSatisfy({ !$0.properties.isAlphabetic }) { return false }
            return true
        }

        // Cap to last 60 lines so chat stays readable
        let capped = meaningful.count > 60 ? Array(meaningful.suffix(60)) : meaningful
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
