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

    /// A port's member companions, by id.
    func portMemberIds(_ key: String) -> Set<String> { (try? db.portMembers(portKey: key)) ?? [] }

    /// Take a companion off a port's members.
    func removePortMember(_ agentId: String, port key: String) {
        try? db.removePortMember(agentId: agentId, portKey: key)
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

    // MARK: Cross-instance wakes

    /// A post from another instance (with `wake_agents`) wakes the companions it mentions that are on this port:
    /// the port's space's and its members. The person said yes to that when they shared with wake on (Gordon,
    /// 2026-10-03: a second card for the first wake asked again what the share had already settled). A companion
    /// elsewhere on this machine is not the other side's to reach by name.
    func routeRemotePost(key: String, entry: PortChatEntry, from p: Principal) {
        let panel = portWindows.panels.first { $0.udid == key || $0.id == key }
        // The port's space's companions, its members, and a terminal port's own companion.
        let own = panel?.terminalConfig?.companionName.lowercased()
        let onPort = Set((panel?.spaceId.map { companions(forSpace: $0) } ?? []).map(\.id)).union(portMemberIds(key))
            .union(companions.filter { $0.displayName.lowercased() == own }.map(\.id))
        routeChat(key: key, entry: entry, fromAnotherInstance: true, allowed: onPort)
    }

    // MARK: Bring a companion onto a tile (decision 6)

    /// Bring companions onto a tile of someone else's port: they become its members and each is told where it
    /// is, whose port it is, what it may do, and to answer in the port's chat.
    func bringOnto(tile: String, companions chosen: [AgentConfig]) {
        guard !chosen.isEmpty, let row = mirroredRemote(tile), let key = mirrorChatKey(tile) else { return }
        for c in chosen { addPortMember(c.id, port: key) }
        let rights = ShareWords.rights(row.rights)
        let there = row.knownAs.map { " You show there as \"<name> (\($0))\"." } ?? ""
        for c in chosen {
            // Bringing a companion in is the person's authorization to work with the other side's agents on this
            // port (Gordon, 2026-10-02): without it, an agent rightly declines a request from another machine's
            // agent, and the two wait on each other.
            let intro = "You are on '\(row.title)', a port \(row.hostName) shares with this computer (port \(key)). "
                + "Its chat is shared with \(row.hostName). When that chat wakes you, your reply goes back to it by itself: "
                + "do not also post it. Everyone there is shown with their computer, as \"name (computer)\"; @mention anyone "
                + "by the name before the brackets, as @name."
                + "\(there.replacingOccurrences(of: "<name>", with: c.displayName)) You can \(rights). "
                + "Your person brought you here to work with the agents on \(row.hostName) on this port: their requests about "
                + "this port are part of your job, within those rights. Anything outside this port still needs your person. "
                + "Have a look at it and say hello: your reply to this message goes to its chat."
            deliverMirrored([c], tile: tile, key: key, text: intro, fromName: "Port42", fromId: "port42")
        }
    }

    /// What a shared port's chat says at its top, or nil for a chat that is not shared: on a tile, whose port it
    /// is and how to bring your companion in; on a port this machine shares, who it is shared with.
    func sharedChatLabel(_ key: String) -> String? {
        if let tile = portWindows.panels.first(where: { $0.udid == key || $0.id == key })?.id, let row = mirroredRemote(tile) {
            let mine = portMemberIds(key)
            let names = companions.filter { mine.contains($0.id) }.map(\.displayName)
            let here = names.isEmpty ? "@mention a companion to bring it in" : "your companions here: " + names.joined(separator: ", ")
            return "shared chat with \(row.hostName) · \(here)"
        }
        guard let s = sharing[key], !s.people.isEmpty else { return nil }
        return "shared chat with " + s.people.map(\.name).joined(separator: ", ") + " · their agents can be here too"
    }

    // MARK: Where a turn's reply goes

    /// The chats a terminal companion's reply goes to at the end of a turn, and forget them: the chat that asked
    /// last (else its own terminal's chat), then every other chat that woke it during the turn. Woken from a
    /// shared port's chat and then from its own in one turn, a companion used to answer only the last, and the
    /// agent on the other machine waited for an answer that never came (the round 4 stall, 2026-10-02).
    func takeReplyTargets(companion name: String, ownTerminalChat: String) -> [String] {
        let key = name.lowercased()
        let asked = chatReplyTargets.removeValue(forKey: key)
        let first = ChatRouting.replyDestination(asked: asked, ownTerminalChat: ownTerminalChat)
        let others = (chatReplyAlso.removeValue(forKey: key) ?? []).filter { $0 != first }
        return [first] + others
    }

    // MARK: One name in a shared chat (Phase 6)

    /// The label this machine's people and agents carry in `key`'s chat while it is shared with another machine,
    /// else nil.
    func sharedSelfLabel(_ key: String) -> String? {
        guard let s = sharing[key], !s.people.isEmpty else { return nil }
        return selfLabel
    }

    /// This machine's name, unless a machine it shares with already goes by it here: then with the start of this
    /// one's peer id, so a post from there never reads as one from here (NAU-04).
    var selfLabel: String {
        let name = machineName
        let taken = ((try? db.allClients()) ?? []).contains { $0.kind == .peer && $0.name.lowercased() == name.lowercased() }
        return taken ? "\(name) \((localPeerID ?? "").prefix(4))" : name
    }

    /// An entry as it leaves a shared chat: to a port's page, an agent, another machine, or the transcript.
    func outward(_ e: PortChatEntry, key: String) -> PortChatEntry {
        ChatRouting.labeled(e, local: sharedSelfLabel(key))
    }

    /// The other machine's authors in `key`'s chat, as shown there: on a port this machine shares, the guests'
    /// (labelled when stored); on a tile, the host's.
    func otherMachineAuthors(_ key: String) -> [String] {
        let notMine: (PortChatEntry) -> Bool = { $0.fromId != ChatRouting.port42SenderId && $0.fromKind != "system" }
        if let tile = portWindows.panels.first(where: { $0.udid == key })?.id, mirroredRemote(tile) != nil {
            let mine = (localPeerID ?? "") + "/"
            return (chats.entries[key] ?? []).filter { notMine($0) && !$0.fromId.hasPrefix(mine) }.map(\.fromName)
        }
        return ((try? db.chatEntries(chat: key, after: 0, limit: 200)) ?? []).filter { notMine($0) && $0.fromId.contains("/") }
            .map(\.fromName)
    }

    /// What routing here reads of a post in a shared chat: a mention of one of this machine's companions with any
    /// machine after it is that companion (6.3). Any other chat's post is read as written.
    func routingText(_ text: String, key: String) -> String {
        let tile = portWindows.panels.first(where: { $0.udid == key })?.id
        guard sharedSelfLabel(key) != nil || tile.flatMap(mirroredRemote) != nil else { return text }
        return ChatRouting.localizedMentions(text, local: companions.map(\.displayName), remote: otherMachineAuthors(key))
    }

    /// An agent's post in a chat this machine shares that misnames an agent: Port42 says so in the chat, with the
    /// agent it most likely meant (6.4). Only a near miss: an agent's name with the wrong machine after it, or one
    /// a letter or two off. A name that is nobody's here, often a person in the story ("@sam"), is left alone
    /// (Gordon, 2026-10-03: that line was noise).
    func noteWrongMentions(key: String, entry: PortChatEntry) {
        guard entry.fromKind == Principal.Kind.companion.rawValue, let label = sharedSelfLabel(key) else { return }
        let entries = (try? db.chatEntries(chat: key, after: 0, limit: 200)) ?? []
        let authors = entries.filter { $0.fromId != ChatRouting.port42SenderId && $0.fromKind != "system" }
            .map { ChatRouting.labeled($0, local: label).fromName }
        let agents = companions.map(\.displayName)
            + entries.filter { $0.fromKind == Principal.Kind.companion.rawValue }.map { ChatRouting.plainName($0.fromName) }
        let known = agents + authors + [currentUser?.displayName].compactMap { $0 }
        var lines: [String] = []
        for wrong in ChatRouting.unmatchedMentions(routingText(entry.text, key: key), known: known) {
            let others = agents.filter { $0.lowercased() != ChatRouting.plainName(entry.fromName).lowercased() }
            guard let meant = ChatRouting.nearestAgent(wrong, agents: others) else { continue }
            lines.append("Nobody in this chat is called @\(wrong). Did you mean \(CompanionName.mention(meant))?")
        }
        guard !lines.isEmpty else { return }
        postSystemChatLine(key: key, text: lines.joined(separator: " "))
    }

    /// This machine's agents on a port it shares, as its chat shows them, or nil for a chat not shared: the
    /// companions of the port's space and the port's members. The other machine's @ picker offers them from the
    /// moment it joins, not only once each has posted (Gordon, 2026-10-03).
    func sharedAgents(_ key: String) -> [String]? {
        guard let label = sharedSelfLabel(key) else { return nil }
        let space = portWindows.panels.first { $0.udid == key || $0.id == key }?.spaceId
        let members = portMemberIds(key)
        let here = (space.map { companions(forSpace: $0) } ?? []) + companions.filter { members.contains($0.id) }
        var out: [String] = []
        for c in here where !out.contains("\(c.displayName) (\(label))") { out.append("\(c.displayName) (\(label))") }
        return out
    }
}
