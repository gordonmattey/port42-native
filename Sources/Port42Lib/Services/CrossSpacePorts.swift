import Foundation

// MARK: - Ports across spaces (#238, docs/plan-cross-space-ports.md)
//
// A PORT MAY REACH A PORT IN ANOTHER SPACE ONLY BY A GRANT. APP-10 confines a port's page to its own
// space, so a page asking about a port elsewhere is told `not_found` and cannot probe what other spaces
// hold. That stays the default. What changes is that the person can let one port reach one other, with
// the rights sharing already uses (`RemoteRight`: see, use, edit, wake_agents, fork), asked once by the
// cross-space card (`CrossSpaceAsk`), kept in the same `grants` table as an invite's rights, and shown
// and revocable in Settings, Access.
//
// THE GRANT. Grantee `port:<reading port's key>`, so it belongs to that one port: a fork has a new key
// and holds nothing, and a port's creator's other ports hold nothing. Object: the target's key, or
// `space:<id>` for the space box, which carries see and use only (edit is per port, always). Zone "",
// as for an invite. The `port:` prefix keeps these rows out of everything that lists another machine's
// rights (`allRemoteRights`).
//
// THE GATE runs after the remote gate, before the permission gate and the body. It acts only when a
// port names, BY ID, a web port in a space it cannot read, through a method whose right is in the table
// below. With the right held, it admits that one target for that one call (`Principal.reaching`), and
// the scope checks (`requireReadablePort`, `requireReadableChat`, the write seam, `state.get`,
// `port.fork`) admit exactly that key. A title never resolves across spaces, a terminal is never
// reached, and a method outside the table is not admitted at all, so `port.exec` stays `not_found` even
// with every right granted.

enum CrossSpace {

    /// The grantee for a reading port's grants.
    static func grantee(_ readerKey: String) -> String { "port:\(readerKey)" }

    /// The object for the space box: every port in that space.
    static func spaceObject(_ spaceId: String) -> String { "space:\(spaceId)" }

    /// How a method reaches a port in another space: the invite table (`RemoteAccess`), the port
    /// methods only, with these differences.
    static func reach(_ method: String) -> RemoteReach {
        switch method {
        // Taking a copy is its own right; a guest's copy is made on its side, a local one here.
        case "port.fork":
            return .port(param: "id", right: .fork)
        // Already answered across spaces without a grant (the subscriptions spike, #246, owns them),
        // so a card here would ask for something the caller already has.
        case "port.subscribe", "presence.list":
            return .never
        // About the caller's own space or its own storage bucket, never another space's.
        case "space.current", "companions.list", "storage.get", "storage.set", "storage.delete",
             "storage.list":
            return .never
        default:
            if case .port = RemoteAccess.reach(method) { return RemoteAccess.reach(method) }
            return .never
        }
    }
}

/// One row of Settings, Access: a port's rights on a port, or on every port, in another space.
public struct CrossSpaceGrantRow: Identifiable, Equatable {
    public var id: String { grantee + "|" + object }
    public let grantee: String
    public let object: String
    /// "Launch desk, small (port42-app)"
    public let reader: String
    /// "Launch desk in port42-growth", or "every port in port42-growth"
    public let target: String
    public let rights: Set<RemoteRight>
    /// The rights this row can hold: all five for one port, see and use for a space.
    public let offered: [RemoteRight]
}

@MainActor
extension AppState {

    /// The calling port's own key and title, or nil for a caller that is not one port's page.
    func crossSpaceReader(_ p: Principal) -> (key: String, title: String)? {
        guard p.kind == .port, let pid = p.portId, let key = resolvePortRef(pid)?.key else { return nil }
        return (key, portWindows.findPort(by: key)?.title ?? p.displayName)
    }

    /// What a port holds on a port in another space: its rights on that port, and see and use from a
    /// space box on that port's space.
    public func crossSpaceRights(reader readerKey: String, target targetKey: String,
                                 targetSpace: String) -> Set<RemoteRight> {
        let grantee = CrossSpace.grantee(readerKey)
        return remoteRights(of: grantee, onPort: targetKey)
            .union(remoteRights(of: grantee, onPort: CrossSpace.spaceObject(targetSpace))
                .intersection(CrossSpaceAsk.spaceWide))
    }

    /// Keep what the person picked on the card. Never narrows what the port already holds.
    func grantCrossSpace(_ choice: CrossSpaceChoice, for ask: CrossSpaceAsk) {
        let picked = choice.rights.intersection(CrossSpaceAsk.offered)
        let grantee = CrossSpace.grantee(ask.readerKey)
        if !picked.isEmpty {
            try? db.saveRemoteRights(remoteRights(of: grantee, onPort: ask.targetKey).union(picked),
                                     grantee: grantee, portKey: ask.targetKey)
        }
        let wide = picked.intersection(CrossSpaceAsk.spaceWide)
        if choice.wholeSpace, !wide.isEmpty {
            let object = CrossSpace.spaceObject(ask.targetSpaceId)
            try? db.saveRemoteRights(remoteRights(of: grantee, onPort: object).union(wide),
                                     grantee: grantee, portKey: object)
        }
    }

    /// **The cross-space gate.** Returns the caller, admitted to the target for this call when it
    /// holds the right; every other call goes on exactly as before, with no admission.
    ///
    /// Not granted anything: the card asks, once. A no stays `not_found`, as if never asked. Granted
    /// something, but not this: `permission_denied` naming the right, so the caller can say what to ask
    /// the person for; the person adds it in Settings, Access.
    func authorizeCrossSpace(_ method: String, principal: Principal, args: BridgeArgs) async throws -> Principal {
        let p = principal.reaching(nil)
        // Cheapest first, because this runs on every call: a page's subscribe, push and storage calls
        // leave at the first two lines without resolving anything.
        guard p.kind == .port, case .port(let param, let right) = CrossSpace.reach(method),
              let raw = args.string(param), let ref = resolvePortRef(raw), let key = ref.key,
              // By id only: a title that happens to match a port in another space must not reach it.
              [ref.id, ref.udid, ref.messageId].contains(raw),
              let space = portSpaceId(ref), !canRead(portInSpace: space, by: p),
              // A web port only: a terminal in another space is a shell, not a page.
              let panel = portWindows.findPort(by: key), panel.portType == "web",
              let reader = crossSpaceReader(p), key != reader.key
        else { return p }

        var held = crossSpaceRights(reader: reader.key, target: key, targetSpace: space)
        if held.isEmpty {
            let ask = CrossSpaceAsk(readerKey: reader.key, readerTitle: reader.title,
                                    readerSpace: spaceName(p.spaceId), targetKey: key,
                                    targetTitle: panel.title, targetSpaceId: space,
                                    targetSpace: spaceName(space), needs: right)
            let answer = await permissions.decideCrossSpace(ask, from: p)
            switch answer.outcome {
            case .granted:
                if let choice = answer.choice { grantCrossSpace(choice, for: ask) }
            case .denied:
                throw BridgeError.notFound("port '\(raw)'")
            case .locked:
                throw BridgeError.locked(PortPermission.crossSpace.rawValue)
            case .cancelled:
                throw BridgeError.permissionCancelled(PortPermission.crossSpace.rawValue)
            }
            held = crossSpaceRights(reader: reader.key, target: key, targetSpace: space)
        }
        guard held.contains(right) else {
            throw BridgeError(code: .permissionDenied,
                              message: "\(method) needs '\(right.rawValue)' on port '\(raw)', which is in another "
                                     + "space, and this port was not given it. The person can add it in "
                                     + "Settings, Access.",
                              details: ["right": right.rawValue])
        }
        return p.reaching(key)
    }

    /// Does this call's admission cover the port `key`? Only the one target the gate admitted.
    func admitsCrossSpace(_ key: String?, by p: Principal) -> Bool {
        guard let key, let admitted = p.crossSpaceTarget else { return false }
        return key == admitted
    }

    /// Whether a post into `chat` may wake its companions. A port posting into another space's port
    /// wakes them only with `wake_agents`, as a guest does: a wake spends that space's companions.
    func crossSpaceWakes(_ p: Principal, chat key: String) -> Bool {
        guard admitsCrossSpace(key, by: p), let reader = crossSpaceReader(p),
              let space = chatSpaceId(key) else { return true }
        return crossSpaceRights(reader: reader.key, target: key, targetSpace: space).contains(.wakeAgents)
    }

    private func spaceName(_ id: String?) -> String {
        spaces.first { $0.id == id }?.name ?? "no space"
    }

    // MARK: Settings, Access

    /// Every cross-space grant, one row per reading port and target.
    public func crossSpaceGrants() -> [CrossSpaceGrantRow] {
        let rows = (try? db.allCrossSpaceRights()) ?? []
        let byPair = Dictionary(grouping: rows, by: { "\($0.grantee)|\($0.object)" })
        return byPair.keys.sorted().compactMap { pair in
            guard let first = byPair[pair]?.first else { return nil }
            let readerKey = String(first.grantee.dropFirst("port:".count))
            let readerPanel = portWindows.findPort(by: readerKey)
            let reader = readerPanel.map { "\($0.title) (\(spaceName($0.spaceId)))" } ?? "a port that is gone"
            let target: String
            let offered: [RemoteRight]
            if first.object.hasPrefix("space:") {
                target = "every port in \(spaceName(String(first.object.dropFirst("space:".count))))"
                offered = CrossSpaceAsk.offered.filter(CrossSpaceAsk.spaceWide.contains)
            } else {
                let panel = portWindows.findPort(by: first.object)
                target = panel.map { "\($0.title) in \(spaceName($0.spaceId))" } ?? "a port that is gone"
                offered = CrossSpaceAsk.offered
            }
            return CrossSpaceGrantRow(grantee: first.grantee, object: first.object, reader: reader,
                                      target: target, rights: Set((byPair[pair] ?? []).map(\.right)),
                                      offered: offered)
        }
    }

    /// Set one row's rights from Settings, Access. Takes effect on the next call; empty revokes it.
    public func setCrossSpaceRights(_ rights: Set<RemoteRight>, grantee: String, object: String) {
        let allowed = object.hasPrefix("space:") ? CrossSpaceAsk.spaceWide : Set(CrossSpaceAsk.offered)
        try? db.saveRemoteRights(rights.intersection(allowed), grantee: grantee, portKey: object)
    }
}
