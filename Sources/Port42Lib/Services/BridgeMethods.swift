import Foundation

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
    return r
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
