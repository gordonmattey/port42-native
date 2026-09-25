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
    registerStorageService(into: &r, appState: appState)   // storage.* KV (BridgeServiceStorage.swift)
    registerPortMethods(into: &r, appState: appState)
    registerCommsMethods(into: &r, appState: appState)
    registerFileMethods(into: &r, appState: appState)
    registerDeviceMethods(into: &r, appState: appState)
    registerLiveDeviceMethods(into: &r, appState: appState)
    registerPortLiveMethods(into: &r, appState: appState)
    registerChatMethods(into: &r, appState: appState)       // chat.* (PortChat.swift)
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


    // Phase L1 (docs/plan-port42-protocol-local-bus.md): subscribe to a port's Notify stream. Yields
    // each { topic, kind, payload } envelope as the port emits it, until the caller cancels. Many
    // subscribers can watch one port; each gets every event (the NotifyBus fans out 1:N).
    r["port.subscribe"] = BridgeStreamMethod(
        permission: nil,
        paramNames: ["id"],
        toolExposed: false,
        description: "Subscribe to a port's live event stream. Yields Notify events { topic, kind, payload, token } as the port emits them (e.g. terminal.output). `token` is the port's state token AT THAT MOMENT, so you can write next without re-reading the port first. OVER THE GATEWAY THIS IS WEBSOCKET-ONLY: connect to /ws and send it as a `call` envelope, and events arrive as `stream` frames on the same call_id. On HTTP /call it is refused with `unsupported`, because the stream never ends and a request/response call could only hang. The stream stays open until cancelled.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The port to observe (id / udid / title)."] as [String: Any]
            ] as [String: Any],
            "required": ["id"]
        ],
        // Runs until cancelled. On a request/response door that is a hang, so the caller is refused
        // there with a message naming the door that works.
        endless: true
    ) { _, args, yield in
        let id = try args.requireString("id")
        let ref = appState.resolvePortRef(id)
        let topic = PortNotify.topic(forPortKey: ref?.key ?? id)
        let subId = appState.notifyBus.subscribe(topic: topic, deliver: yield)
        defer { appState.notifyBus.unsubscribe(id: subId, topic: topic) }
        // Hold the stream open until the caller cancels — the run executes on a tracked Task that is
        // cancelled on close/cancel (mirrors ai.complete's cancellation). Poll so cleanup is prompt.
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return .object(["ok": .bool(true)])
    }


    // I2 · C5 — the streaming twin of the one-shot injection above. A streaming write verb added
    // tomorrow gets compare-and-swap by construction, on the same terms, instead of silently
    // escaping the token because its registry had no notion of a write.
    return r.mapValues { $0.acceptingExpect() }
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
        description: "Create a port and return its id. The uniform way to make any port. type:\"web\" needs html (a full port HTML body) and renders inline in chat. type:\"terminal\" needs command and opens a native terminal (runs in /bin/zsh; the command is typed in — claude/gemini get the Port42 hooks). type:\"browser\" needs url and opens an embedded browser tile with an address bar that follows links. type:\"chat\" reveals that space's chat port (idempotent — one chat per space; brings it back if parked, popped out or closed, and a DM is a space, so pass its space_id to open that conversation). For terminals you may also pass args, cwd, systemPrompt (companion personality), env, and initialInput (a line left waiting, unsent, in the CLI's input box). Drive the result with port_push (input to terminals, data to web ports) and list with ports_list. Pass space_id to target a space (default: current).",
        inputSchema: [
            "type": "object",
            "properties": [
                "type": ["type": "string", "enum": ["web", "terminal", "browser", "chat"], "description": "The port type to create."],
                "title": ["type": "string", "description": "Port title (default: derived from html <title>, or the command)."],
                "html": ["type": "string", "description": "type:\"web\" — full port HTML body (include a <title> and <meta name=\"version\">)."],
                "command": ["type": "string", "description": "type:\"terminal\" — executable/CLI to run (e.g. \"bash\", \"htop\", \"claude\")."],
                "url": ["type": "string", "description": "type:\"browser\" — the page to open (e.g. \"https://example.com\")."],
                "args": ["type": "array", "items": ["type": "string"], "description": "type:\"terminal\" — arguments for the command."],
                "cwd": ["type": "string", "description": "type:\"terminal\" — working directory (default: home)."],
                "systemPrompt": ["type": "string", "description": "type:\"terminal\" — companion personality/role appended to the CLI's system prompt."],
                "env": ["type": "object", "description": "type:\"terminal\" — custom environment variables for the shell."],
                "initialInput": ["type": "string", "description": "type:\"terminal\" — a line typed into the CLI once it is up but NOT submitted: it waits in the input box for the user to press Enter. For handing someone a first prompt to run. Use port_push instead to actually send input."],
                "space_id": ["type": "string", "description": "Space to create the port in (default: current space)."],
                "presentation": ["type": "string", "description": "Where the port appears: \"tiled\" (default, a desktop tile) or \"parked\"."]
            ],
            "required": ["type"]
        ] as [String: Any]) { p, args in
        let o = args.object("options") ?? args.dictionary
        let sid = (o["space_id"] as? String) ?? p.spaceId ?? appState.currentSpace?.id ?? ""

        // THE GATE IS ON THE FIRST COMMAND, NOT THE SECOND (slice-02, GM 2026-07-29).
        //
        // `terminal.exec` requires `.terminal` and `browser.open` requires `.browser`, but creating
        // the PORT did neither — so both gates could be skipped by making a port instead of calling
        // the verb. `port42 teleport` is the live case: it created a terminal already running
        // `claude`, in the user's current space, with no prompt, and so could any local process that
        // reached the gateway.
        //
        // This needs NO NEW PERMISSION. Creating a terminal IS using the terminal; creating a
        // browser IS browsing. The escalation is keyed on `type`, in the body, which is the pattern
        // `screen.record` already uses when it asks for `.microphone` only because `audio` said so.
        //
        // `web` and `chat` stay ungated deliberately: a web port renders inert HTML, and `chat` only
        // reveals the space's own chat port and is idempotent. Neither starts anything.
        //
        // Landing this AFTER the grant reap matters. Had it come first, the 121 `.terminal` grants
        // given for `exec` would silently have started authorizing process spawning. With the store
        // empty, every caller consents to the wider meaning rather than inheriting it.
        // Through `ensurePermission`, not `permissions.request` — the request path PROMPTS, and only
        // the dispatcher's gate remembered the answer, so asking directly here would re-ask on every
        // single create.
        let needed: PortPermission? = {
            switch (o["type"] as? String)?.lowercased() {
            case "terminal": return .terminal
            case "browser": return .browser
            default: return nil          // web renders inert HTML; chat reveals an existing port
            }
        }()
        if let needed {
            guard await appState.ensurePermission(needed, for: p) else {
                throw BridgeError.permissionDenied(needed.rawValue)
            }
        }

        let result = appState.createPort(
            type: o["type"] as? String, title: o["title"] as? String, html: o["html"] as? String,
            command: o["command"] as? String, args: o["args"] as? [String] ?? [], cwd: o["cwd"] as? String,
            systemPrompt: o["systemPrompt"] as? String, env: o["env"] as? [String: String] ?? [:],
            spaceId: sid, createdBy: p.id, createdByName: p.displayName,
            presentation: o["presentation"] as? String,
            initialInput: o["initialInput"] as? String ?? "", url: o["url"] as? String)
        if let err = result["error"] as? String { throw BridgeError.badArg(err) }
        // WAIT FOR THE DOCUMENT before answering. Measured 2026-07-27: create returned 0.24s before
        // the port's DOM existed, so `port.exec` on a port you had just made found nothing — and the
        // manual teaches create-then-write, so a generated port reading its own DOM is exactly the
        // case that hit it. The panel id (not the udid) is the webview's key.
        if let id = result["id"] as? String,
           let panelId = appState.portWindows.panels.first(where: { $0.id == id || $0.udid == id })?.id {
            await appState.portWindows.awaitDocument(panelId)
        }
        // The creator holds a token from BIRTH, so its first write needs no read. Without this the
        // one caller who unambiguously knows the port's state (it just made it) would still have to
        // go and ask. Read AFTER the wait, so it reflects anything the load itself counted.
        var out = result
        if let id = result["id"] as? String, let key = appState.portKey(for: id) {
            out[PortActivity.tokenKey] = appState.portInput.token(for: key)
        }
        return .fromJSONObject(out)   // { id, title, token }
    }

    r["port.push"] = BridgeMethod(permission: nil, paramNames: ["id", "data"], writesTarget: "id",
        needsLiveSurface: true,
        description: "Send input to a port — one verb, dispatched by the port's type. A WEB port receives the data as a 'port42:data' CustomEvent with the payload in event.detail. A TERMINAL port receives the data as raw keystrokes typed into the shell: end with a newline (e.g. \"ls\\n\") to run the command, or omit it to leave the line waiting unsubmitted. Use the id from ports_list. Prefer this over port_exec for data transfer.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The port's UDID (from ports_list), or a terminal's name."],
                "data": ["description": "For web ports: any JSON value (object/array/string/number) delivered as event.detail. For terminal ports: a string of raw keystrokes (include \\n to execute). Required — omitting it is refused with missing_arg rather than sent as nothing, and a terminal refuses an explicit null because there is no keystroke for null."]
            ],
            "required": ["id", "data"]
        ]) { _, args in
        let id = try args.requireString("id")
        // REQUIRED MEANS REFUSED (2026-07-31). This was `args.any("data") ?? NSNull()` while the
        // schema above declared `data` required, so a push naming the wrong param (`text`) serialized
        // NSNull to the string "null" at :264 and TYPED IT AT A LIVE PROMPT, sixty times, each
        // answering ok:true. A terminal is a shell; a malformed call became text.
        //
        // Presence, not type: a web port's payload is legitimately any JSON value, and "" is a real
        // thing to send. Checked BEFORE the target is resolved, so a caller who got the argument
        // wrong is told THAT, rather than being sent to look for a port that was never the problem.
        let data = try args.requirePresent("data")
        // Phase L0: one resolver for the target (docs/plan-port42-protocol-local-bus.md). The PortRef
        // carries the full identity, so each branch uses the key its accessor keys on (terminal id /
        // webViews-key / inline messageId). Terminal-wins precedence lives in PortResolution now, not here.
        guard let ref = appState.resolvePortRef(id) else {
            NSLog("[Port42][portdrive] push id=%@ → NOTFOUND space=%@", id, appState.currentSpace?.name ?? "?")
            throw BridgeError.notFound("port '\(id)'")
        }
        NSLog("[Port42][portdrive] push id=%@ → %@ space=%@", id, ref.kind.rawValue, appState.currentSpace?.name ?? "?")
        // A TERMINAL TAKES KEYSTROKES, and there is no keystroke for null. Presence alone closes the
        // reported bug (an omitted `data` can no longer reach the prompt), but `{"data": null}` would
        // still serialize to the string "null" at the branch below and type it. Refused here rather
        // than in the branch so a rejected push publishes NOTHING: the republish below is what an
        // observer watches to see how a port is being driven, and an event for input that never
        // landed is the same lie in a quieter place. A web port is untouched — `event.detail = null`
        // is legitimate JSON, and only the shell has a prompt to corrupt.
        if ref.kind == .terminal, data is NSNull {
            throw BridgeError(code: .badArg,
                              message: "port.push to a terminal needs keystrokes, and `data` was null. "
                                     + "Send a string (end it with \\n to run it).")
        }
        // Phase L1: republish the delivered input on the port's Notify topic (a cheap no-op when nobody
        // subscribes), so an observer can watch what a port is being driven with.
        appState.notifyBus.publish(topic: PortNotify.topic(forPortKey: ref.key ?? id),
                                   kind: PortEventKind.push.wire,
                                   payload: BridgeValue.fromJSONObject(data))
        switch ref.kind {
        case .terminal:
            guard let tid = ref.id, let controller = appState.terminalControllers[tid] else {
                throw BridgeError(code: .noSurface, message: "terminal '\(id)' has no live surface")
            }
            let str = (data as? String) ?? (String(data: (try? JSONSerialization.data(withJSONObject: data, options: [.fragmentsAllowed])) ?? Data(), encoding: .utf8) ?? "")
            // AWAITED: a push is not finished until its Enter has landed, and the response's token
            // is read after this returns. Fire-and-forget handed back a token the deferred Enter
            // then moved, so threading it was refused every time (measured in Dev3).
            guard await controller.sendRaw(str) else { throw BridgeError(code: .noSurface, message: "terminal '\(id)' has no live surface") }
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
                "kind": ["type": "string", "description": "Event kind, e.g. 'state', 'progress', 'error'. Namespaced on the way out: you publish 'state', subscribers see 'port.state', so a port cannot emit a system event like 'driver' or 'browser.load'."],
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
            throw BridgeError(code: .notFound, message: "port.publish is only callable from within a port")
        }
        // NAMESPACED (2026-07-28). A port names its own events, and until now that name landed in the
        // same flat space as `driver`, `browser.load` and `terminal.output` — so a port could emit an
        // envelope indistinguishable from one Port42 sent. The prefix cannot be escaped, which is why
        // this is a prefix and not a list of reserved words: a blocklist would rot the moment a system
        // kind was added.
        let kind = PortEventKind.fromPort(try args.requireString("kind"))
        // A port's payload arrives as untyped JSON off the JS bridge, so this is the one place a
        // BridgeValue is PARSED rather than built. Everything downstream is typed from here on.
        let payload = BridgeValue.fromJSONObject(args.any("payload") ?? NSNull())
        appState.notifyBus.publish(topic: PortNotify.topic(forPortKey: ref.key ?? key),
                                   kind: kind, payload: payload)
        return .object(["ok": .bool(true)])
    }

    r["port.exec"] = BridgeMethod(permission: nil, paramNames: ["id", "js"], writesTarget: "id",
        needsLiveSurface: true,
        description: "Execute JavaScript on a live port. Use this to call functions, push data, or update state on an existing port without replacing its HTML. The JS runs in the port's webview context with access to window, document, and any globals the port defines.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The port's UDID (from ports_list)"],
                "js": ["type": "string", "description": "JavaScript code to execute in the port's context. Return a value to get it back in the response, as {value, token}. A bare expression yields its value (multi-line is fine). A multi-statement body needs an explicit return: `foo(); 42` is a syntax error, `foo(); return 42;` works."]
            ],
            "required": ["id", "js"]
        ]) { _, args in
        let id = try args.requireString("id")
        let js = try args.requireString("js")
        // Phase L0: resolve the target, then require a web surface (docs/plan-port42-protocol-local-bus.md).
        guard let ref = appState.resolvePortRef(id), ref.kind == .web || ref.kind == .browser,
              let wv = webView(ref.id ?? ref.messageId ?? id) else { throw BridgeError.notFound("port '\(id)'") }
        // #5: PortExecJS awaits promises + marshals objects; nil = undefined/no-return.
        //
        // The catch is what makes a failure ACTIONABLE. Thrown as-is, a JS error reached the caller
        // as the bare string "A JavaScript exception occurred" with no code, so an agent could not
        // branch on it and a human got no hint (register §5). Now: `js_syntax` or `js_error`, the
        // real exception text, and the body that actually ran — which differs from the source when
        // an expression was wrapped.
        do {
            guard let result = try await PortExecJS.run(wv, js) else { return .object(["ok": .bool(true)]) }
            return .fromJSONObject(result)
        } catch let e as PortExecError {
            throw BridgeError(code: e.code, message: e.errorDescription ?? "port.exec failed",
                              details: ["ran": { if case .jsFailed(_, let ran) = e { return ran } else { return js } }()])
        }
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
        if let key = ref.key { out["token"] = .string(appState.portInput.token(for: key)) }
        return .object(out)
    }

    r["port.manage"] = BridgeMethod(permission: nil, paramNames: ["id", "action"], writesTarget: "id",
        description: "Manage a port. Actions: focus (raise to the front of the desktop), close (archive it: it can be reopened with port.reopen), minimize/dock (off the desktop but still running), restore/undock (bring a docked port back onto the desktop). Check the status field from ports_list — 'tiled' | 'parked' | 'docked'.",
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
            _ = appState.portWindows.restore(panel.id)
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
        // Was `?? ""` while the schema declared it required, so a caller who misnamed the key got a
        // titled notification with nothing in it and no way to tell. Same class as port.push, lower
        // stakes, and it also reached UNUserNotificationCenter before anything could refuse it.
        let body = try args.requireString("body")
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
        if let err = r["error"] as? String { throw BridgeError(code: .browserError, message: err) }
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
        description: "Read the HTML of an open browser session, optionally scoped to a CSS selector.",
        inputSchema: [
            "type": "object",
            "properties": [
                "sessionId": ["type": "string", "description": "The browser session."],
                "options": ["type": "object", "description": "{ selector } to scope the read."],
                "selector": ["type": "string", "description": "CSS selector to read from (default: the whole page)."]
            ] as [String: Any],
            "required": ["sessionId"]
        ]) { _, args in
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
        if let err = result["error"] as? String { throw BridgeError(code: .deviceError, message: err) }
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
        case .failure(let e): throw BridgeError(code: .deviceError, message: e.message)
        }
        let audio = (opts["audio"] as? String) ?? "none"
        if audio == "mic" || audio == "both" {
            // `ensurePermission`, not `permissions.request` — the same defect `port.create`'s gate was
            // written to avoid. `request` PROMPTS; only the dispatcher's gate ever remembered the
            // answer, so this asked for the microphone on EVERY mic recording and the grant never
            // persisted. This was the precedent that made the flaw visible, and it was left live when
            // the create gate was fixed; now both go through the one implementation.
            guard await appState.ensurePermission(.microphone, for: p) else {
                throw BridgeError.permissionDenied(PortPermission.microphone.rawValue)
            }
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
            throw BridgeError(code: .deviceError, message: "screen.record convenience requires options.seconds > 0; use screen.record.start for start/stop handles")
        }
        let (target, dir, outputURL) = try await resolveRecordStart(opts, p)
        let started = await screen.recorder.start(
            target: target, opts: opts, destinationDir: dir, outputURL: outputURL,
            ownerPortId: p.portId,
            portFrameLookup: { appState.portWindows.portFrame(by: $0) })
        if let err = started["error"] as? String { throw BridgeError(code: .deviceError, message: err) }
        guard let rid = started["recordingId"] as? String else {
            throw BridgeError(code: .deviceError, message: "screen.record: start returned no recordingId")
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
                throw BridgeError(code: .accessDenied, message: "absolute paths require a file picked by this caller — use fs.pick")
            }
            return standardized
        }
        // Block traversal out of the sandbox.
        let joined = (BridgeFilePaths.dataDir as NSString).appendingPathComponent(path)
        let standardized = (joined as NSString).standardizingPath
        guard standardized.hasPrefix((BridgeFilePaths.dataDir as NSString).standardizingPath) else {
            throw BridgeError(code: .pathEscape, message: "path escapes the data directory")
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
            throw BridgeError(code: .io, message: error.localizedDescription)
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
            throw BridgeError(code: .io, message: error.localizedDescription)
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
            throw BridgeError(code: .io, message: error.localizedDescription)
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
            throw BridgeError(code: .io, message: error.localizedDescription)
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
            throw BridgeError(code: .notFound, message: "unknown help topic '\(other)' — known topics: ports")
        }
    }

    r["user.get"] = BridgeMethod(permission: nil,
        description: "Get the current user's identity (id and display name)",
        inputSchema: ["type": "object", "properties": [String: Any]()]) { _, _ in
        guard let user = appState.currentUser else { throw BridgeError(code: .noUser, message: "no user signed in") }
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
        // Members: the person and the space's companions (the old list was derived from who had
        // posted in the space's messages, which went with the old chat).
        var list: [SpaceMember] = []
        if let me = appState.currentUser {
            list.append(SpaceMember(senderId: me.id, name: me.displayName, type: "human", owner: nil))
        }
        for c in appState.companions(forSpace: ch.id) {
            list.append(SpaceMember(senderId: c.id, name: c.displayName, type: "agent",
                                    owner: appState.currentUser?.displayName))
        }
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
    r["space.create"] = BridgeMethod(permission: nil, paramNames: ["name", "switch"], toolExposed: false,
        description: "Create a space. Returns {id, name}. The name is lowercased with spaces as dashes. Pass switch: true to also make it the current space; by default the person stays where they are.",
        inputSchema: [
            "type": "object",
            "properties": [
                "name": ["type": "string", "description": "The space's name."],
                "switch": ["type": "boolean", "description": "Also switch to it (default false)."],
            ],
            "required": ["name"],
        ]) { _, args in
        let name = try args.requireString("name")
        guard let space = appState.createSpace(name: name, select: args.bool("switch") ?? false) else {
            throw BridgeError.badArg("space.create needs a non-empty name")
        }
        return .object(["id": .string(space.id), "name": .string(space.name)])
    }

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
        description: "Set (or clear) a space's working directory. Command companions spawned in the space default their cwd here so they share one workspace; each still gets its own claude session. Clearing falls back to home, and is a deliberate act: send path as null (or an empty string). OMITTING path is an error, not a clear. Defaults to the current space.",
        inputSchema: [
            "type": "object",
            "properties": [
                "space_id": ["type": "string", "description": "Space id (default: current space)."],
                "path": ["description": "Absolute directory path. Send null or \"\" to clear it and fall back to home. Required: omitting it is refused with missing_arg, so a malformed call cannot silently clear the setting."]
            ],
            "required": ["path"]
        ]) { p, args in
        let id = args.string("space_id") ?? p.spaceId ?? appState.currentSpace?.id ?? ""
        // PRESENCE DECIDES (GM option B, 2026-07-31). This was `args.string("path")`, which yields nil
        // for an omitted key exactly as it does for an explicit null — so a call that simply forgot
        // the argument CLEARED the space's working directory and answered `{"ok": true}`, and every
        // terminal created there afterwards silently fell back to home.
        //
        // Clearing stays reachable, because the UI has always had two acts ("Choose…" and "Clear (use
        // home)") and the API must be able to express both. It now costs a deliberate null instead of
        // an omission. Anything else present but not a string is a caller error, not a clear.
        let rawPath = try args.requirePresent("path")
        let path: String?
        if rawPath is NSNull {
            path = nil
        } else if let s = rawPath as? String {
            path = s          // "" still folds to nil via Space.normalizeWorkingDirectory, as before
        } else {
            throw BridgeError.badArg("path must be a string, or null to clear the working directory")
        }
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

/// Which DESKTOP a position verb is talking about (v46). A port renders on its home space and on
/// every space that kept it, and since 2026-08-03 it holds a position for each, so "move this port"
/// has to name one. An explicit `space_id` must be a desktop the port is actually on — silently
/// writing a position for a desktop it never appears on would be a value nothing reads.
@MainActor
private func desktopFor(_ panel: PortPanel, requested: String?, appState: AppState) throws -> String? {
    let desktops = [panel.spaceId].compactMap { $0 } + panel.adoptedSpaceIds
    if let requested {
        guard desktops.contains(requested) else {
            throw BridgeError.badArg("port '\(panel.udid)' is not on space '\(requested)' "
                                     + "(it is on: \(desktops.joined(separator: ", ")))")
        }
        return requested
    }
    if let current = appState.currentSpace?.id, desktops.contains(current) { return current }
    return panel.spaceId
}

@MainActor
private func registerPortMethods(into r: inout BridgeRegistry, appState: AppState) {

    r["port.reopen"] = BridgeMethod(permission: nil, paramNames: ["id"],
        description: "Reopen a closed port with its id, content, position and chat. A terminal relaunches its command in its last working directory. Closed ports are listed by ports_list with include_closed.",
        inputSchema: [
            "type": "object",
            "properties": ["id": ["type": "string", "description": "The closed port's id."]],
            "required": ["id"],
        ]) { _, args in
        let id = try args.requireString("id")
        guard appState.portWindows.reopen(id) else { throw BridgeError.notFound("closed port '\(id)'") }
        let key = appState.portWindows.panels.first { $0.id == id }?.udid ?? id
        return .object(["ok": .bool(true), "id": .string(id),
                        PortActivity.tokenKey: .string(appState.portInput.token(for: key))])
    }

    r["ports.list"] = BridgeMethod(permission: nil, paramNames: ["capabilities", "space_id", "include_closed"],
        description: "List active ports. Each port has an id (UDID), title, capabilities array, status, spaceId, createdBy (an id) with createdByName (who that is, for display), and cwd (if it has a terminal). Terminal ports also report surfaceBound. Use capabilities: [\"terminal\"] to filter to terminal ports; pass space_id to list only that space's ports. Use the id field with port_push for reliable routing (raw keystrokes to terminals, data to web ports). Always show the id and capabilities fields when presenting results — they are required for follow-up tool calls.",
        inputSchema: [
            "type": "object",
            "properties": [
                "capabilities": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Filter to ports that have all of these capabilities. Examples: \"terminal\", \"claude-code\", \"browser\". Omit to list all ports."
                ] as [String: Any],
                "space_id": ["type": "string", "description": "List only this space's ports. Omit to list every space's."],
                "include_closed": ["type": "boolean", "description": "Also list closed (archived) ports, with status 'closed'. Reopen one with port.reopen."]
            ]
        ]) { p, args in
        let filterCaps = (args.array("capabilities") as? [String]) ?? []
        let filterSpace = args.string("space_id")
        let registered = appState.portWindows.allPorts()

        // Snapshot the counters once, before building the list. A value type, so every entry reports
        // the same instant — a listing whose rows were read at different moments would hand out
        // tokens that were never all true together.
        let activity = appState.portInput.activitySnapshot
        // Who each creator id is, resolved once here on the main actor: registered clients first,
        // then companions by id.
        var creatorNames: [String: String] = [:]
        for c in appState.companions { creatorNames[c.id] = c.displayName }
        for c in appState.clientRegistry.clients() { creatorNames[c.id] = c.name }

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
            if let createdBy {
                o["createdBy"] = .string(createdBy)
                // The NAME a person reads (audit F7). `createdBy` is an id, and a companion's terminal
                // client id is `terminal-<panel>-<space>`, which tells nobody who made the port.
                if let name = creatorNames[createdBy] { o["createdByName"] = .string(name) }
            }
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
        if args.bool("include_closed") == true {
            for row in appState.portWindows.closedPorts() {
                let caps = (row.capabilities?.data(using: .utf8))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
                entry(id: row.udid ?? row.id, title: row.userTitle ?? row.title, createdBy: row.createdBy,
                      capabilities: caps, cwd: nil, status: "closed", spaceId: row.spaceId,
                      x: nil, y: nil, surfaceBound: nil)
            }
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

    r["port.update"] = BridgeMethod(permission: nil, paramNames: ["id", "html"], writesTarget: "id", replacesState: true,
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
        guard await appState.portWindows.updatePort(idOrTitle: target, html: html) else {
            throw BridgeError.notFound("port '\(id)'")
        }
        return .object(["ok": .bool(true)])
    }

    r["port.patch"] = BridgeMethod(permission: nil, paramNames: ["id", "search", "replace"], writesTarget: "id", replacesState: true,
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
        guard await appState.portWindows.updatePort(idOrTitle: udid, html: patched) else {
            throw BridgeError.notFound("port '\(id)'")
        }
        return .object(["ok": .bool(true)])
    }

    r["port.restore"] = BridgeMethod(permission: nil, paramNames: ["id", "version"], writesTarget: "id", replacesState: true,
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
        guard await appState.portWindows.updatePort(idOrTitle: udid, html: html) else {
            throw BridgeError.notFound("port '\(id)'")
        }
        return .object(["ok": .bool(true)])
    }

    r["port.rename"] = BridgeMethod(permission: nil, paramNames: ["id", "title"], writesTarget: "id", replacesState: true,
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
        // BOTH paths count, and the port may live in either: a desktop panel, or an inline bridge in
        // a chat message. Reporting success when NEITHER matched is what this verb used to do.
        let renamedPanel = appState.portWindows.renamePort(id: ref?.udid ?? id, title: title)
        var renamedInline = false
        if let bridge = appState.findInlineBridge(by: ref?.messageId ?? id) {
            bridge.title = title
            renamedInline = true
        }
        guard renamedPanel || renamedInline else { throw BridgeError.notFound("port '\(id)'") }
        return .object(["ok": .bool(true)])
    }

    r["port.move"] = BridgeMethod(permission: nil, paramNames: ["id", "x", "y", "space_id"], writesTarget: "id",
        needsLiveSurface: true,
        description: "Move a port's tile to specific desktop coordinates. Use screen_info to get display bounds first.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The port's UDID (from ports_list)"],
                "x": ["type": "number", "description": "Horizontal position in desktop points"],
                "y": ["type": "number", "description": "Vertical position in desktop points"],
                "space_id": ["type": "string", "description": "Which desktop to move it on. A port kept from another space is a tile on BOTH, with a position on each. Defaults to the current space when the port is on it, else the port's home space."]
            ],
            "required": ["id", "x", "y"]
        ]) { _, args in
        let id = try args.requireString("id")
        guard let x = args.double("x"), let y = args.double("y") else {
            throw BridgeError.badArg("port.move requires numeric x and y")
        }
        let target = appState.resolvePortRef(id)?.udid ?? id
        guard let panel = appState.portWindows.findPort(by: target) else {
            throw BridgeError.notFound("port '\(id)'")
        }
        let desktop = try desktopFor(panel, requested: args.string("space_id"), appState: appState)
        appState.portWindows.movePort(id: target, x: CGFloat(x), y: CGFloat(y), on: desktop)
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
            info["token"] = .string(appState.portInput.token(for: key))
        }
        return .object(info)
    }

    // WHAT A PORT SAID. A read, so it takes no token and moves nothing.
    //
    // Until now a port's output was write-only: a web port's console.log went to NSLog, a terminal's
    // output was published to whoever had already subscribed and then dropped. Neither reaches the
    // caller who most needs it — an agent that GENERATED a port and wants to know why it is throwing,
    // or anyone asking why a terminal looks empty. Subscribing does not help, because nobody
    // subscribes before the thing they did not expect.
    r["port.console"] = BridgeMethod(permission: nil, paramNames: ["id", "tail"],
        description: "Read what a port has printed — a web port's console.log/warn/error, or a terminal's output. Returns the most recent lines, oldest first, each with a level and a timestamp. Use it to debug a port you built: a generative port that throws at runtime says so here, and a terminal whose command died says nothing else at all. Pass the id from ports_list; tail defaults to 100.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The port's UDID (from ports_list), or a terminal's name."],
                "tail": ["type": "integer", "description": "How many recent lines to return (default 100)."]
            ],
            "required": ["id"]
        ]) { _, args in
        let id = try args.requireString("id")
        let tail = args.int("tail") ?? 100
        // Resolve through the same seam every other port verb uses, so a name, a panel id and a udid
        // all work here exactly as they do for port.push.
        guard let key = appState.resolvePortRef(id)?.key else {
            throw BridgeError(code: .notFound, message: "no port \(id)")
        }
        let lines = PortConsole.shared.recent(portId: key, tail: tail)
        let iso = ISO8601DateFormatter()
        return .object([
            "id": .string(key),
            "lines": .array(lines.map { line in
                .object(["level": .string(line.level),
                         "message": .string(line.text),
                         "at": .string(iso.string(from: line.at))])
            })
        ])
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

    r["port.position"] = BridgeMethod(permission: nil, paramNames: ["id", "space_id"], toolExposed: false,
        description: "Return a port's position and size on one desktop (a kept port has a position per desktop).") { _, args in
        let id = try args.requireString("id")
        let desktop = try appState.portWindows.findPort(by: id).map { try desktopFor($0, requested: args.string("space_id"), appState: appState) }
        guard let frame = appState.portWindows.portFrame(by: id, on: desktop ?? nil) else {
            throw BridgeError.notFound("port '\(id)' (no positioned tile)")
        }
        return .object([
            "x": .double(frame.origin.x), "y": .double(frame.origin.y),
            "width": .double(frame.size.width), "height": .double(frame.size.height),
        ])
    }
}
