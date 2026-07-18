import Foundation
import AppKit

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
    return r
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

    r["clipboard.read"] = BridgeMethod(permission: .clipboard) { _, _ in
        .fromJSONObject(clipboard.read())
    }

    r["clipboard.write"] = BridgeMethod(permission: .clipboard, paramNames: ["data"]) { _, args in
        guard let data = args.any("data") else { throw BridgeError.missingArg("data") }
        return .fromJSONObject(clipboard.write([data]))
    }

    // No permission (docs: "no permissions required"). NSScreen, structured array — the canonical
    // form of the old `screen_info` text blob.
    r["screen.displays"] = BridgeMethod(permission: nil) { _, _ in
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

    r["fs.read"] = BridgeMethod(permission: .filesystem, paramNames: ["path", "encoding"], wired: false) { _, args in
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

    r["fs.write"] = BridgeMethod(permission: .filesystem, paramNames: ["path", "data", "encoding"], wired: false) { _, args in
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

    r["fs.list"] = BridgeMethod(permission: .filesystem, paramNames: ["path"], wired: false) { _, args in
        let path = try resolve(try args.requireString("path"))
        do {
            let items = try FileManager.default.contentsOfDirectory(atPath: path)
            return .object(["items": .array(items.sorted().map { .string($0) })])
        } catch {
            throw BridgeError(code: "io", message: error.localizedDescription)
        }
    }

    r["fs.mkdir"] = BridgeMethod(permission: .filesystem, paramNames: ["path"], wired: false) { _, args in
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

    r["user.get"] = BridgeMethod(permission: nil) { _, _ in
        guard let user = appState.currentUser else { throw BridgeError(code: "no_user", message: "no user signed in") }
        return .object(["id": .string(user.id), "displayName": .string(user.displayName)])
    }

    r["space.current"] = BridgeMethod(permission: nil, paramNames: ["space_id"]) { _, args in
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

    r["space.list"] = BridgeMethod(permission: nil) { _, _ in
        .array(appState.spaces.map { .object(["id": .string($0.id), "name": .string($0.name)]) })
    }

    r["companions.list"] = BridgeMethod(permission: nil, paramNames: ["space_id"]) { _, args in
        let companions = Port42Members.companions(appState: appState, spaceId: args.string("space_id"))
        return .array(companions.map { c in
            .object([
                "id": .string(c.id), "name": .string(c.displayName),
                "model": .string(c.model ?? "unknown"), "trigger": .string(c.trigger.rawValue),
            ])
        })
    }

    r["companions.get"] = BridgeMethod(permission: nil, paramNames: ["id"]) { _, args in
        let id = try args.requireString("id")
        guard let c = appState.companions.first(where: { $0.id == id }) else {
            throw BridgeError.notFound("companion '\(id)'")
        }
        return .object([
            "id": .string(c.id), "name": .string(c.displayName),
            "model": .string(c.model ?? "unknown"), "systemPrompt": .string(c.systemPrompt ?? ""),
        ])
    }

    r["messages.recent"] = BridgeMethod(permission: nil, paramNames: ["count", "space_id", "topic"]) { p, args in
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

    r["bus.read"] = BridgeMethod(permission: nil, paramNames: ["topic", "limit", "space_id"]) { p, args in
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

    r["bus.publish"] = BridgeMethod(permission: nil, paramNames: ["topic", "payload", "space_id"]) { p, args in
        let topic = try args.requireString("topic")
        let payload = try args.requireString("payload")
        appState.publishToBus(spaceId: targetSpace(p, args), topic: topic, payload: payload, senderName: senderName(p, args))
        return .object(["ok": .bool(true), "topic": .string(topic)])
    }

    r["messages.send"] = BridgeMethod(permission: nil, paramNames: ["text", "space_id"]) { p, args in
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

    r["ports.list"] = BridgeMethod(permission: nil, paramNames: ["capabilities"]) { p, args in
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

    r["port.getHtml"] = BridgeMethod(permission: nil, paramNames: ["id", "version"]) { _, args in
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

    r["port.history"] = BridgeMethod(permission: nil, paramNames: ["id"]) { _, args in
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

    r["port.update"] = BridgeMethod(permission: nil, paramNames: ["id", "html"]) { _, args in
        let id = try args.requireString("id")
        let html = try args.requireString("html")
        guard appState.portWindows.updatePort(idOrTitle: id, html: html) else {
            throw BridgeError.notFound("port '\(id)'")
        }
        return .object(["ok": .bool(true)])
    }

    r["port.patch"] = BridgeMethod(permission: nil, paramNames: ["id", "search", "replace"]) { _, args in
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

    r["port.restore"] = BridgeMethod(permission: nil, paramNames: ["id", "version"]) { _, args in
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

    r["port.rename"] = BridgeMethod(permission: nil, paramNames: ["id", "title"]) { _, args in
        let id = try args.requireString("id")
        let title = try args.requireString("title")
        guard !title.isEmpty else { throw BridgeError.badArg("port.rename requires a non-empty title") }
        appState.portWindows.renamePort(id: id, title: title)
        if let bridge = appState.findInlineBridge(by: id) { bridge.title = title }
        return .object(["ok": .bool(true)])
    }

    r["port.move"] = BridgeMethod(permission: nil, paramNames: ["id", "x", "y"]) { _, args in
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

    r["storage.get"] = BridgeMethod(permission: nil, paramNames: ["key", "options"]) { p, args in
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

    r["storage.set"] = BridgeMethod(permission: nil, paramNames: ["key", "value", "options"]) { p, args in
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

    r["storage.delete"] = BridgeMethod(permission: nil, paramNames: ["key", "options"]) { p, args in
        let key = try args.requireString("key")
        let s = try scope(p, args)
        try appState.db.deletePortStorage(key: key, scope: s.scope, creatorId: s.creator)
        return .object(["ok": .bool(true)])
    }

    r["storage.list"] = BridgeMethod(permission: nil, paramNames: ["options"]) { p, args in
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

    r["crease.read"] = BridgeMethod(permission: nil) { p, args in
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

    r["crease.write"] = BridgeMethod(permission: nil, paramNames: ["content"]) { p, args in
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

    r["crease.touch"] = BridgeMethod(permission: nil, paramNames: ["id"]) { _, args in
        guard let id = args.string("id") else { throw BridgeError.badArg("crease_touch requires 'id'") }
        try appState.db.touchCrease(id: id)
        return .string("ok")
    }

    r["crease.forget"] = BridgeMethod(permission: nil, paramNames: ["id"]) { _, args in
        guard let id = args.string("id") else { throw BridgeError.badArg("crease_forget requires 'id'") }
        try appState.db.deleteCrease(id: id)
        return .string("ok")
    }

    // MARK: engravings

    r["engrave.read"] = BridgeMethod(permission: nil) { p, args in
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

    r["engrave.write"] = BridgeMethod(permission: nil, paramNames: ["content"]) { p, args in
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

    r["engrave.touch"] = BridgeMethod(permission: nil, paramNames: ["id"]) { _, args in
        guard let id = args.string("id") else { throw BridgeError.badArg("engrave_touch requires 'id'") }
        try appState.db.touchEngraving(id: id)
        return .string("ok")
    }

    r["engrave.forget"] = BridgeMethod(permission: nil, paramNames: ["id"]) { _, args in
        guard let id = args.string("id") else { throw BridgeError.badArg("engrave_forget requires 'id'") }
        try appState.db.deleteEngraving(id: id)
        return .string("ok")
    }

    // MARK: fold

    r["fold.read"] = BridgeMethod(permission: nil) { p, args in
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

    r["fold.update"] = BridgeMethod(permission: nil) { p, args in
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

    r["position.read"] = BridgeMethod(permission: nil) { p, args in
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

    r["position.set"] = BridgeMethod(permission: nil, paramNames: ["read"]) { p, args in
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
