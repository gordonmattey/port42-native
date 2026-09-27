import Testing
import Foundation
@testable import Port42Lib

/// Nautilus Phase 4, step 4.6b: fork. A copy of a port becomes a new port of this instance, independent
/// of the original. A port someone shared is copied only when they allowed it (Gordon, option A: their
/// leave, honoured by Port42, not a lock).
@Suite("Fork (Phase 4, 4.6b)")
@MainActor
struct ForkTests {

    func here(_ state: AppState) throws {
        let space = Space.create(name: "here")
        try state.db.saveSpace(space)
        state.spaces = [space]
        state.currentSpace = space
    }

    @Test("forking your own port makes an independent copy beside it")
    func localFork() async throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        try here(state)
        _ = state.portWindows.registerTiledPort(id: "o", html: "<p>original</p>", spaceId: state.currentSpace?.id,
                                                createdBy: "author-1", title: "chart", position: nil)
        let copy = try await state.forkPort("o")
        let panel = try #require(state.portWindows.panels.first { $0.id == copy })
        #expect(panel.id != "o" && panel.title == "chart (copy)")
        #expect(panel.html == "<p>original</p>")
        _ = await state.portWindows.updatePort(idOrTitle: "o", html: "<p>changed</p>")
        #expect(state.portWindows.panels.first { $0.id == copy }?.html == "<p>original</p>", "the copy followed the original")
    }

    @Test("a shared port is forked only when its sharer allowed a copy")
    func remoteFork() async throws {
        let rt = RemoteTileTests()
        var allowed = ["see", "use"]
        let (state, gw) = try rt.world()
        try here(state)
        gw.reply = { method, _ in
            switch method {
            case "invite.redeem": return [RemotePortTests.response(["port": "P", "title": "shared chart", "rights": allowed])]
            case "port.getHtml": return [RemotePortTests.response("<p>theirs</p>")]
            case "port.subscribe": return []
            default: return [["type": "error", "code": "transport_failed", "error": "unscripted \(method)"]]
            }
        }
        let tile = try await rt.accept(state)
        let before = state.portWindows.panels.count
        do { _ = try await state.forkPort(tile); Issue.record("a port was copied without leave") }
        catch let e as BridgeError { #expect(e.code == "not_granted") }
        #expect(state.portWindows.panels.count == before, "a copy was made anyway")
        state.leaveRemotePort(tile: tile)

        allowed = ["see", "use", "fork"]
        let tile2 = try await rt.accept(state)
        let copy = try await state.forkPort(tile2)
        let panel = try #require(state.portWindows.panels.first { $0.id == copy })
        #expect(panel.html == "<p>theirs</p>" && panel.title == "shared chart (copy)")
        #expect(state.mirroredRemote(copy) == nil, "the copy is still theirs")
        state.leaveRemotePort(tile: tile2)
    }

    @Test("a move invite hands the port over once: its page goes, it closes here, and no right is granted")
    func moveHandsOver() async throws {
        let t = InviteTests()
        let w = try t.world()
        let made = try await t.create(w, rights: ["see", "move"])
        let v = try await t.remote(w, as: InviteTests.ada, "invite.redeem", ["nonce": try t.coupon(made).nonce, "name": "Ada"])
        let o = try #require(v as? [String: Any])
        #expect(o["moved"] as? Bool == true && o["html"] as? String == "<p>p</p>" && o["title"] as? String == "shared chart")
        for _ in 0..<50 where w.state.portWindows.panels.contains(where: { $0.id == "inv-p" }) { await Task.yield() }
        #expect(!w.state.portWindows.panels.contains { $0.id == "inv-p" }, "the port stayed here after moving")
        #expect(w.state.remoteRights(of: InviteTests.ada, onPort: w.p).isEmpty, "a move granted a right to a port that is gone")
        let again = try await t.remote(w, as: InviteTests.ada, "invite.redeem", ["nonce": try t.coupon(made).nonce, "name": "Ada"])
        #expect(t.reason(again) == "used" || t.reason(again) == "gone", "a port moved twice")
    }

    @Test("taking a moved port makes it this instance's own, with nothing mirrored")
    func moveReceived() async throws {
        let (state, gw) = try RemotePortTests().world()
        try here(state)
        gw.reply = { method, _ in
            method == "invite.redeem"
                ? [RemotePortTests.response(["moved": true, "title": "shared chart", "html": "<p>given</p>"])]
                : [["type": "error", "code": "transport_failed", "error": "unscripted \(method)"]]
        }
        let link = InviteCoupon(host: RemotePortTests.host, relays: ["r"], port: "P", rights: ["see", "move"], nonce: "n",
                                exp: Int(Date().timeIntervalSince1970) + 600, hostName: "Ada", portTitle: "shared chart",
                                code: false).link
        let out = try await state.runBridgeMethod("invite.accept", principal: .human(id: "u", displayName: "Me", spaceId: nil),
                                                  args: BridgeArgs(["link": link]))
        let o = try #require(out.toJSONObject() as? [String: Any])
        let id = try #require(o["port"] as? String)
        #expect(o["moved"] as? Bool == true)
        let panel = try #require(state.portWindows.panels.first { $0.id == id })
        #expect(panel.html == "<p>given</p>" && panel.title == "shared chart")
        let rows = try state.db.remotePorts()
        #expect(state.mirroredRemote(id) == nil && rows.isEmpty, "a moved port was mirrored as theirs")
    }
}
