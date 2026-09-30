import AppKit
import WebKit

// MARK: - port.look / port.act (browser use, Phase 2: docs/plan-browser-use.md)

extension AppState {

    /// The grant object for a site a companion uses in a browser port, beside `secret:<name>`.
    static func siteObject(_ host: String) -> String { "site:\(host.lowercased())" }

    /// May this caller look at or act on this site in a browser port? The person may see the page
    /// is theirs, so a companion is asked once per site, by a card naming it, and the answer is kept
    /// (revocable in Settings, Access). The person is never asked about their own use.
    func ensureSiteGrant(_ host: String, for p: Principal) async throws -> Bool {
        if p.kind == .human { return true }
        let object = Self.siteObject(host)
        if (try? db.grants(grantee: p.id, object: object, zone: ""))?.contains(.browser) == true { return true }
        guard try await ask(.browser, from: p,
                            detail: "Use \(host) in your browser, where you may be signed in") else { return false }
        try? db.saveGrants([.browser], grantee: p.id, object: object, zone: "")
        return true
    }

    /// Port42's own input to a port, for a companion, is not the person driving it. The port's input
    /// tap sees the events as trusted (they are real events), so for a moment after an act they are not
    /// counted as the person's (right of way stays with the person's own hands).
    func markAgentInput(on portUdid: String, for seconds: TimeInterval = 1.0) {
        agentInputUntil[portUdid] = Date().addingTimeInterval(seconds)
    }

    func isAgentInput(on portUdid: String, now: Date = Date()) -> Bool {
        guard let until = agentInputUntil[portUdid] else { return false }
        return now < until
    }
}

@MainActor
func registerBrowserUseMethods(into r: inout BridgeRegistry, appState: AppState) {

    /// The live web view a look or act works on, and the checks every call makes: the caller may see
    /// the port, it is a web or browser port, it is on screen (input needs a window), and, for a browser
    /// port, the caller may use its site.
    func surface(_ p: Principal, _ id: String) async throws -> (PortRef, WKWebView, PortPanel, Bool) {
        let ref = try appState.requireReadablePort(id, by: p)
        guard ref.kind == .web || ref.kind == .browser, let pid = ref.id,
              let panel = appState.portWindows.panels.first(where: { $0.id == pid }),
              let wv = appState.portWindows.webViews[pid] else {
            throw BridgeError.notFound("web or browser port '\(id)'")
        }
        // Paused means the person set it aside: nothing acts on it. Anything else that is not on screen
        // (running with no tile, or a tile on another space) is worked on out of sight (Gordon, 2026-09-30).
        guard panel.presentation != "parked" else {
            throw BridgeError(code: .portPaused,
                              message: "port '\(id)' is paused; it has to be running or shown before it can be looked at or acted on")
        }
        let offscreen = wv.window == nil && appState.portWindows.hostOffscreen(pid)
        guard wv.window != nil else {
            throw BridgeError(code: .noSurface, message: "port '\(id)' has no page to work on")
        }
        if ref.kind == .browser, let host = wv.url?.host, !host.isEmpty {
            do {
                guard try await appState.ensureSiteGrant(host, for: p) else {
                    throw BridgeError(code: .permissionDenied, message: "not allowed to use \(host) in the browser")
                }
            } catch {
                if offscreen { appState.portWindows.releaseOffscreen(pid) }
                throw error
            }
        }
        return (ref, wv, panel, offscreen)
    }

    func token(_ ref: PortRef) -> BridgeValue? {
        ref.key.map { .string(appState.portInput.token(for: $0)) }
    }

    r["port.look"] = BridgeMethod(permission: nil, paramNames: ["id"],
        description: "See a web or browser port as the person sees it, to act on it with port_act. Returns image (the path of a PNG of the visible page with every actionable element outlined and numbered: read it with your image tool), elements ([{n, role, label, box:[x,y,w,h]}] in page pixels; a field also has type and value, never a password's value), text (the visible page's text), url, title and token. Look again after every act: the numbers are this look's. A browser port asks the person once per site before a companion may look at or act on it. The port must be on the desktop.",
        inputSchema: [
            "type": "object",
            "properties": ["id": ["type": "string", "description": "The port's UDID (from ports_list)"]],
            "required": ["id"]
        ]) { p, args in
        let id = try args.requireString("id")
        let (ref, wv, panel, offscreen) = try await surface(p, id)
        defer { if offscreen { appState.portWindows.releaseOffscreen(panel.id) } }
        let raw = try? await wv.callAsyncJavaScript(BrowserLook.scanJS, arguments: [:], in: nil, contentWorld: BrowserLook.world)
        let (elements, text) = BrowserLook.parse(raw)
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        var imagePath: String?
        if let page = try? await wv.takeSnapshot(configuration: config),
           let png = BrowserLook.markedPNG(page, size: wv.bounds.size, elements: elements, scale: wv.magnification) {
            let url = BrowserLook.directory.appendingPathComponent("\(panel.udid.prefix(8))-\(Int(Date().timeIntervalSince1970 * 1000)).png")
            if (try? png.write(to: url)) != nil { imagePath = url.path }
        }
        var out: [String: BridgeValue] = [
            "elements": .array(elements.map(\.bridgeValue)),
            "text": .string(text),
            "url": .string(wv.url?.absoluteString ?? ""),
            "title": .string(wv.title ?? ""),
        ]
        if let imagePath { out["image"] = .string(imagePath) }
        if let t = token(ref) { out["token"] = t }
        return .object(out)
    }

    r["port.act"] = BridgeMethod(permission: nil,
        paramNames: ["id", "action", "n", "x", "y", "text", "key", "dy", "url", "token"], writesTarget: "id",
        description: "Do one step in a web or browser port, as the person would, after port_look. action: click (element n from your last look, or a point x,y in page pixels), type (text into element n, clicking it first, or into what has focus), key (a key: enter, tab, escape, up, down, left, right, pageup, pagedown, home, end, backspace, space, or one character as a site's shortcut, with modifiers as cmd+k, shift+tab), scroll (dy page pixels, down is positive, over element n or the page), navigate (url), back, forward. Delivered as real input, so the page treats it as a person's. Returns url, title and navigated, and a new token; look again before the next step. Refused as stale_write if the person touched the port since your look.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The port's UDID (from ports_list)"],
                "action": ["type": "string", "enum": ["click", "type", "key", "scroll", "navigate", "back", "forward"]],
                "n": ["type": "integer", "description": "An element number from your last port_look"],
                "x": ["type": "number", "description": "click: page x in pixels, when not naming an element"],
                "y": ["type": "number", "description": "click: page y in pixels, when not naming an element"],
                "text": ["type": "string", "description": "type: the text to enter"],
                "key": ["type": "string", "description": "key: the key, with any modifiers joined by + (cmd+enter)"],
                "dy": ["type": "number", "description": "scroll: pixels, down is positive"],
                "url": ["type": "string", "description": "navigate: the address"],
                "token": ["type": "string", "description": "REQUIRED. The port's token from your last look or act."]
            ],
            "required": ["id", "action", "token"]
        ]) { p, args in
        let id = try args.requireString("id")
        let action = try args.requireString("action")
        let (ref, wv, panel, offscreen) = try await surface(p, id)
        defer { if offscreen { appState.portWindows.releaseOffscreen(panel.id) } }
        let before = wv.url
        /// What the card says the companion is doing, for a port worked on out of sight as much as one on screen.
        @MainActor func doing(_ what: String) { appState.agentActs[panel.id] = (p.displayName, what, Date()) }
        @MainActor func label(_ n: Int) async -> String {
            let js = "const el = (globalThis.__port42marks || [])[n - 1]; if (!el) return '';"
                   + " return (el.getAttribute('aria-label') || el.innerText || el.getAttribute('placeholder') || el.getAttribute('title') || '').replace(/\\s+/g, ' ').trim().slice(0, 40);"
            return ((try? await wv.callAsyncJavaScript(js, arguments: ["n": n], in: nil, contentWorld: BrowserLook.world)) as? String) ?? ""
        }
        @MainActor func named(_ n: Int?) async -> String {
            guard let n else { return "the page" }
            let l = await label(n)
            return l.isEmpty ? "element \(n)" : "'\(l)'"
        }
        appState.markAgentInput(on: panel.udid, for: 3)
        defer { appState.markAgentInput(on: panel.udid, for: 0.6) }

        /// The center of element n from the last look, scrolled into view, in page pixels.
        func center(_ n: Int) async throws -> CGPoint {
            let js = "const el = (globalThis.__port42marks || [])[n - 1]; if (!el || !el.isConnected) return null;"
                   + " el.scrollIntoView({block: 'nearest', inline: 'nearest'});"
                   + " const r = el.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2];"
            guard let xy = (try? await wv.callAsyncJavaScript(js, arguments: ["n": n], in: nil, contentWorld: BrowserLook.world)) as? [NSNumber],
                  xy.count == 2 else {
                throw BridgeError(code: .notFound, message: "no element \(n) on the page now; look again")
            }
            return CGPoint(x: xy[0].doubleValue, y: xy[1].doubleValue)
        }
        /// Give element n the page's focus, from Port42's world. Handing the person's keyboard back after
        /// a click takes the web view out of first responder, and WebKit then blurs the page; focus set
        /// by script holds without it (measured), so a field clicked or typed into stays focused.
        func focus(_ n: Int) async {
            let js = "const el = (globalThis.__port42marks || [])[n - 1]; if (el && el.isConnected && el.focus) el.focus({preventScroll: true});"
            _ = try? await wv.callAsyncJavaScript(js, arguments: ["n": n], in: nil, contentWorld: BrowserLook.world)
        }
        func toView(_ css: CGPoint) -> CGPoint {
            BrowserAct.viewPoint(cssX: css.x, cssY: css.y, magnification: wv.magnification)
        }

        try await BrowserAct.keepingKeyboard(wv) {
        switch action {
        case "click":
            doing("clicking \(await named(args.int("n")))")
            let css: CGPoint
            if let n = args.int("n") { css = try await center(n) }
            else if let x = args.double("x"), let y = args.double("y") { css = CGPoint(x: x, y: y) }
            else { throw BridgeError(code: .missingArg, message: "click needs n (an element) or x and y") }
            await BrowserAct.click(wv, at: toView(css))
            if let n = args.int("n") { await focus(n) }
        case "type":
            let text = try args.requireString("text")
            doing("typing into \(await named(args.int("n")))")
            if let n = args.int("n") { _ = try await center(n); await focus(n) }
            let js = "const a = document.activeElement;"
                   + " if (!a || !(a.isContentEditable || a.tagName === 'INPUT' || a.tagName === 'TEXTAREA')) return false;"
                   + " return document.execCommand('insertText', false, text);"
            let ok = (try? await wv.callAsyncJavaScript(js, arguments: ["text": text], in: nil, contentWorld: BrowserLook.world)) as? Bool
            guard ok == true else {
                throw BridgeError(code: .noSurface, message: "nothing on the page takes text there; click a field first (or pass n)")
            }
        case "key":
            let spec = try args.requireString("key")
            doing("pressing \(spec)")
            let parts = spec.split(separator: "+").map(String.init)
            guard let name = parts.last, let k = BrowserAct.key(name) else {
                throw BridgeError(code: .badArg, message: "unknown key '\(spec)'")
            }
            await BrowserAct.press(wv, code: k.code, chars: k.chars, modifiers: BrowserAct.modifiers(Array(parts.dropLast())))
        case "scroll":
            let dy = args.double("dy") ?? 400
            doing("scrolling")
            let css: CGPoint
            if let n = args.int("n") { css = try await center(n) }
            else { css = CGPoint(x: wv.bounds.width / 2 / max(wv.magnification, 0.01), y: wv.bounds.height / 2 / max(wv.magnification, 0.01)) }
            await BrowserAct.scroll(wv, at: toView(css), dy: dy)
        case "navigate":
            let raw = try args.requireString("url")
            guard let url = URL(string: PortWindowManager.normalizedBrowserURL(raw)) else {
                throw BridgeError(code: .badArg, message: "not an address: '\(raw)'")
            }
            if ref.kind == .browser, let host = url.host, !host.isEmpty {
                guard try await appState.ensureSiteGrant(host, for: p) else {
                    throw BridgeError(code: .permissionDenied, message: "not allowed to use \(host) in the browser")
                }
            }
            doing("going to \(url.host ?? raw)")
            appState.browserNavigated(port: panel.udid, to: url)
            wv.load(URLRequest(url: url))
        case "back": doing("going back"); wv.goBack()
        case "forward": doing("going forward"); wv.goForward()
        default:
            throw BridgeError(code: .badArg, message: "unknown action '\(action)'")
        }
        }
        // Let the page answer before reporting, and wait out a navigation the act set off: a site that
        // routes a moment after the click (Gmail) would otherwise move the port's token after this returned,
        // and the companion's next act would be refused as stale (found on the Gmail test, 2026-09-30).
        await BrowserAct.settle(wv)
        var out: [String: BridgeValue] = [
            "ok": .bool(true),
            "url": .string(wv.url?.absoluteString ?? ""),
            "title": .string(wv.title ?? ""),
            "navigated": .bool(wv.url != before),
        ]
        if let t = token(ref) { out["token"] = t }
        return .object(out)
    }
}
