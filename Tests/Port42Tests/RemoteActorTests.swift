import Testing
import Foundation
@testable import Port42Lib

/// Nautilus Phase 4, step 4.6c: a call from another instance says who there made it, and this
/// instance records and routes the post by that actor. The instance is proven by the relay; the actor
/// is its claim, so it names the post and picks the routing rule, and grants nothing.
@Suite("Remote actor (Phase 4, 4.6c)")
@MainActor
struct RemoteActorTests {

    static let peer = RemotePortTests.host

    @Test("only the four kinds are believed, and long fields are cut")
    func claimShape() {
        #expect(RemoteActor(wireId: "x", name: "n", kind: "remote") == nil, "an actor claimed to be another instance")
        #expect(RemoteActor(wireId: "x", name: "n", kind: "system") == nil, "a kind outside the four was believed")
        #expect(RemoteActor(wireId: "", name: "n", kind: "human") == nil)
        #expect(RemoteActor(wireId: "x", name: String(repeating: "a", count: 500), kind: "companion")?.name.count == 64)
    }

    @Test("a companion there posting plainly wakes nobody here; the person there does, with wake_agents")
    func routedByActor() throws {
        let w = try makeParityWorld()
        var a = AgentConfig.createCommand(ownerId: "u", displayName: "alpha", command: "claude", systemPrompt: nil, trigger: .mentionOnly)
        a.openInTerminal = true
        w.state.companions = [a]
        let panelId = w.state.spawnNativeTerminalPort(command: "true", cwd: NSTemporaryDirectory(), spaceId: w.space.id,
                                                      title: "alpha", companionName: "alpha", companionId: a.id,
                                                      systemPrompt: nil, postCard: false)
        let key = try #require(w.state.portWindows.panels.first { $0.id == panelId }?.udid)
        w.state.grantRemoteRights([.see, .use, .wakeAgents], to: Self.peer, onPort: key)
        let there = Principal.remote(peer: Self.peer, displayName: "Ada")
        w.state.pendingTerminalInjections = [:]

        let theirCompanion = there.acting(as: RemoteActor(id: "c-9", name: "wise-tern", kind: .companion))
        let e1 = try w.state.postToChat(key: key, text: "my part is done", from: theirCompanion)
        #expect(e1.fromId == "\(Self.peer)/c-9" && e1.fromName == "wise-tern (Ada)" && e1.fromKind == "companion")
        #expect(w.state.chatReplyTargets["alpha"] == nil, "a companion on another instance woke this one without a mention")

        let theirPerson = there.acting(as: RemoteActor(id: "u-ada", name: "Ada", kind: .human))
        let e2 = try w.state.postToChat(key: key, text: "alpha, go", from: theirPerson)
        #expect(e2.fromName == "Ada" && e2.fromId == "\(Self.peer)/u-ada", "the person there was not named as themselves")
        #expect(e2.fromId != w.state.currentUser?.id, "a claim of human became this instance's person")
        #expect(w.state.chatReplyTargets["alpha"] == key, "the person there, with wake_agents, did not wake the port's companion")
        withExtendedLifetime(w.state) {}
    }

    @Test("a write from another instance names the actor there as the port's driver")
    func driverNamesActor() async throws {
        let w = try makeParityWorld()
        _ = w.state.portWindows.registerTiledPort(id: "d", html: "<p>x</p>", spaceId: w.space.id, createdBy: nil,
                                                  title: "d", position: nil)
        let key = try #require(w.state.portWindows.panels.first { $0.id == "d" }?.udid)
        w.state.grantRemoteRights([.see, .use, .edit], to: Self.peer, onPort: key)
        let there = Principal.remote(peer: Self.peer, displayName: "Ada")
            .acting(as: RemoteActor(id: "c-9", name: "wise-tern", kind: .companion))
        let tok = try #require((try await w.state.runBridgeMethod("ports.list", principal: there, args: BridgeArgs([:]))
            .toJSONObject() as? [[String: Any]])?.first?["token"] as? String)
        // Read as of the write, not of whenever the check runs: a driver shows for 30 seconds, and a
        // loaded machine took longer than that to get from the write to the check.
        let before = Date()
        _ = try await w.state.runBridgeMethod("port.update", principal: there,
                                              args: BridgeArgs(["id": key, "html": "<p>y</p>", "token": tok]))
        let d = try #require(w.state.portInput.driver(of: key, now: before.addingTimeInterval(1)))
        #expect(d.ref == ActorRef(peer: Self.peer, principal: "c-9") && d.name == "wise-tern (Ada)",
                "the driver was \(d.ref) \(d.name)")
    }

    @Test("whoami lists the companions met on other instances, how to mention each, and the chat; not this instance's own")
    func whoamiElsewhere() async throws {
        let w = try makeParityWorld()
        _ = w.state.portWindows.registerTiledPort(id: "s", html: "<p>x</p>", spaceId: w.space.id, createdBy: nil,
                                                  title: "shared", position: nil)
        let key = try #require(w.state.portWindows.panels.first { $0.id == "s" }?.udid)
        w.state.grantRemoteRights([.see, .use], to: Self.peer, onPort: key)
        let there = Principal.remote(peer: Self.peer, displayName: "Ada")
        _ = try w.state.postToChat(key: key, text: "hi", from: there.acting(as: RemoteActor(id: "c-9", name: "wise-tern", kind: .companion)))
        _ = try w.state.postToChat(key: key, text: "me", from: there.acting(as: RemoteActor(id: "u-ada", name: "Ada", kind: .human)))
        let me = Principal.companion(id: w.companion.id, displayName: w.companion.displayName, spaceId: w.space.id)
        let o = try #require(try await w.state.runBridgeMethod("whoami", principal: me, args: BridgeArgs([:])).toJSONObject() as? [String: Any])
        let elsewhere = try #require(o["elsewhere"] as? [[String: Any]])
        #expect(elsewhere.map { $0["name"] as? String } == ["wise-tern (Ada)"], "a person, or nobody, was listed as a companion")
        #expect(elsewhere.first?["mention"] as? String == "@wise-tern%20%28Ada%29" && elsewhere.first?["port"] as? String == key)
    }

    @Test("a mention of a companion on another instance never wakes this instance's companion of the same name")
    func noLocalWakeForARemoteName() throws {
        let w = try makeParityWorld(companionName: "wise-tern")
        let mentioned = AgentRouter.findTargetAgents(content: CompanionName.mention("wise-tern (Ada)") + " your turn", agents: [w.companion],
                                                     spaceAgentIds: [], localOwner: nil)
        #expect(mentioned.isEmpty, "a mention of Ada's wise-tern woke this instance's wise-tern")
        #expect(AgentRouter.findTargetAgents(content: "@wise-tern your turn", agents: [w.companion],
                                             spaceAgentIds: [], localOwner: nil).count == 1)
    }

    @Test("a call sent to another instance says who here made it; a companion in a terminal goes as a companion")
    func actorSent() async throws {
        let (state, gw) = try RemotePortTests().world()
        try state.db.upsertRemotePort(.init(peerKey: Self.peer, portKey: "P", title: "t", rights: [.see, .use],
                                            relays: ["r"], hostName: "Ada"))
        gw.reply = { _, _ in [RemotePortTests.response(["ok": true])] }
        let c = AgentConfig.createCommand(ownerId: "u", displayName: "wise-tern", command: "claude", systemPrompt: nil, trigger: .mentionOnly)
        state.companions = [c]
        let address = "port42://\(Self.peer)/P"
        let cases: [(Principal, String, String)] = [
            (.peer(id: "cli-7", displayName: "wise-tern"), "companion", c.id),
            (.peer(id: "cli-8", displayName: "some script"), "peer", "cli-8"),
            (.human(id: "u", displayName: "Gordon", spaceId: nil), "human", "u"),
        ]
        for (who, kind, id) in cases {
            _ = try await state.runBridgeMethod("chat.post", principal: who, args: BridgeArgs(["port": address, "text": "hi"]))
            let actor = gw.calls.last?["actor"] as? [String: String]
            #expect(actor?["kind"] == kind && actor?["id"] == id, "\(who.displayName) went as \(actor ?? [:])")
        }
    }
}
