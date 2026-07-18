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
    return r
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
