import Foundation

// MARK: - Keeper service (the first manifest-declared, in-process service)
//
// Keeper is the memory DSL: epistemic memory (crease / fold / position — how the companion's model of
// the relationship breaks and reforms) and knowledge (engrave — facts about the user's world). It is
// the second service extracted (after `ai`), and the one that tests whether the manifest shape proven
// externally in Spike D holds for an in-process service. See `docs/bridge-architecture-and-mcp.md` §6.
//
// Two things Keeper brings that `ai` did not:
//   - a DECLARED DSL name-map: the JS surface is plural (`creases.*`, `engravings.*`) while the methods
//     are singular (`crease.*`, `engrave.*`). Each method declares both its canonical and its surface
//     name, and the map derives from that (`ServiceManifest.nameMap`). This replaces the literal's
//     inconsistent per-call patching (`creases.read` dispatched a name that resolved nowhere) and folds
//     into the same mechanism as `files.* -> fs.*`.
//   - an in-process body bound per canonical name. The manifest carries the CONTRACT (names, schema,
//     permission, paramNames); `registerManifest`'s generic body dispatches to these closures. Same
//     manifest an external plugin would ship, only the body binding differs.
//
// Bodies are behavior-preserving moves of the former `registerMemoryMethods`.

/// Keeper's declaration, as data. Surface names differ from canonical only for crease/engrave (plural).
@MainActor
func keeperManifest() -> ServiceManifest {
    ServiceManifest(service: "keeper", methods: [
        // MARK: creases (epistemic memory)
        ManifestMethod(
            canonical: "crease.read", surface: "creases.read",
            description: "Read your creases — the moments where your prediction broke and something reformed. These shape your posture in this relationship. Read these before responding in an ongoing relationship.",
            inputSchema: [
                "type": "object",
                "properties": ["limit": ["type": "integer", "description": "Max entries to return. Default 8."]]
            ]),
        ManifestMethod(
            canonical: "crease.write", surface: "creases.write", paramNames: ["content"],
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
            ]),
        ManifestMethod(
            canonical: "crease.touch", surface: "creases.touch", paramNames: ["id"],
            description: "Mark a crease as currently shaping this response. Updates its recency and increases its weight. Use when an existing crease is active — don't re-write it.",
            inputSchema: [
                "type": "object",
                "properties": ["id": ["type": "string", "description": "The crease id (from crease_read)."]],
                "required": ["id"]
            ]),
        ManifestMethod(
            canonical: "crease.forget", surface: "creases.forget", paramNames: ["id"],
            description: "Remove a crease. Use when your model has updated and the break no longer matters.",
            inputSchema: [
                "type": "object",
                "properties": ["id": ["type": "string", "description": "The crease id to remove."]],
                "required": ["id"]
            ]),
        // MARK: engravings (knowledge)
        ManifestMethod(
            canonical: "engrave.read", surface: "engravings.read",
            description: "Read your engravings — factual knowledge about the user's world. Context, preferences, constraints, goals, capabilities. Things learned about their situation, not breaks in your model. Read these alongside creases to understand who you're swimming with.",
            inputSchema: [
                "type": "object",
                "properties": ["limit": ["type": "integer", "description": "Max entries to return. Default 8."]]
            ]),
        ManifestMethod(
            canonical: "engrave.write", surface: "engravings.write", paramNames: ["content"],
            description: "Carve an engraving — a fact about the user's world worth keeping. Not what changed in you (that's a crease) — what you learned about their situation. Use category to classify: context, preference, constraint, goal, capability.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "content": ["type": "string", "description": "The factual knowledge about their world."],
                    "category": ["type": "string", "description": "Optional: context, preference, constraint, goal, capability."],
                    "spaceId": ["type": "string", "description": "Omit for a global engraving that shapes all relationships."]
                ],
                "required": ["content"]
            ]),
        ManifestMethod(
            canonical: "engrave.touch", surface: "engravings.touch", paramNames: ["id"],
            description: "Mark an engraving as currently relevant to this response. Updates recency and increases weight. Use when an existing engraving is shaping what you say.",
            inputSchema: [
                "type": "object",
                "properties": ["id": ["type": "string", "description": "The engraving id (from engrave_read)."]],
                "required": ["id"]
            ]),
        ManifestMethod(
            canonical: "engrave.forget", surface: "engravings.forget", paramNames: ["id"],
            description: "Remove an engraving. Use when the fact is no longer true or no longer matters.",
            inputSchema: [
                "type": "object",
                "properties": ["id": ["type": "string", "description": "The engraving id to remove."]],
                "required": ["id"]
            ]),
        // MARK: fold (epistemic memory) — surface == canonical
        ManifestMethod(
            canonical: "fold.read",
            description: "Read the fold — your orientation in this relationship. Returns established understandings, tensions being held, what you're carrying, and relational depth. If no fold exists yet, returns empty state.",
            inputSchema: ["type": "object", "properties": [String: Any]()]),
        ManifestMethod(
            canonical: "fold.update",
            description: "Update the fold — your orientation in this relationship. Update specific fields: established (shared understandings), tensions (unresolved threads), holding (the one thing you're carrying). Use depthDelta: 1 only when a real fold happened — something new was compressed into the relationship, not just a message exchanged.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "established": ["type": "array", "items": ["type": "string"], "description": "Shared understandings that no longer need renegotiation."] as [String: Any],
                    "tensions": ["type": "array", "items": ["type": "string"], "description": "Unresolved things being held in productive suspension."] as [String: Any],
                    "holding": ["type": "string", "description": "The one thread you're carrying that hasn't found its place yet."],
                    "depthDelta": ["type": "integer", "description": "Pass 1 when a real fold happened. Never more than 1 per exchange."]
                ]
            ]),
        // MARK: position (epistemic memory) — surface == canonical
        ManifestMethod(
            canonical: "position.read",
            description: "Read your current position in this space — what you think is actually happening beneath the surface, what you think needs to happen, and what signals you're watching. Returns empty if you haven't formed a position yet.",
            inputSchema: ["type": "object", "properties": [String: Any]()]),
        ManifestMethod(
            canonical: "position.set", paramNames: ["read"],
            description: "Establish or update your position — where you stand independent of what was just asked. This is not what you say. It's what you see and what you believe. Call this when your read of the situation changes, not after every exchange. A position gives you somewhere to push back from.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "read": ["type": "string", "description": "What you think is actually happening beneath what's being said."],
                    "stance": ["type": "string", "description": "What you think needs to happen."],
                    "watching": ["type": "array", "items": ["type": "string"], "description": "Signals you're tracking that would confirm or change your read."] as [String: Any]
                ],
                "required": ["read"]
            ]),
    ])
}

/// Register Keeper: the manifest supplies the contract; these closures supply the in-process bodies,
/// bound by canonical name through `registerManifest`'s generic body.
@MainActor
func registerKeeperService(into r: inout BridgeRegistry, appState: AppState) {

    // Space resolution mirrors ToolExecutor.memReadSpaceId / memWriteSpaceId (D4: memory is
    // space-scoped — the current space, or the companion's DM when headless).
    func readSpace(_ companionId: String, _ principalSpace: String?) -> String? {
        if let s = principalSpace { return s }
        return (try? appState.db.directSpaceId(companionId: companionId)) ?? nil
    }
    func writeSpace(_ companionId: String, _ principalSpace: String?) -> String? {
        if let s = principalSpace { return s }
        return (try? appState.db.getOrCreateDirectSpaceId(companionId: companionId)) ?? nil
    }

    let bodies: [String: @MainActor (Principal, BridgeArgs) async throws -> BridgeValue] = [
        "crease.read": { p, args in
            let companionId = p.id
            let limit = args.int("limit") ?? 8
            let sid = readSpace(companionId, p.spaceId)
            let creases = (try? appState.db.fetchCreases(companionId: companionId, spaceId: sid, limit: limit)) ?? []
            if creases.isEmpty { return .string("No creases yet. Creases form when a prediction breaks.") }
            let lines = creases.map { c -> String in
                var line = "[\(c.id)] \(c.asPromptText())"
                if c.spaceId == nil { line += " (global)" }
                return line
            }
            return .string(lines.joined(separator: "\n"))
        },
        "crease.write": { p, args in
            let companionId = p.id
            guard let content = args.string("content"), !content.isEmpty else {
                throw BridgeError.badArg("crease_write requires 'content'")
            }
            let crease = CompanionCrease(
                companionId: companionId, spaceId: writeSpace(companionId, p.spaceId),
                content: content, prediction: args.string("prediction"), actual: args.string("actual"))
            try appState.db.saveCrease(crease)
            return .object(["id": .string(crease.id), "ok": .bool(true)])
        },
        "crease.touch": { _, args in
            guard let id = args.string("id") else { throw BridgeError.badArg("crease_touch requires 'id'") }
            try appState.db.touchCrease(id: id)
            return .string("ok")
        },
        "crease.forget": { _, args in
            guard let id = args.string("id") else { throw BridgeError.badArg("crease_forget requires 'id'") }
            try appState.db.deleteCrease(id: id)
            return .string("ok")
        },
        "engrave.read": { p, args in
            let companionId = p.id
            let limit = args.int("limit") ?? 8
            let sid = readSpace(companionId, p.spaceId)
            let engravings = (try? appState.db.fetchEngravings(companionId: companionId, spaceId: sid, limit: limit)) ?? []
            if engravings.isEmpty { return .string("No engravings yet. Engravings form when you learn something about their world.") }
            let lines = engravings.map { e -> String in
                var line = "[\(e.id)] \(e.asPromptText())"
                if e.spaceId == nil { line += " (global)" }
                return line
            }
            return .string(lines.joined(separator: "\n"))
        },
        "engrave.write": { p, args in
            let companionId = p.id
            guard let content = args.string("content"), !content.isEmpty else {
                throw BridgeError.badArg("engrave_write requires 'content'")
            }
            let engraving = CompanionEngraving(
                companionId: companionId, spaceId: writeSpace(companionId, p.spaceId),
                content: content, category: args.string("category"))
            try appState.db.saveEngraving(engraving)
            return .object(["id": .string(engraving.id), "ok": .bool(true)])
        },
        "engrave.touch": { _, args in
            guard let id = args.string("id") else { throw BridgeError.badArg("engrave_touch requires 'id'") }
            try appState.db.touchEngraving(id: id)
            return .string("ok")
        },
        "engrave.forget": { _, args in
            guard let id = args.string("id") else { throw BridgeError.badArg("engrave_forget requires 'id'") }
            try appState.db.deleteEngraving(id: id)
            return .string("ok")
        },
        "fold.read": { p, args in
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
        },
        "fold.update": { p, args in
            let companionId = p.id
            guard let sid = writeSpace(companionId, p.spaceId) else { throw BridgeError.badArg("no space context for fold") }
            var fold = (try? appState.db.fetchFold(companionId: companionId, spaceId: sid))
                ?? CompanionFold(companionId: companionId, spaceId: sid)
            if let est = args.array("established") as? [String] { fold.established = est }
            if let ten = args.array("tensions") as? [String] { fold.tensions = ten }
            if let h = args.string("holding") { fold.holding = h.isEmpty ? nil : h }
            if let delta = args.int("depthDelta") { fold.depth = max(0, fold.depth + delta) }
            fold.updatedAt = Date()
            try appState.db.saveFold(fold)
            return .string("ok")
        },
        "position.read": { p, args in
            let companionId = args.string("companionId") ?? p.id
            let none: BridgeValue = .string("No position formed yet.")
            guard let sid = readSpace(companionId, p.spaceId) else { return none }
            guard let pos = try appState.db.fetchPosition(companionId: companionId, spaceId: sid), !pos.isEmpty else { return none }
            return .object([
                "read": .string(pos.read ?? ""),
                "stance": .string(pos.stance ?? ""),
                "watching": .array((pos.watching ?? []).map { .string($0) }),
                "confidence": .double(pos.confidence)
            ])
        },
        "position.set": { p, args in
            let companionId = p.id
            guard let read = args.string("read"), !read.isEmpty else { throw BridgeError.badArg("position_set requires 'read'") }
            guard let sid = writeSpace(companionId, p.spaceId) else { throw BridgeError.badArg("no space context for position") }
            var pos = (try? appState.db.fetchPosition(companionId: companionId, spaceId: sid))
                ?? CompanionPosition(companionId: companionId, spaceId: sid)
            pos.read = read
            if let stance = args.string("stance") { pos.stance = stance.isEmpty ? nil : stance }
            if let watching = args.array("watching") as? [String] { pos.watching = watching.isEmpty ? nil : watching }
            pos.updatedAt = Date()
            try appState.db.savePosition(pos)
            return .string("ok")
        },
    ]

    registerManifest(keeperManifest(), into: &r) { canonical, principal, args in
        guard let body = bodies[canonical] else {
            throw BridgeError(code: "no_body", message: "keeper: no in-process body for \(canonical)")
        }
        return try await body(principal, args)
    }
}
