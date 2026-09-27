import Foundation

// MARK: - Storage service (knowledge faculty — the third, simplest tenant)
//
// A scoped key-value store. The third service extracted, and the simplest: its surface names equal its
// canonical names, so its manifest declares an EMPTY name-map (the "no rename" case, which the shape
// must handle as cleanly as Keeper's renames). Bodies are behavior-preserving moves of the former
// registerStorageMethods. See `docs/bridge-architecture-and-mcp.md` §6.
//
// Contract (GM: no backward compatibility, one clean shape):
//   scope   = opts.scope=="global" ? "__global__" : the caller's space (a port's: its own space)
//   creator = opts.shared ? "__shared__" : a port's page stores under "port:<its key>" (each port its
//             own; it was the port's creator, so two ports one companion made shared a bucket), any
//             other caller under its principal id
// A copy of a shared port on another machine names the port (`port`) and reaches that port's own
// bucket, reading with `see` and writing with `use`; never the space's shared bucket or the global one
// (nautilus Phase 4, 4.7b). Every change is a `storage` event to every copy.
//   get -> { value }   set/delete -> { ok }   list -> { keys }

@MainActor
func storageManifest() -> ServiceManifest {
    ServiceManifest(service: "storage", methods: [
        ManifestMethod(
            canonical: "storage.get", paramNames: ["key", "options"],
            description: "Get a value from persistent key-value storage",
            inputSchema: [
                "type": "object",
                "properties": ["key": ["type": "string", "description": "The storage key"],
                               "port": portArg, "scope": scopeArg, "shared": sharedArg],
                "required": ["key"]
            ]),
        ManifestMethod(
            canonical: "storage.set", paramNames: ["key", "value", "options"],
            description: "Store a value in persistent key-value storage",
            inputSchema: [
                "type": "object",
                "properties": [
                    "key": ["type": "string", "description": "The storage key"],
                    "value": ["type": "string", "description": "The value to store"],
                    "port": portArg, "scope": scopeArg, "shared": sharedArg
                ],
                "required": ["key", "value"]
            ]),
        ManifestMethod(
            canonical: "storage.delete", paramNames: ["key", "options"],
            description: "Delete a value from persistent storage",
            inputSchema: [
                "type": "object",
                "properties": ["key": ["type": "string", "description": "The storage key to delete"],
                               "port": portArg, "scope": scopeArg, "shared": sharedArg],
                "required": ["key"]
            ]),
        ManifestMethod(
            canonical: "storage.list", paramNames: ["options"],
            description: "List all keys in persistent storage",
            inputSchema: ["type": "object", "properties": ["port": portArg, "scope": scopeArg, "shared": sharedArg]]),
    ])
}

/// The options a named caller may pass flat (a port passes them in `options`).
private let scopeArg: [String: Any] = ["type": "string", "enum": ["global"],
    "description": "\"global\" for storage shared across spaces; omit for this space's."]
private let sharedArg: [String: Any] = ["type": "boolean",
    "description": "true for the space's shared bucket rather than the caller's own."]

/// `port` on a storage call: a copy of a shared port on another machine names the port whose storage
/// it means. A port's own page never needs it.
private let portArg: [String: Any] = ["type": "string",
    "description": "For a copy of a port shared from another machine: that port's id, to reach its own storage there."]

@MainActor
func registerStorageService(into r: inout BridgeRegistry, appState: AppState) {

    // opts arrive nested (JS positional: (key, value, {scope,shared})) or flat (tool/gateway named
    // dict). Scope derives from the PRINCIPAL, so a port and a companion each land in the scope that
    // matches who they are, without a per-surface branch.
    func scope(_ p: Principal, _ args: BridgeArgs) throws -> (scope: String, creator: String, port: String?) {
        let opts = args.object("options") ?? args.dictionary
        let global = (opts["scope"] as? String) == "global"
        let shared = (opts["shared"] as? Bool) ?? false
        // Another machine reaches one shared port's own bucket, named by `port`; its rights on that
        // port were checked before this body ran (RemoteAccess).
        if p.kind == .remote {
            guard !global, !shared else {
                throw BridgeError(code: .notGranted, message: "only a shared port's own storage is reachable from another machine")
            }
            guard let raw = args.string("port"), let key = appState.resolvePortRef(raw)?.key,
                  let space = appState.portWindows.panels.first(where: { $0.udid == key })?.spaceId else {
                throw BridgeError.notFound("a shared port to store for")
            }
            return (space, "port:" + key, key)
        }
        // A port's page stores under the port itself, in its own space.
        if p.kind == .port, let own = p.portId, let key = appState.resolvePortRef(own)?.key {
            let space = appState.portWindows.panels.first(where: { $0.udid == key })?.spaceId ?? p.spaceId
            guard let space else { throw BridgeError.badArg("storage requires space context for space-scoped storage") }
            if global { return ("__global__", shared ? "__shared__" : "port:" + key, nil) }
            return (space, shared ? "__shared__" : "port:" + key, shared ? nil : key)
        }
        let scope: String
        if global {
            scope = "__global__"
        } else if let sid = p.spaceId {
            scope = sid
        } else {
            throw BridgeError.badArg("storage requires space context for space-scoped storage")
        }
        return (scope, shared ? "__shared__" : p.id, nil)
    }

    /// A port's storage changed: every copy hears it, the port's own page and those subscribed to it
    /// (a tile on another machine, a browser guest), so each can load the key again.
    func announce(_ s: (scope: String, creator: String, port: String?), key: String) {
        guard let port = s.port, !s.scope.hasPrefix("__") else { return }
        let payload = BridgeValue.object(["key": .string(key)])
        // The port's own page hears it, and that also publishes it on the port's topic for its copies.
        if let page = appState.portWindows.panels.first(where: { $0.udid == port })?.bridge {
            page.pushEvent(.storage, data: payload)
        } else {
            appState.notifyBus.publish(topic: PortNotify.topic(forPortKey: port), kind: PortEventKind.storage.wire, payload: payload)
        }
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
            } else if let data = SafeJSON.data(rawValue, options: [.fragmentsAllowed]),
                      let json = String(data: data, encoding: .utf8) {
                stored = json
            } else {
                throw BridgeError.badArg("storage.set value must be serializable")
            }
            try appState.db.setPortStorage(key: key, value: stored, scope: s.scope, creatorId: s.creator)
            announce(s, key: key)
            return .object(["ok": .bool(true)])
        },
        "storage.delete": { p, args in
            let key = try args.requireString("key")
            let s = try scope(p, args)
            try appState.db.deletePortStorage(key: key, scope: s.scope, creatorId: s.creator)
            announce(s, key: key)
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
            throw BridgeError(code: .noBody, message: "storage: no in-process body for \(canonical)")
        }
        return try await body(principal, args)
    }
}
