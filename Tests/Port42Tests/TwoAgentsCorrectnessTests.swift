import Testing
import Foundation
@testable import Port42Lib

// Two instances, an agent on each side, on one shared port: Phase 2, correctness
// (docs/plan-two-agents-one-port.md).

@Suite("two agents: correctness")
@MainActor
struct TwoAgentsCorrectnessTests {
    func call(_ w: ParityWorld, _ m: String, _ p: Principal, _ a: [String: Any]) async throws -> [String: Any] {
        (try await w.state.runBridgeMethod(m, principal: p, args: BridgeArgs(a))).toJSONObject() as? [String: Any] ?? [:]
    }
    func port(_ w: ParityWorld) throws -> String {
        let made = w.state.createPort(type: "web", title: "board", html: "<title>board</title><h1>board</h1>", command: nil,
                                      cwd: nil, systemPrompt: nil, spaceId: w.space.id, createdBy: w.principal.id,
                                      createdByName: w.principal.displayName)
        return try #require(made["id"] as? String)
    }

    @Test("a code write lands after other activity, and is refused only after another code write (decision 4)")
    func codeOnlyConflicts() async throws {
        let w = try makeParityWorld()
        let id = try port(w)
        let p = w.principal
        let read = w.state.portInput.token(for: id)
        _ = try await call(w, "port.push", p, ["id": id, "data": "a card", "token": read])        // ordinary activity
        #expect(w.state.portInput.token(for: id) != read, "the push did not move the token")
        _ = try await call(w, "port.patch", p, ["id": id, "search": "<h1>board</h1>", "replace": "<h1>board one</h1>", "token": read])
        // Another agent composed against the same old token: a code write landed since, so it is refused.
        do {
            _ = try await call(w, "port.patch", p, ["id": id, "search": "board one", "replace": "board two", "token": read])
            Issue.record("a code write over another code write was accepted")
        } catch let e as BridgeError { #expect(e.code == "stale_write") }
        #expect(TwoAgentsCorrectnessTests.pure())
    }

    static func pure() -> Bool {
        AppState.noCodeWriteSince("e:5", current: "e:9", lastCode: 3)
            && !AppState.noCodeWriteSince("e:5", current: "e:9", lastCode: 7)
            && !AppState.noCodeWriteSince("x:5", current: "e:9", lastCode: nil)
            && !AppState.noCodeWriteSince("e:12", current: "e:9", lastCode: nil)
    }

    @Test("a version names who made it, a local agent or one on another instance")
    func versionAuthors() async throws {
        let w = try makeParityWorld()
        let id = try port(w)
        _ = try await call(w, "port.patch", w.principal, ["id": id, "search": "<h1>board</h1>", "replace": "<h1>one</h1>",
                                                          "token": w.state.portInput.token(for: id)])
        w.state.grantRemoteRights([.see, .use, .edit], to: "guestpeer", onPort: id)
        let bram = Principal.remote(peer: "guestpeer", displayName: "gordon11")
            .acting(as: RemoteActor(id: "B1", name: "bram", kind: .companion))
        _ = try await call(w, "port.patch", bram, ["id": id, "search": "<h1>one</h1>", "replace": "<h1>two</h1>",
                                                   "token": w.state.portInput.token(for: id)])
        let authors = try w.state.db.fetchPortVersions(portUdid: id).map { $0.createdBy ?? "" }
        #expect(authors.contains(w.principal.displayName), "the local agent's version is not named: \(authors)")
        #expect(authors.contains("bram (gordon11)"), "the remote agent's version is not named: \(authors)")
    }

    @Test("the port's maker manages who it is shared with, even after a guest changed its code (finding 6)")
    func makerManagesSharing() async throws {
        let w = try makeParityWorld()
        // Made by a client on the gateway (the live case: the test client made the board, its agent shared it).
        let client = Principal.peer(id: "nautilus", displayName: "nautilus")
        let made = w.state.createPort(type: "web", title: "board", html: "<title>board</title>", command: nil, cwd: nil,
                                      systemPrompt: nil, spaceId: w.space.id, createdBy: client.id, createdByName: client.displayName)
        let id = try #require(made["id"] as? String)
        w.state.grantRemoteRights([.see, .use, .edit], to: "guestpeer", onPort: id)
        // The guest's agent changed the code, so the port no longer acts as its maker (NAU-02): the case live.
        w.state.recordCodeWrite(to: id, by: .remote(peer: "guestpeer", displayName: "gordon11"), replacesAll: true)
        let rows = try await w.state.runBridgeMethod("invite.shared", principal: client, args: BridgeArgs(["port": id]))
        guard case .array(let list) = rows else { Issue.record("no list"); return }
        #expect(list.count == 1, "the maker could not see who the port is shared with")
        let stranger = Principal.companion(id: "stranger", displayName: "stranger", spaceId: w.space.id)
        await #expect(throws: BridgeError.self) {
            _ = try await w.state.runBridgeMethod("invite.shared", principal: stranger, args: BridgeArgs(["port": id]))
        }
    }

    static let me = "25njqamcweflpvkl73j4szahhihoc4xt3ktcgjnpaingr5yhkena"
    static let host = "aaaqeayeaudaocajbifqydiob4ibceqtcqkrmfyydenbwha5dypq"

    /// A tile of the host's port "P", in the world's space, and a gateway answering each call with `reply`.
    func tileWorld(reply: @escaping (String) -> String) throws -> (ParityWorld, String) {
        let w = try makeParityWorld()
        w.state.door.receive(#"{"type":"welcome","sender_id":"host","self_peer":"\#(Self.me)"}"#)
        let door = w.state.door
        door.sendOverride = { [weak door] text in
            guard let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  o["type"] as? String == "remote_call", let id = o["call_id"] as? String else { return }
            let frame = reply(o["method"] as? String ?? "").replacingOccurrences(of: "CALLID", with: id)
            Task { @MainActor in door?.receive(frame) }
        }
        let made = w.state.createPort(type: "web", title: "board", html: "<title>board</title>", command: nil, cwd: nil,
                                      systemPrompt: nil, spaceId: w.space.id, createdBy: nil, createdByName: nil)
        let tile = try #require(made["id"] as? String)
        try w.state.db.upsertRemotePort(.init(peerKey: Self.host, portKey: "P", title: "board", rights: [.see, .use, .edit],
                                              relays: ["wss://relay.test/v1"], hostName: "Gordon"))
        try w.state.db.setRemotePortTile(peerKey: Self.host, portKey: "P", localPort: tile)
        return (w, tile)
    }

    static func response(_ content: String) -> String {
        let c = try! JSONSerialization.data(withJSONObject: ["type": "response", "call_id": "CALLID",
            "payload": ["senderName": "host", "senderType": "host", "content": content]])
        return String(decoding: c, as: UTF8.self)
    }

    @Test("a tile hands out the host's token: from its events, and from a refused write's current (finding 1)")
    func tileHostToken() async throws {
        let (w, tile) = try tileWorld { _ in Self.response(#"{"code":"stale_write","error":"moved","current":"HOST:31"}"#) }
        let row = try #require(w.state.mirroredRemote(tile))
        w.state.mirrorEvent(tile: tile, row: row, ["kind": "state", "token": "HOST:30", "payload": [:]])
        guard case .array(let list) = try await w.state.runBridgeMethod("ports.list", principal: w.principal, args: BridgeArgs([:])) else {
            Issue.record("no list"); return
        }
        let entry = list.compactMap { v -> [String: BridgeValue]? in if case .object(let o) = v, o["id"] == .string(tile) { return o }; return nil }.first
        #expect(entry?["token"] == .string("HOST:30"), "the tile's token is not the host's: \(String(describing: entry?["token"]))")
        let person = Principal.human(id: "u", displayName: "Gordon", spaceId: w.space.id)
        do {
            _ = try await w.state.runBridgeMethod("port.patch", principal: person,
                                                  args: BridgeArgs(["id": tile, "search": "a", "replace": "b", "token": "HOST:29"]))
        } catch {}
        #expect(w.state.mirrorHostTokens[tile] == "HOST:31", "a refused write's current was not kept for the tile")
    }

    @Test("an unreachable host is reported as offline or no longer sharing (finding 5)")
    func unreachableHostMessage() async throws {
        let (w, tile) = try tileWorld { _ in #"{"type":"error","code":"host_offline","error":"that instance is not connected to its relay","call_id":"CALLID"}"# }
        do {
            _ = try await w.state.runBridgeMethod("port.getHtml", principal: .human(id: "u", displayName: "Gordon", spaceId: w.space.id),
                                                  args: BridgeArgs(["id": tile]))
            Issue.record("an unreachable host answered")
        } catch let e as BridgeError {
            #expect(e.code == "host_offline")
            #expect(e.message.contains("no longer shares"), "the message does not say sharing may have stopped: \(e.message)")
        }
    }

    @Test("a tile keeps no versions of its own: its history is the host's (decision 7)")
    func tileKeepsNoVersions() async throws {
        let (w, tile) = try tileWorld { _ in Self.response(#"[{"version":3,"createdBy":"bram (gordon11)","createdAt":"2026-10-02T21:00:00Z"}]"#) }
        let row = try #require(w.state.mirroredRemote(tile))
        _ = await w.state.portWindows.updatePort(idOrTitle: tile, html: "<title>board</title><p>v2</p>", skipVersionSnapshot: true)
        w.state.portWindows.movePort(id: tile, x: 10, y: 10)                    // a persist, which used to snapshot
        #expect(try w.state.db.fetchPortVersions(portUdid: tile).count <= 1, "the tile kept versions of the host's page")
        await w.state.refreshMirrorHistory(tile: tile, row: row)
        #expect(w.state.mirrorHistory[tile]?.first?.createdBy == "bram (gordon11)", "the tile does not show the host's history")
    }
}
