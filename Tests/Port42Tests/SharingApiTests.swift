import Testing
import Foundation
@testable import Port42Lib

// API parity, Phase E (docs/plan-api-parity.md): what the share panel does after the invite, as calls.
// invite.shared, invite.setRights, invite.stop, remote.leave, remote.setWake.

@Suite("sharing after the invite")
@MainActor
struct SharingApiTests {
    let person = Principal.human(id: "alice", displayName: "Alice", spaceId: nil)
    static let guest = "guestpeerkey"
    static let host = "hostpeerkey"

    func call(_ w: ParityWorld, _ method: String, _ p: Principal, _ args: [String: Any]) async throws -> BridgeValue {
        try await w.state.runBridgeMethod(method, principal: p, args: BridgeArgs(args))
    }
    func code(_ body: () async throws -> Void) async -> String? {
        do { try await body(); return nil } catch let e as BridgeError { return e.code } catch { return "other" }
    }
    func waitForCard(_ w: ParityWorld) async {
        for _ in 0..<400 where w.state.permissions.current == nil { await Task.yield() }
    }

    /// A port the world's companion made and invited someone to; the guest holds see and use.
    func shared(_ w: ParityWorld) throws -> String {
        let r = w.state.createPort(type: "web", title: "desk", html: "<title>desk</title>", command: nil, cwd: nil,
                                   systemPrompt: nil, spaceId: w.space.id, createdBy: w.principal.id, createdByName: "c")
        let key = try #require(r["id"] as? String)
        try w.state.db.insertInvite(id: "inv", portKey: key, rights: [.see, .use], nonceHash: "n", codeHash: nil,
                                    createdBy: w.principal.id, expiresAt: Date().addingTimeInterval(3600))
        w.state.grantRemoteRights([.see, .use], to: Self.guest, onPort: key)
        return key
    }
    func held(_ w: ParityWorld, _ key: String) -> Set<RemoteRight> { w.state.remoteRights(of: Self.guest, onPort: key) }
    func mallory(_ w: ParityWorld) -> Principal { Principal.companion(id: "mallory", displayName: "mallory", spaceId: w.space.id) }

    @Test("the person lists who a port is shared with, changes their rights, and stops sharing")
    func personManages() async throws {
        let w = try makeParityWorld()
        let key = try shared(w)
        guard case .array(let rows) = try await call(w, "invite.shared", person, ["port": key]) else { Issue.record("no list"); return }
        #expect(rows.count == 1)
        _ = try await call(w, "invite.setRights", person, ["port": key, "peer": Self.guest, "rights": ["use", "edit"]])
        #expect(held(w, key) == [.see, .use, .edit], "rights: \(held(w, key))")
        _ = try await call(w, "invite.setRights", person, ["port": key, "peer": Self.guest, "rights": []])
        #expect(held(w, key) == [.see], "taking rights away left: \(held(w, key))")
        _ = try await call(w, "invite.stop", person, ["port": key, "peer": Self.guest])
        #expect(held(w, key).isEmpty, "they still have access")
    }

    @Test("a companion that made the invite widens rights only through a card, and may narrow or stop freely")
    func makerAsksToWiden() async throws {
        let w = try makeParityWorld()
        let key = try shared(w)
        let ask = Task { @MainActor in try await self.call(w, "invite.setRights", w.principal, ["port": key, "peer": Self.guest, "rights": ["use", "edit"]]) }
        await waitForCard(w)
        #expect(w.state.permissions.current?.permission == .share, "a companion widened a share without asking")
        w.state.permissions.resolveCurrent(granted: false)
        await #expect(throws: BridgeError.self) { _ = try await ask.value }
        #expect(held(w, key) == [.see, .use], "a refused change was applied")

        let again = Task { @MainActor in try await self.call(w, "invite.setRights", w.principal, ["port": key, "peer": Self.guest, "rights": ["use", "edit"]] ) }
        await waitForCard(w)
        #expect(w.state.permissions.current != nil, "edit was remembered; it asks every time")
        w.state.permissions.resolveCurrent(granted: true)
        _ = try await again.value
        #expect(held(w, key) == [.see, .use, .edit])

        _ = try await call(w, "invite.setRights", w.principal, ["port": key, "peer": Self.guest, "rights": ["use"]])
        #expect(w.state.permissions.current == nil, "taking a right away asked")
        #expect(held(w, key) == [.see, .use])
        _ = try await call(w, "invite.stop", w.principal, ["port": key, "peer": Self.guest])
        #expect(w.state.permissions.current == nil, "stopping asked")
        #expect(held(w, key).isEmpty)
    }

    @Test("another caller neither sees nor changes a port's sharing, and the refusals are plain")
    func scopeAndRefusals() async throws {
        let w = try makeParityWorld()
        let key = try shared(w)
        for (m, a) in [("invite.shared", ["port": key]), ("invite.stop", ["port": key, "peer": Self.guest]),
                       ("invite.setRights", ["port": key, "peer": Self.guest, "rights": ["use", "edit"]])] as [(String, [String: Any])] {
            #expect(await code { _ = try await call(w, m, mallory(w), a) } == BridgeErrorCode.notFound.rawValue, "\(m) was open to another caller")
        }
        #expect(held(w, key) == [.see, .use])
        #expect(w.state.permissions.current == nil)
        #expect(await code { _ = try await call(w, "invite.setRights", person, ["port": key, "peer": "nobody", "rights": ["use"]]) } == BridgeErrorCode.notFound.rawValue)
        #expect(await code { _ = try await call(w, "invite.setRights", person, ["port": key, "peer": Self.guest, "rights": ["move"]]) } == BridgeErrorCode.badArg.rawValue)
        #expect(await code { _ = try await call(w, "invite.setRights", person, ["port": key, "peer": Self.guest, "rights": ["use"]]) } == BridgeErrorCode.badArg.rawValue, "a no-op was accepted")
    }

    /// A tile of someone else's port: a local stand-in tile linked to a remote row.
    func mirror(_ w: ParityWorld) throws -> String {
        let r = w.state.createPort(type: "web", title: "theirs", html: "<title>theirs</title>", command: nil, cwd: nil,
                                   systemPrompt: nil, spaceId: w.space.id, createdBy: nil, createdByName: nil)
        let tile = try #require(r["id"] as? String)
        try w.state.db.upsertRemotePort(.init(peerKey: Self.host, portKey: "P", title: "theirs", rights: [.see, .use],
                                              relays: ["r"], hostName: "Gordon"))
        try w.state.db.setRemotePortTile(peerKey: Self.host, portKey: "P", localPort: tile)
        return tile
    }
    func remoteRow(_ w: ParityWorld) throws -> DatabaseService.RemotePortRow? {
        try w.state.db.remotePorts().first { $0.portKey == "P" }
    }

    @Test("remote.setWake: the person flips it; a companion turning it on asks every time, turning it off does not")
    func setWake() async throws {
        let w = try makeParityWorld()
        let tile = try mirror(w)
        _ = try await call(w, "remote.setWake", person, ["tile": tile, "on": true])
        #expect(try remoteRow(w)?.wakes == true)
        _ = try await call(w, "remote.setWake", w.principal, ["tile": tile, "on": false])
        #expect(w.state.permissions.current == nil, "turning wake off asked")
        #expect(try remoteRow(w)?.wakes == false)

        let ask = Task { @MainActor in try await self.call(w, "remote.setWake", w.principal, ["tile": tile, "on": true]) }
        await waitForCard(w)
        #expect(w.state.permissions.current?.permission == .changeSharing, "a companion let another machine wake companions without asking")
        w.state.permissions.resolveCurrent(granted: false)
        await #expect(throws: BridgeError.self) { _ = try await ask.value }
        #expect(try remoteRow(w)?.wakes == false, "a refused change was applied")
    }

    @Test("remote.leave: a companion asks first, the person does not, and another space's tile is not found")
    func leave() async throws {
        let w = try makeParityWorld()
        let tile = try mirror(w)
        let ask = Task { @MainActor in try await self.call(w, "remote.leave", w.principal, ["tile": tile]) }
        await waitForCard(w)
        #expect(w.state.permissions.current?.permission == .changeSharing, "a companion left a shared port without asking")
        w.state.permissions.resolveCurrent(granted: false)
        await #expect(throws: BridgeError.self) { _ = try await ask.value }
        #expect(try remoteRow(w) != nil, "a refused leave went ahead")
        #expect(await code { _ = try await call(w, "remote.leave", w.principal, ["tile": "not-a-tile"]) } == BridgeErrorCode.notFound.rawValue)
        _ = try await call(w, "remote.leave", person, ["tile": tile])
        #expect(try remoteRow(w) == nil, "the person's leave did nothing")
    }
}
