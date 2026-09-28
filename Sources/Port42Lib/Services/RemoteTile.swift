import Foundation

// MARK: - A port on another instance, as a tile here (nautilus Phase 4, step 4.6b)
//
// The tile is an ordinary web tile on this desktop whose HTML comes from the instance that holds the
// port. It runs the port's own code, as a browser guest would, and everything that code asks of
// `window.port42` goes to that instance, as this one, whose rights decide. It subscribes to the port:
// a `state` event means the host's port changed, so the tile fetches the HTML again; a `push` reaches
// the tile's page exactly as it reaches the host's, so both copies see the same input. When the
// connection drops the tile says the host is offline and tries again.

/// A port's sharing, as the chrome shows it (4.6b).
public struct PortSharing: Equatable {
    public var people: [AppState.SharedPort] = []
    public var openInvites: Int = 0
}

/// The sharing pill in a tile's chrome: one word for whose the port is and who else is in it.
public enum SharePill: Equatable {
    /// A port on this instance: how many machines have it, and invites not yet used.
    case shared(people: Int, invites: Int)
    /// A tile mirroring someone else's port.
    case theirs(host: String, online: Bool)

    public var label: String {
        switch self {
        case .shared(let n, let i): return n > 0 ? "shared · \(n)" : (i == 1 ? "invite sent" : "\(i) invites sent")
        case .theirs(let h, let on): return on ? "\(h)'s" : "\(h)'s · offline"
        }
    }
}

public struct MirrorStatus: Equatable {
    public let hostName: String
    public var online: Bool
    /// Whether a mention in the host's chat may wake this instance's companions (4.6c).
    public var wakes: Bool = false
}

extension AppState {

    /// Methods a mirrored tile answers for itself: they are about this desktop, not the port.
    static let mirrorLocalMethods: Set<String> = ["presentation", "port.info", "user.get"]
    /// Calls a shared port's page makes that the host answers for that port, so the copy names it: its
    /// storage, and the space and companions it reads at start (4.7b). `user.get` is the viewer, here.
    static func namesItsPort(_ method: String) -> Bool {
        method.hasPrefix("storage.") || method == "space.current" || method == "companions.list"
    }

    /// How long a mirror waits before trying again after its connection drops.
    static var mirrorRetry: TimeInterval = 5
    /// The longest a tile waits between tries, however long its host has been away.
    static var mirrorRetryMax: TimeInterval = 300
    /// A subscription that held this long counts as connected, so the wait starts short again.
    static var mirrorHeld: TimeInterval = 30

    /// How long a tile waits after `failures` tries in a row: doubling from `mirrorRetry` to
    /// `mirrorRetryMax`. A host that is gone for good (a changed identity, a Mac that is off) costs a try
    /// every five minutes, not every five seconds; the relay limits session requests, and constant
    /// tries from a few such tiles locked the live ones out (Dev6, 2026-09-27).
    static func mirrorDelay(failures: Int) -> TimeInterval {
        min(mirrorRetry * pow(2, Double(max(0, failures - 1))), mirrorRetryMax)
    }

    /// The remote port a local tile mirrors, if it is one.
    func mirroredRemote(_ tile: String) -> DatabaseService.RemotePortRow? {
        guard let link = (try? db.remotePortTiles())?[tile] else { return nil }
        return ((try? db.remotePorts()) ?? []).first { $0.peerKey == link.peerKey && $0.portKey == link.portKey }
    }

    /// A mirrored tile's call, sent to the instance that holds the port. nil for any other tile, or
    /// for a method the tile answers about this desktop.
    ///
    /// **WHETHER A TILE IS A MIRROR IS READ FROM ITS DATABASE LINK** (NAU-01). This used to be
    /// `mirrorStatus[tile] != nil`, which only `startMirror` sets, after the gateway's welcome. A tile
    /// restored at launch loads the other machine's saved page at once, so until the welcome (or for
    /// good, if it never came, or after `stopMirror`) this returned nil and the page's calls ran HERE,
    /// as a local port with this machine's authority: a foreign page could reach `port.push` into
    /// local terminals. A mirror that is not forwarding now has its calls refused, never run locally.
    func mirroredCall(_ method: String, fromTile tile: String, args: [Any]) -> Task<Any, Never>? {
        guard !Self.mirrorLocalMethods.contains(method), let row = mirroredRemote(tile) else { return nil }
        guard mirrorStatus[tile] != nil else {
            let refusal = BridgeError(
                code: .hostOffline,
                message: "This tile mirrors '\(row.title)' on \(row.hostName)'s machine and is not connected "
                       + "to it yet, so '\(method)' was not run here. It connects once Port42's gateway "
                       + "is up; call again then.")
            return Task { ["error": refusal.message, "code": refusal.code] }
        }
        // The page's own id resolves as any reference to the tile does (`remotePort(for:)`): to the
        // host's port. Its calls name it implicitly as well as by id, so all of them go.
        let names = bridgeRegistry[method]?.paramNames ?? bridgeStreamRegistry[method]?.paramNames ?? []
        var named = BridgeArgs(positional: args, names: names).dictionary
        // The page names its own port by the id it has here; the host knows it by its own.
        for (k, v) in named where (v as? String) == tile { named[k] = row.portKey }
        if Self.namesItsPort(method), named["port"] == nil { named["port"] = row.portKey }
        return Task { @MainActor in
            do {
                let page = self.portWindows.panels.first { $0.id == tile }
                return try await self.door.remoteCall(to: row.peerKey, relays: row.relays, method: method, args: named,
                                                      actor: RemoteActor(id: tile, name: page?.title ?? "a port", kind: .port))
            } catch let e as BridgeError {
                var payload: [String: Any] = ["error": e.message, "code": e.code]
                for (k, v) in e.details where k != "error" && k != "code" { payload[k] = v }
                return payload
            } catch {
                return ["error": error.localizedDescription]
            }
        }
    }

    /// Open a tile for a remote port this instance was invited to, and start mirroring it.
    @discardableResult
    func openRemoteTile(peer: String, port: String) async throws -> String {
        guard let row = ((try? db.remotePorts()) ?? []).first(where: { $0.peerKey == peer && $0.portKey == port }) else {
            throw BridgeError.notFound("no invite to that port")
        }
        if let existing = (try? db.remotePortTiles())?.first(where: { $0.value.peerKey == peer && $0.value.portKey == port })?.key,
           portWindows.panels.contains(where: { $0.id == existing }) {
            return existing
        }
        let html = try await door.remoteCall(to: peer, relays: row.relays, method: "port.getHtml", args: ["id": port])
        let id = UUID().uuidString
        _ = portWindows.registerTiledPort(id: id, html: html as? String ?? "", spaceId: currentSpace?.id,
                                          createdBy: nil,   // it acts on nothing here: every call goes to the host
                                          title: "\(row.title) · \(row.hostName)", position: nil)
        try db.setRemotePortTile(peerKey: peer, portKey: port, localPort: id)
        startMirror(tile: id, fresh: true)
        return id
    }

    /// Mirror a remote port into its tile until the tile goes.
    /// `fresh` when the tile was just opened with the host's current page; otherwise (a restart, a
    /// resubscribe) the page is fetched first, since the host may have changed it meanwhile and a
    /// restored tile would otherwise run what it saved last time.
    func startMirror(tile: String, fresh: Bool = false) {
        guard remoteMirrors[tile] == nil, let row = mirroredRemote(tile) else { return }
        mirrorStatus[tile] = MirrorStatus(hostName: row.hostName, online: true, wakes: row.wakes)
        remoteMirrors[tile] = Task { @MainActor [weak self] in
            var first = true
            var failures = 0
            while let self, !Task.isCancelled, self.portWindows.panels.contains(where: { $0.id == tile }) {
                let started = Date()
                // Online only once the host has answered: a fresh tile just did, anything else must reach
                // it first (the flag said online while every call was failing).
                let reached = (first && fresh) ? true : await self.refreshMirror(tile: tile, row: row)
                first = false
                self.mirrorStatus[tile]?.online = reached
                await self.loadMirrorChat(tile: tile, row: row)
                do {
                    _ = try await self.door.remoteCall(to: row.peerKey, relays: row.relays, method: "port.subscribe",
                                                       args: ["id": row.portKey],
                                                       onStream: { [weak self] event in self?.mirrorEvent(tile: tile, row: row, event) })
                } catch is CancellationError {
                    break
                } catch {
                    p42log("[mirror] \(row.title): \(error)")
                }
                self.mirrorStatus[tile]?.online = false
                if let key = self.mirrorChatKey(tile) { self.presence.setRemote(key, []) }
                failures = Date().timeIntervalSince(started) > Self.mirrorHeld ? 1 : failures + 1
                await self.mirrorWait(Self.mirrorDelay(failures: failures))
            }
            self?.remoteMirrors[tile] = nil
        }
    }

    func stopMirror(tile: String) {
        if let key = mirrorChatKey(tile) { presence.setRemote(key, []) }
        remoteMirrors.removeValue(forKey: tile)?.cancel()
        mirrorStatus.removeValue(forKey: tile)
    }

    /// Mirror the tiles restored from the last run, once both the gateway is up (its welcome names this
    /// instance) and the tiles are back. Either can come first: the welcome used to win, find no tiles,
    /// and never try again, so after a restart shared tiles stayed disconnected (2026-09-27).
    func resumeMirrorsWhenReady() {
        guard localPeerID != nil, portPanelsRestored, !mirrorsRestored else { return }
        mirrorsRestored = true
        restoreMirrors()
        refreshSharing()
    }

    /// Start mirroring every remote tile that survived a restart. Run once the gateway is up.
    func restoreMirrors() {
        for tile in ((try? db.remotePortTiles()) ?? [:]).keys where portWindows.panels.contains(where: { $0.id == tile }) {
            startMirror(tile: tile)
        }
    }

    func mirrorEvent(tile: String, row: DatabaseService.RemotePortRow, _ event: Any) {
        guard let o = event as? [String: Any], let kind = o["kind"] as? String else { return }
        switch kind {
        case PortEventKind.state.wire:
            Task { @MainActor in await self.refreshMirror(tile: tile, row: row) }
        case PortEventKind.chat.wire:
            // The tile's chat is the host's: each post there is shown here as it lands, stored only there.
            if let key = mirrorChatKey(tile), let entry = PortChatEntry.fromEvent(o["payload"]) {
                chats.received(key, entry)
                wakeMentioned(tile: tile, key: key, entry: entry)
            }
        case PortEventKind.presence.wire:
            // Who is working in the host's chat, as the host sees it (presence in the API).
            if let key = mirrorChatKey(tile) {
                let list = ((o["payload"] as? [String: Any])?["presence"] as? [Any]) ?? []
                presence.setRemote(key, list.compactMap(ChatPresence.init(wire:)))
            }
        case PortEventKind.storage.wire:
            portWindows.panels.first { $0.id == tile }?.bridge.pushEvent(.storage, data: BridgeValue.fromJSONObject(o["payload"] ?? NSNull()))
        case PortEventKind.push.wire:
            // The host's page received this push as a `port42:data` event, so the copy does too. The
            // `push` bus event is for watchers of the port, and the page was never one.
            portWindows.panels.first { $0.id == tile }?.bridge.deliverData(o["payload"] ?? NSNull())
        default:
            break
        }
    }

    /// Fork a port into a new one of this instance's, in the current space: an independent copy with no
    /// grants of its own, titled as a copy. A port someone shared is copied only when they allowed it
    /// (`fork`); that is their leave, not a lock, since the page is already here.
    @discardableResult
    public func forkPort(_ id: String) async throws -> String {
        let html: String, title: String, home: String?
        if let row = mirroredRemote(id) {
            guard row.rights.contains(.fork) else {
                throw BridgeError(code: .notGranted, message: "\(row.hostName) did not allow a copy of this port")
            }
            guard let h = try await door.remoteCall(to: row.peerKey, relays: row.relays, method: "port.getHtml",
                                                    args: ["id": row.portKey]) as? String else {
                throw BridgeError(code: .noSurface, message: "\(row.hostName)'s port sent nothing to copy")
            }
            (html, title, home) = (h, row.title, portWindows.panels.first { $0.id == id }?.spaceId)
        } else {
            guard let panel = portWindows.panels.first(where: { $0.id == id || $0.udid == id }), AppState.shareable(panel) else {
                throw BridgeError.notFound("port '\(id)'")
            }
            html = (try? db.fetchPortHtml(udid: panel.udid)).flatMap { $0 } ?? panel.html
            (title, home) = (panel.title, panel.spaceId)
        }
        guard let space = currentSpace?.id ?? home else { throw BridgeError(code: .wrongState, message: "no space to fork into") }
        let made = createPort(type: "web", title: "\(title) (copy)", html: html, command: nil, cwd: nil,
                              systemPrompt: nil, spaceId: space, createdBy: nil, createdByName: nil)
        guard let newId = made["id"] as? String else {
            throw BridgeError.badArg(made["error"] as? String ?? "the copy could not be made")
        }
        return newId
    }

    /// Leave a port someone shared: its tile closes here and this instance forgets it. The sharer's
    /// grant stays theirs to remove; a new invite brings it back.
    public func leaveRemotePort(tile: String) {
        guard let row = mirroredRemote(tile) else { return }
        stopMirror(tile: tile)
        try? db.deleteRemotePort(peerKey: row.peerKey, portKey: row.portKey)
        portWindows.close(tile)
    }

    /// The person's switch on a tile: may the host's chat wake this instance's companions.
    public func setMirrorWakes(tile: String, _ on: Bool) {
        guard let row = mirroredRemote(tile) else { return }
        try? db.setRemotePortWakes(peerKey: row.peerKey, portKey: row.portKey, wakes: on)
        mirrorStatus[tile]?.wakes = on
    }

    /// This instance's companions a post in a mirrored chat mentions, by the name the host knows them
    /// by (`name (knownAs)`), exactly: another machine's companion of the same name is never one.
    func mirroredMentions(_ text: String, knownAs: String) -> [AgentConfig] {
        let named = Set(MentionParser.extractMentions(from: text).map { String($0.dropFirst()).lowercased() })
        return companions.filter { named.contains("\($0.displayName) (\(knownAs))".lowercased()) }
    }

    /// A mention in the host's chat of one of this instance's companions wakes it, when the tile's switch
    /// is on; its reply goes to the tile's chat, so to the host (`postReply`). A companion never wakes
    /// for its own post.
    func wakeMentioned(tile: String, key: String, entry: PortChatEntry) {
        guard let row = mirroredRemote(tile), row.wakes, let knownAs = row.knownAs,
              let panel = portWindows.panels.first(where: { $0.id == tile }),
              let spaceId = panel.spaceId ?? currentSpace?.id else { return }
        let targets = mirroredMentions(entry.text, knownAs: knownAs)
            .filter { "\($0.displayName) (\(knownAs))".lowercased() != entry.fromName.lowercased() }
        guard !targets.isEmpty else { return }
        let line = ChatRouting.terminalLine(sender: entry.fromName, source: chatSourceLabel(key: key, panel: panel),
                                            text: entry.text)
        let members = Set(((try? db.getAgentsForSpace(spaceId: spaceId)) ?? []).map(\.id))
        for c in targets where c.openInTerminal {
            deliverToTerminalCompanion(c, line: line, replyChat: key, spaceId: spaceId)
        }
        let headless = targets.filter { !$0.openInTerminal }
        if !headless.isEmpty {
            launchAgents(headless, spaceId: spaceId, spaceAgentIds: members, triggerContent: entry.text,
                         senderId: entry.fromId, senderName: entry.fromName, replyChat: key)
        }
    }

    /// A reply from this instance's companion into a chat: posted here, or, for a tile mirroring a port
    /// on another instance, sent there as that companion.
    func postReply(key: String, text: String, from p: Principal) throws {
        guard let target = remotePort(for: key) else {
            try postToChat(key: key, text: text, from: p)
            return
        }
        Task { @MainActor in
            do {
                _ = try await forwardRemote("chat.post", to: (target.peer, target.port, "port"),
                                            args: BridgeArgs(["port": key, "text": text]), as: p)
            } catch {
                p42log("[chat] reply to %@ on another instance failed: %@", key, error.localizedDescription)
            }
        }
    }

    /// The chat key the shell uses for a tile: its port key, as for any tile.
    func mirrorChatKey(_ tile: String) -> String? {
        portWindows.panels.first { $0.id == tile }.map { $0.udid }
    }

    /// Fill the tile's chat from the host's, so the shell shows the conversation so far.
    func loadMirrorChat(tile: String, row: DatabaseService.RemotePortRow) async {
        guard let key = mirrorChatKey(tile),
              let out = try? await door.remoteCall(to: row.peerKey, relays: row.relays, method: "chat.read",
                                                   args: ["port": row.portKey]) as? [String: Any],
              let list = out["entries"] as? [Any] else { return }
        chats.replace(key, list.compactMap(PortChatEntry.fromEvent))
        // And who is on it right now, so a tile opened mid-turn shows it. A host older than presence in
        // the API has no `presence.list`; the tile then shows presence from the next event on.
        if let now = try? await door.remoteCall(to: row.peerKey, relays: row.relays, method: "presence.list",
                                                 args: ["port": row.portKey]) as? [String: Any],
           let list = now["presence"] as? [Any] {
            presence.setRemote(key, list.compactMap(ChatPresence.init(wire:)))
        }
    }

    /// Fetch the host's page into the tile. False when the host could not be reached.
    @discardableResult
    func refreshMirror(tile: String, row: DatabaseService.RemotePortRow) async -> Bool {
        guard let html = try? await door.remoteCall(to: row.peerKey, relays: row.relays, method: "port.getHtml",
                                                    args: ["id": row.portKey]) as? String else { return false }
        _ = await portWindows.updatePort(idOrTitle: tile, html: html)
        return true
    }
}
