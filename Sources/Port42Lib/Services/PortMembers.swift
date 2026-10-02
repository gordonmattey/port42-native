import Foundation

// MARK: - Port members and cross-instance wakes (two agents, one port)
//
// docs/plan-two-agents-one-port.md, decisions 1 to 3 (Gordon, 2026-10-02):
//  1. A mention in a port's chat gives that companion the port, not its space.
//  2. On a tile of someone else's port, only companions the person brought onto it act on it.
//  3. The first time an agent on another instance wakes one of yours on a port, the person is asked, once
//     per (that agent, yours, that port), and the yes is remembered.

extension AppState {
    /// Whether a companion is one of a port's members (apart from the space's).
    func isPortMember(_ agentId: String, port key: String) -> Bool {
        ((try? db.portMembers(portKey: key)) ?? []).contains(agentId)
    }

    /// Add a companion to a port's members.
    func addPortMember(_ agentId: String, port key: String) {
        try? db.addPortMember(agentId: agentId, portKey: key)
    }

    /// A caller reaches a port when it may read the port's space (APP-10), or when it is the port's member.
    func canReach(_ ref: PortRef, by p: Principal) -> Bool {
        if canRead(portInSpace: portSpaceId(ref), by: p) { return true }
        guard let key = ref.key, let c = companion(actingAs: p) else { return false }
        return isPortMember(c.id, port: key)
    }

    /// The local tile of a port on another instance, by its key here, if there is one.
    func mirrorTileKey(peer: String, port: String) -> String? {
        let links = (try? db.remotePortTiles()) ?? [:]
        guard let tile = links.first(where: { $0.value.peerKey == peer && $0.value.portKey == port })?.key else { return nil }
        return portWindows.panels.first { $0.id == tile }?.udid ?? tile
    }

    /// Who may act on a tile (decision 2): a companion only as one of the tile's members; anyone else by the
    /// tile's space, as for any port.
    func mayUseTile(peer: String, port: String, by p: Principal) -> Bool {
        if let c = companion(actingAs: p), p.kind != .human {
            guard let key = mirrorTileKey(peer: peer, port: port) else { return false }
            return isPortMember(c.id, port: key)
        }
        return canRead(portInSpace: mirrorTileSpace(peer: peer, port: port), by: p)
    }

    // MARK: Cross-instance wakes (decision 3)

    static func crossWakeObject(companion: String, port: String) -> String { "wake:\(companion)@\(port)" }

    /// Whether `from` (an agent on another instance, by its id there) may wake `companion` on `port`.
    func mayCrossWake(_ companion: String, from: String, port: String) -> Bool {
        (try? db.grants(grantee: from, object: Self.crossWakeObject(companion: companion, port: port), zone: ""))?
            .contains(.crossWake) == true
    }

    /// Ask the person, once, whether `fromName` may wake `companion` on the port; a yes is remembered and makes
    /// the companion the port's member.
    func askCrossWake(_ companion: AgentConfig, from: String, fromName: String, port key: String, portTitle: String) async -> Bool {
        if mayCrossWake(companion.id, from: from, port: key) { return true }
        let asker = Principal.remote(peer: from, displayName: fromName)
        let detail = "\(fromName), an agent on another machine, wants to wake \(companion.displayName) on '\(portTitle)'. "
            + "\(companion.displayName) would run here, in your terminal, on your model."
        guard (try? await ask(.crossWake, from: asker, detail: detail)) == true else { return false }
        try? db.saveGrants([.crossWake], grantee: from, object: Self.crossWakeObject(companion: companion.id, port: key), zone: "")
        addPortMember(companion.id, port: key)
        return true
    }

    /// A post from another instance (with `wake_agents`) wakes only the companions it mentions that the
    /// person allowed that agent to wake; for any not yet allowed, the person is asked first (decision 3).
    func routeRemotePost(key: String, entry: PortChatEntry, from p: Principal) {
        // A person there (or a guest with no agent named) is not an agent waking an agent: as before.
        guard entry.fromKind == Principal.Kind.companion.rawValue else {
            routeChat(key: key, entry: entry, fromAnotherInstance: true)
            return
        }
        let mentioned = AgentRouter.findTargetAgents(content: entry.text, agents: companions, spaceAgentIds: [],
                                                     localOwner: currentUser?.displayName)
        let allowed = Set(mentioned.filter { mayCrossWake($0.id, from: entry.fromId, port: key) }.map(\.id))
        routeChat(key: key, entry: entry, fromAnotherInstance: true, allowed: allowed)
        let title = portWindows.panels.first { $0.udid == key || $0.id == key }?.title ?? "a shared port"
        for c in mentioned where !allowed.contains(c.id) {
            Task { @MainActor [weak self] in
                guard let self, await self.askCrossWake(c, from: entry.fromId, fromName: entry.fromName, port: key, portTitle: title) else { return }
                self.routeChat(key: key, entry: entry, fromAnotherInstance: true, allowed: [c.id])
            }
        }
    }
}
