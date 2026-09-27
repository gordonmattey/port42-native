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
    static let mirrorLocalMethods: Set<String> = ["presentation", "port.info"]

    /// How long a mirror waits before trying again after its connection drops.
    static var mirrorRetry: TimeInterval = 5

    /// The remote port a local tile mirrors, if it is one.
    func mirroredRemote(_ tile: String) -> DatabaseService.RemotePortRow? {
        guard let link = (try? db.remotePortTiles())?[tile] else { return nil }
        return ((try? db.remotePorts()) ?? []).first { $0.peerKey == link.peerKey && $0.portKey == link.portKey }
    }

    /// A mirrored tile's call, sent to the instance that holds the port. nil for any other tile.
    func mirroredCall(_ method: String, fromTile tile: String, args: [Any]) -> Task<Any, Never>? {
        guard mirrorStatus[tile] != nil, !Self.mirrorLocalMethods.contains(method),
              let row = mirroredRemote(tile) else { return nil }
        // The page's own id resolves as any reference to the tile does (`remotePort(for:)`): to the
        // host's port. Its calls name it implicitly as well as by id, so all of them go.
        let names = bridgeRegistry[method]?.paramNames ?? bridgeStreamRegistry[method]?.paramNames ?? []
        var named = BridgeArgs(positional: args, names: names).dictionary
        // The page names its own port by the id it has here; the host knows it by its own.
        for (k, v) in named where (v as? String) == tile { named[k] = row.portKey }
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
        startMirror(tile: id)
        return id
    }

    /// Mirror a remote port into its tile until the tile goes.
    func startMirror(tile: String) {
        guard remoteMirrors[tile] == nil, let row = mirroredRemote(tile) else { return }
        mirrorStatus[tile] = MirrorStatus(hostName: row.hostName, online: true, wakes: row.wakes)
        remoteMirrors[tile] = Task { @MainActor [weak self] in
            var first = true
            while let self, !Task.isCancelled, self.portWindows.panels.contains(where: { $0.id == tile }) {
                if !first { await self.refreshMirror(tile: tile, row: row) }
                first = false
                self.mirrorStatus[tile]?.online = true
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
                try? await Task.sleep(nanoseconds: UInt64(Self.mirrorRetry * 1_000_000_000))
            }
            self?.remoteMirrors[tile] = nil
        }
    }

    func stopMirror(tile: String) {
        remoteMirrors.removeValue(forKey: tile)?.cancel()
        mirrorStatus.removeValue(forKey: tile)
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
    }

    func refreshMirror(tile: String, row: DatabaseService.RemotePortRow) async {
        guard let html = try? await door.remoteCall(to: row.peerKey, relays: row.relays, method: "port.getHtml",
                                                    args: ["id": row.portKey]) as? String else { return }
        _ = await portWindows.updatePort(idOrTitle: tile, html: html)
    }
}
