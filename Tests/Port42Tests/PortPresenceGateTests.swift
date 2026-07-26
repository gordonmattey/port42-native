import Testing
import Foundation
@testable import Port42Lib

/// L2.b — the right-of-way gate at the dispatch seam.
///
/// `PortLeaseTests` proves the lease arithmetic; this proves it is actually WIRED: a real
/// `runBridgeMethod` write takes the pen, a second principal's write is rejected, and reads are
/// never gated. Uses `port.rename`, the write verb with no live-surface requirement, so the test
/// stays headless.
@Suite("PortLease — the dispatch gate (L2.b)")
@MainActor
struct PortLeaseGateTests {

    func makeWorld() throws -> (AppState, String) {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let id = "lease-target-1"
        _ = state.portWindows.registerInlinePort(
            id: id, html: "<html><body>hi</body></html>",
            spaceId: nil, createdBy: nil, title: "t", anchorMessageId: nil)
        return (state, id)
    }

    func principal(_ id: String, _ name: String) -> Principal {
        Principal(id: id, displayName: name, spaceId: nil, kind: .companion)
    }

    @Test("the first writer takes the pen; a second principal is refused BY NAME")
    func secondWriterIsDenied() async throws {
        let (state, id) = try makeWorld()
        let alice = principal("alice", "alice"), bob = principal("bob", "bob")

        _ = try await state.runBridgeMethod("port.rename", principal: alice,
                                            args: BridgeArgs(["id": id, "title": "alice's"]))

        await #expect(throws: BridgeError.self) {
            _ = try await state.runBridgeMethod("port.rename", principal: bob,
                                                args: BridgeArgs(["id": id, "title": "bob's"]))
        }
        // The rejection must say WHO, or the user has no way to act on it.
        do {
            _ = try await state.runBridgeMethod("port.rename", principal: bob,
                                                args: BridgeArgs(["id": id, "title": "bob's"]))
            Issue.record("expected the write to be refused")
        } catch let e as BridgeError {
            #expect(e.code == "port_busy")
            #expect(e.message.contains("alice"))
        }
        // And the port still carries the holder's write, not the loser's.
        #expect(state.portWindows.panels.first(where: { $0.id == id })?.userTitle == "alice's")
    }

    @Test("the holder keeps writing — a lease is not a one-shot")
    func holderKeepsWriting() async throws {
        let (state, id) = try makeWorld()
        let alice = principal("alice", "alice")
        for title in ["one", "two", "three"] {
            _ = try await state.runBridgeMethod("port.rename", principal: alice,
                                                args: BridgeArgs(["id": id, "title": title]))
        }
        #expect(state.portWindows.panels.first(where: { $0.id == id })?.userTitle == "three")
    }

    @Test("reads are never gated — a non-holder can still look")
    func readsAreNotGated() async throws {
        let (state, id) = try makeWorld()
        let alice = principal("alice", "alice"), bob = principal("bob", "bob")
        _ = try await state.runBridgeMethod("port.rename", principal: alice,
                                            args: BridgeArgs(["id": id, "title": "alice's"]))
        // Bob is locked out of writing but must still be able to observe: reading is not driving.
        // `ports.list` is the read that works headless (getHtml reads the DB, and an inline port is
        // deliberately never persisted). The assertion is that it does not throw for a non-holder.
        _ = try await state.runBridgeMethod("ports.list", principal: bob, args: BridgeArgs([:]))
    }

    @Test("an unresolvable target is never a LEASE error — a lock on nothing is not a lock")
    func unknownTargetFallsThrough() async throws {
        let (state, _) = try makeWorld()
        let alice = principal("alice", "alice"), bob = principal("bob", "bob")
        // Whatever an unknown id does (rename happens to no-op rather than throw), the gate must
        // not claim it: it must not mint a lease on a port that does not exist, and a second
        // principal must not then be locked out by a phantom holder.
        _ = try? await state.runBridgeMethod("port.rename", principal: alice,
                                             args: BridgeArgs(["id": "no-such-port", "title": "x"]))
        do {
            _ = try await state.runBridgeMethod("port.rename", principal: bob,
                                                args: BridgeArgs(["id": "no-such-port", "title": "y"]))
        } catch let e as BridgeError {
            #expect(e.code != "port_busy", "an unresolvable target must not be leaseable")
        }
    }

    // MARK: - L2.c: the holder is broadcast on the port's own topic

    @Test("a holder CHANGE publishes once; the holder's own repeat writes publish nothing")
    func holderBroadcast() async throws {
        let (state, id) = try makeWorld()
        // A short TTL so expiry (and therefore the next change) is reachable in a test.
        state.portLeases = LeaseRegistry(ttl: 0.15)
        let alice = principal("alice", "alice"), bob = principal("bob", "bob")

        var envelopes: [String] = []
        let sub = state.notifyBus.subscribe(topic: "port:\(id)") { envelopes.append($0) }
        defer { state.notifyBus.unsubscribe(id: sub, topic: "port:\(id)") }

        _ = try await state.runBridgeMethod("port.rename", principal: alice,
                                            args: BridgeArgs(["id": id, "title": "a"]))
        let afterFirst = envelopes.count
        #expect(afterFirst == 1, "taking a free port is a holder change")
        #expect(envelopes[0].contains("\"kind\":\"holder\"") || envelopes[0].contains("holder"))
        #expect(envelopes[0].contains("alice"))

        // Same holder writing again is NOT news.
        _ = try await state.runBridgeMethod("port.rename", principal: alice,
                                            args: BridgeArgs(["id": id, "title": "b"]))
        #expect(envelopes.count == afterFirst, "a refresh must not publish")

        // Let it lapse; the next driver IS news.
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = try await state.runBridgeMethod("port.rename", principal: bob,
                                            args: BridgeArgs(["id": id, "title": "c"]))
        #expect(envelopes.count == afterFirst + 1, "a new holder after expiry is a change")
        #expect(envelopes.last?.contains("bob") == true)
    }

    @Test("closing a port drops its lease — a reopened id inherits no holder")
    func closeForgetsTheLease() async throws {
        let (state, id) = try makeWorld()
        let alice = principal("alice", "alice"), bob = principal("bob", "bob")
        _ = try await state.runBridgeMethod("port.rename", principal: alice,
                                            args: BridgeArgs(["id": id, "title": "a"]))
        state.portWindows.close(id)

        _ = state.portWindows.registerInlinePort(
            id: id, html: "<html><body>again</body></html>",
            spaceId: nil, createdBy: nil, title: "t", anchorMessageId: nil)
        // Bob must be able to drive the new port: the old holder died with the old one.
        _ = try await state.runBridgeMethod("port.rename", principal: bob,
                                            args: BridgeArgs(["id": id, "title": "b"]))
        #expect(state.portWindows.panels.first(where: { $0.id == id })?.userTitle == "b")
    }

    // MARK: - L2.d: the human can hold the pen

    func makeWorldWithUser() throws -> (AppState, String) {
        let (state, id) = try makeWorld()
        let user = AppUser.createForTesting(displayName: "gordon")
        try state.db.saveUser(user)
        state.currentUser = user
        return (state, id)
    }

    @Test("the human is a principal — until the lease, the person had none")
    func humanPrincipalExists() throws {
        let (state, _) = try makeWorldWithUser()
        let p = try #require(state.humanPrincipal)
        #expect(p.kind == .human)
        #expect(p.id == state.currentUser?.id)
        #expect(p.displayName == "gordon")
    }

    @Test("focusing a free port gives the human the pen, and a companion is then refused")
    func focusClaimsForHuman() async throws {
        let (state, id) = try makeWorldWithUser()
        state.claimFocusForHuman(portId: id)

        do {
            _ = try await state.runBridgeMethod("port.rename", principal: principal("echo", "echo"),
                                                args: BridgeArgs(["id": id, "title": "echo's"]))
            Issue.record("a companion must not write to a port the human is driving")
        } catch let e as BridgeError {
            #expect(e.code == "port_busy")
            #expect(e.message.contains("gordon"))
        }
    }

    @Test("focus NEVER steals — a companion mid-write keeps the pen")
    func focusDoesNotSteal() async throws {
        let (state, id) = try makeWorldWithUser()
        // Echo is driving first.
        _ = try await state.runBridgeMethod("port.rename", principal: principal("echo", "echo"),
                                            args: BridgeArgs(["id": id, "title": "echo's"]))
        // The human focuses it — allowed to LOOK, not to seize.
        state.claimFocusForHuman(portId: id)
        // Echo can still write: the lease denies, it does not evict.
        _ = try await state.runBridgeMethod("port.rename", principal: principal("echo", "echo"),
                                            args: BridgeArgs(["id": id, "title": "still echo's"]))
        #expect(state.portWindows.panels.first(where: { $0.id == id })?.userTitle == "still echo's")
    }

    @Test("typing in a port claims it — native input is invisible to the bridge without this")
    func interactionClaims() async throws {
        let (state, id) = try makeWorldWithUser()
        // The signal the surfaces fire on keydown/pointerdown. Keyed on udid, as the surfaces key it.
        let udid = try #require(state.portWindows.panels.first(where: { $0.id == id })?.udid)
        state.humanInteracted(with: udid)

        do {
            _ = try await state.runBridgeMethod("port.rename", principal: principal("echo", "echo"),
                                                args: BridgeArgs(["id": id, "title": "echo's"]))
            Issue.record("a companion must not write into a port the human is typing in")
        } catch let e as BridgeError {
            #expect(e.code == "port_busy")
            #expect(e.message.contains("gordon"))
        }
    }

    @Test("interaction before setup is a no-op — no user, no claim")
    func interactionNeedsAHuman() throws {
        let (state, id) = try makeWorld()          // no currentUser
        state.humanInteracted(with: id)
        #expect(state.portLeases.holder(of: id, now: Date()) == nil)
    }

    // MARK: - L2.e: the header learns the holder BY SUBSCRIBING

    @Test("the shell picks up the holder off the port's topic, and stays quiet about yourself")
    func shellLearnsHolderFromTheBus() async throws {
        let (state, id) = try makeWorldWithUser()
        let shell = ShellState(appState: state)
        let udid = try #require(state.portWindows.panels.first(where: { $0.id == id })?.udid)

        // Subscribe the way the desktop does. (contextItems is empty headless, so subscribe by hand
        // to the same topic the sync would use — the parsing is what is under test.)
        let sub = state.notifyBus.subscribe(topic: "port:\(udid)") { _ in }
        defer { state.notifyBus.unsubscribe(id: sub, topic: "port:\(udid)") }
        shell.syncHolderSubscriptions()

        // A companion takes the pen → the shell should hear it and show it.
        _ = try await state.runBridgeMethod("port.rename", principal: principal("echo", "echo"),
                                            args: BridgeArgs(["id": id, "title": "echo's"]))
        // Only ports on the desktop are subscribed, so drive the parse directly for the headless case.
        shell.applyHolderEnvelopeForTesting(
            #"{"topic":"port:\#(udid)","kind":"holder","payload":{"holder":"echo","holderName":"echo","until":\#(Date().addingTimeInterval(30).timeIntervalSince1970)}}"#,
            port: udid)
        #expect(shell.otherHolder(of: udid)?.name == "echo")

        // The HUMAN holding it is not news — the chrome stays silent about you.
        shell.applyHolderEnvelopeForTesting(
            #"{"topic":"port:\#(udid)","kind":"holder","payload":{"holder":"\#(state.currentUser!.id)","holderName":"gordon","until":\#(Date().addingTimeInterval(30).timeIntervalSince1970)}}"#,
            port: udid)
        #expect(shell.otherHolder(of: udid) == nil)
    }

    @Test("an expired badge stops showing — the chip does not outlive the lease")
    func expiredBadgeIsSilent() throws {
        let (state, id) = try makeWorldWithUser()
        let shell = ShellState(appState: state)
        let udid = try #require(state.portWindows.panels.first(where: { $0.id == id })?.udid)
        shell.applyHolderEnvelopeForTesting(
            #"{"topic":"port:\#(udid)","kind":"holder","payload":{"holder":"echo","holderName":"echo","until":\#(Date().addingTimeInterval(-1).timeIntervalSince1970)}}"#,
            port: udid)
        #expect(shell.otherHolder(of: udid) == nil)
    }

    // MARK: - The declaration cannot rot

    @Test("every write verb declares writesTarget, and no read verb does")
    func declarationsAreComplete() throws {
        let db = try DatabaseService(inMemory: true)
        let registry = buildBridgeRegistry(AppState(db: db))

        // ADD A NEW WRITE VERB? Add it here. This list failing is the reminder.
        let writes = ["port.push", "port.exec", "port.patch", "port.update",
                      "port.rename", "port.move", "port.restore", "port.manage"]
        for name in writes {
            let m = try #require(registry[name], "missing method \(name)")
            #expect(m.writesTarget == "id", "\(name) must declare writesTarget or it escapes the lease")
        }

        // Reading is not driving.
        for name in ["port.getHtml", "port.history", "port.info", "port.position", "ports.list"] {
            #expect(registry[name]?.writesTarget == nil, "\(name) is a read and must not be gated")
        }
    }
}
