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
    registerKeeperService(into: &r, appState: appState)    // crease/engrave/fold/position (BridgeServiceKeeper.swift)
    registerStorageService(into: &r, appState: appState)   // storage.* KV (BridgeServiceStorage.swift)
    registerPortMethods(into: &r, appState: appState)
    registerCommsMethods(into: &r, appState: appState)
    registerFileMethods(into: &r, appState: appState)
    registerDeviceMethods(into: &r, appState: appState)
    registerLiveDeviceMethods(into: &r, appState: appState)
    registerPortLiveMethods(into: &r, appState: appState)
    registerAIService(into: &r, appState: appState)   // ai.models, ai.status (BridgeServiceAI.swift)
    // R3: every WRITE verb gains the optional `expect` token here, once, instead of eight times in
    // eight declarations. A write verb added tomorrow gets compare-and-swap by construction.
    return r.mapValues { $0.acceptingExpect() }
}

// MARK: Streaming registry (item 8)
//
// Two streaming methods. `ai.complete` lives in its own service module (`BridgeServiceAI.swift`) — the
// `ai` namespace is the reference plug-in service (see docs §6). `companions.invoke` is an agent-runtime
// faculty too, but it lives in the `companions` namespace (platform roster + one runtime verb), so it
// stays here with the comms surface. Both are self-describing (inline description + inputSchema), from
// which `anthropicToolSchema` generates the tool-use schema. `ai.cancel` stays at the port-JS adapter
// (callId → Task cancellation is transport-coupled, not a service method).
@MainActor
public func buildBridgeStreamRegistry(_ appState: AppState) -> BridgeStreamRegistry {
    var r: BridgeStreamRegistry = [:]

    registerAIServiceStream(into: &r, appState: appState)   // ai.complete (BridgeServiceAI.swift)

    // Phase L1 (docs/plan-port42-protocol-local-bus.md): subscribe to a port's Notify stream. Yields
    // each { topic, kind, payload } envelope as the port emits it, until the caller cancels. Many
    // subscribers can watch one port; each gets every event (the NotifyBus fans out 1:N).
    r["port.subscribe"] = BridgeStreamMethod(
        permission: nil,
        paramNames: ["id"],
        toolExposed: false,
        description: "Subscribe to a port's live event stream. Yields Notify events { topic, kind, payload } as the port emits them (e.g. terminal.output). The stream stays open until cancelled.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The port to observe (id / udid / title)."] as [String: Any]
            ] as [String: Any],
            "required": ["id"]
        ]
    ) { _, args, yield in
        let id = try args.requireString("id")
        let ref = appState.resolvePortRef(id)
        let topic = "port:\(ref?.udid ?? ref?.id ?? id)"
        let subId = appState.notifyBus.subscribe(topic: topic, deliver: yield)
        defer { appState.notifyBus.unsubscribe(id: subId, topic: topic) }
        // Hold the stream open until the caller cancels — the run executes on a tracked Task that is
        // cancelled on close/cancel (mirrors ai.complete's cancellation). Poll so cleanup is prompt.
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return .object(["ok": .bool(true)])
    }

    r["companions.invoke"] = BridgeStreamMethod(
        permission: .ai,
        paramNames: ["identifier", "prompt"],
        toolExposed: false,
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
        description: "Create a port and return its id. The uniform way to make any port. type:\"web\" needs html (a full port HTML body) and renders inline in chat. type:\"terminal\" needs command and opens a native terminal (runs in /bin/zsh; the command is typed in — claude/gemini get the Port42 hooks). For terminals you may also pass args, cwd, systemPrompt (companion personality), env, and initialInput (a line left waiting, unsent, in the CLI's input box). Drive the result with port_push (input to terminals, data to web ports) and list with ports_list. Pass space_id to target a space (default: current).",
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
                "initialInput": ["type": "string", "description": "type:\"terminal\" — a line typed into the CLI once it is up but NOT submitted: it waits in the input box for the user to press Enter. For handing someone a first prompt to run. Use port_push instead to actually send input."],
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
            presentation: o["presentation"] as? String,
            initialInput: o["initialInput"] as? String ?? "")
        if let err = result["error"] as? String { throw BridgeError.badArg(err) }
        return .fromJSONObject(result)   // { id, title }
    }

    r["port.push"] = BridgeMethod(permission: nil, paramNames: ["id", "data"], writesTarget: "id",
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
        // Phase L0: one resolver for the target (docs/plan-port42-protocol-local-bus.md). The PortRef
        // carries the full identity, so each branch uses the key its accessor keys on (terminal id /
        // webViews-key / inline messageId). Terminal-wins precedence lives in PortResolution now, not here.
        guard let ref = appState.resolvePortRef(id) else {
            NSLog("[Port42][portdrive] push id=%@ → NOTFOUND space=%@", id, appState.currentSpace?.name ?? "?")
            throw BridgeError.notFound("port '\(id)'")
        }
        NSLog("[Port42][portdrive] push id=%@ → %@ space=%@", id, ref.kind.rawValue, appState.currentSpace?.name ?? "?")
        // Phase L1: republish the delivered input on the port's Notify topic (a cheap no-op when nobody
        // subscribes), so an observer can watch what a port is being driven with.
        appState.notifyBus.publish(topic: "port:\(ref.udid ?? ref.id ?? id)", kind: "push", payload: data)
        switch ref.kind {
        case .terminal:
            guard let tid = ref.id, let controller = appState.terminalControllers[tid] else {
                throw BridgeError(code: "no_surface", message: "terminal '\(id)' has no live surface")
            }
            let str = (data as? String) ?? (String(data: (try? JSONSerialization.data(withJSONObject: data, options: [.fragmentsAllowed])) ?? Data(), encoding: .utf8) ?? "")
            guard controller.sendRaw(str) else { throw BridgeError(code: "no_surface", message: "terminal '\(id)' has no live surface") }
            return .object(["ok": .bool(true)])
        case .web, .browser:
            guard let wv = webView(ref.id ?? ref.messageId ?? id) else {
                throw BridgeError.notFound("port '\(id)'")
            }
            guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: [.fragmentsAllowed]),
                  let jsonStr = String(data: jsonData, encoding: .utf8) else {
                throw BridgeError.badArg("could not serialize data to JSON")
            }
            _ = try? await wv.evaluateJavaScript("window.dispatchEvent(new CustomEvent('port42:data', {detail: \(jsonStr)}))")
            return .object(["ok": .bool(true)])
        case .unknown:
            throw BridgeError.notFound("port '\(id)'")
        }
    }

    r["port.publish"] = BridgeMethod(permission: nil, paramNames: ["kind", "payload"],
        description: "A port emits its OWN state or event on its own Notify topic, for consumers watching via port_subscribe. This is a port broadcasting AS itself — distinct from port_push, which is input sent INTO a port. Only meaningful from inside a port; the topic is the calling port's own id, so there is no target argument. Use this instead of having a consumer reach in with port_exec to read state: the port publishes, consumers subscribe.",
        inputSchema: [
            "type": "object",
            "properties": [
                "kind": ["type": "string", "description": "Event kind, e.g. 'state', 'progress', 'error'."],
                "payload": ["description": "Any JSON value (object/array/string/number) delivered as the Notify envelope's payload."]
            ],
            "required": ["kind"]
        ]) { p, args in
        // Phase L1 follow-on (docs/plan-port42-protocol-local-bus.md): the caller publishes AS itself.
        // The Principal carries the caller's own port id (portId); a port can only publish on its own
        // topic, so there is no target argument. The topic is computed the SAME way port.push does
        // (resolvePortRef on the caller's own id), so publish and subscribe are symmetric — a consumer
        // that subscribed to this port receives it. Retires the port.exec(getState) hydration path.
        let key = p.portId ?? p.id
        guard p.kind == .port, let ref = appState.resolvePortRef(key) else {
            throw BridgeError(code: "no_port", message: "port.publish is only callable from within a port")
        }
        let kind = try args.requireString("kind")
        let payload = args.any("payload") ?? NSNull()
        appState.notifyBus.publish(topic: "port:\(ref.udid ?? ref.id ?? key)", kind: kind, payload: payload)
        return .object(["ok": .bool(true)])
    }

    r["port.exec"] = BridgeMethod(permission: nil, paramNames: ["id", "js"], writesTarget: "id",
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
        // Phase L0: resolve the target, then require a web surface (docs/plan-port42-protocol-local-bus.md).
        guard let ref = appState.resolvePortRef(id), ref.kind == .web || ref.kind == .browser,
              let wv = webView(ref.id ?? ref.messageId ?? id) else { throw BridgeError.notFound("port '\(id)'") }
        // #5: PortExecJS awaits promises + marshals objects; nil = undefined/no-return.
        guard let result = try await PortExecJS.run(wv, js) else { return .object(["ok": .bool(true)]) }
        return .fromJSONObject(result)
    }

    r["port.getDom"] = BridgeMethod(permission: nil, paramNames: ["id", "selector"],
        description: "Read a WEB or BROWSER port's LIVE DOM — what is on screen right now, including "
                   + "everything its JS has changed since load. Use this, not port_get_html, when you "
                   + "need current state: port_get_html returns the stored SOURCE, which does not "
                   + "reflect any port_exec or port_push that has run since. Returns {html, token}; "
                   + "pass that token as 'expect' on your next write and it will be refused rather "
                   + "than clobber someone if the port moved in between.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The port's UDID (from ports_list)"],
                "selector": ["type": "string", "description": "Optional CSS selector to read just one subtree. Omit for the whole document."]
            ],
            "required": ["id"]
        ]) { _, args in
        // A READ, and `writesTarget` is deliberately nil so it neither bumps the activity token nor
        // records presence. That is the whole reason it exists.
        //
        // R3 exposed the gap: `port.exec` is (correctly) a write, because it runs arbitrary JS and
        // can mutate — so INSPECTING a live port through it moved the token, and a caller that
        // looked before writing invalidated its own token. "Read the live state, then write against
        // it" was not expressible; the read was a write.
        //
        // What makes this honestly read-only is that there is NO `js` parameter. The expression is
        // fixed here, so a caller cannot smuggle a mutation through a read verb — the classification
        // is enforced by the method's shape, not by trusting the caller.
        let id = try args.requireString("id")
        guard let ref = appState.resolvePortRef(id), ref.kind == .web || ref.kind == .browser,
              let wv = webView(ref.id ?? ref.messageId ?? id) else {
            throw BridgeError.notFound("web port '\(id)'")
        }
        let js: String
        if let sel = args.string("selector"), !sel.isEmpty {
            let quoted = sel.replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "'", with: "\\'")
            js = "(document.querySelector('\(quoted)') || {}).outerHTML || ''"
        } else {
            js = "document.documentElement.outerHTML"
        }
        let html = (try await PortExecJS.run(wv, js) as? String) ?? ""
        // The token comes back WITH the DOM, from the same instant: fetching it separately would
        // leave a gap in which the port could move, and hand back a token that was never true of
        // the html beside it.
        var out: [String: BridgeValue] = ["html": .string(html)]
        if let key = ref.udid ?? ref.id { out["token"] = .string(appState.portActivity.token(for: key)) }
        return .object(out)
    }

    r["port.manage"] = BridgeMethod(permission: nil, paramNames: ["id", "action"], writesTarget: "id",
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
        guard let panel = appState.portWindows.findPort(by: appState.resolvePortRef(id)?.udid ?? id) else { throw BridgeError.notFound("port '\(id)'") }
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

    // presentation — the calling port asks about ITSELF (backlog 1.1): its current placement state and
    // whether it is on screen, so it can idle its animation loop when hidden. Port-JS only (a companion
    // is not a port), so toolExposed is false. No permission — a port reading its own visibility.
    r["presentation"] = BridgeMethod(permission: nil, toolExposed: false,
        description: "The calling port's current presentation state { state, visible, w, h }: whether its surface is on screen right now and at what content size, so the port can pause its animation loop when not visible and scale fidelity to its size. The same value is delivered as the 'presentation' event on every change; this call returns the current snapshot for the initial read.",
        inputSchema: [
            "type": "object",
            "properties": [String: Any]()
        ]) { p, _ in
        let key = p.portId ?? p.id
        // Unknown port (no shell, or not staged) → a safe visible default so a caller never idles wrongly.
        let snap = appState.shell?.presentation(forPortId: key)
            ?? PortPresentation(state: .tiled, visible: true, size: ShellState.defaultTileSize)
        return .fromJSONObject(snap.jsonObject)
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
// Extracted during the Phase-2 live pass (request/response) + tail item 6 (the stateful capture and
// stream family). Thin pass-throughs to the device bridges, converting the bridge's `[String: Any]`
// to a BridgeValue; an `{error}` dict throws (clean break). The image methods return a top-level
// `.data`, so tool-use renders a real Anthropic image block (the model sees the pixels) while
// JS/gateway get the base64 string; width/height are dropped (use `screen.displays` for geometry).
// The stateful families (audio capture, camera/screen streams) run on the ONE shared instance per
// family held by AppState: sessions are shared across all surfaces, remember the port that started
// them (owner) for event routing, and are stopped by a dying owner's deinit (the mic-leak teardown).

@MainActor
private func registerLiveDeviceMethods(into r: inout BridgeRegistry, appState: AppState) {
    let screen = appState.screenDevice
    let camera = appState.cameraDevice
    let audio = appState.audioDevice
    let notifications = NotificationBridge()
    let automation = AutomationBridge()

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
        ]) { p, args in
        let text = try args.requireString("text")
        return .fromJSONObject(await audio.speak(text: text, opts: args.object("options"), owner: owningPortBridge(p)))
    }

    r["audio.play"] = BridgeMethod(permission: nil, paramNames: ["data", "options"], toolExposed: false,
        description: "Play base64-encoded audio data (WAV, MP3, AAC).") { p, args in
        let data = try args.requireString("data")
        return .fromJSONObject(audio.play(data: data, opts: args.object("options"), owner: owningPortBridge(p)))
    }

    r["audio.stop"] = BridgeMethod(permission: nil, toolExposed: false,
        description: "Stop any active speech synthesis or audio playback.") { _, _ in
        .fromJSONObject(audio.stop())
    }

    // Tail item 5 — browser.*. ONE shared BrowserBridge instance (appState.browserDevice, backlog
    // 0.5): sessions are shared across all surfaces (the old design was one instance per PortBridge
    // plus one per ToolExecutor, so a session opened from a port was invisible to a companion). A
    // session opened by a port routes its load/redirect/error events to that port via `owner` and is
    // torn down when that port closes (deviceBridges). Errors throw (clean break from the {error}
    // dicts the old switches returned).
    let browser = appState.browserDevice
    func browserResult(_ r: [String: Any]) throws -> BridgeValue {
        if let err = r["error"] as? String { throw BridgeError(code: "browser_error", message: err) }
        return .fromJSONObject(r)
    }
    func owningPortBridge(_ p: Principal) -> PortBridge? {
        guard p.kind == .port else { return nil }
        // Resolve on the port's OWN id (portId), not the authz id: a companion-created port's `id` is
        // its creator, shared across ports, so matching it would find the wrong port or none (backlog
        // 0.5). Falls back to `id` for a port with no portId (nil messageId — starts no captures).
        let key = p.portId ?? p.id
        return appState.portWindows.panels.first(where: { $0.udid == key || $0.messageId == key })?.bridge
            ?? appState.findInlineBridge(by: key)
    }

    r["browser.open"] = BridgeMethod(permission: .browser, paramNames: ["url", "options"],
        description: "Open a URL in a headless browser and return the page title. Use browser_text to read page content after opening.",
        inputSchema: [
            "type": "object",
            "properties": [
                "url": ["type": "string", "description": "The URL to open (http or https)"]
            ],
            "required": ["url"]
        ]) { p, args in
        let url = try args.requireString("url")
        guard !url.isEmpty else { throw BridgeError.badArg("browser.open requires a URL") }
        let opts = args.object("options") ?? args.dictionary
        return try browserResult(await browser.open(url: url, opts: opts, owner: owningPortBridge(p)))
    }

    r["browser.navigate"] = BridgeMethod(permission: .browser, paramNames: ["sessionId", "url"], toolExposed: false,
        description: "Navigate an open browser session to a new URL.") { _, args in
        let sessionId = try args.requireString("sessionId")
        let url = try args.requireString("url")
        return try browserResult(await browser.navigate(sessionId: sessionId, url: url))
    }

    r["browser.capture"] = BridgeMethod(permission: .browser, paramNames: ["sessionId", "options"],
        description: "Take a screenshot of an open browser session. Returns base64 PNG.",
        inputSchema: [
            "type": "object",
            "properties": [
                "sessionId": ["type": "string", "description": "Browser session ID from browser_open"]
            ],
            "required": ["sessionId"]
        ]) { _, args in
        let sessionId = try args.requireString("sessionId")
        let result = try browserResult(await browser.capture(sessionId: sessionId, opts: args.object("options") ?? args.dictionary))
        // Same convention as screen.capture: a captured image is .data, so the tool surface renders a
        // real image block and JS/gateway get the bare base64 string.
        if case let .object(o) = result, case let .string(base64)? = o["image"] {
            return .data(base64: base64, mime: "image/png")
        }
        return result
    }

    r["browser.text"] = BridgeMethod(permission: .browser, paramNames: ["sessionId", "options"],
        description: "Extract text content from an open browser session",
        inputSchema: [
            "type": "object",
            "properties": [
                "sessionId": ["type": "string", "description": "Browser session ID from browser_open"],
                "selector": ["type": "string", "description": "CSS selector to extract from (default: body)"]
            ],
            "required": ["sessionId"]
        ]) { _, args in
        let sessionId = try args.requireString("sessionId")
        var opts = args.object("options") ?? args.dictionary
        if opts["selector"] == nil, let sel = args.string("selector") { opts["selector"] = sel }
        return try browserResult(await browser.text(sessionId: sessionId, opts: opts))
    }

    r["browser.html"] = BridgeMethod(permission: .browser, paramNames: ["sessionId", "options"], toolExposed: false,
        description: "Read the HTML of an open browser session, optionally scoped to a CSS selector.") { _, args in
        let sessionId = try args.requireString("sessionId")
        var opts = args.object("options") ?? args.dictionary
        if opts["selector"] == nil, let sel = args.string("selector") { opts["selector"] = sel }
        return try browserResult(await browser.html(sessionId: sessionId, opts: opts))
    }

    r["browser.execute"] = BridgeMethod(permission: .browser, paramNames: ["sessionId", "js"], toolExposed: false,
        description: "Run JavaScript in an open browser session and return the result.") { _, args in
        let sessionId = try args.requireString("sessionId")
        let js = try args.requireString("js")
        return try browserResult(await browser.execute(sessionId: sessionId, js: js))
    }

    r["browser.close"] = BridgeMethod(permission: .browser, paramNames: ["sessionId"],
        description: "Close a browser session",
        inputSchema: [
            "type": "object",
            "properties": [
                "sessionId": ["type": "string", "description": "Browser session ID to close"]
            ],
            "required": ["sessionId"]
        ]) { _, args in
        let sessionId = try args.requireString("sessionId")
        return try browserResult(browser.close(sessionId: sessionId))
    }

    // Tail item 6 — the stateful capture/stream family, on the shared AppState instances (audio /
    // camera / screen). All six are port-event-driven (audio.transcription / audio.data /
    // camera.frame / screen.frame events push to the owning port), so none are LLM tools. Errors
    // throw, including stop on an idle device (clean break from the {error} dicts). The stop
    // methods keep the old permission split: audio.stopCapture rides the .microphone grant its
    // start acquired; the two stopStreams are ungated (stopping an already-permitted stream).
    func avResult(_ result: [String: Any]) throws -> BridgeValue {
        if let err = result["error"] as? String { throw BridgeError(code: "device_error", message: err) }
        return .fromJSONObject(result)
    }

    r["audio.capture"] = BridgeMethod(permission: .microphone, paramNames: ["options"], toolExposed: false,
        description: "Start microphone capture. Streams audio.transcription events (and audio.data when rawAudio is set) to the calling port until audio.stopCapture.") { p, args in
        try avResult(await audio.capture(opts: args.object("options") ?? args.dictionary, owner: owningPortBridge(p)))
    }

    r["audio.stopCapture"] = BridgeMethod(permission: .microphone, toolExposed: false,
        description: "Stop the microphone capture and release the audio engine.") { _, _ in
        try avResult(audio.stopCapture())
    }

    r["camera.stream"] = BridgeMethod(permission: .camera, paramNames: ["options"], toolExposed: false,
        description: "Start continuous camera streaming. Pushes camera.frame events to the calling port until camera.stopStream.") { p, args in
        try avResult(await camera.stream(opts: args.object("options") ?? args.dictionary, owner: owningPortBridge(p)))
    }

    r["camera.stopStream"] = BridgeMethod(permission: nil, toolExposed: false,
        description: "Stop the camera stream and release the capture session.") { _, _ in
        try avResult(camera.stopStream())
    }

    r["screen.stream"] = BridgeMethod(permission: .screen, paramNames: ["options"], toolExposed: false,
        description: "Start continuous screen streaming. Pushes screen.frame events to the calling port until screen.stopStream.") { p, args in
        try avResult(await screen.stream(opts: args.object("options") ?? args.dictionary, owner: owningPortBridge(p)))
    }

    r["screen.stopStream"] = BridgeMethod(permission: nil, toolExposed: false,
        description: "Stop the screen stream and release the capture stream.") { _, _ in
        try avResult(await screen.stopStream())
    }

    // screen.record (docs/plan-screen-record.md): record app surfaces to a real video file (not
    // base64). Shares the ScreenBridge SCStream plumbing; SCRecordingOutput writes video + optional
    // system/mic audio. Requires macOS 15. Destination: the calling space's workingDirectory/recordings,
    // else dataDir/recordings; a `path` option overrides. `.screen` is auto-prompted by the dispatcher;
    // `audio:mic|both` additionally asks for `.microphone` here.

    /// Where a recording lands: the calling space's working directory (`recordings/`), else the
    /// app data dir (`recordings/`, reachable by the sandboxed fs.* API). `~/.port42` is never used.
    func recordingsDir(spaceId: String?) -> URL {
        if let sid = spaceId,
           let wd = appState.spaces.first(where: { $0.id == sid })?.workingDirectory,
           !wd.isEmpty {
            return URL(fileURLWithPath: wd).appendingPathComponent("recordings")
        }
        return URL(fileURLWithPath: BridgeFilePaths.dataDir).appendingPathComponent("recordings")
    }

    /// Resolve start options → (target, destinationDir, outputURL override) or throw a legible error.
    /// Also asks for `.microphone` when audio is mic/both.
    func resolveRecordStart(_ opts: [String: Any], _ p: Principal) async throws -> (RecordTarget, URL, URL?) {
        let target: RecordTarget
        switch RecordTarget.parse(opts) {
        case .success(let t): target = t
        case .failure(let e): throw BridgeError(code: "device_error", message: e.message)
        }
        let audio = (opts["audio"] as? String) ?? "none"
        if audio == "mic" || audio == "both" {
            let ok = await appState.permissions.request(.microphone, from: p)
            if !ok { throw BridgeError.permissionDenied("microphone") }
        }
        let dir = recordingsDir(spaceId: p.spaceId)
        var outputURL: URL? = nil
        if let path = opts["path"] as? String, !path.isEmpty {
            outputURL = (path as NSString).isAbsolutePath
                ? URL(fileURLWithPath: path)
                : dir.appendingPathComponent(path)
        }
        return (target, dir, outputURL)
    }

    let recordSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "options": [
                "type": "object",
                "description": "Recording options: target ({window:\"self\"} | {window:<osId>} | {port:<udid>} | {ports:[<udid>...]} | {region:{x,y,w,h}} | {display:<id>}). window/port/ports are occlusion-proof (only that surface); region/display capture the raw display (may catch other apps). Also aspect (e.g. \"16:9\"), fit (cover|exact; contain is not yet supported), width, height, scale, fps, padding, cursor (bool; only on a display or region target — a window/port capture cannot include the cursor), audio (none|system|mic|both), format (mov|mp4), path, and for the convenience form seconds."
            ]
        ]
    ]

    r["screen.record.start"] = BridgeMethod(permission: .screen, paramNames: ["options"],
        description: "Start recording an app surface (window:self / a port / multiple ports) to a video file with optional system or mic audio. Returns {recordingId, width, height, target}. Stop with screen.record.stop.",
        inputSchema: recordSchema) { p, args in
        // Lenient bag: options nested under `options` OR passed flat at the top level both work — the
        // `options` wrapper is optional. (Previously `?? [:]` silently swallowed a flat call into an
        // empty bag → a default self-recording with no error. The whole-args fallback is the same idiom
        // audio.play / storage already use.)
        let opts = args.object("options") ?? args.dictionary
        let (target, dir, outputURL) = try await resolveRecordStart(opts, p)
        return try avResult(await screen.recorder.start(
            target: target, opts: opts, destinationDir: dir, outputURL: outputURL,
            ownerPortId: p.portId,
            portFrameLookup: { appState.portWindows.portFrame(by: $0) }))
    }

    r["screen.record.stop"] = BridgeMethod(permission: nil, paramNames: ["recordingId"],
        description: "Stop a recording started with screen.record.start. Returns {path, width, height, seconds, fps, bytes}.",
        inputSchema: [
            "type": "object",
            "properties": ["recordingId": ["type": "string", "description": "The id returned by screen.record.start"]],
            "required": ["recordingId"]
        ]) { _, args in
        let id = try args.requireString("recordingId")
        return try avResult(await screen.recorder.stop(recordingId: id))
    }

    r["screen.record.status"] = BridgeMethod(permission: nil, paramNames: ["recordingId"],
        description: "Report whether a recording (or any recording) is active and its elapsed seconds.",
        inputSchema: [
            "type": "object",
            "properties": ["recordingId": ["type": "string", "description": "Optional recording id; omit for the overall status"]]
        ]) { _, args in
        .fromJSONObject(screen.recorder.status(recordingId: args.string("recordingId")))
    }

    r["screen.record"] = BridgeMethod(permission: .screen, paramNames: ["options"],
        description: "Record an app surface for a fixed number of seconds and auto-stop (the convenience form). Pass options.seconds. Returns {path, width, height, seconds, fps, bytes}.",
        inputSchema: recordSchema) { p, args in
        let opts = args.object("options") ?? args.dictionary
        guard let seconds = RecordConfig.numOpt(opts["seconds"]), seconds > 0 else {
            throw BridgeError(code: "device_error", message: "screen.record convenience requires options.seconds > 0; use screen.record.start for start/stop handles")
        }
        let (target, dir, outputURL) = try await resolveRecordStart(opts, p)
        let started = await screen.recorder.start(
            target: target, opts: opts, destinationDir: dir, outputURL: outputURL,
            ownerPortId: p.portId,
            portFrameLookup: { appState.portWindows.portFrame(by: $0) })
        if let err = started["error"] as? String { throw BridgeError(code: "device_error", message: err) }
        guard let rid = started["recordingId"] as? String else {
            throw BridgeError(code: "device_error", message: "screen.record: start returned no recordingId")
        }
        try? await Task.sleep(nanoseconds: UInt64(min(seconds, 3600) * 1_000_000_000))
        return try avResult(await screen.recorder.stop(recordingId: rid))
    }

    // Tail item 4 — rest.call. One body for all surfaces, carrying BOTH old paths' semantics: the
    // port path's dict-body support and the tool path's per-companion secret grant + filtered
    // response headers. JS calls (url, opts-bag); tool-use passes flat keys; reads fall through
    // bag-then-flat. Schema text matches the frozen golden byte-for-byte (parity-checked).
    r["rest.call"] = BridgeMethod(permission: .rest, paramNames: ["url", "options"],
        description: "Make an HTTP request to an external API. Use the 'secret' parameter to inject authentication from the secrets store — you never see the raw credential. Supports GET, POST, PUT, PATCH, DELETE. JSON bodies are auto-serialized. Responses with JSON content-type are auto-parsed.",
        inputSchema: [
            "type": "object",
            "properties": [
                "url": ["type": "string", "description": "Full URL to call (https recommended)"],
                "method": ["type": "string", "description": "HTTP method: GET, POST, PUT, PATCH, DELETE. Default: GET."],
                "headers": [
                    "type": "object",
                    "description": "Additional HTTP headers as key-value pairs.",
                    "additionalProperties": ["type": "string"]
                ] as [String: Any],
                "body": ["type": "string", "description": "Request body. Objects are JSON-serialized automatically."],
                "secret": ["type": "string", "description": "Named secret from the secrets store. The runtime injects the auth header — you never see the raw key."],
                "timeout": ["type": "integer", "description": "Timeout in milliseconds. Default: 30000, max: 120000."]
            ],
            "required": ["url"]
        ]) { p, args in
        let bag = args.object("options") ?? args.dictionary
        func optString(_ key: String) -> String? { (bag[key] as? String) ?? args.string(key) }
        func optInt(_ key: String) -> Int? { (bag[key] as? Int) ?? args.int(key) }
        func optObject(_ key: String) -> [String: Any]? { (bag[key] as? [String: Any]) ?? args.object(key) }

        let url = try args.requireString("url")
        guard let parsed = URL(string: url), parsed.scheme != nil else {
            throw BridgeError.badArg("rest.call requires a valid URL")
        }

        // Secret scoping: a companion may only use secrets granted to it in its settings.
        let secretName = optString("secret")
        if let secretName, p.kind == .companion {
            let allowed = appState.companions.first(where: { $0.id == p.id })?.secretNames ?? []
            guard allowed.contains(secretName) else {
                throw BridgeError.permissionDenied("companion does not have access to secret '\(secretName)'")
            }
        }

        var request = URLRequest(url: parsed)
        request.httpMethod = (optString("method") ?? "GET").uppercased()
        request.timeoutInterval = TimeInterval(min(optInt("timeout") ?? 30000, 120000)) / 1000.0
        if let headers = optObject("headers") as? [String: String] {
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        }
        if let body = optString("body") {
            request.httpBody = body.data(using: .utf8)
        } else if let bodyObj = optObject("body"),
                  let jsonData = try? JSONSerialization.data(withJSONObject: bodyObj) {
            request.httpBody = jsonData
        }
        if request.httpBody != nil, request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let secretName {
            guard let (headerName, headerValue) = Port42AuthStore.shared.resolveSecretHeader(name: secretName) else {
                throw BridgeError.notFound("secret '\(secretName)'")
            }
            request.setValue(headerValue, forHTTPHeaderField: headerName)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        var result: [String: Any] = ["status": httpResponse?.statusCode ?? 0]
        if let headers = httpResponse?.allHeaderFields as? [String: String] {
            var filtered: [String: String] = [:]
            for key in ["content-type", "x-request-id", "x-ratelimit-remaining", "retry-after", "location"] {
                if let v = headers.first(where: { $0.key.lowercased() == key })?.value { filtered[key] = v }
            }
            if !filtered.isEmpty { result["headers"] = filtered }
        }
        let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("json"), let json = try? JSONSerialization.jsonObject(with: data) {
            result["body"] = json
        } else if let text = String(data: data, encoding: .utf8) {
            result["body"] = text   // full body to every caller; the model path bounds it in ToolExecutor
        }
        return .fromJSONObject(result)
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

    // Resolve a caller path. Relative → inside the data-dir sandbox (traversal blocked). Absolute →
    // only if THIS principal picked it (tail item 7: grants live on AppState keyed by principal id,
    // the Phase-3 seam); anything else is access_denied.
    func resolve(_ path: String, for p: Principal) throws -> String {
        if path.hasPrefix("/") {
            let standardized = (path as NSString).standardizingPath
            guard appState.principalHasPickedPath(standardized, principalId: p.id) else {
                throw BridgeError(code: "access_denied", message: "absolute paths require a file picked by this caller — use fs.pick")
            }
            return standardized
        }
        // Block traversal out of the sandbox.
        let joined = (BridgeFilePaths.dataDir as NSString).appendingPathComponent(path)
        let standardized = (joined as NSString).standardizingPath
        guard standardized.hasPrefix((BridgeFilePaths.dataDir as NSString).standardizingPath) else {
            throw BridgeError(code: "escape", message: "path escapes the data directory")
        }
        return standardized
    }

    // fs.pick: the user-consent path to absolute file access. Presents the native panel and grants
    // every chosen path to the CALLING principal. Not an LLM tool (a companion cannot pop panels).
    let picker = FileBridge()
    r["fs.pick"] = BridgeMethod(permission: .filesystem, paramNames: ["options"], toolExposed: false,
        description: "Open the native file picker. The chosen paths become readable and writable for the calling principal via fs.read / fs.write.") { p, args in
        let result = await picker.pick(opts: args.object("options") ?? args.dictionary)
        if let one = result["path"] as? String { appState.grantPickedPath(one, to: p.id) }
        if let many = result["paths"] as? [String] {
            for path in many { appState.grantPickedPath(path, to: p.id) }
        }
        return .fromJSONObject(result)
    }

    r["fs.read"] = BridgeMethod(permission: .filesystem, paramNames: ["path", "encoding"],
        description: "Read a file. Use a relative path (e.g. \"scopes/strategy/scope.md\") to read from the Port42 data directory without a file picker. Use an absolute path for picker-approved files.",
        inputSchema: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Relative path within Port42 data directory (e.g. \"scopes/strategy/scope.md\") or absolute path for picker-approved files."],
                "encoding": ["type": "string", "description": "utf8 (default) or base64"]
            ],
            "required": ["path"]
        ]) { p, args in
        let path = try resolve(try args.requireString("path"), for: p)
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

    r["fs.write"] = BridgeMethod(permission: .filesystem, paramNames: ["path", "data", "encoding"],
        description: "Write a file. Use a relative path (e.g. \"scopes/strategy/facts.md\") to write to the Port42 data directory — parent directories are created automatically. Use an absolute path for picker-approved files.",
        inputSchema: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Relative path within Port42 data directory (e.g. \"scopes/strategy/facts.md\") or absolute path for picker-approved files."],
                "data": ["type": "string", "description": "Content to write"],
                "encoding": ["type": "string", "description": "utf8 (default) or base64"]
            ],
            "required": ["path", "data"]
        ]) { p, args in
        let path = try resolve(try args.requireString("path"), for: p)
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

    r["fs.list"] = BridgeMethod(permission: .filesystem, paramNames: ["path"],
        description: "List the contents of a directory in the Port42 data directory. Relative paths only (e.g. \"scopes/strategy\" or \"scopes/strategy/decisions\"). Returns a sorted list of filenames.",
        inputSchema: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Relative path to the directory (e.g. \"scopes/strategy\")"]
            ],
            "required": ["path"]
        ]) { p, args in
        let path = try resolve(try args.requireString("path"), for: p)
        do {
            let items = try FileManager.default.contentsOfDirectory(atPath: path)
            return .object(["items": .array(items.sorted().map { .string($0) })])
        } catch {
            throw BridgeError(code: "io", message: error.localizedDescription)
        }
    }

    r["fs.mkdir"] = BridgeMethod(permission: .filesystem, paramNames: ["path"],
        description: "Create a directory (and any missing parent directories) in the Port42 data directory. Relative paths only (e.g. \"scopes/strategy/decisions\").",
        inputSchema: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Relative path to create (e.g. \"scopes/strategy/decisions\")"]
            ],
            "required": ["path"]
        ]) { p, args in
        let path = try resolve(try args.requireString("path"), for: p)
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

    // (Shared helpers stay ABOVE the first method entry: the Spike B source scan attributes
    // preamble reads to every method in the segment.)
    func targetSpace(_ p: Principal, _ args: BridgeArgs) -> String {
        args.string("space_id") ?? p.spaceId ?? appState.currentSpace?.id ?? ""
    }
    func senderName(_ p: Principal, _ args: BridgeArgs) -> String {
        if let override = args.string("senderName") ?? args.string("sender_name"), !override.isEmpty { return override }
        if p.kind == .companion, let c = appState.companions.first(where: { $0.id == p.id }) { return c.displayName }
        return appState.currentUser?.displayName ?? "agent"
    }

    // help: the API reference, GENERATED from the registry (close-out step 4c) — the conceptual
    // preamble is the llms-preamble.txt resource, the inventory renders from the live registries.
    // A surface affordance for port JS and the gateway, not an LLM tool.
    // Tool-exposed (GM decision 2026-07-19): help with topics is the ONE lazy-load mechanism for
    // platform knowledge on every surface — an in-app companion pulls the port-craft manual the
    // same way Claude Code, Codex, or a curl caller would, instead of carrying it resident.
    r["help"] = BridgeMethod(permission: nil, paramNames: ["topic"],
        description: "Return the Port42 API reference. Pass topic:\"ports\" for the port-authoring manual (read it BEFORE building or editing a port: sizing, module-scope, patterns, the design system). No topic returns the full method reference.",
        inputSchema: [
            "type": "object",
            "properties": [
                "topic": ["type": "string", "description": "Optional. \"ports\" = the port-authoring manual. Omit for the API reference."]
            ]
        ]) { _, args in
        switch args.string("topic") {
        case nil, "":
            return .string(appState.apiReference)
        case "ports":
            return .string(AppState.portsContext)
        case let other?:
            throw BridgeError(code: "not_found", message: "unknown help topic '\(other)' — known topics: ports")
        }
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

    // Tail item 2. Not an LLM tool (companions navigate by talking; switching the visible space is a
    // surface affordance), so toolExposed: false — same class as the audio playback methods.
    r["space.switchTo"] = BridgeMethod(permission: nil, paramNames: ["space_id"], toolExposed: false,
        description: "Switch the app's current space by id.") { _, args in
        let id = try args.requireString("space_id")
        guard let space = appState.spaces.first(where: { $0.id == id }) else {
            throw BridgeError.notFound("space '\(id)'")
        }
        appState.selectSpace(space)
        return .object(["ok": .bool(true)])
    }

    r["space.setWorkingDirectory"] = BridgeMethod(permission: nil, paramNames: ["space_id", "path"], toolExposed: false,
        description: "Set (or clear) a space's working directory. Command companions spawned in the space default their cwd here so they share one workspace; each still gets its own claude session. Empty path clears it (falls back to home). Defaults to the current space.",
        inputSchema: [
            "type": "object",
            "properties": [
                "space_id": ["type": "string", "description": "Space id (default: current space)."],
                "path": ["type": "string", "description": "Absolute directory path. Empty clears the setting."]
            ],
            "required": ["path"]
        ]) { p, args in
        let id = args.string("space_id") ?? p.spaceId ?? appState.currentSpace?.id ?? ""
        let path = args.string("path")
        guard appState.setSpaceWorkingDirectory(path, spaceId: id) else {
            throw BridgeError.notFound("space '\(id)'")
        }
        let resolved = appState.spaces.first(where: { $0.id == id })?.workingDirectory
        return .object(["ok": .bool(true), "workingDirectory": resolved.map { .string($0) } ?? .null])
    }

    r["companions.list"] = BridgeMethod(permission: nil, paramNames: ["space_id"],
        description: "List the companions in a space with their names, models, and trigger modes. Defaults to YOUR space — the companions you share this space with — because a companion acts within its space, not the whole instance. Pass space_id to target a different space, or space_id:\"*\" for the full global roster across every space in the Port42 instance (rarely what you want).",
        inputSchema: [
            "type": "object",
            "properties": [
                "space_id": ["type": "string", "description": "Omit for your own space (the default). A space id targets that space. \"*\" returns the whole-instance roster."]
            ]
        ]) { p, args in
        let sid = Port42Members.resolveScope(requested: args.string("space_id"),
                                             principalSpace: p.spaceId, currentSpace: appState.currentSpace?.id)
        let companions = Port42Members.companions(appState: appState, spaceId: sid)
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

    // Tail item 1. Sends attributed to the CALLING principal's display identity (companion name on
    // the gateway/tool-use surfaces; the port's createdBy, falling back to its title, on port JS).
    // Replaces the old port-only switch case, whose createdBy-required guard becomes "requires a
    // caller identity" under the unified principal. Not an LLM tool (companions' replies are already
    // attributed; this is the identity path for CLI/terminal callers), so toolExposed: false.
    r["messages.sendAsCreator"] = BridgeMethod(permission: nil, paramNames: ["text", "space_id"], toolExposed: false,
        description: "Send a message to a space attributed to the calling principal's display identity.") { p, args in
        let text = try args.requireString("text")
        guard !text.isEmpty else {
            throw BridgeError.badArg("messages.sendAsCreator requires a non-empty text argument")
        }
        let senderName = p.displayName
        guard !senderName.isEmpty else {
            throw BridgeError.badArg("messages.sendAsCreator requires a caller identity")
        }
        let target = args.string("space_id") ?? p.spaceId
        appState.sendMessageAsNamedAgent(content: text, senderName: senderName, toSpaceId: target)
        // Clear the typing indicator: terminal companions set it at routing time but have no stream
        // delegate to clear it (moved verbatim from the old port switch case).
        if let sid = target {
            appState.typingAgentNamesBySpace[sid, default: []].remove(senderName)
            appState.sync.sendTyping(spaceId: sid, senderName: senderName, isTyping: false,
                                     senderOwner: appState.currentUser?.displayName)
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

    r["ports.list"] = BridgeMethod(permission: nil, paramNames: ["capabilities", "space_id"],
        description: "List active ports. Each port has an id (UDID), title, capabilities array, status, spaceId, createdBy, and cwd (if it has a terminal). Terminal ports also report surfaceBound. Use capabilities: [\"terminal\"] to filter to terminal ports; pass space_id to list only that space's ports. Use the id field with port_push for reliable routing (raw keystrokes to terminals, data to web ports). Always show the id and capabilities fields when presenting results — they are required for follow-up tool calls.",
        inputSchema: [
            "type": "object",
            "properties": [
                "capabilities": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Filter to ports that have all of these capabilities. Examples: \"terminal\", \"claude-code\", \"browser\". Omit to list all ports."
                ] as [String: Any],
                "space_id": ["type": "string", "description": "List only this space's ports. Omit to list every space's."]
            ]
        ]) { p, args in
        let filterCaps = (args.array("capabilities") as? [String]) ?? []
        let filterSpace = args.string("space_id")
        let registered = appState.portWindows.allPorts()
        let inline = appState.inlinePorts().filter { $0.spaceId == p.spaceId || p.spaceId == nil }.suffix(5)

        // Snapshot the counters once, before building the list. A value type, so every entry reports
        // the same instant — a listing whose rows were read at different moments would hand out
        // tokens that were never all true together.
        let activity = appState.portActivity

        var entries: [BridgeValue] = []
        func entry(id: String, title: String, createdBy: String?, capabilities: [String],
                   cwd: String?, status: String, spaceId: String?, x: CGFloat?, y: CGFloat?,
                   surfaceBound: Bool?) {
            if !filterCaps.isEmpty && !filterCaps.allSatisfy({ capabilities.contains($0) }) { return }
            if let filterSpace, spaceId != filterSpace { return }
            var o: [String: BridgeValue] = [
                "id": .string(id), "title": .string(title),
                "capabilities": .array(capabilities.map { .string($0) }),
                "status": .string(status),
                // R3: the port's activity token, so a caller can compose a write against the state
                // it just read and pass it back as `expect`. Surfaced on the DISCOVERY call because
                // that is where a caller already learns the id — a token you have to make a second
                // call for is a token nobody uses.
                "token": .string(activity.token(for: id)),
            ]
            if let spaceId { o["spaceId"] = .string(spaceId) }
            if let createdBy { o["createdBy"] = .string(createdBy) }
            if let cwd { o["cwd"] = .string(cwd) }
            if let surfaceBound { o["surfaceBound"] = .bool(surfaceBound) }
            if let x, let y { o["x"] = .double(Double(x)); o["y"] = .double(Double(y)) }
            entries.append(.object(o))
        }
        for pt in registered {
            entry(id: pt.udid, title: pt.title, createdBy: pt.createdBy, capabilities: pt.capabilities,
                  cwd: pt.cwd, status: pt.isBackground ? "docked" : pt.presentation, spaceId: pt.spaceId,
                  x: pt.x, y: pt.y,
                  surfaceBound: appState.terminalControllers[pt.udid]?.isSurfaceBound)
        }
        for pt in inline {
            entry(id: pt.id, title: pt.title, createdBy: pt.createdBy, capabilities: pt.capabilities,
                  cwd: pt.cwd, status: "inline", spaceId: pt.spaceId, x: nil, y: nil, surfaceBound: nil)
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
        // Phase L0: resolve a udid/title/name to the canonical udid for the DB read.
        let udid = appState.resolvePortRef(id)?.udid ?? id
        if let version = args.int("version") {
            guard let html = try? appState.db.fetchPortVersionHtml(udid: udid, version: version) else {
                throw BridgeError.notFound("version \(version) for port '\(id)'")
            }
            return .string(html)
        }
        if let html = try? appState.db.fetchPortHtml(udid: udid) { return .string(html) }
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
        let udid = appState.resolvePortRef(id)?.udid ?? id
        let versions = (try? appState.db.fetchPortVersions(portUdid: udid)) ?? []
        let iso = ISO8601DateFormatter()
        return .array(versions.map { v in
            .object([
                "version": .int(v.version),
                "createdBy": .string(v.createdBy ?? "unknown"),
                "createdAt": .string(iso.string(from: v.createdAt)),
            ])
        })
    }

    r["port.update"] = BridgeMethod(permission: nil, paramNames: ["id", "html"], writesTarget: "id",
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
        let target = appState.resolvePortRef(id)?.udid ?? id
        guard appState.portWindows.updatePort(idOrTitle: target, html: html) else {
            throw BridgeError.notFound("port '\(id)'")
        }
        return .object(["ok": .bool(true)])
    }

    r["port.patch"] = BridgeMethod(permission: nil, paramNames: ["id", "search", "replace"], writesTarget: "id",
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
        let udid = appState.resolvePortRef(id)?.udid ?? id
        guard let current = try? appState.db.fetchPortHtml(udid: udid) else {
            throw BridgeError.notFound("port '\(id)'")
        }
        guard current.contains(search) else {
            throw BridgeError.badArg("search string not found in port '\(id)' — read the current HTML with port.getHtml and copy the exact string")
        }
        let patched = current.replacingOccurrences(of: search, with: replace)
        guard appState.portWindows.updatePort(idOrTitle: udid, html: patched) else {
            throw BridgeError.notFound("port '\(id)'")
        }
        return .object(["ok": .bool(true)])
    }

    r["port.restore"] = BridgeMethod(permission: nil, paramNames: ["id", "version"], writesTarget: "id",
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
        let udid = appState.resolvePortRef(id)?.udid ?? id
        guard let html = try? appState.db.fetchPortVersionHtml(udid: udid, version: version) else {
            throw BridgeError.notFound("version \(version) for port '\(id)'")
        }
        guard appState.portWindows.updatePort(idOrTitle: udid, html: html) else {
            throw BridgeError.notFound("port '\(id)'")
        }
        return .object(["ok": .bool(true)])
    }

    r["port.rename"] = BridgeMethod(permission: nil, paramNames: ["id", "title"], writesTarget: "id",
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
        let ref = appState.resolvePortRef(id)
        appState.portWindows.renamePort(id: ref?.udid ?? id, title: title)
        if let bridge = appState.findInlineBridge(by: ref?.messageId ?? id) { bridge.title = title }
        return .object(["ok": .bool(true)])
    }

    r["port.move"] = BridgeMethod(permission: nil, paramNames: ["id", "x", "y"], writesTarget: "id",
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
        let target = appState.resolvePortRef(id)?.udid ?? id
        guard appState.portWindows.findPort(by: target) != nil else {
            throw BridgeError.notFound("port '\(id)'")
        }
        appState.portWindows.movePort(id: target, x: CGFloat(x), y: CGFloat(y))
        return .object(["ok": .bool(true)])
    }

    // MARK: Tail item 9 — self-referential port methods
    //
    // Keyed on the CALLER's own principal: for a call from inside a port's webview the adapter sets
    // principal.id to the port's identity, so the body resolves the caller's own panel (by udid or,
    // for inline fence ports, the anchoring messageId). None are LLM tools: a companion acts on
    // OTHER ports by id (port.rename / port.manage); these are the port acting on itself.

    /// The calling port's own panel, or not_found if the principal isn't a live panel.
    @MainActor func ownPanel(_ p: Principal) throws -> PortPanel {
        guard let panel = appState.portWindows.panels.first(where: { $0.udid == p.id || $0.messageId == p.id }) else {
            throw BridgeError.notFound("calling port's panel")
        }
        return panel
    }

    r["port.info"] = BridgeMethod(permission: nil, toolExposed: false,
        description: "Return the calling port's own id, title, space, capabilities, and activity token.") { p, _ in
        var info: [String: BridgeValue] = ["id": .string(p.id), "createdBy": .string(p.displayName)]
        if let sid = p.spaceId { info["spaceId"] = .string(sid) }
        // R3: a port's own token, for a port that reads-then-writes itself.
        if let key = appState.portKey(for: p.id) {
            info["token"] = .string(appState.portActivity.token(for: key))
        }
        return .object(info)
    }

    r["port.setTitle"] = BridgeMethod(permission: nil, paramNames: ["title"], toolExposed: false,
        description: "Set the calling port's own title.") { p, args in
        let title = try args.requireString("title")
        guard !title.isEmpty else { throw BridgeError.badArg("port.setTitle requires a non-empty title") }
        let panel = try ownPanel(p)
        panel.bridge.title = title
        appState.portWindows.renamePort(id: panel.udid, title: title)
        return .object(["ok": .bool(true)])
    }

    r["port.setCapabilities"] = BridgeMethod(permission: nil, paramNames: ["capabilities"], toolExposed: false,
        description: "Set the calling port's own capabilities list.") { p, args in
        guard let caps = args.array("capabilities") as? [String] else {
            throw BridgeError.badArg("port.setCapabilities requires an array of strings")
        }
        let panel = try ownPanel(p)
        panel.bridge.storedCapabilities = caps
        appState.portWindows.setCapabilities(id: panel.udid, capabilities: caps)
        return .object(["ok": .bool(true)])
    }

    r["port.close"] = BridgeMethod(permission: nil, toolExposed: false,
        description: "Close the calling port.") { p, _ in
        let panel = try ownPanel(p)
        appState.portWindows.close(panel.id)
        return .object(["ok": .bool(true)])
    }

    r["port.position"] = BridgeMethod(permission: nil, paramNames: ["id"], toolExposed: false,
        description: "Return a port's position and size.") { _, args in
        let id = try args.requireString("id")
        guard let frame = appState.portWindows.portFrame(by: id) else {
            throw BridgeError.notFound("port '\(id)' (no positioned tile)")
        }
        return .object([
            "x": .double(frame.origin.x), "y": .double(frame.origin.y),
            "width": .double(frame.size.width), "height": .double(frame.size.height),
        ])
    }
}
