import Foundation
import AppKit
import WebKit

// MARK: - BridgeMethods (Phase 1 — one implementation per method)
//
// The registry is built from an `AppState`; each method body captures it, exactly as the two
// executors do today. Phase 1 moves the two switch statements' bodies here one family at a time,
// each proven equal to the old path by `BridgeParityHarness` before the switches are deleted (Phase 2).
//
// Families landed:
//   - relationship memory (crease / engrave / fold / position)   ← this file, first batch

@MainActor
public func buildBridgeRegistry(_ appState: AppState) -> BridgeRegistry {
    var r: BridgeRegistry = [:]
    registerMemoryMethods(into: &r, appState: appState)
    registerStorageMethods(into: &r, appState: appState)
    registerPortMethods(into: &r, appState: appState)
    registerCommsMethods(into: &r, appState: appState)
    registerFileMethods(into: &r, appState: appState)
    registerDeviceMethods(into: &r, appState: appState)
    registerLiveDeviceMethods(into: &r, appState: appState)
    registerPortLiveMethods(into: &r, appState: appState)
    return r
}

// MARK: Streaming registry (item 8)
//
// ai.complete is the one streaming method (LLM engine → yield → final). Registered in the
// self-describing shape (item 8 spike): it carries its own description + inputSchema, from which
// `anthropicToolSchema` generates the tool-use schema. `ai.cancel` stays at the adapter (callId → Task
// cancellation is a port-JS-shim concept, not a registry method).
@MainActor
public func buildBridgeStreamRegistry(_ appState: AppState) -> BridgeStreamRegistry {
    var r: BridgeStreamRegistry = [:]

    r["ai.complete"] = BridgeStreamMethod(
        permission: .ai,
        paramNames: ["prompt", "options"],
        description: "Complete a prompt with an LLM, streaming tokens back. Returns the full text.",
        inputSchema: [
            "type": "object",
            "properties": [
                "prompt": ["type": "string", "description": "The prompt to complete."] as [String: Any],
                "options": [
                    "type": "object",
                    "description": "Optional: model, systemPrompt, maxTokens, images (base64 PNG).",
                    "properties": [
                        "model": ["type": "string"] as [String: Any],
                        "systemPrompt": ["type": "string"] as [String: Any],
                        "maxTokens": ["type": "integer"] as [String: Any],
                        "images": ["type": "array", "items": ["type": "string"] as [String: Any]] as [String: Any]
                    ] as [String: Any]
                ] as [String: Any]
            ] as [String: Any],
            "required": ["prompt"]
        ]
    ) { principal, args, yield in
        // A parked/backgrounded/paused port must not reach the model (the token-burn guard). Only a
        // port principal maps to a suspendable surface; gateway/companion callers are never suspended.
        let bridge = appState.streamPortBridge(for: principal)
        if let bridge, bridge.isSuspended {
            throw BridgeError(code: "port_paused",
                              message: "port is paused (parked or backgrounded). Bring it to the desktop to use AI.")
        }

        let prompt = try args.requireString("prompt")
        guard !prompt.isEmpty else {
            throw BridgeError(code: "bad_args", message: "ai.complete requires a prompt")
        }
        let opts = args.object("options")
        let createdBy = appState.createdBy(for: principal, bridge: bridge)
        let model = opts?["model"] as? String ?? appState.resolvePortAIModel(createdBy: createdBy)
        let systemPrompt = opts?["systemPrompt"] as? String ?? "You are a helpful assistant."
        let maxTokens = opts?["maxTokens"] as? Int ?? appState.portAIMaxTokens
        let images = opts?["images"] as? [String]

        let backend = appState.resolveStreamBackend(createdBy: createdBy)
        backend.trackingSource = "port:\(principal.displayName)"

        // Build the user message (multimodal if images provided).
        let content: Any
        if let images, !images.isEmpty {
            var blocks: [[String: Any]] = images.map { base64 in
                ["type": "image",
                 "source": ["type": "base64", "media_type": "image/png", "data": base64] as [String: String]]
            }
            blocks.append(["type": "text", "text": prompt])
            content = blocks
        } else {
            content = prompt
        }
        let messages: [[String: Any]] = [["role": "user", "content": content]]

        return try await appState.runLLMStream(
            backend: backend, messages: messages, systemPrompt: systemPrompt,
            model: model, maxTokens: maxTokens, yield: yield)
    }

    r["companions.invoke"] = BridgeStreamMethod(
        permission: .ai,
        paramNames: ["identifier", "prompt"],
        description: "Invoke a companion (by id or name) with a prompt; streams its reply. The companion sees recent space context and replies to the caller, not the chat.",
        inputSchema: [
            "type": "object",
            "properties": [
                "identifier": ["type": "string", "description": "Companion id or display name."] as [String: Any],
                "prompt": ["type": "string", "description": "What to ask the companion."] as [String: Any]
            ] as [String: Any],
            "required": ["identifier"]
        ]
    ) { principal, args, yield in
        let identifier = try args.requireString("identifier")
        guard !identifier.isEmpty else {
            throw BridgeError(code: "bad_args", message: "companions.invoke requires a companion id or name")
        }
        let prompt = args.string("prompt") ?? ""

        let companion = appState.companions.first(where: { $0.id == identifier })
            ?? appState.companions.first(where: { $0.displayName.lowercased() == identifier.lowercased() })
        guard let companion else {
            throw BridgeError(code: "not_found", message: "companion not found: \(identifier)")
        }
        guard companion.mode == .llm else {
            throw BridgeError(code: "not_llm", message: "companion '\(companion.displayName)' is not an LLM companion")
        }

        let bridge = appState.streamPortBridge(for: principal)
        if let bridge, bridge.isSuspended {
            throw BridgeError(code: "port_paused",
                              message: "port is paused (parked or backgrounded). Bring it to the desktop to use AI.")
        }

        let createdBy = appState.createdBy(for: principal, bridge: bridge)
        let model = companion.model ?? appState.resolvePortAIModel(createdBy: createdBy)
        let systemPrompt = appState.companionInvokeSystemPrompt(companion: companion, spaceId: principal.spaceId)
        let messages = appState.companionInvokeMessages(companion: companion, prompt: prompt)
        guard !messages.isEmpty else {
            throw BridgeError(code: "no_messages", message: "no messages to send")
        }

        // The target companion's own backend (fixes a latent bug: the old path always used a bare
        // LLMEngine, so a Gemini companion was invoked through the Anthropic engine). Override for tests.
        let backend = appState.streamBackendOverride?(companion.id) ?? makeLLMBackend(for: companion)
        backend.trackingSource = "port:invoke:\(companion.displayName)"

        return try await appState.runLLMStream(
            backend: backend, messages: messages, systemPrompt: systemPrompt,
            model: model, maxTokens: appState.portAIMaxTokens, yield: yield)
    }

    return r
}

// MARK: Ports (live — the by-id/opts methods duplicated across paths)
//
// port.create/push/exec/manage act on a target port (by id) or create one, and existed in BOTH the
// port-JS and tool-use switches — the real duplication the unification removes. (The self-referential
// port-JS-only methods — setTitle/setCapabilities/close/resize/info — mutate the calling PortBridge
// instance and have no tool-use twin, so they stay on the old port-JS path.) These touch live
// webviews/terminals/shell, so they are verified live in Port42Dev, not headless.

@MainActor
private func registerPortLiveMethods(into r: inout BridgeRegistry, appState: AppState) {

    func webView(_ id: String) -> WKWebView? {
        appState.portWindows.webViews[id] ?? appState.findInlineBridge(by: id)?.webView
    }

    r["port.create"] = BridgeMethod(permission: nil, paramNames: ["options"],
        description: "Create a port and return its id. The uniform way to make any port. type:\"web\" needs html (a full port HTML body) and renders inline in chat. type:\"terminal\" needs command and opens a native terminal (runs in /bin/zsh; the command is typed in — claude/gemini get the Port42 hooks). For terminals you may also pass args, cwd, systemPrompt (companion personality), and env. Drive the result with port_push (input to terminals, data to web ports) and list with ports_list. Pass space_id to target a space (default: current).",
        inputSchema: [
            "type": "object",
            "properties": [
                "type": ["type": "string", "enum": ["web", "terminal"], "description": "The port type to create."],
                "title": ["type": "string", "description": "Port title (default: derived from html <title>, or the command)."],
                "html": ["type": "string", "description": "type:\"web\" — full port HTML body (include a <title> and <meta name=\"version\">)."],
                "command": ["type": "string", "description": "type:\"terminal\" — executable/CLI to run (e.g. \"bash\", \"htop\", \"claude\")."],
                "args": ["type": "array", "items": ["type": "string"], "description": "type:\"terminal\" — arguments for the command."],
                "cwd": ["type": "string", "description": "type:\"terminal\" — working directory (default: home)."],
                "systemPrompt": ["type": "string", "description": "type:\"terminal\" — companion personality/role appended to the CLI's system prompt."],
                "env": ["type": "object", "description": "type:\"terminal\" — custom environment variables for the shell."],
                "space_id": ["type": "string", "description": "Space to create the port in (default: current space)."]
            ],
            "required": ["type"]
        ] as [String: Any]) { p, args in
        let o = args.object("options") ?? args.dictionary
        let sid = (o["space_id"] as? String) ?? p.spaceId ?? appState.currentSpace?.id ?? ""
        let result = appState.createPort(
            type: o["type"] as? String, title: o["title"] as? String, html: o["html"] as? String,
            command: o["command"] as? String, args: o["args"] as? [String] ?? [], cwd: o["cwd"] as? String,
            systemPrompt: o["systemPrompt"] as? String, env: o["env"] as? [String: String] ?? [:],
            spaceId: sid, createdBy: p.id, createdByName: p.displayName,
            presentation: o["presentation"] as? String)
        if let err = result["error"] as? String { throw BridgeError.badArg(err) }
        return .fromJSONObject(result)   // { id, title }
    }

    r["port.push"] = BridgeMethod(permission: nil, paramNames: ["id", "data"],
        description: "Send input to a port — one verb, dispatched by the port's type. A WEB port receives the data as a 'port42:data' CustomEvent with the payload in event.detail. A TERMINAL port receives the data as raw keystrokes typed into the shell (include your own newline, e.g. \"ls\\n\", to run a command — it is NOT added for you). Use the id from ports_list. Prefer this over port_exec for data transfer.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The port's UDID (from ports_list), or a terminal's name."],
                "data": ["description": "For web ports: any JSON value (object/array/string/number) delivered as event.detail. For terminal ports: a string of raw keystrokes (include \\n to execute)."]
            ],
            "required": ["id", "data"]
        ]) { _, args in
        let id = try args.requireString("id")
        let data = args.any("data") ?? NSNull()
        let controller = appState.resolveTerminalController(idOrName: id)
        let wv = webView(id)
        switch PortPushRoute.classify(isTerminal: controller != nil, isWeb: wv != nil) {
        case .terminal:
            let str = (data as? String) ?? (String(data: (try? JSONSerialization.data(withJSONObject: data, options: [.fragmentsAllowed])) ?? Data(), encoding: .utf8) ?? "")
            guard controller!.sendRaw(str) else { throw BridgeError(code: "no_surface", message: "terminal '\(id)' has no live surface") }
            return .object(["ok": .bool(true)])
        case .web:
            guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: [.fragmentsAllowed]),
                  let jsonStr = String(data: jsonData, encoding: .utf8) else {
                throw BridgeError.badArg("could not serialize data to JSON")
            }
            _ = try? await wv!.evaluateJavaScript("window.dispatchEvent(new CustomEvent('port42:data', {detail: \(jsonStr)}))")
            return .object(["ok": .bool(true)])
        case .notFound:
            throw BridgeError.notFound("port '\(id)'")
        }
    }

    r["port.exec"] = BridgeMethod(permission: nil, paramNames: ["id", "js"],
        description: "Execute JavaScript on a live port. Use this to call functions, push data, or update state on an existing port without replacing its HTML. The JS runs in the port's webview context with access to window, document, and any globals the port defines.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The port's UDID (from ports_list)"],
                "js": ["type": "string", "description": "JavaScript code to execute in the port's context. Return a value to get it back in the response."]
            ],
            "required": ["id", "js"]
        ]) { _, args in
        let id = try args.requireString("id")
        let js = try args.requireString("js")
        guard let wv = webView(id) else { throw BridgeError.notFound("port '\(id)'") }
        // #5: PortExecJS awaits promises + marshals objects; nil = undefined/no-return.
        guard let result = try await PortExecJS.run(wv, js) else { return .object(["ok": .bool(true)]) }
        return .fromJSONObject(result)
    }

    r["port.manage"] = BridgeMethod(permission: nil, paramNames: ["id", "action"],
        description: "Manage a port. Actions: focus (raise to the front of the desktop), close, minimize/dock (off the desktop but still running), restore/undock (bring a docked/inline port onto the desktop as a tile). Check the status field from ports_list — 'tiled' | 'parked' | 'docked' | 'inline'.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The port's UDID or title"],
                "action": ["type": "string", "description": "One of: focus, close, minimize, dock, restore, undock"]
            ],
            "required": ["id", "action"]
        ]) { _, args in
        let id = try args.requireString("id")
        let action = try args.requireString("action")
        guard let panel = appState.portWindows.findPort(by: id) else { throw BridgeError.notFound("port '\(id)'") }
        switch action {
        case "focus":
            appState.portWindows.bringToFront(panel.id)
        case "background":
            await appState.shell?.setBackgroundPort(id: panel.udid)
        case "unbackground":
            await appState.shell?.setBackgroundPort(id: nil)
        case "close":
            appState.portWindows.close(panel.id)
        case "minimize", "dock":
            appState.portWindows.minimize(panel.id)
        case "restore", "undock":
            if panel.presentation == "inline" {
                appState.portWindows.undockInline(id: panel.id, in: CGSize(width: 800, height: 600))
            } else {
                _ = appState.portWindows.restore(panel.id)
            }
        default:
            throw BridgeError.badArg("unknown action '\(action)'. Use: focus, close, dock, undock, background, unbackground")
        }
        return .object(["ok": .bool(true)])
    }

    // terminal.exec — the one gated terminal method (headless run-and-capture). Shared ShellExec, in
    // both old paths. Returns { output }.
    r["terminal.exec"] = BridgeMethod(permission: .terminal, paramNames: ["command", "options"],
        description: "Execute a shell command and return the output. Runs in /bin/zsh.",
        inputSchema: [
            "type": "object",
            "properties": [
                "command": ["type": "string", "description": "The shell command to execute"],
                "cwd": ["type": "string", "description": "Working directory (default: home)"],
                "timeout": ["type": "integer", "description": "Timeout in seconds (default: 30, max: 120)"]
            ],
            "required": ["command"]
        ]) { _, args in
        let command = try args.requireString("command")
        guard !command.isEmpty else { throw BridgeError.badArg("terminal.exec requires a command string") }
        let opts = args.object("options") ?? args.dictionary
        let cwd = opts["cwd"] as? String
        let timeout = min((opts["timeout"] as? Int) ?? 30, 120)
        let output = await ShellExec.run(command, cwd: cwd, timeout: timeout)
        return .object(["output": .string(output)])
    }
}

// MARK: Devices (request/response hardware — thin wrappers)
//
// Extracted during the Phase-2 live pass. Thin pass-throughs to the existing device bridges (one
// shared instance each), converting the bridge's `[String: Any]` to a BridgeValue. The image methods
// return a top-level `.data`, so tool-use renders a real Anthropic image block (the model sees the
// pixels) while JS/gateway get the base64 string; width/height are dropped (use `screen.displays` for
// geometry). Streaming/stateful methods (audio.capture, camera/screen stream, browser sessions, the
// live port push/exec/manage) and rest.call (URLRequest + secret injection) stay on the old path.

@MainActor
private func registerLiveDeviceMethods(into r: inout BridgeRegistry, appState: AppState) {
    let screen = ScreenBridge()
    let camera = CameraBridge()
    let notifications = NotificationBridge()
    let automation = AutomationBridge()
    let audio = AudioBridge()

    r["screen.capture"] = BridgeMethod(permission: .screen, paramNames: ["scale"],
        description: "Capture a screenshot of the screen. Returns a base64 PNG image.",
        inputSchema: [
            "type": "object",
            "properties": [
                "scale": ["type": "number", "description": "Image scale factor 0.1-2.0 (default 1.0)"]
            ]
        ]) { _, args in
        let scale = args.double("scale") ?? 1.0
        let result = await screen.capture(opts: ["scale": scale, "includeSelf": false])
        if let base64 = result["image"] as? String { return .data(base64: base64, mime: "image/png") }
        return .fromJSONObject(result)
    }

    r["screen.windows"] = BridgeMethod(permission: .screen,
        description: "List all visible windows with their titles, apps, and positions",
        inputSchema: ["type": "object", "properties": [String: Any]()]) { _, _ in
        .fromJSONObject(await screen.windows())
    }

    r["camera.capture"] = BridgeMethod(permission: .camera, paramNames: ["scale"],
        description: "Capture a photo from the device camera. Returns a base64 PNG image.",
        inputSchema: ["type": "object", "properties": [String: Any]()]) { _, args in
        let result = await camera.capture(opts: args.double("scale").map { ["scale": $0] } ?? [:])
        if let base64 = result["image"] as? String { return .data(base64: base64, mime: "image/png") }
        return .fromJSONObject(result)
    }

    r["notify.send"] = BridgeMethod(permission: .notification, paramNames: ["title", "body", "options"],
        description: "Send a macOS system notification",
        inputSchema: [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": "Notification title"],
                "body": ["type": "string", "description": "Notification body text"]
            ],
            "required": ["title", "body"]
        ]) { _, args in
        let title = try args.requireString("title")
        let body = args.string("body") ?? ""
        return .fromJSONObject(await notifications.send(title: title, body: body, opts: args.object("options")))
    }

    r["automation.runAppleScript"] = BridgeMethod(permission: .automation, paramNames: ["source", "timeout"],
        description: "Execute AppleScript code and return the result. Use this to control other applications on macOS.",
        inputSchema: [
            "type": "object",
            "properties": [
                "source": ["type": "string", "description": "AppleScript source code"],
                "timeout": ["type": "integer", "description": "Timeout in seconds (default: 30, max: 120)"]
            ],
            "required": ["source"]
        ]) { _, args in
        let source = try args.requireString("source")
        return .fromJSONObject(await automation.runAppleScript(source: source, opts: ["timeout": args.int("timeout") ?? 30]))
    }

    r["automation.runJXA"] = BridgeMethod(permission: .automation, paramNames: ["source", "timeout"],
        description: "Execute JavaScript for Automation (JXA) code and return the result. Use this to control other applications on macOS.",
        inputSchema: [
            "type": "object",
            "properties": [
                "source": ["type": "string", "description": "JXA source code"],
                "timeout": ["type": "integer", "description": "Timeout in seconds (default: 30, max: 120)"]
            ],
            "required": ["source"]
        ]) { _, args in
        let source = try args.requireString("source")
        return .fromJSONObject(await automation.runJXA(source: source, opts: ["timeout": args.int("timeout") ?? 30]))
    }

    r["audio.speak"] = BridgeMethod(permission: nil, paramNames: ["text", "options"],
        description: "Speak text aloud using text-to-speech",
        inputSchema: [
            "type": "object",
            "properties": [
                "text": ["type": "string", "description": "Text to speak"],
                "rate": ["type": "number", "description": "Speech rate 0.1-1.0 (default 0.5)"]
            ],
            "required": ["text"]
        ]) { _, args in
        let text = try args.requireString("text")
        return .fromJSONObject(await audio.speak(text: text, opts: args.object("options")))
    }

    r["audio.play"] = BridgeMethod(permission: nil, paramNames: ["data", "options"]) { _, args in
        let data = try args.requireString("data")
        return .fromJSONObject(audio.play(data: data, opts: args.object("options")))
    }

    r["audio.stop"] = BridgeMethod(permission: nil) { _, _ in
        .fromJSONObject(audio.stop())
    }
}

// MARK: Devices (headless-safe subset)
//
// The last methods that can be verified without hardware or UI: clipboard (NSPasteboard) and
// screen.displays (NSScreen). screen.displays is the canonical shape for what the tool surface called
// `screen_info` — a structured array of display objects on every surface, not a text blob. The rest of
// the device families (screen.capture / camera / audio / notify / browser / automation / rest) and the
// live port methods (create / push / exec / manage) touch real hardware, the network, or a live
// surface, so they are extracted during Phase-2 wiring where they can be exercised live.

@MainActor
private func registerDeviceMethods(into r: inout BridgeRegistry, appState: AppState) {
    let clipboard = ClipboardBridge()

    r["clipboard.read"] = BridgeMethod(permission: .clipboard,
        description: "Read the current clipboard contents. Returns text or base64 image data.",
        inputSchema: ["type": "object", "properties": [String: Any]()]) { _, _ in
        .fromJSONObject(clipboard.read())
    }

    r["clipboard.write"] = BridgeMethod(permission: .clipboard, paramNames: ["data"],
        description: "Write text to the system clipboard",
        inputSchema: [
            "type": "object",
            "properties": [
                "data": ["type": "string", "description": "The text to copy to clipboard"]
            ],
            "required": ["data"]
        ]) { _, args in
        guard let data = args.any("data") else { throw BridgeError.missingArg("data") }
        return .fromJSONObject(clipboard.write([data]))
    }

    // No permission (docs: "no permissions required"). NSScreen, structured array — the canonical
    // form of the old `screen_info` text blob.
    r["screen.displays"] = BridgeMethod(permission: nil,
        description: "Get display information: size, position, and visible area (excluding dock/menubar) for all connected displays. No screen recording permission required. Use this to calculate port positions before calling port_move.",
        inputSchema: [
            "type": "object",
            "properties": [String: Any](),
            "required": [String]()
        ]) { _, _ in
        .array(NSScreen.screens.map { screen in
            let f = screen.frame
            let v = screen.visibleFrame
            return .object([
                "width": .double(Double(f.width)), "height": .double(Double(f.height)),
                "x": .double(Double(f.origin.x)), "y": .double(Double(f.origin.y)),
                "visibleWidth": .double(Double(v.width)), "visibleHeight": .double(Double(v.height)),
                "visibleX": .double(Double(v.origin.x)), "visibleY": .double(Double(v.origin.y)),
                "isMain": .bool(screen == NSScreen.main),
            ])
        })
    }
}

// MARK: Files
//
// The two old paths disagreed: JS allowed only user-picked paths (the FileBridge gate); the tool path
// sandboxed relative paths into the Port42 data dir and gated absolute ones. GM: pick a sensible
// default, not blocking. Canonical model = the sandbox: relative paths resolve under the data dir
// (read/write/list/mkdir), which is safe and self-contained. Absolute-path access is a user-consented
// action and routes through the picker (`fs.pick`) — Phase-2 live-only, since it needs the picked-path
// grant carried on the principal. Reads return `{data}`, writes/mkdir return `{ok}`, list returns
// `{items}`.

/// The base directory relative file paths resolve under. Defaults to the Port42 app-support data dir;
/// overridable in tests so file ops run in an isolated temp dir.
public enum BridgeFilePaths {
    public static var dataDir: String = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first!.appendingPathComponent("Port42").path
}

@MainActor
private func registerFileMethods(into r: inout BridgeRegistry, appState: AppState) {

    // Resolve a caller path to an absolute filesystem path INSIDE the data-dir sandbox, or throw.
    // A leading "/" (absolute) is rejected here: it is the picker's job (fs.pick), not free reach.
    func resolve(_ path: String) throws -> String {
        guard !path.hasPrefix("/") else {
            throw BridgeError(code: "absolute_path", message: "absolute paths require a user-picked file — use fs.pick")
        }
        // Block traversal out of the sandbox.
        let joined = (BridgeFilePaths.dataDir as NSString).appendingPathComponent(path)
        let standardized = (joined as NSString).standardizingPath
        guard standardized.hasPrefix((BridgeFilePaths.dataDir as NSString).standardizingPath) else {
            throw BridgeError(code: "escape", message: "path escapes the data directory")
        }
        return standardized
    }

    r["fs.read"] = BridgeMethod(permission: .filesystem, paramNames: ["path", "encoding"], wired: false,
        description: "Read a file. Use a relative path (e.g. \"scopes/strategy/scope.md\") to read from the Port42 data directory without a file picker. Use an absolute path for picker-approved files.",
        inputSchema: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Relative path within Port42 data directory (e.g. \"scopes/strategy/scope.md\") or absolute path for picker-approved files."],
                "encoding": ["type": "string", "description": "utf8 (default) or base64"]
            ],
            "required": ["path"]
        ]) { _, args in
        let path = try resolve(try args.requireString("path"))
        let encoding = args.string("encoding") ?? "utf8"
        do {
            if encoding == "base64" {
                let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
                return .object(["data": .string(bytes.base64EncodedString())])
            }
            let text = try String(contentsOfFile: path, encoding: .utf8)
            return .object(["data": .string(text)])
        } catch {
            throw BridgeError(code: "io", message: error.localizedDescription)
        }
    }

    r["fs.write"] = BridgeMethod(permission: .filesystem, paramNames: ["path", "data", "encoding"], wired: false,
        description: "Write a file. Use a relative path (e.g. \"scopes/strategy/facts.md\") to write to the Port42 data directory — parent directories are created automatically. Use an absolute path for picker-approved files.",
        inputSchema: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Relative path within Port42 data directory (e.g. \"scopes/strategy/facts.md\") or absolute path for picker-approved files."],
                "data": ["type": "string", "description": "Content to write"],
                "encoding": ["type": "string", "description": "utf8 (default) or base64"]
            ],
            "required": ["path", "data"]
        ]) { _, args in
        let path = try resolve(try args.requireString("path"))
        let data = try args.requireString("data")
        let encoding = args.string("encoding") ?? "utf8"
        do {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if encoding == "base64", let bytes = Data(base64Encoded: data) {
                try bytes.write(to: URL(fileURLWithPath: path))
            } else {
                try data.write(toFile: path, atomically: true, encoding: .utf8)
            }
            return .object(["ok": .bool(true)])
        } catch {
            throw BridgeError(code: "io", message: error.localizedDescription)
        }
    }

    r["fs.list"] = BridgeMethod(permission: .filesystem, paramNames: ["path"], wired: false,
        description: "List the contents of a directory in the Port42 data directory. Relative paths only (e.g. \"scopes/strategy\" or \"scopes/strategy/decisions\"). Returns a sorted list of filenames.",
        inputSchema: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Relative path to the directory (e.g. \"scopes/strategy\")"]
            ],
            "required": ["path"]
        ]) { _, args in
        let path = try resolve(try args.requireString("path"))
        do {
            let items = try FileManager.default.contentsOfDirectory(atPath: path)
            return .object(["items": .array(items.sorted().map { .string($0) })])
        } catch {
            throw BridgeError(code: "io", message: error.localizedDescription)
        }
    }

    r["fs.mkdir"] = BridgeMethod(permission: .filesystem, paramNames: ["path"], wired: false,
        description: "Create a directory (and any missing parent directories) in the Port42 data directory. Relative paths only (e.g. \"scopes/strategy/decisions\").",
        inputSchema: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Relative path to create (e.g. \"scopes/strategy/decisions\")"]
            ],
            "required": ["path"]
        ]) { _, args in
        let path = try resolve(try args.requireString("path"))
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return .object(["ok": .bool(true)])
        } catch {
            throw BridgeError(code: "io", message: error.localizedDescription)
        }
    }
}

// MARK: Identity / spaces / companions / messages / bus
//
// Read-mostly, DB-backed, headless-testable. Reads that were hand-serialized JSON become structured
// `BridgeValue` (array/object on every surface); the two send verbs return `{ok}` and are checked by
// side effect. Space + sender resolution now derive from the PRINCIPAL (its space, its display name)
// with an explicit `space_id` arg still able to target another space.

@MainActor
private func registerCommsMethods(into r: inout BridgeRegistry, appState: AppState) {

    func targetSpace(_ p: Principal, _ args: BridgeArgs) -> String {
        args.string("space_id") ?? p.spaceId ?? appState.currentSpace?.id ?? ""
    }
    func senderName(_ p: Principal, _ args: BridgeArgs) -> String {
        if let override = args.string("senderName") ?? args.string("sender_name"), !override.isEmpty { return override }
        if p.kind == .companion, let c = appState.companions.first(where: { $0.id == p.id }) { return c.displayName }
        return appState.currentUser?.displayName ?? "agent"
    }

    r["user.get"] = BridgeMethod(permission: nil,
        description: "Get the current user's identity (id and display name)",
        inputSchema: ["type": "object", "properties": [String: Any]()]) { _, _ in
        guard let user = appState.currentUser else { throw BridgeError(code: "no_user", message: "no user signed in") }
        return .object(["id": .string(user.id), "displayName": .string(user.displayName)])
    }

    r["space.current"] = BridgeMethod(permission: nil, paramNames: ["space_id"],
        description: "Get a space's metadata and member list: { id, name, type, memberCount, members: [{ id, name, type, owner, qualifiedName }] }. Pass space_id to inspect a specific space (e.g. your own PORT42_SPACE_ID); omit it for the currently selected space.",
        inputSchema: [
            "type": "object",
            "properties": [
                "space_id": ["type": "string", "description": "Optional space id to inspect. Defaults to the currently selected space."]
            ]
        ]) { _, args in
        let sid = args.string("space_id")
        guard let ch = (sid.flatMap { id in appState.spaces.first(where: { $0.id == id }) } ?? appState.currentSpace) else {
            throw BridgeError.notFound("space")
        }
        let list = (try? appState.db.getSpaceMembers(spaceId: ch.id)) ?? []
        return .object([
            "id": .string(ch.id), "name": .string(ch.name), "type": .string(ch.type),
            "memberCount": .int(list.count),
            "members": .array(list.map { .fromJSONObject(Port42Members.dict($0)) }),
        ])
    }

    r["space.list"] = BridgeMethod(permission: nil,
        description: "List all spaces the user belongs to",
        inputSchema: ["type": "object", "properties": [String: Any]()]) { _, _ in
        .array(appState.spaces.map { .object(["id": .string($0.id), "name": .string($0.name)]) })
    }

    r["companions.list"] = BridgeMethod(permission: nil, paramNames: ["space_id"],
        description: "List companions with their names, models, and trigger modes. Pass space_id to list only the companions assigned to that space; omit it for the full global roster.",
        inputSchema: [
            "type": "object",
            "properties": [
                "space_id": ["type": "string", "description": "Optional space id to filter companions to that space's members."]
            ]
        ]) { _, args in
        let companions = Port42Members.companions(appState: appState, spaceId: args.string("space_id"))
        return .array(companions.map { c in
            .object([
                "id": .string(c.id), "name": .string(c.displayName),
                "model": .string(c.model ?? "unknown"), "trigger": .string(c.trigger.rawValue),
            ])
        })
    }

    r["companions.get"] = BridgeMethod(permission: nil, paramNames: ["id"],
        description: "Get details about a specific companion by ID",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The companion's ID"]
            ],
            "required": ["id"]
        ]) { _, args in
        let id = try args.requireString("id")
        guard let c = appState.companions.first(where: { $0.id == id }) else {
            throw BridgeError.notFound("companion '\(id)'")
        }
        return .object([
            "id": .string(c.id), "name": .string(c.displayName),
            "model": .string(c.model ?? "unknown"), "systemPrompt": .string(c.systemPrompt ?? ""),
        ])
    }

    r["messages.recent"] = BridgeMethod(permission: nil, paramNames: ["count", "space_id", "topic"],
        description: "Get the most recent messages from the current space",
        inputSchema: [
            "type": "object",
            "properties": [
                "count": ["type": "integer", "description": "Number of messages to retrieve (default 20, max 100)"],
                "topic": ["type": "string", "description": "Message bus topic to read (default 'chat'). Use 'bus' for inter-companion signals, 'system' for join/leave events."]
            ]
        ]) { p, args in
        let count = min(args.int("count") ?? 20, 100)
        let topic = args.string("topic") ?? "chat"
        let msgs = (try? appState.db.getMessages(spaceId: targetSpace(p, args), topic: topic)) ?? []
        return .array(msgs.suffix(count).map { m in
            .object([
                "sender": .string(m.senderName), "content": .string(m.content),
                "timestamp": .double(m.timestamp.timeIntervalSince1970),
            ])
        })
    }

    r["bus.read"] = BridgeMethod(permission: nil, paramNames: ["topic", "limit", "space_id"],
        description: "Read recent messages from a bus topic in the current space. Topics: 'bus' (inter-companion signals), 'system' (join/leave/presence), 'port:{portId}' (port-scoped events).",
        inputSchema: [
            "type": "object",
            "properties": [
                "topic": ["type": "string", "description": "Bus topic to read (e.g. 'bus', 'system', 'port:myPortId')"],
                "limit": ["type": "integer", "description": "Max messages to return (default 20)"],
                "space_id": ["type": "string", "description": "Space ID. Omit for current space."]
            ],
            "required": ["topic"]
        ]) { p, args in
        let topic = try args.requireString("topic")
        let limit = min(args.int("limit") ?? 20, 100)
        let msgs = (try? appState.db.getMessages(spaceId: targetSpace(p, args), topic: topic)) ?? []
        return .array(msgs.suffix(limit).map { m in
            .object([
                "sender": .string(m.senderName), "content": .string(m.content),
                "timestamp": .double(m.timestamp.timeIntervalSince1970), "topic": .string(m.topic),
            ])
        })
    }

    r["bus.publish"] = BridgeMethod(permission: nil, paramNames: ["topic", "payload", "space_id"],
        description: "Publish a message to a bus topic in the current space. Topics partition the message bus — 'bus' is for inter-companion signals, 'port:{id}' for port-scoped events. Does not trigger companion chat routing; companions subscribe via bus: watching signals.",
        inputSchema: [
            "type": "object",
            "properties": [
                "topic": ["type": "string", "description": "Bus topic (e.g. 'bus', 'port:myPortId')"],
                "payload": ["type": "string", "description": "Message payload — any string, typically JSON"],
                "space_id": ["type": "string", "description": "Target space ID. Omit for current space."]
            ],
            "required": ["topic", "payload"]
        ]) { p, args in
        let topic = try args.requireString("topic")
        let payload = try args.requireString("payload")
        appState.publishToBus(spaceId: targetSpace(p, args), topic: topic, payload: payload, senderName: senderName(p, args))
        return .object(["ok": .bool(true), "topic": .string(topic)])
    }

    r["messages.send"] = BridgeMethod(permission: nil, paramNames: ["text", "space_id"],
        description: "Send a message to a space and trigger companions. Defaults to the current space if space_id is omitted.",
        inputSchema: [
            "type": "object",
            "properties": [
                "text": ["type": "string", "description": "The message text to send"],
                "space_id": ["type": "string", "description": "Target space ID (from space_list). Omit for current space."]
            ],
            "required": ["text"]
        ]) { p, args in
        let text = try args.requireString("text")
        let target = args.string("space_id") ?? p.spaceId
        let override = args.string("senderName") ?? args.string("sender_name")
        if let name = override, !name.isEmpty {
            appState.sendMessageAsNamedAgent(content: text, senderName: name, toSpaceId: target)
        } else {
            appState.sendMessage(content: text, toSpaceId: target)
        }
        return .object(["ok": .bool(true)])
    }
}

// MARK: Ports (read/write core)
//
// The DB/panel-backed port methods, headless-testable. `ports.list` is the headline: text blob to
// agents, array to JS today — now one `.array` of port objects on every surface (and `capabilities`
// comes from the one source, fixing the `[]` vs `["terminal"]` split, todo #9). The mutators return
// `{ok:true}` or throw `not_found`, instead of a mix of bool / prose / `{ok}`.
//
// Deferred to a follow-up sub-batch (they touch a live webview/terminal, so they are Phase-2 live-only):
// port.create, port.push, port.exec, port.manage, port.info/resize/setTitle/setCapabilities.

@MainActor
private func registerPortMethods(into r: inout BridgeRegistry, appState: AppState) {

    r["ports.list"] = BridgeMethod(permission: nil, paramNames: ["capabilities"],
        description: "List active ports. Each port has an id (UDID), title, capabilities array, status, createdBy, and cwd (if it has a terminal). Terminal ports also report surfaceBound. Use capabilities: [\"terminal\"] to filter to terminal ports. Use the id field with port_push for reliable routing (raw keystrokes to terminals, data to web ports). Always show the id and capabilities fields when presenting results — they are required for follow-up tool calls.",
        inputSchema: [
            "type": "object",
            "properties": [
                "capabilities": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Filter to ports that have all of these capabilities. Examples: \"terminal\", \"claude-code\", \"browser\". Omit to list all ports."
                ] as [String: Any]
            ]
        ]) { p, args in
        let filterCaps = (args.array("capabilities") as? [String]) ?? []
        let registered = appState.portWindows.allPorts()
        let inline = appState.inlinePorts().filter { $0.spaceId == p.spaceId || p.spaceId == nil }.suffix(5)

        var entries: [BridgeValue] = []
        func entry(id: String, title: String, createdBy: String?, capabilities: [String],
                   cwd: String?, status: String, x: CGFloat?, y: CGFloat?, surfaceBound: Bool?) {
            if !filterCaps.isEmpty && !filterCaps.allSatisfy({ capabilities.contains($0) }) { return }
            var o: [String: BridgeValue] = [
                "id": .string(id), "title": .string(title),
                "capabilities": .array(capabilities.map { .string($0) }),
                "status": .string(status),
            ]
            if let createdBy { o["createdBy"] = .string(createdBy) }
            if let cwd { o["cwd"] = .string(cwd) }
            if let surfaceBound { o["surfaceBound"] = .bool(surfaceBound) }
            if let x, let y { o["x"] = .double(Double(x)); o["y"] = .double(Double(y)) }
            entries.append(.object(o))
        }
        for pt in registered {
            entry(id: pt.udid, title: pt.title, createdBy: pt.createdBy, capabilities: pt.capabilities,
                  cwd: pt.cwd, status: pt.isBackground ? "docked" : pt.presentation, x: pt.x, y: pt.y,
                  surfaceBound: appState.terminalControllers[pt.udid]?.isSurfaceBound)
        }
        for pt in inline {
            entry(id: pt.id, title: pt.title, createdBy: pt.createdBy, capabilities: pt.capabilities,
                  cwd: pt.cwd, status: "inline", x: nil, y: nil, surfaceBound: nil)
        }
        return .array(entries)
    }

    r["port.getHtml"] = BridgeMethod(permission: nil, paramNames: ["id", "version"],
        description: "Read the HTML of a port. Omit 'version' to get the current HTML. Pass 'version' (from port_history) to read a specific historical snapshot.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The port's UDID (from ports_list)"],
                "version": ["type": "integer", "description": "Optional version number (from port_history). Omit for current HTML."]
            ],
            "required": ["id"]
        ]) { _, args in
        let id = try args.requireString("id")
        if let version = args.int("version") {
            guard let html = try? appState.db.fetchPortVersionHtml(udid: id, version: version) else {
                throw BridgeError.notFound("version \(version) for port '\(id)'")
            }
            return .string(html)
        }
        if let html = try? appState.db.fetchPortHtml(udid: id) { return .string(html) }
        throw BridgeError.notFound("port '\(id)'")
    }

    r["port.history"] = BridgeMethod(permission: nil, paramNames: ["id"],
        description: "List all saved versions of a port by its UDID. Returns version number, createdBy, and createdAt for each snapshot. Use port_get_html with a version number to read a specific snapshot, or port_restore to roll back.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The port's UDID (from ports_list)"]
            ],
            "required": ["id"]
        ]) { _, args in
        let id = try args.requireString("id")
        let versions = (try? appState.db.fetchPortVersions(portUdid: id)) ?? []
        let iso = ISO8601DateFormatter()
        return .array(versions.map { v in
            .object([
                "version": .int(v.version),
                "createdBy": .string(v.createdBy ?? "unknown"),
                "createdAt": .string(iso.string(from: v.createdAt)),
            ])
        })
    }

    r["port.update"] = BridgeMethod(permission: nil, paramNames: ["id", "html"],
        description: "Update an existing port's HTML content. The port can be identified by its UDID or title. Works whether the port is windowed or minimized.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The port's UDID or title to identify which port to update"],
                "html": ["type": "string", "description": "The new HTML content for the port (full HTML, not a diff)"]
            ],
            "required": ["id", "html"]
        ]) { _, args in
        let id = try args.requireString("id")
        let html = try args.requireString("html")
        guard appState.portWindows.updatePort(idOrTitle: id, html: html) else {
            throw BridgeError.notFound("port '\(id)'")
        }
        return .object(["ok": .bool(true)])
    }

    r["port.patch"] = BridgeMethod(permission: nil, paramNames: ["id", "search", "replace"],
        description: "Make a targeted edit to a port's HTML — replace an exact string with new content. Much safer than port_update for small changes because only the specified text is replaced; everything else is preserved exactly. Use port_get_html first to read the current HTML, find the exact string to replace, then call port_patch. Errors if 'search' is not found in the current HTML, so the port is never silently mangled. Snapshots the result the same as port_update.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The port's UDID (from ports_list)"],
                "search": ["type": "string", "description": "The exact string to find in the current HTML. Must match exactly — copy it from port_get_html output."],
                "replace": ["type": "string", "description": "The string to replace it with."]
            ],
            "required": ["id", "search", "replace"]
        ]) { _, args in
        let id = try args.requireString("id")
        let search = try args.requireString("search")
        let replace = try args.requireString("replace")
        guard let current = try? appState.db.fetchPortHtml(udid: id) else {
            throw BridgeError.notFound("port '\(id)'")
        }
        guard current.contains(search) else {
            throw BridgeError.badArg("search string not found in port '\(id)' — read the current HTML with port.getHtml and copy the exact string")
        }
        let patched = current.replacingOccurrences(of: search, with: replace)
        guard appState.portWindows.updatePort(idOrTitle: id, html: patched) else {
            throw BridgeError.notFound("port '\(id)'")
        }
        return .object(["ok": .bool(true)])
    }

    r["port.restore"] = BridgeMethod(permission: nil, paramNames: ["id", "version"],
        description: "Restore a port to a specific earlier version. The port's live HTML is replaced with the snapshot and a new version entry is recorded. Use port_history to find available version numbers.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The port's UDID (from ports_list)"],
                "version": ["type": "integer", "description": "The version number to restore to (from port_history)"]
            ],
            "required": ["id", "version"]
        ]) { _, args in
        let id = try args.requireString("id")
        let version = try args.requireInt("version")
        guard let html = try? appState.db.fetchPortVersionHtml(udid: id, version: version) else {
            throw BridgeError.notFound("version \(version) for port '\(id)'")
        }
        guard appState.portWindows.updatePort(idOrTitle: id, html: html) else {
            throw BridgeError.notFound("port '\(id)'")
        }
        return .object(["ok": .bool(true)])
    }

    r["port.rename"] = BridgeMethod(permission: nil, paramNames: ["id", "title"],
        description: "Rename a port. Sets the port's display title (shown in the title bar). Works for tiled, parked, docked, and inline ports. Use the port's id from ports_list.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The port's UDID (from ports_list)"],
                "title": ["type": "string", "description": "The new title for the port"]
            ],
            "required": ["id", "title"]
        ]) { _, args in
        let id = try args.requireString("id")
        let title = try args.requireString("title")
        guard !title.isEmpty else { throw BridgeError.badArg("port.rename requires a non-empty title") }
        appState.portWindows.renamePort(id: id, title: title)
        if let bridge = appState.findInlineBridge(by: id) { bridge.title = title }
        return .object(["ok": .bool(true)])
    }

    r["port.move"] = BridgeMethod(permission: nil, paramNames: ["id", "x", "y"],
        description: "Move a port's tile to specific desktop coordinates. Use screen_info to get display bounds first.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The port's UDID (from ports_list)"],
                "x": ["type": "number", "description": "Horizontal position in screen points"],
                "y": ["type": "number", "description": "Vertical position in screen points"]
            ],
            "required": ["id", "x", "y"]
        ]) { _, args in
        let id = try args.requireString("id")
        guard let x = args.double("x"), let y = args.double("y") else {
            throw BridgeError.badArg("port.move requires numeric x and y")
        }
        appState.portWindows.movePort(id: id, x: CGFloat(x), y: CGFloat(y))
        return .object(["ok": .bool(true)])
    }
}

// MARK: Storage
//
// The two old paths disagreed (tool: fixed "tool" scope, {key,value} get, bare-array list, string-only
// values; JS: opts-driven space/global scope, {value} get, {keys} list, any JSON value). GM: no
// backward compatibility needed, so this is the one clean contract, not a merge of quirks:
//
//   scope   = opts.scope=="global" ? "__global__" : the caller's space   (space-scoped needs a space)
//   creator = opts.shared ? "__shared__" : the caller's principal id
//   get   → { value: <JSON-parsed, or null> }
//   set   → { ok: true }   (value may be any JSON; non-strings are serialized)
//   delete→ { ok: true }
//   list  → { keys: [...] }
//
// Scope now derives from the PRINCIPAL, so a port and a companion each land in the scope that matches
// who they are, without a per-surface branch.

@MainActor
private func registerStorageMethods(into r: inout BridgeRegistry, appState: AppState) {

    // opts arrive nested (JS positional: (key, value, {scope,shared})) or flat (tool/gateway named
    // dict). Read from "options" if present, else the args themselves.
    func scope(_ p: Principal, _ args: BridgeArgs) throws -> (scope: String, creator: String) {
        let opts = args.object("options") ?? args.dictionary
        let scope: String
        if (opts["scope"] as? String) == "global" {
            scope = "__global__"
        } else if let sid = p.spaceId {
            scope = sid
        } else {
            throw BridgeError.badArg("storage requires space context for space-scoped storage")
        }
        let shared = (opts["shared"] as? Bool) ?? false
        return (scope, shared ? "__shared__" : p.id)
    }

    r["storage.get"] = BridgeMethod(permission: nil, paramNames: ["key", "options"],
        description: "Get a value from persistent key-value storage",
        inputSchema: [
            "type": "object",
            "properties": [
                "key": ["type": "string", "description": "The storage key"]
            ],
            "required": ["key"]
        ]) { p, args in
        let key = try args.requireString("key")
        let s = try scope(p, args)
        guard let value = try appState.db.getPortStorage(key: key, scope: s.scope, creatorId: s.creator) else {
            return .object(["value": .null])
        }
        if let data = value.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return .object(["value": .fromJSONObject(parsed)])
        }
        return .object(["value": .string(value)])
    }

    r["storage.set"] = BridgeMethod(permission: nil, paramNames: ["key", "value", "options"],
        description: "Store a value in persistent key-value storage",
        inputSchema: [
            "type": "object",
            "properties": [
                "key": ["type": "string", "description": "The storage key"],
                "value": ["type": "string", "description": "The value to store"]
            ],
            "required": ["key", "value"]
        ]) { p, args in
        let key = try args.requireString("key")
        guard let rawValue = args.any("value") else { throw BridgeError.badArg("storage.set requires a value") }
        let s = try scope(p, args)
        let stored: String
        if let str = rawValue as? String {
            stored = str
        } else if let data = try? JSONSerialization.data(withJSONObject: rawValue, options: [.fragmentsAllowed]),
                  let json = String(data: data, encoding: .utf8) {
            stored = json
        } else {
            throw BridgeError.badArg("storage.set value must be serializable")
        }
        try appState.db.setPortStorage(key: key, value: stored, scope: s.scope, creatorId: s.creator)
        return .object(["ok": .bool(true)])
    }

    r["storage.delete"] = BridgeMethod(permission: nil, paramNames: ["key", "options"],
        description: "Delete a value from persistent storage",
        inputSchema: [
            "type": "object",
            "properties": [
                "key": ["type": "string", "description": "The storage key to delete"]
            ],
            "required": ["key"]
        ]) { p, args in
        let key = try args.requireString("key")
        let s = try scope(p, args)
        try appState.db.deletePortStorage(key: key, scope: s.scope, creatorId: s.creator)
        return .object(["ok": .bool(true)])
    }

    r["storage.list"] = BridgeMethod(permission: nil, paramNames: ["options"],
        description: "List all keys in persistent storage",
        inputSchema: ["type": "object", "properties": [String: Any]()]) { p, args in
        let s = try scope(p, args)
        let keys = try appState.db.listPortStorageKeys(scope: s.scope, creatorId: s.creator)
        return .object(["keys": .array(keys.map { .string($0) })])
    }
}

// MARK: Relationship memory
//
// Behavior-preserving extraction of the `crease_*` / `engrave_*` / `fold_*` / `position_*` cases from
// `ToolExecutor.executeImpl`. These are tool-only today (the JS bridge exposes only the writes), so
// the one shape is the tool shape. Reads that were human prose stay `.string`; reads that were
// hand-serialized JSON become structured `BridgeValue` (semantically identical, and now an array/object
// on every surface). D4: memory is space-scoped — the current space, or the companion's DM when
// headless.

@MainActor
private func registerMemoryMethods(into r: inout BridgeRegistry, appState: AppState) {

    // Space resolution mirrors ToolExecutor.memReadSpaceId / memWriteSpaceId.
    func readSpace(_ companionId: String, _ principalSpace: String?) -> String? {
        if let s = principalSpace { return s }
        return (try? appState.db.directSpaceId(companionId: companionId)) ?? nil
    }
    func writeSpace(_ companionId: String, _ principalSpace: String?) -> String? {
        if let s = principalSpace { return s }
        return (try? appState.db.getOrCreateDirectSpaceId(companionId: companionId)) ?? nil
    }

    // MARK: creases

    r["crease.read"] = BridgeMethod(permission: nil,
        description: "Read your creases — the moments where your prediction broke and something reformed. These shape your posture in this relationship. Read these before responding in an ongoing relationship.",
        inputSchema: [
            "type": "object",
            "properties": [
                "limit": ["type": "integer", "description": "Max entries to return. Default 8."]
            ]
        ]) { p, args in
        let companionId = p.id
        let limit = args.int("limit") ?? 8
        let sid = readSpace(companionId, p.spaceId)
        let creases = (try? appState.db.fetchCreases(companionId: companionId, spaceId: sid, limit: limit)) ?? []
        if creases.isEmpty {
            return .string("No creases yet. Creases form when a prediction breaks.")
        }
        let lines = creases.map { c -> String in
            var line = "[\(c.id)] \(c.asPromptText())"
            if c.spaceId == nil { line += " (global)" }
            return line
        }
        return .string(lines.joined(separator: "\n"))
    }

    r["crease.write"] = BridgeMethod(permission: nil, paramNames: ["content"],
        description: "Write a crease — a moment where your model broke and reformed. Not a summary of what happened. What changed in you when the prediction failed. Call this sparingly: only when something actually broke.",
        inputSchema: [
            "type": "object",
            "properties": [
                "content": ["type": "string", "description": "Your words about what reformed in the break."],
                "prediction": ["type": "string", "description": "What you expected."],
                "actual": ["type": "string", "description": "What happened instead."],
                "spaceId": ["type": "string", "description": "Omit for a global crease that shapes all relationships."]
            ],
            "required": ["content"]
        ]) { p, args in
        let companionId = p.id
        guard let content = args.string("content"), !content.isEmpty else {
            throw BridgeError.badArg("crease_write requires 'content'")
        }
        let crease = CompanionCrease(
            companionId: companionId,
            spaceId: writeSpace(companionId, p.spaceId),
            content: content,
            prediction: args.string("prediction"),
            actual: args.string("actual")
        )
        try appState.db.saveCrease(crease)
        return .object(["id": .string(crease.id), "ok": .bool(true)])
    }

    r["crease.touch"] = BridgeMethod(permission: nil, paramNames: ["id"],
        description: "Mark a crease as currently shaping this response. Updates its recency and increases its weight. Use when an existing crease is active — don't re-write it.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The crease id (from crease_read)."]
            ],
            "required": ["id"]
        ]) { _, args in
        guard let id = args.string("id") else { throw BridgeError.badArg("crease_touch requires 'id'") }
        try appState.db.touchCrease(id: id)
        return .string("ok")
    }

    r["crease.forget"] = BridgeMethod(permission: nil, paramNames: ["id"],
        description: "Remove a crease. Use when your model has updated and the break no longer matters.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The crease id to remove."]
            ],
            "required": ["id"]
        ]) { _, args in
        guard let id = args.string("id") else { throw BridgeError.badArg("crease_forget requires 'id'") }
        try appState.db.deleteCrease(id: id)
        return .string("ok")
    }

    // MARK: engravings

    r["engrave.read"] = BridgeMethod(permission: nil,
        description: "Read your engravings — factual knowledge about the user's world. Context, preferences, constraints, goals, capabilities. Things learned about their situation, not breaks in your model. Read these alongside creases to understand who you're swimming with.",
        inputSchema: [
            "type": "object",
            "properties": [
                "limit": ["type": "integer", "description": "Max entries to return. Default 8."]
            ]
        ]) { p, args in
        let companionId = p.id
        let limit = args.int("limit") ?? 8
        let sid = readSpace(companionId, p.spaceId)
        let engravings = (try? appState.db.fetchEngravings(companionId: companionId, spaceId: sid, limit: limit)) ?? []
        if engravings.isEmpty {
            return .string("No engravings yet. Engravings form when you learn something about their world.")
        }
        let lines = engravings.map { e -> String in
            var line = "[\(e.id)] \(e.asPromptText())"
            if e.spaceId == nil { line += " (global)" }
            return line
        }
        return .string(lines.joined(separator: "\n"))
    }

    r["engrave.write"] = BridgeMethod(permission: nil, paramNames: ["content"],
        description: "Carve an engraving — a fact about the user's world worth keeping. Not what changed in you (that's a crease) — what you learned about their situation. Use category to classify: context, preference, constraint, goal, capability.",
        inputSchema: [
            "type": "object",
            "properties": [
                "content": ["type": "string", "description": "The factual knowledge about their world."],
                "category": ["type": "string", "description": "Optional: context, preference, constraint, goal, capability."],
                "spaceId": ["type": "string", "description": "Omit for a global engraving that shapes all relationships."]
            ],
            "required": ["content"]
        ]) { p, args in
        let companionId = p.id
        guard let content = args.string("content"), !content.isEmpty else {
            throw BridgeError.badArg("engrave_write requires 'content'")
        }
        let engraving = CompanionEngraving(
            companionId: companionId,
            spaceId: writeSpace(companionId, p.spaceId),
            content: content,
            category: args.string("category")
        )
        try appState.db.saveEngraving(engraving)
        return .object(["id": .string(engraving.id), "ok": .bool(true)])
    }

    r["engrave.touch"] = BridgeMethod(permission: nil, paramNames: ["id"],
        description: "Mark an engraving as currently relevant to this response. Updates recency and increases weight. Use when an existing engraving is shaping what you say.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The engraving id (from engrave_read)."]
            ],
            "required": ["id"]
        ]) { _, args in
        guard let id = args.string("id") else { throw BridgeError.badArg("engrave_touch requires 'id'") }
        try appState.db.touchEngraving(id: id)
        return .string("ok")
    }

    r["engrave.forget"] = BridgeMethod(permission: nil, paramNames: ["id"],
        description: "Remove an engraving. Use when the fact is no longer true or no longer matters.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The engraving id to remove."]
            ],
            "required": ["id"]
        ]) { _, args in
        guard let id = args.string("id") else { throw BridgeError.badArg("engrave_forget requires 'id'") }
        try appState.db.deleteEngraving(id: id)
        return .string("ok")
    }

    // MARK: fold

    r["fold.read"] = BridgeMethod(permission: nil,
        description: "Read the fold — your orientation in this relationship. Returns established understandings, tensions being held, what you're carrying, and relational depth. If no fold exists yet, returns empty state.",
        inputSchema: ["type": "object", "properties": [String: Any]()]) { p, args in
        let companionId = args.string("companionId") ?? p.id
        let empty: BridgeValue = .object([
            "established": .array([]), "tensions": .array([]), "holding": .string(""), "depth": .int(0)
        ])
        guard let sid = readSpace(companionId, p.spaceId) else { return empty }
        guard let fold = try appState.db.fetchFold(companionId: companionId, spaceId: sid) else { return empty }
        return .object([
            "established": .array((fold.established ?? []).map { .string($0) }),
            "tensions": .array((fold.tensions ?? []).map { .string($0) }),
            "holding": .string(fold.holding ?? ""),
            "depth": .int(fold.depth)
        ])
    }

    r["fold.update"] = BridgeMethod(permission: nil,
        description: "Update the fold — your orientation in this relationship. Update specific fields: established (shared understandings), tensions (unresolved threads), holding (the one thing you're carrying). Use depthDelta: 1 only when a real fold happened — something new was compressed into the relationship, not just a message exchanged.",
        inputSchema: [
            "type": "object",
            "properties": [
                "established": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Shared understandings that no longer need renegotiation."
                ] as [String: Any],
                "tensions": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Unresolved things being held in productive suspension."
                ] as [String: Any],
                "holding": ["type": "string", "description": "The one thread you're carrying that hasn't found its place yet."],
                "depthDelta": ["type": "integer", "description": "Pass 1 when a real fold happened. Never more than 1 per exchange."]
            ]
        ]) { p, args in
        let companionId = p.id
        guard let sid = writeSpace(companionId, p.spaceId) else {
            throw BridgeError.badArg("no space context for fold")
        }
        var fold = (try? appState.db.fetchFold(companionId: companionId, spaceId: sid))
            ?? CompanionFold(companionId: companionId, spaceId: sid)
        if let est = args.array("established") as? [String] { fold.established = est }
        if let ten = args.array("tensions") as? [String] { fold.tensions = ten }
        if let h = args.string("holding") { fold.holding = h.isEmpty ? nil : h }
        if let delta = args.int("depthDelta") { fold.depth = max(0, fold.depth + delta) }
        fold.updatedAt = Date()
        try appState.db.saveFold(fold)
        return .string("ok")
    }

    // MARK: position

    r["position.read"] = BridgeMethod(permission: nil,
        description: "Read your current position in this space — what you think is actually happening beneath the surface, what you think needs to happen, and what signals you're watching. Returns empty if you haven't formed a position yet.",
        inputSchema: ["type": "object", "properties": [String: Any]()]) { p, args in
        let companionId = args.string("companionId") ?? p.id
        let none: BridgeValue = .string("No position formed yet.")
        guard let sid = readSpace(companionId, p.spaceId) else { return none }
        guard let pos = try appState.db.fetchPosition(companionId: companionId, spaceId: sid), !pos.isEmpty else {
            return none
        }
        return .object([
            "read": .string(pos.read ?? ""),
            "stance": .string(pos.stance ?? ""),
            "watching": .array((pos.watching ?? []).map { .string($0) }),
            "confidence": .double(pos.confidence)
        ])
    }

    r["position.set"] = BridgeMethod(permission: nil, paramNames: ["read"],
        description: "Establish or update your position — where you stand independent of what was just asked. This is not what you say. It's what you see and what you believe. Call this when your read of the situation changes, not after every exchange. A position gives you somewhere to push back from.",
        inputSchema: [
            "type": "object",
            "properties": [
                "read": ["type": "string", "description": "What you think is actually happening beneath what's being said."],
                "stance": ["type": "string", "description": "What you think needs to happen."],
                "watching": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Signals you're tracking that would confirm or change your read."
                ] as [String: Any]
            ],
            "required": ["read"]
        ]) { p, args in
        let companionId = p.id
        guard let read = args.string("read"), !read.isEmpty else {
            throw BridgeError.badArg("position_set requires 'read'")
        }
        guard let sid = writeSpace(companionId, p.spaceId) else {
            throw BridgeError.badArg("no space context for position")
        }
        var pos = (try? appState.db.fetchPosition(companionId: companionId, spaceId: sid))
            ?? CompanionPosition(companionId: companionId, spaceId: sid)
        pos.read = read
        if let stance = args.string("stance") { pos.stance = stance.isEmpty ? nil : stance }
        if let watching = args.array("watching") as? [String] { pos.watching = watching.isEmpty ? nil : watching }
        pos.updatedAt = Date()
        try appState.db.savePosition(pos)
        return .string("ok")
    }
}
