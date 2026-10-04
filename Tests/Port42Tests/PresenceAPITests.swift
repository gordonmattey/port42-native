import Testing
import Foundation
@testable import Port42Lib

/// Presence in the API (GM, 2026-09-27): who is on a chat's messages can be read (`presence.list`) and
/// heard (the `presence` event on the chat's port topic), by a port, a companion, or another machine the
/// port is shared with. Before, it lived only in the chat panel, so nothing outside the app could see it.
@Suite("Presence in the API")
@MainActor
struct PresenceAPITests {

    func list(_ w: ParityWorld, _ port: String, as p: Principal? = nil) async throws -> [[String: Any]] {
        let v = try await w.state.runBridgeMethod("presence.list", principal: p ?? w.principal,
                                                  args: BridgeArgs(["port": port]))
        return (v.toJSONObject() as? [String: Any])?["presence"] as? [[String: Any]] ?? []
    }

    @Test("presence.list follows a turn: has the message, working, waiting and why, then nobody")
    func listFollowsTheTurn() async throws {
        let w = try makeParityWorld()
        let chat = w.space.id
        #expect(try await list(w, chat).isEmpty)

        w.state.presence.received("echo", in: chat)
        var now = try await list(w, chat)
        #expect(now.map { $0["name"] as? String } == ["echo"])
        #expect(now.first?["state"] as? String == "received")
        #expect((now.first?["since"] as? Int ?? 0) > 1_700_000_000, "since is not seconds since 1970")

        w.state.presence.update("echo", to: .working)
        #expect(try await list(w, chat).first?["state"] as? String == "working")

        w.state.presence.update("echo", to: .waiting("allow Bash?"))
        now = try await list(w, chat)
        #expect(now.first?["state"] as? String == "waiting" && now.first?["why"] as? String == "allow Bash?")

        w.state.presence.done("echo")
        #expect(try await list(w, chat).isEmpty, "presence stayed after the turn ended")
    }

    @Test("each change is published on the chat's port topic as a presence event carrying the whole list")
    func publishesEachChange() async throws {
        let w = try makeParityWorld()
        let chat = w.space.id
        var lists: [[String]] = []
        let topic = PortNotify.topic(forPortKey: chat)
        let id = w.state.notifyBus.subscribe(topic: topic) { json in
            guard let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  o["kind"] as? String == "presence",
                  let p = (o["payload"] as? [String: Any])?["presence"] as? [[String: Any]] else { return }
            lists.append(p.map { "\($0["name"] as? String ?? "?"):\($0["state"] as? String ?? "?")" })
        }
        defer { w.state.notifyBus.unsubscribe(id: id, topic: topic) }

        w.state.presence.received("echo", in: chat)
        w.state.presence.update("echo", to: .working)
        w.state.presence.update("echo", to: .working)            // no change: no event
        w.state.presence.done("echo")
        #expect(lists == [["echo:received"], ["echo:working"], []], "events: \(lists)")
    }

    @Test("a machine a port is shared with reads that port's presence, and no other chat's")
    func remoteSeesOnlyItsPort() async throws {
        let t = InviteTests()
        let w = try t.world()
        _ = try await t.remote(w, as: InviteTests.ada, "invite.redeem", ["nonce": try t.coupon(try await t.create(w)).nonce, "name": "Ada"])
        w.state.presence.received("echo", in: w.p)
        w.state.presence.received("scout", in: w.q)

        let mine = try #require(try await t.remote(w, as: InviteTests.ada, "presence.list", ["port": w.p]) as? [String: Any])
        // Shown with this machine's name, as its chat shows it to the other machine (two agents, Phase 6.2).
        #expect((mine["presence"] as? [[String: Any]])?.map { $0["name"] as? String } == ["echo (\(w.state.selfLabel))"])
        #expect(t.reason(try await t.remote(w, as: InviteTests.ada, "presence.list", ["port": w.q])) == "not_granted",
                "another machine read the presence of a port not shared with it")
    }
}
