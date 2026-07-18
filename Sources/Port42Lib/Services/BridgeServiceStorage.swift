import Foundation

// MARK: - Storage service (knowledge faculty — the third, simplest tenant)
//
// A scoped key-value store. The third service extracted, and the simplest: its surface names equal its
// canonical names, so its manifest declares an EMPTY name-map (the "no rename" case, which the shape
// must handle as cleanly as Keeper's renames). Bodies are behavior-preserving moves of the former
// registerStorageMethods. See `docs/bridge-architecture-and-mcp.md` §6.
//
// Contract (GM: no backward compatibility, one clean shape):
//   scope   = opts.scope=="global" ? "__global__" : the caller's space
//   creator = opts.shared ? "__shared__" : the caller's principal id
//   get -> { value }   set/delete -> { ok }   list -> { keys }

@MainActor
func storageManifest() -> ServiceManifest {
    ServiceManifest(service: "storage", methods: [
        ManifestMethod(
            canonical: "storage.get", paramNames: ["key", "options"],
            description: "Get a value from persistent key-value storage",
            inputSchema: [
                "type": "object",
                "properties": ["key": ["type": "string", "description": "The storage key"]],
                "required": ["key"]
            ]),
        ManifestMethod(
            canonical: "storage.set", paramNames: ["key", "value", "options"],
            description: "Store a value in persistent key-value storage",
            inputSchema: [
                "type": "object",
                "properties": [
                    "key": ["type": "string", "description": "The storage key"],
                    "value": ["type": "string", "description": "The value to store"]
                ],
                "required": ["key", "value"]
            ]),
        ManifestMethod(
            canonical: "storage.delete", paramNames: ["key", "options"],
            description: "Delete a value from persistent storage",
            inputSchema: [
                "type": "object",
                "properties": ["key": ["type": "string", "description": "The storage key to delete"]],
                "required": ["key"]
            ]),
        ManifestMethod(
            canonical: "storage.list", paramNames: ["options"],
            description: "List all keys in persistent storage",
            inputSchema: ["type": "object", "properties": [String: Any]()]),
    ])
}

@MainActor
func registerStorageService(into r: inout BridgeRegistry, appState: AppState) {

    // opts arrive nested (JS positional: (key, value, {scope,shared})) or flat (tool/gateway named
    // dict). Scope derives from the PRINCIPAL, so a port and a companion each land in the scope that
    // matches who they are, without a per-surface branch.
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

    let bodies: [String: @MainActor (Principal, BridgeArgs) async throws -> BridgeValue] = [
        "storage.get": { p, args in
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
        },
        "storage.set": { p, args in
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
        },
        "storage.delete": { p, args in
            let key = try args.requireString("key")
            let s = try scope(p, args)
            try appState.db.deletePortStorage(key: key, scope: s.scope, creatorId: s.creator)
            return .object(["ok": .bool(true)])
        },
        "storage.list": { p, args in
            let s = try scope(p, args)
            let keys = try appState.db.listPortStorageKeys(scope: s.scope, creatorId: s.creator)
            return .object(["keys": .array(keys.map { .string($0) })])
        },
    ]

    registerManifest(storageManifest(), into: &r) { canonical, principal, args in
        guard let body = bodies[canonical] else {
            throw BridgeError(code: "no_body", message: "storage: no in-process body for \(canonical)")
        }
        return try await body(principal, args)
    }
}
