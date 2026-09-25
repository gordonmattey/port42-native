import Testing
import Foundation
@testable import Port42Lib

/// Closing never destroys (nautilus Phase 2 step 2, GM: "we should never close them"). Close archives
/// the port; reopen brings back the same port with its id; only "delete forever" removes it.
@Suite("Port archive (close is not destroy)")
@MainActor
struct PortArchiveTests {

    @MainActor struct World {
        let state: AppState
        let space: Space
        var pw: PortWindowManager { state.portWindows }
    }

    func world() throws -> World {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let space = Space.create(name: "main")
        try db.saveSpace(space)
        state.spaces = [space]; state.currentSpace = space
        state.portWindows.registerTiledPort(id: "p", html: "<title>p</title><p>one</p>", spaceId: space.id,
                                            createdBy: nil, title: "p", position: CGPoint(x: 120, y: 140))
        state.portWindows.registerTiledPort(id: "q", html: "<title>q</title>", spaceId: space.id,
                                            createdBy: nil, title: "q", position: CGPoint(x: 700, y: 140))
        return World(state: state, space: space)
    }

    func call(_ w: World, _ method: String, _ args: [String: Any]) async throws -> BridgeValue {
        try await w.state.runBridgeMethod(method, principal: .peer(id: "cli", displayName: "cli"),
                                          args: BridgeArgs(args))
    }

    func token(_ w: World, _ id: String) -> String {
        w.state.portInput.token(for: w.pw.panels.first { $0.id == id }?.udid ?? id)
    }

    @Test("close then reopen gives back the same id, content and position, and moves no other port")
    func closeReopen() throws {
        let w = try world()
        let q0 = w.pw.panels.first { $0.id == "q" }?.position(on: w.space.id)
        w.pw.close("p")
        #expect(!w.pw.panels.contains { $0.id == "p" })
        #expect(w.pw.reopen("p"))
        let p = try #require(w.pw.panels.first { $0.id == "p" })
        #expect(p.udid == "p")
        #expect(p.html.contains("one"))
        #expect(p.position(on: w.space.id) == CGPoint(x: 120, y: 140))
        #expect(w.pw.panels.first { $0.id == "q" }?.position(on: w.space.id) == q0)
        #expect(!w.pw.reopen("p"), "an open port cannot be reopened")
        withExtendedLifetime(w.state) {}
    }

    @Test("a closed port is on no desktop and out of ports.list unless asked, where it reads closed")
    func closedIsHidden() async throws {
        let w = try world()
        w.pw.close("p")
        #expect(try w.state.db.fetchPortPanels().map(\.id) == ["q"], "launch restores only open ports")
        let plain = try await call(w, "ports.list", [:]).toJSONObject() as? [[String: Any]] ?? []
        #expect(!plain.contains { $0["id"] as? String == "p" })
        let all = try await call(w, "ports.list", ["include_closed": true]).toJSONObject() as? [[String: Any]] ?? []
        #expect(all.first { $0["id"] as? String == "p" }?["status"] as? String == "closed")
        withExtendedLifetime(w.state) {}
    }

    @Test("a subscriber holding the id hears the port again after reopen")
    func subscriberSurvives() async throws {
        let w = try world()
        var kinds: [String] = []
        let topic = PortNotify.topic(forPortKey: "p")
        let sub = w.state.notifyBus.subscribe(topic: topic) { json in
            if let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
               let k = o["kind"] as? String { kinds.append(k) }
        }
        defer { w.state.notifyBus.unsubscribe(id: sub, topic: topic) }
        w.pw.close("p")
        let reopened = try await call(w, "port.reopen", ["id": "p"]).toJSONObject() as? [String: Any]
        let t = try #require(reopened?[PortActivity.tokenKey] as? String)
        _ = try await call(w, "port.update", ["id": "p", "html": "<title>p</title><p>two</p>", "token": t])
        #expect(kinds.contains(PortEventKind.state.wire))
        withExtendedLifetime(w.state) {}
    }

    @Test("a token from before the close is still refused after reopen")
    func staleTokenRefused() async throws {
        let w = try world()
        let t0 = token(w, "p")
        _ = try await call(w, "port.update", ["id": "p", "html": "<title>p</title><p>a</p>", "token": t0])
        w.pw.close("p")
        #expect(w.pw.reopen("p"))
        do {
            _ = try await call(w, "port.update", ["id": "p", "html": "<title>p</title><p>b</p>", "token": t0])
            Issue.record("a pre-close token was accepted")
        } catch let e as BridgeError {
            #expect(e.code == BridgeErrorCode.staleWrite.wire)
        }
        withExtendedLifetime(w.state) {}
    }

    @Test("port.reopen of a port that is not closed is not_found")
    func reopenUnknown() async throws {
        let w = try world()
        await #expect(throws: BridgeError.self) { _ = try await call(w, "port.reopen", ["id": "nope"]) }
        withExtendedLifetime(w.state) {}
    }

    @Test("port.delete refuses an open port and deletes a closed one")
    func portDelete() async throws {
        let w = try world()
        await #expect(throws: BridgeError.self) { _ = try await call(w, "port.delete", ["id": "p"]) }
        #expect(w.pw.panels.contains { $0.id == "p" }, "an open port is never deleted in one step")
        w.pw.close("p")
        _ = try await call(w, "port.delete", ["id": "p"])
        #expect(try w.state.db.fetchPortPanel(id: "p") == nil)
        withExtendedLifetime(w.state) {}
    }

    @Test("delete forever removes the record, its versions and its chat")
    func deleteForever() throws {
        let w = try world()
        _ = try w.state.db.appendChatEntry(chat: "p", text: "hi", at: Date(), fromId: "a", fromName: "a", fromKind: "human")
        w.pw.close("p")
        #expect(try w.state.db.reapOrphanChats() == 0, "a closed port keeps its chat")
        w.pw.deleteForever("p")
        #expect(try w.state.db.fetchPortPanel(id: "p") == nil)
        #expect(try w.state.db.lastChatSeq(chat: "p") == 0)
        #expect(w.pw.closedPorts().isEmpty)
        #expect(!w.pw.reopen("p"))
        withExtendedLifetime(w.state) {}
    }
}
