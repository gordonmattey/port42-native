import Foundation
import AppKit

/// Executes tool calls from LLM companions against port42 bridge APIs.
/// One instance per conversation (channel handler or swim session).
@MainActor
public final class ToolExecutor {
    private weak var appState: AppState?
    private let channelId: String?

    /// Granted permissions for this conversation (per-companion, per-conversation).
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

    init(appState: AppState, channelId: String?) {
        self.appState = appState
        self.channelId = channelId
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
