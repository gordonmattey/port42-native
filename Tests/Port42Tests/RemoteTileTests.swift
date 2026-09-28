import Testing
import Foundation
import Combine
@testable import Port42Lib

/// Nautilus Phase 4, step 4.6b: a port on another instance as a tile here. Accepting an invite opens a
/// tile with the host's HTML; a `state` event refetches it; the tile's own `window.port42` calls go to
/// the host with the host's port id; a host that cannot be reached shows as offline. Headless: a
/// scripted gateway plays the other instance.
@Suite("Remote tile (Phase 4, 4.6b)")
@MainActor
struct RemoteTileTests {

    static let host = RemotePortTests.host
    typealias Gateway = RemotePortTests.ScriptedGateway

    func world() throws -> (AppState, Gateway) {
        let (state, gw) = try RemotePortTests().world()
        AppState.mirrorRetry = 0.05
        state.mirrorsRestored = true    // no launch-time resume: each test starts and stops mirrors itself
        return (state, gw)
    }

    func accept(_ state: AppState) async throws -> String {
        let person = Principal.human(id: "u", displayName: "Ada", spaceId: nil)
        let out = try await state.runBridgeMethod("invite.accept", principal: person,
                                                  args: BridgeArgs(["link": RemotePortTests().invite()]))
        return try #require((out.toJSONObject() as? [String: Any])?["tile"] as? String)
    }

    /// The other instance: redeem works, getHtml serves `html()`, subscribe streams `events` and stays open.
    static func entry(_ seq: Int, _ text: String, from: String = "Gordon") -> [String: Any] {
        ["seq": seq, "at": 1_800_000_000.0 + Double(seq), "text": text,
         "from": ["id": "u-\(from)", "name": from, "kind": "human"]]
    }

    func host(_ gw: Gateway, html: @escaping () -> String, events: [[String: Any]] = [],
              chat: [[String: Any]] = []) {
        gw.reply = { method, _ in
            switch method {
            case "invite.redeem":
                return [RemotePortTests.response(["port": "P", "title": "shared chart", "rights": ["see", "use"], "knownAs": "Ada"])]
            case "port.getHtml":
                return [RemotePortTests.response(html())]
            case "port.subscribe":
                return events.map { e in
                    let c = String(decoding: try! JSONSerialization.data(withJSONObject: e), as: UTF8.self)
                    return ["type": "stream", "payload": ["senderName": "host", "senderType": "host", "content": c]]
                }
            case "port.push":
                return [RemotePortTests.response(["ok": true, "token": "t:1"])]
            case "chat.read":
                return [RemotePortTests.response(["entries": chat, "last": chat.count])]
            case "chat.post":
                return [RemotePortTests.response(["ok": true])]
            default:
                return [["type": "error", "code": "transport_failed", "error": "unscripted \(method)"]]
            }
        }
    }

    func settle(_ until: () -> Bool) async {
        for _ in 0..<200 where !until() { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    @Test("accepting an invite opens a tile with the host's port, marked as theirs")
    func acceptOpensTile() async throws {
        let (state, gw) = try world()
        host(gw, html: { "<p>theirs v1</p>" })
        let tile = try await accept(state)
        let panel = try #require(state.portWindows.panels.first { $0.id == tile })
        #expect(panel.html == "<p>theirs v1</p>")
        #expect(panel.title == "shared chart · Gordon")
        #expect(state.mirrorStatus[tile]?.online == true && state.mirrorStatus[tile]?.hostName == "Gordon")
        #expect(state.mirroredRemote(tile)?.portKey == "P")
        state.stopMirror(tile: tile)
    }

    @Test("a tile restored after a restart shows the host's current page, not the one it saved")
    func restoredTileRefreshes() async throws {
        let (state, gw) = try world()
        var version = 1
        host(gw, html: { "<p>theirs v\(version)</p>" })
        let tile = try await accept(state)
        state.stopMirror(tile: tile)
        version = 2                              // the host changed it while this instance was away
        state.restoreMirrors()
        await settle { state.portWindows.panels.first { $0.id == tile }?.html == "<p>theirs v2</p>" }
        #expect(state.portWindows.panels.first { $0.id == tile }?.html == "<p>theirs v2</p>",
                "a restored tile kept the page it saved")
        state.stopMirror(tile: tile)
    }

    @Test("tiles restored after a restart mirror again whichever comes first, the gateway or the tiles")
    func resumesInEitherOrder() async throws {
        let (state, gw) = try world()        // the gateway's welcome has come (world() sends it)
        host(gw, html: { "<p>x</p>" })
        let tile = try await accept(state)
        state.stopMirror(tile: tile)
        state.mirrorsRestored = false
        state.portPanelsRestored = false      // as at launch: the welcome is in, the tiles are not yet
        #expect(state.mirrorStatus[tile] == nil)
        state.portPanelsRestored = true       // the tiles come back after the welcome
        #expect(state.mirrorStatus[tile] != nil, "a tile restored after the gateway's welcome never mirrored")
        state.stopMirror(tile: tile)
    }

    @Test("a state event from the host refetches the port into the tile")
    func stateRefreshes() async throws {
        let (state, gw) = try world()
        var version = 1
        host(gw, html: { "<p>theirs v\(version)</p>" }, events: [["kind": "state", "payload": [:]]])
        version = 1
        let tile = try await accept(state)
        version = 2
        state.stopMirror(tile: tile)
        state.startMirror(tile: tile)   // subscribes again, and the host says its state moved
        await settle { state.portWindows.panels.first { $0.id == tile }?.html == "<p>theirs v2</p>" }
        #expect(state.portWindows.panels.first { $0.id == tile }?.html == "<p>theirs v2</p>")
        state.stopMirror(tile: tile)
    }

    @Test("a push to the host's port reaches the tile's page as the host's page gets it, a port42:data event")
    func pushReachesPage() async throws {
        let (state, gw) = try world()
        host(gw, html: { "<p>x</p>" })
        let tile = try await accept(state)
        state.stopMirror(tile: tile)
        let bridge = try #require(state.portWindows.panels.first { $0.id == tile }?.bridge)
        var scripts: [String] = []
        bridge.scriptSink = { scripts.append($0) }
        host(gw, html: { "<p>x</p>" }, events: [["kind": "push", "payload": ["n": 7]]])
        state.startMirror(tile: tile)
        await settle { !scripts.isEmpty }
        #expect(scripts == [PortBridge.dataEventScript(["n": 7])], "the tile's page did not get the push the host's page gets")
        state.stopMirror(tile: tile)
    }

    @Test("the tile's own calls go to the host, naming the host's port; presentation stays here")
    func tileCallsForwarded() async throws {
        let (state, gw) = try world()
        host(gw, html: { "<p>x</p>" })
        let tile = try await accept(state)
        let bridge = try #require(state.portWindows.panels.first { $0.id == tile }?.bridge)
        let before = gw.calls.count
        let out = await bridge.handleMethod("port.push", args: [tile, ["n": 1]])
        #expect((out as? [String: Any])?["ok"] as? Bool == true)
        let pushes = gw.calls.dropFirst(before).filter { $0["method"] as? String == "port.push" }
        #expect(pushes.count == 1, "the tile's call was not sent to the host once")
        let sent = try #require(pushes.first)
        #expect((sent["args"] as? [String: Any])?["id"] as? String == "P", "the tile's own id reached the host")

        _ = await bridge.handleMethod("presentation", args: [])
        #expect(!gw.calls.contains { $0["method"] as? String == "presentation" },
                "presentation, a fact about this desktop, was sent to the host")
        state.stopMirror(tile: tile)
    }

    @Test("a host that cannot be reached shows as offline")
    func offline() async throws {
        let (state, gw) = try world()
        host(gw, html: { "<p>x</p>" })
        let tile = try await accept(state)
        state.stopMirror(tile: tile)
        gw.reply = { method, _ in method == "port.subscribe" ? [["type": "error", "code": "host_offline", "error": "gone"]]
                                                           : [["type": "error", "code": "host_offline", "error": "gone"]] }
        var seen: [Bool] = []
        let watch = state.$mirrorStatus.sink { if let s = $0[tile] { seen.append(s.online) } }
        state.startMirror(tile: tile)
        await settle { state.mirrorStatus[tile]?.online == false && seen.count > 2 }
        watch.cancel()
        #expect(state.mirrorStatus[tile]?.online == false)
        // Never online on the way: the tile has not reached the host once.
        #expect(!seen.dropFirst().contains(true), "a tile said online while its host could not be reached: \(seen)")
        let listed = try await state.runBridgeMethod("ports.list", principal: .human(id: "u", displayName: "Ada", spaceId: nil), args: BridgeArgs([:]))
        let entry = (listed.toJSONObject() as? [[String: Any]])?.first { $0["id"] as? String == tile }
        #expect((entry?["mirrors"] as? [String: Any])?["online"] as? Bool == false, "ports.list does not say the tile is offline")
        #expect((entry?["mirrors"] as? [String: Any])?["peer"] as? String == RemotePortTests.host)
        state.stopMirror(tile: tile)
    }

    @Test("any caller naming the tile, by id, title or this instance's address, reaches the host's port")
    func tileIsTheHostsPort() async throws {
        let (state, gw) = try world()
        host(gw, html: { "<p>theirs</p>" })
        let tile = try await accept(state)
        state.stopMirror(tile: tile)
        let companion = Principal.peer(id: "cli", displayName: "a companion's CLI")
        for ref in [tile, "shared chart · Gordon", "port42://\(RemotePortTests.me)/\(tile)"] {
            let before = gw.calls.count
            let out = try await state.runBridgeMethod("port.getHtml", principal: companion, args: BridgeArgs(["id": ref]))
            #expect(out.toJSONObject() as? String == "<p>theirs</p>", "\(ref) read this instance's copy")
            let sent = gw.calls.dropFirst(before).filter { $0["method"] as? String == "port.getHtml" }
            #expect(sent.count == 1 && (sent.first?["args"] as? [String: Any])?["id"] as? String == "P",
                    "\(ref) did not reach the host's port by its own id")
        }
    }

    @Test("what the tile shows is read here: its page and console by the tile's id; by the port's address, they go there")
    func windowStaysHere() async throws {
        let (state, gw) = try world()
        host(gw, html: { "<p>theirs</p>" })
        let tile = try await accept(state)
        state.stopMirror(tile: tile)
        let me = Principal.peer(id: "cli", displayName: "a companion's CLI")
        for method in ["port.getDom", "port.console"] {
            let before = gw.calls.count
            _ = try? await state.runBridgeMethod(method, principal: me, args: BridgeArgs(["id": tile]))
            #expect(!gw.calls.dropFirst(before).contains { $0["method"] as? String == method },
                    "\(method) naming the tile read the host's page, not this window")
            _ = try? await state.runBridgeMethod(method, principal: me,
                                                 args: BridgeArgs(["id": "port42://\(RemoteTileTests.host)/P"]))
            #expect(gw.calls.dropFirst(before).contains { $0["method"] as? String == method },
                    "\(method) naming the port's address did not go to the port")
        }
    }

    @Test("the tile's chat is the host's: it shows the host's posts, and a post here goes there, stored only there")
    func tileChatIsTheHosts() async throws {
        let (state, gw) = try world()
        host(gw, html: { "<p>x</p>" }, events: [["kind": "chat", "payload": Self.entry(2, "second, live")]],
             chat: [Self.entry(1, "first, before")])
        let tile = try await accept(state)
        let key = try #require(state.mirrorChatKey(tile))
        await settle { state.chats.entries[key]?.count == 2 }
        #expect(state.chats.entries[key]?.map(\.text) == ["first, before", "second, live"])

        state.currentUser = AppUser.createLocal(displayName: "Ada")
        try await state.postToChatAsPerson(key: key, text: "hello from here")
        let post = try #require(gw.calls.last { $0["method"] as? String == "chat.post" })
        #expect((post["args"] as? [String: Any])?["port"] as? String == "P", "the post did not go to the host's port")
        #expect(try state.db.chatEntries(chat: key, after: 0, limit: 50).isEmpty, "the tile kept its own chat")
        state.stopMirror(tile: tile)
    }

    @Test("a mention in the host's chat wakes this instance's companion only with the tile's switch on, and only by its own name there")
    func wakesBySwitchAndExactName() async throws {
        let (state, gw) = try world()
        host(gw, html: { "<p>x</p>" })
        var c = AgentConfig.createCommand(ownerId: "u", displayName: "wise-tern", command: "claude", systemPrompt: nil, trigger: .mentionOnly)
        c.openInTerminal = true
        state.companions = [c]
        let space = Space.create(name: "here")
        try state.db.saveSpace(space)
        state.spaces = [space]
        state.currentSpace = space            // a tile opens on the current space, as in the app
        let tile = try await accept(state)
        let key = try #require(state.mirrorChatKey(tile))
        state.stopMirror(tile: tile)
        func hear(_ text: String, from: String = "alpha") async {
            host(gw, html: { "<p>x</p>" }, events: [["kind": "chat", "payload": [
                "seq": 1, "at": 1.0, "text": text, "from": ["id": "a", "name": from, "kind": "companion"]]]])
            state.chatReplyTargets = [:]
            state.startMirror(tile: tile)
            await settle { state.chats.entries[key]?.contains { $0.text == text } == true }
            state.stopMirror(tile: tile)
        }
        #expect(state.mirroredRemote(tile)?.wakes == true, "remote wake was not on after accepting by default")
        state.setMirrorWakes(tile: tile, false)
        let mine = CompanionName.mention("wise-tern (Ada)")
        await hear("\(mine) your turn")
        #expect(state.chatReplyTargets["wise-tern"] == nil, "woke with the tile's switch off")

        state.setMirrorWakes(tile: tile, true)
        #expect(state.mirroredRemote(tile)?.wakes == true)
        await hear("\(CompanionName.mention("wise-tern (Bob)")) your turn")
        #expect(state.chatReplyTargets["wise-tern"] == nil, "another machine's wise-tern woke this one")
        await hear("\(mine) same again", from: "wise-tern (Ada)")
        #expect(state.chatReplyTargets["wise-tern"] == nil, "a companion woke for its own post")
        await hear("\(mine) your turn, again")
        #expect(state.chatReplyTargets["wise-tern"] == key, "the switch was on and it was named, and it did not wake")

        state.setMirrorWakes(tile: tile, false)
        await hear("\(mine) and once more")
        #expect(state.chatReplyTargets["wise-tern"] == nil, "woke after the switch went off")
    }

    @Test("accepting with remote wake off leaves it off")
    func acceptWithoutRemoteWake() async throws {
        let (state, gw) = try world()
        host(gw, html: { "<p>x</p>" })
        let person = Principal.human(id: "u", displayName: "Ada", spaceId: nil)
        let out = try await state.runBridgeMethod("invite.accept", principal: person,
                                                  args: BridgeArgs(["link": RemotePortTests().invite(), "remoteWake": false]))
        let tile = try #require((out.toJSONObject() as? [String: Any])?["tile"] as? String)
        #expect(state.mirroredRemote(tile)?.wakes == false && state.mirrorStatus[tile]?.wakes == false)
        state.stopMirror(tile: tile)
    }

    @Test("a companion's reply to the tile's chat goes to the host as that companion, stored only there")
    func replyGoesToHost() async throws {
        let (state, gw) = try world()
        host(gw, html: { "<p>x</p>" })
        let tile = try await accept(state)
        state.stopMirror(tile: tile)
        let key = try #require(state.mirrorChatKey(tile))
        let c = AgentConfig.createCommand(ownerId: "u", displayName: "wise-tern", command: "claude", systemPrompt: nil, trigger: .mentionOnly)
        try state.postReply(key: key, text: "done my part", from: .companion(id: c.id, displayName: "wise-tern", spaceId: nil))
        await settle { gw.calls.contains { $0["method"] as? String == "chat.post" } }
        let post = try #require(gw.calls.last { $0["method"] as? String == "chat.post" })
        #expect((post["args"] as? [String: Any])?["port"] as? String == "P")
        #expect((post["actor"] as? [String: String])?["kind"] == "companion")
        #expect(try state.db.chatEntries(chat: key, after: 0, limit: 50).isEmpty, "the reply was kept here")
    }

    @Test("the tile page's storage is its port's on the host: its storage calls name the port")
    func tileStorageNamesThePort() async throws {
        let (state, gw) = try world()
        host(gw, html: { "<p>x</p>" })
        let tile = try await accept(state)
        let bridge = try #require(state.portWindows.panels.first { $0.id == tile }?.bridge)
        let before = gw.calls.count
        _ = await bridge.handleMethod("storage.get", args: ["state"])
        let sent = try #require(gw.calls.dropFirst(before).first { $0["method"] as? String == "storage.get" })
        #expect((sent["args"] as? [String: Any])?["port"] as? String == "P", "the copy's storage call did not name its port")
        #expect((sent["args"] as? [String: Any])?["key"] as? String == "state")
        state.stopMirror(tile: tile)
    }

    @Test("the tile page's start-up reads: space and companions name its port on the host; the user is the viewer, here")
    func tileStartupReads() async throws {
        let (state, gw) = try world()
        state.currentUser = AppUser.createLocal(displayName: "Viewer")
        host(gw, html: { "<p>x</p>" })
        let tile = try await accept(state)
        let bridge = try #require(state.portWindows.panels.first { $0.id == tile }?.bridge)
        let before = gw.calls.count
        for m in ["companions.list", "space.current"] { _ = await bridge.handleMethod(m, args: []) }
        let user = await bridge.handleMethod("user.get", args: []) as? [String: Any]
        let sent = gw.calls.dropFirst(before)
        for m in ["companions.list", "space.current"] {
            let call = try #require(sent.first { $0["method"] as? String == m }, "\(m) did not go to the host")
            #expect((call["args"] as? [String: Any])?["port"] as? String == "P", "\(m) did not name its port")
        }
        #expect(!sent.contains { $0["method"] as? String == "user.get" }, "user.get asked the host who is viewing")
        #expect(user?["displayName"] as? String == "Viewer")
        state.stopMirror(tile: tile)
    }

    @Test("a tile whose host cannot be reached waits longer each time, up to a cap")
    func backsOff() async throws {
        #expect(AppState.mirrorDelay(failures: 1) == AppState.mirrorRetry)
        #expect(AppState.mirrorDelay(failures: 3) == AppState.mirrorRetry * 4)
        #expect(AppState.mirrorDelay(failures: 60) == AppState.mirrorRetryMax, "the wait has no cap")
        let (state, gw) = try world()
        host(gw, html: { "<p>x</p>" })
        let tile = try await accept(state)
        state.stopMirror(tile: tile)
        gw.reply = { _, _ in [["type": "error", "code": "host_offline", "error": "gone"]] }
        var waits: [TimeInterval] = []
        state.mirrorWait = { d in waits.append(d); await Task.yield() }
        state.startMirror(tile: tile)
        for _ in 0..<2000 where waits.count < 5 { await Task.yield() }
        state.stopMirror(tile: tile)
        #expect(Array(waits.prefix(5)) == (1...5).map { AppState.mirrorDelay(failures: $0) },
                "a tile did not wait longer after each failure: \(waits.prefix(5))")
    }

    @Test("an ordinary tile's calls are never sent to another instance")
    func localTileStaysLocal() async throws {
        let (state, gw) = try world()
        _ = state.portWindows.registerTiledPort(id: "mine", html: "<p>mine</p>", spaceId: nil, createdBy: nil,
                                                title: "mine", position: nil)
        let bridge = try #require(state.portWindows.panels.first { $0.id == "mine" }?.bridge)
        _ = await bridge.handleMethod("port.getHtml", args: ["mine"])
        #expect(gw.calls.isEmpty)
    }
}
