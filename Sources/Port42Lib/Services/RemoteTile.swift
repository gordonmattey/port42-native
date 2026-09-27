import Foundation

// MARK: - A port on another instance, as a tile here (nautilus Phase 4, step 4.6b)
//
// The tile is an ordinary web tile on this desktop whose HTML comes from the instance that holds the
// port. It runs the port's own code, as a browser guest would, and everything that code asks of
// `window.port42` goes to that instance, as this one, whose rights decide. It subscribes to the port:
// a `state` event means the host's port changed, so the tile fetches the HTML again; a `push` reaches
// the tile's page exactly as it reaches the host's, so both copies see the same input. When the
// connection drops the tile says the host is offline and tries again.

public struct MirrorStatus: Equatable {
    public let hostName: String
    public var online: Bool
}

extension AppState {

    /// Methods a mirrored tile answers for itself: they are about this desktop, not the port.
    static let mirrorLocalMethods: Set<String> = ["presentation"]

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
                return try await self.door.remoteCall(to: row.peerKey, relays: row.relays, method: method, args: named)
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
        mirrorStatus[tile] = MirrorStatus(hostName: row.hostName, online: true)
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
            }
        case PortEventKind.push.wire:
            // The host's page received this push as a `port42:data` event, so the copy does too. The
            // `push` bus event is for watchers of the port, and the page was never one.
            portWindows.panels.first { $0.id == tile }?.bridge.deliverData(o["payload"] ?? NSNull())
        default:
            break
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
