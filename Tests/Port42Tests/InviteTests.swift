import Testing
import Foundation
@testable import Port42Lib

/// Nautilus Phase 4, step 4.5: one invite per port. Made here, redeemed at the remote door by an
/// attested but not yet enrolled peer, once; optionally behind a code; withdrawable; and a peer's
/// grants removable port by port. Headless: the door is driven frame by frame.
@Suite("Invites (Phase 4, 4.5)")
@MainActor
struct InviteTests {

    static let key = "attest-key-for-this-spawn"
    static let me = "25njqamcweflpvkl73j4szahhihoc4xt3ktcgjnpaingr5yhkena"
    static let ada = "aaaqeayeaudaocajbifqydiob4ibceqtcqkrmfyydenbwha5dypq"
    static let eve = "evevevevevevevevevevevevevevevevevevevevevevevevevq"

    final class Wire {
        var sent: [[String: Any]] = []
        func responses() -> [[String: Any]] { sent.filter { $0["type"] as? String == "response" } }
    }

    struct World {
        let state: AppState
        let wire: Wire
        let p: String
        let q: String
    }

    func world(relays: [String] = ["wss://relay.test/v1"]) throws -> World {
        let state = AppState(db: try DatabaseService(inMemory: true))
        state.remoteAttestKey = { Self.key }
        state.relayList = { relays }
        state.door.receive(#"{"type":"welcome","sender_id":"host","self_peer":"\#(Self.me)"}"#)
        let wire = Wire()
        state.door.sendOverride = { t in
            if let d = t.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                wire.sent.append(o)
            }
        }
        _ = state.portWindows.registerTiledPort(id: "inv-p", html: "<p>p</p>", spaceId: nil, createdBy: "author-1",
                                                title: "shared chart", position: nil)
        _ = state.portWindows.registerTiledPort(id: "inv-q", html: "<p>q</p>", spaceId: nil, createdBy: nil,
                                                title: "second", position: nil)
        let p = try #require(state.portWindows.panels.first { $0.id == "inv-p" }?.udid)
        let q = try #require(state.portWindows.panels.first { $0.id == "inv-q" }?.udid)
        return World(state: state, wire: wire, p: p, q: q)
    }

    let person = Principal.human(id: "u", displayName: "Gordon", spaceId: nil)

    func create(_ w: World, port: String? = nil, rights: [String]? = nil, code: Bool = false) async throws -> [String: Any] {
        var args: [String: Any] = ["port": port ?? w.p]
        if let rights { args["rights"] = rights }
        if code { args["requireCode"] = true }
        let v = try await w.state.runBridgeMethod("invite.create", principal: person, args: BridgeArgs(args))
        return try #require(v.toJSONObject() as? [String: Any])
    }

    func coupon(_ made: [String: Any]) throws -> InviteCoupon {
        let link = try #require(made["link"] as? String)
        let fragment = try #require(link.split(separator: "#", maxSplits: 1).last.map(String.init))
        return try #require(InviteCoupon.decode(fragment))
    }

    /// Call through the remote door as `peer`, attested, and return the response's content.
    func remote(_ w: World, as peer: String, _ method: String, _ args: [String: Any]) async throws -> Any? {
        let before = w.wire.responses().count
        let argJSON = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        let attest = AppState.attest(key: Self.key, peer: peer)
        w.state.door.receive(#"{"type":"call","call_id":"c\#(before)","sender_id":"remote-x","method":"\#(method)","args":\#(argJSON),"remote_peer":"\#(peer)","remote_attest":"\#(attest)"}"#)
        for _ in 0..<400 where w.wire.responses().count == before { try await Task.sleep(nanoseconds: 5_000_000) }
        let frame = try #require(w.wire.responses().last)
        let p = try #require(frame["payload"] as? [String: Any])
        let c = try #require(p["content"] as? String)
        return try JSONSerialization.jsonObject(with: Data(c.utf8), options: [.fragmentsAllowed])
    }

    func reason(_ v: Any?) -> String? {
        guard let o = v as? [String: Any] else { return nil }
        return (o["reason"] as? String) ?? (o["code"] as? String)
    }

    // MARK: - Making

    @Test("an invite is a port42.ai link whose fragment names this instance, its relays, one port and its rights")
    func linkShape() async throws {
        let w = try world()
        let made = try await create(w)
        let link = try #require(made["link"] as? String)
        #expect(link.hasPrefix("https://tele.port42.ai/#"))
        let c = try coupon(made)
        #expect(c.host == Self.me && c.port == w.p && c.relays == ["wss://relay.test/v1"])
        #expect(c.rights == ["see", "use", "wake_agents"], "the default rights are view, drive and remote wake")
        #expect(c.portTitle == "shared chart" && !c.code && made["code"] == nil)
        #expect(c.exp > Int(Date().timeIntervalSince1970))
        // The table holds a hash, never the nonce itself.
        let row = try #require(try w.state.db.allInvites().first)
        #expect(row.portKey == w.p)
        #expect(try w.state.db.invite(nonceHash: c.nonce) == nil, "the raw nonce was stored")
    }

    @Test("port 0, a space, a missing port, no relay and no peer id are all refused")
    func refusals() async throws {
        let w = try world()
        for port in ["0", "no-such-port"] {
            await #expect(throws: BridgeError.self) { _ = try await create(w, port: port) }
        }
        let space = Space.create(name: "a space")
        try w.state.db.saveSpace(space)
        w.state.spaces.append(space)
        do { _ = try await create(w, port: space.id); Issue.record("a space was shared") }
        catch let e as BridgeError { #expect(e.message.contains("not a space"), "a space was refused for the wrong reason: \(e.message)") }
        let lonely = try world(relays: [])
        await #expect(throws: BridgeError.self) { _ = try await create(lonely) }
    }

    @Test("a terminal or a browser port is never shared, and an invite made for one before is refused at redeem")
    func onlyWebPortsShared() async throws {
        let w = try world()
        let i = try #require(w.state.portWindows.panels.firstIndex { $0.id == "inv-q" })
        let made = try await create(w, port: w.q)                  // a web port: fine
        w.state.portWindows.panels[i].portType = "terminal"
        do { _ = try await create(w, port: w.q); Issue.record("a terminal was shared") }
        catch let e as BridgeError { #expect(e.message.contains("only a web port"), "refused for the wrong reason: \(e.message)") }
        w.state.portWindows.panels[i].portType = "browser"
        await #expect(throws: BridgeError.self) { _ = try await create(w, port: w.q) }
        let v = try await remote(w, as: Self.ada, "invite.redeem", ["nonce": try coupon(made).nonce, "name": "Ada"])
        #expect(reason(v) == "gone", "an invite for a port that is now a browser was redeemed")
        #expect(w.state.remoteRights(of: Self.ada, onPort: w.q).isEmpty)
    }

    @Test("an agent asks before sharing; the person is never asked on their own behalf")
    func sharingIsAsked() async throws {
        let w = try world()
        _ = try await create(w)
        #expect(w.state.permissions.current == nil, "the person was asked to allow themselves")
        let agent = Principal.peer(id: "some-cli", displayName: "a script")
        let pending = Task { @MainActor in
            try await w.state.runBridgeMethod("invite.create", principal: agent, args: BridgeArgs(["port": w.p]))
        }
        for _ in 0..<200 where w.state.permissions.current == nil { await Task.yield() }
        #expect(w.state.permissions.current?.permission == .share, "an agent shared a port without asking")
        w.state.permissions.resolveCurrent(granted: false)
        await #expect(throws: BridgeError.self) { _ = try await pending.value }
    }

    @Test("an agent is asked for each port it shares or opens, not once for all of them")
    func sharingIsAskedPerPort() async throws {
        let w = try world()
        let agent = Principal.peer(id: "some-cli", displayName: "a script")
        func share(_ port: String) -> Task<BridgeValue, Error> {
            Task { @MainActor in try await w.state.runBridgeMethod("invite.create", principal: agent, args: BridgeArgs(["port": port])) }
        }
        let first = share(w.p)
        for _ in 0..<200 where w.state.permissions.current == nil { await Task.yield() }
        #expect(w.state.permissions.current?.detail?.contains("shared chart") == true, "the card did not name the port")
        w.state.permissions.resolveCurrent(granted: true)
        _ = try await first.value
        _ = try await share(w.p).value                      // the same port again: not asked
        #expect(w.state.permissions.current == nil)
        let second = share(w.q)
        for _ in 0..<200 where w.state.permissions.current == nil { await Task.yield() }
        #expect(w.state.permissions.current?.detail?.contains("second") == true,
                "leave to share one port let the agent share another without asking")
        w.state.permissions.resolveCurrent(granted: false)
        await #expect(throws: BridgeError.self) { _ = try await second.value }

        let link = InviteCoupon(host: "aaaqeayeaudaocajbifqydiob4ibceqtcqkrmfyydenbwha5dypq", relays: ["r"], port: "P",
                                rights: ["see"], nonce: "n", exp: Int(Date().timeIntervalSince1970) + 600,
                                hostName: "Ada", portTitle: "her chart", code: false).link
        let gw = RemotePortTests.ScriptedGateway()     // answers any call with an error, so nothing waits
        gw.install(on: w.state.door)
        let open = Task { @MainActor in
            try await w.state.runBridgeMethod("invite.accept", principal: agent, args: BridgeArgs(["link": link]))
        }
        for _ in 0..<200 where w.state.permissions.current == nil { await Task.yield() }
        #expect(w.state.permissions.current?.detail == "Open 'her chart' from Ada. Their companions can wake yours in its chat (remote wake)",
                "an agent opened a port from another machine without asking for that port")
        w.state.permissions.resolveCurrent(granted: false)
        await #expect(throws: BridgeError.self) { _ = try await open.value }
    }

    @Test("a machine joining under a name already taken here gains its id; the first keeps it, and each is told its name")
    func labelsAtEnrolment() async throws {
        let w = try world()
        w.state.currentUser = AppUser.createLocal(displayName: "Gordon")
        func join(_ peer: String, as name: String) async throws -> String? {
            let c = try coupon(try await create(w))
            return (try await remote(w, as: peer, "invite.redeem", ["nonce": c.nonce, "name": name]) as? [String: Any])?["knownAs"] as? String
        }
        #expect(try await join(Self.ada, as: "Ada") == "Ada", "the first to take a name did not keep it")
        #expect(try await join(Self.eve, as: "ada") == "ada \(Self.eve.prefix(4))", "a second 'Ada' was not told apart")
        let third = "thirdthirdthirdthirdthirdthirdthirdthirdthirdthirdq"
        #expect(try await join(third, as: "Gordon") == "Gordon thir", "a machine took this person's own name")
        #expect(try await join(Self.ada, as: "Someone else") == "Ada", "a label people had seen changed")
    }

    @Test("an unused link can be copied again, with its code; used or withdrawn it is forgotten; invite.list never shows it")
    func linkCopiedAgain() async throws {
        let w = try world()
        let made = try await create(w, code: true)
        let id = try #require(made["id"] as? String)
        let link = try #require(made["link"] as? String)
        let code = try #require(made["code"] as? String)
        #expect(try coupon(made).link == link, "one invite spelled out twice gave two links")
        let message = w.state.inviteMessage(id: id)
        #expect(message == "\(link)\ncode: \(code)", "an unused link could not be copied again: \(message ?? "nil")")
        let listed = try await w.state.runBridgeMethod("invite.list", principal: person, args: BridgeArgs([:]))
        #expect(!(String(describing: listed.toJSONObject() ?? "")).contains(link), "invite.list handed out a link")

        w.state.withdrawInvite(id: id)
        #expect(w.state.inviteMessage(id: id) == nil, "a withdrawn link can still be copied")
        #expect(AppState.testInviteLinks[id] == nil, "a withdrawn link was kept")

        let used = try await create(w)
        let usedId = try #require(used["id"] as? String)
        _ = try await remote(w, as: Self.ada, "invite.redeem", ["nonce": try coupon(used).nonce, "name": "Ada"])
        #expect(w.state.inviteMessage(id: usedId) == nil && AppState.testInviteLinks[usedId] == nil, "a used link was kept")
    }

    @Test("the invite discloses what the port can do on this machine")
    func disclosure() async throws {
        let w = try world()
        w.state.saveGrants([.clipboard, .rest], grantee: "author-1", on: .machine, zone: nil)
        let made = try await create(w)
        #expect((made["discloses"] as? [String]) == ["clipboard", "rest"])
    }

    // MARK: - Redeeming

    @Test("redeeming enrols the guest, grants the one port, and posts a notice that wakes nobody")
    func redeem() async throws {
        let w = try world()
        let c = try coupon(try await create(w))
        let out = try #require(try await remote(w, as: Self.ada, "invite.redeem", ["nonce": c.nonce, "name": "Ada"]) as? [String: Any])
        #expect(out["port"] as? String == w.p)
        let client = try #require(try w.state.db.client(peerKey: Self.ada))
        #expect(client.kind == .peer && client.name == "Ada")
        #expect(w.state.remoteRights(of: Self.ada, onPort: w.p) == [.see, .use, .wakeAgents])
        #expect(w.state.remoteRights(of: Self.ada, onPort: w.q).isEmpty)

        // Now enrolled, the guest's ordinary calls work, confined to the port.
        let rows = try #require(try await remote(w, as: Self.ada, "ports.list", [:]) as? [[String: Any]])
        #expect(Set(rows.compactMap { $0["id"] as? String }) == [w.p])

        let notice = try #require(try w.state.db.chatEntries(chat: w.p, after: 0, limit: 10).last)
        #expect(notice.fromKind == "system" && notice.text.contains("Ada joined"))
    }

    @Test("a link lets in two machines (a browser, then Port42), refuses a third, and either may repeat it")
    func twoUses() async throws {
        let w = try world()
        let c = try coupon(try await create(w))
        let browser = Self.ada, app = Self.eve
        let third = "thirdthirdthirdthirdthirdthirdthirdthirdthirdthirdq"
        _ = try await remote(w, as: browser, "invite.redeem", ["nonce": c.nonce, "name": "Gordon"])
        _ = try await remote(w, as: browser, "invite.redeem", ["nonce": c.nonce])           // a refresh: not a use
        let second = try await remote(w, as: app, "invite.redeem", ["nonce": c.nonce, "name": "Gordon"])
        #expect((second as? [String: Any])?["port"] as? String == w.p, "the same link in Port42 after the browser was refused")
        #expect(w.state.remoteRights(of: app, onPort: w.p) == [.see, .use, .wakeAgents])
        #expect(!w.state.remoteRights(of: browser, onPort: w.p).isEmpty, "the browser lost the port")
        #expect(reason(try await remote(w, as: third, "invite.redeem", ["nonce": c.nonce, "name": "Mallory"])) == "used")
        #expect(try w.state.db.client(peerKey: third) == nil, "a third redeemer was enrolled")
        for peer in [browser, app] {
            let again = try await remote(w, as: peer, "invite.redeem", ["nonce": c.nonce])
            #expect((again as? [String: Any])?["port"] as? String == w.p, "a machine it let in was refused on reconnecting")
        }
        let joins = try w.state.db.chatEntries(chat: w.p, after: 0, limit: 20).filter { $0.text.contains("joined from another machine") }
        #expect(joins.count == 2, "each machine let in is announced once: \(joins.count)")
    }

    @Test("the second machine meets the same checks as the first: expiry and code")
    func secondUseChecked() async throws {
        let w = try world()
        let made = try await create(w, code: true)
        let c = try coupon(made)
        let code = try #require(made["code"] as? String)
        _ = try await remote(w, as: Self.ada, "invite.redeem", ["nonce": c.nonce, "code": code])
        #expect(reason(try await remote(w, as: Self.eve, "invite.redeem", ["nonce": c.nonce])) == "wrong_code",
                "the second machine got in without the code")
        try w.state.db.insertInvite(id: "soon", portKey: w.p, rights: [.see], nonceHash: AppState.inviteHash("soon-nonce"),
                                    codeHash: nil, createdBy: "u", expiresAt: Date().addingTimeInterval(-60))
        try w.state.db.markInviteRedeemed(id: "soon", by: Self.ada)
        #expect(reason(try await remote(w, as: Self.eve, "invite.redeem", ["nonce": "soon-nonce"])) == "expired",
                "an expired link let in a second machine")
        #expect((try await remote(w, as: Self.ada, "invite.redeem", ["nonce": "soon-nonce"]) as? [String: Any])?["port"] as? String == w.p,
                "the first machine was refused on reconnecting after expiry")
    }

    @Test("an unknown, expired or withdrawn invite is refused with its reason")
    func deadInvites() async throws {
        let w = try world()
        #expect(reason(try await remote(w, as: Self.ada, "invite.redeem", ["nonce": "made-up"])) == "unknown")

        try w.state.db.insertInvite(id: "old", portKey: w.p, rights: [.see], nonceHash: AppState.inviteHash("old-nonce"),
                                    codeHash: nil, createdBy: "u", expiresAt: Date().addingTimeInterval(-60))
        #expect(reason(try await remote(w, as: Self.ada, "invite.redeem", ["nonce": "old-nonce"])) == "expired")

        let made = try await create(w)
        _ = try await w.state.runBridgeMethod("invite.revoke", principal: person,
                                              args: BridgeArgs(["id": try #require(made["id"] as? String)]))
        #expect(reason(try await remote(w, as: Self.ada, "invite.redeem", ["nonce": try coupon(made).nonce])) == "revoked")
        #expect(try w.state.db.client(peerKey: Self.ada) == nil)
    }

    @Test("a required code is enforced, and the fifth wrong one kills the invite")
    func code() async throws {
        let w = try world()
        let made = try await create(w, code: true)
        let code = try #require(made["code"] as? String)
        #expect(code.count == 6 && code.allSatisfy(\.isNumber))
        let c = try coupon(made)
        #expect(c.code)
        #expect(reason(try await remote(w, as: Self.ada, "invite.redeem", ["nonce": c.nonce])) == "wrong_code",
                "the link alone was enough")
        #expect(reason(try await remote(w, as: Self.ada, "invite.redeem", ["nonce": c.nonce, "code": code])) == nil)

        let other = try await create(w, code: true)
        let oc = try coupon(other)
        for _ in 0..<(AppState.inviteCodeTries - 1) {
            #expect(reason(try await remote(w, as: Self.eve, "invite.redeem", ["nonce": oc.nonce, "code": "000000x"])) == "wrong_code")
        }
        #expect(reason(try await remote(w, as: Self.eve, "invite.redeem", ["nonce": oc.nonce, "code": "000000x"])) == "locked")
        let right = try #require(other["code"] as? String)
        #expect(reason(try await remote(w, as: Self.eve, "invite.redeem", ["nonce": oc.nonce, "code": right])) == "revoked",
                "a locked invite still redeemed with the right code")
    }

    @Test("removing a peer's rights on one port leaves its others; removing the peer ends all")
    func removal() async throws {
        let w = try world()
        _ = try await remote(w, as: Self.ada, "invite.redeem", ["nonce": try coupon(try await create(w)).nonce, "name": "Ada"])
        _ = try await remote(w, as: Self.ada, "invite.redeem", ["nonce": try coupon(try await create(w, port: w.q)).nonce])
        w.state.grantRemoteRights([], to: Self.ada, onPort: w.p)
        let rows = try #require(try await remote(w, as: Self.ada, "ports.list", [:]) as? [[String: Any]])
        #expect(Set(rows.compactMap { $0["id"] as? String }) == [w.q])

        let id = try #require(try w.state.db.client(peerKey: Self.ada)?.id)
        w.state.revokeClient(id: id)
        #expect(reason(try await remote(w, as: Self.ada, "ports.list", [:])) == "auth_revoked")
    }

    @Test("Access lists each shared port with its guest and rights, and open invites; stop sharing removes one")
    func manager() async throws {
        let w = try world()
        let open = try await create(w, port: w.q)
        _ = try await remote(w, as: Self.ada, "invite.redeem", ["nonce": try coupon(try await create(w)).nonce, "name": "Ada"])
        let shared = w.state.sharedPorts()
        #expect(shared.map { "\($0.name) \($0.title) \($0.rights.map(\.rawValue))" } == ["Ada shared chart [\"see\", \"use\", \"wake_agents\"]"])
        #expect(w.state.openInvites().map(\.id) == [open["id"] as? String], "a used invite is not open")
        w.state.stopSharing(peer: Self.ada, port: w.p)
        #expect(w.state.sharedPorts().isEmpty)
        #expect(reason(try await remote(w, as: Self.ada, "port.getHtml", ["id": w.p])) == "not_granted")
    }
}
