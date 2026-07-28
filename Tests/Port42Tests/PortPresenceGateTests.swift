import Testing
import Foundation
@testable import Port42Lib

/// L2.b — presence recorded at the dispatch seam (demoted from a gate by R1).
///
/// `PortLeaseTests` proves the arithmetic; this proves it is actually WIRED: a real
/// `runBridgeMethod` write names its principal as the driver, a second principal's write SUCCEEDS
/// and moves it, and reads record nothing. Uses `port.rename`, the write verb with no live-surface
/// requirement, so the test stays headless.
///
/// These assertions are the INVERSE of what they were up to 2026-07-26. They used to prove the
/// second writer was refused; the refusal was the part that turned out to be wrong, so the tests
/// now pin the opposite and would fail if a gate came back by accident.
@Suite("PortLease — presence at the dispatch seam (L2.b)")
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
        Principal.companion(id: id, displayName: name, spaceId: nil)
    }

    @Test("a second principal's write SUCCEEDS with a token, and presence follows it (R1 + R5)")
    func secondWriterSucceeds() async throws {
        let (state, id) = try makeWorld()
        let alice = principal("alice", "alice"), bob = principal("bob", "bob")
        let udid = try #require(state.portWindows.panels.first(where: { $0.id == id })?.udid)

        _ = try await state.runBridgeMethod("port.rename", principal: alice,
                                            args: BridgeArgs(["id": id, "title": "alice's", PortActivity.expectParam: state.portInput.token(for: state.portKey(for: id) ?? id)]))
        #expect(state.portInput.driver(of: udid, now: Date())?.name == "alice")

        // No throw. This is the whole of R1: presence observes, it does not arbitrate.
        _ = try await state.runBridgeMethod("port.rename", principal: bob,
                                            args: BridgeArgs(["id": id, "title": "bob's", PortActivity.expectParam: state.portInput.token(for: state.portKey(for: id) ?? id)]))
        #expect(state.portWindows.panels.first(where: { $0.id == id })?.userTitle == "bob's")
        #expect(state.portInput.driver(of: udid, now: Date())?.name == "bob")
    }

    @Test("the driver keeps writing — presence is not a one-shot")
    func holderKeepsWriting() async throws {
        let (state, id) = try makeWorld()
        let alice = principal("alice", "alice")
        for title in ["one", "two", "three"] {
            _ = try await state.runBridgeMethod("port.rename", principal: alice,
                                                args: BridgeArgs(["id": id, "title": title, PortActivity.expectParam: state.portInput.token(for: state.portKey(for: id) ?? id)]))
        }
        #expect(state.portWindows.panels.first(where: { $0.id == id })?.userTitle == "three")
    }

    @Test("reading is not driving — a read leaves presence exactly where it was")
    func readsDoNotDrive() async throws {
        let (state, id) = try makeWorld()
        let alice = principal("alice", "alice"), bob = principal("bob", "bob")
        let udid = try #require(state.portWindows.panels.first(where: { $0.id == id })?.udid)
        _ = try await state.runBridgeMethod("port.rename", principal: alice,
                                            args: BridgeArgs(["id": id, "title": "alice's", PortActivity.expectParam: state.portInput.token(for: state.portKey(for: id) ?? id)]))
        // `ports.list` is the read that works headless (getHtml reads the DB, and an inline port is
        // deliberately never persisted). Bob looking must not make Bob the driver.
        _ = try await state.runBridgeMethod("ports.list", principal: bob, args: BridgeArgs([:]))
        #expect(state.portInput.driver(of: udid, now: Date())?.name == "alice")
    }

    @Test("an unresolvable target records NO presence — a driver of nothing is not a driver")
    func unknownTargetRecordsNothing() async throws {
        let (state, _) = try makeWorld()
        let alice = principal("alice", "alice")
        // Whatever an unknown id does (rename happens to no-op rather than throw), the seam must
        // not record against it. A phantom entry would later be shown against whatever real port
        // claimed that id.
        _ = try? await state.runBridgeMethod("port.rename", principal: alice,
                                             args: BridgeArgs(["id": "no-such-port", "title": "x"]))
        #expect(state.portInput.driver(of: "no-such-port", now: Date()) == nil)
    }

    // MARK: - L2.c: the holder is broadcast on the port's own topic

    @Test("a driver CHANGE publishes once; the driver's own repeat writes publish nothing")
    func holderBroadcast() async throws {
        let (state, id) = try makeWorld()
        let alice = principal("alice", "alice"), bob = principal("bob", "bob")

        var envelopes: [String] = []
        let sub = state.notifyBus.subscribe(topic: "port:\(id)") { envelopes.append($0) }
        defer { state.notifyBus.unsubscribe(id: sub, topic: "port:\(id)") }

        _ = try await state.runBridgeMethod("port.rename", principal: alice,
                                            args: BridgeArgs(["id": id, "title": "a", PortActivity.expectParam: state.portInput.token(for: state.portKey(for: id) ?? id)]))
        let afterFirst = envelopes.count
        #expect(afterFirst == 1, "the first writer on a port nobody was driving is a change")
        #expect(envelopes[0].contains("\"kind\":\"driver\"") || envelopes[0].contains("holder"))
        #expect(envelopes[0].contains("alice"))

        // Same driver writing again is NOT news.
        _ = try await state.runBridgeMethod("port.rename", principal: alice,
                                            args: BridgeArgs(["id": id, "title": "b", PortActivity.expectParam: state.portInput.token(for: state.portKey(for: id) ?? id)]))
        #expect(envelopes.count == afterFirst, "a refresh must not publish")

        // A DIFFERENT driver is news immediately — no waiting for the record to go stale, which is
        // what the old gate forced (the take-over could not happen until the TTL lapsed).
        _ = try await state.runBridgeMethod("port.rename", principal: bob,
                                            args: BridgeArgs(["id": id, "title": "c", PortActivity.expectParam: state.portInput.token(for: state.portKey(for: id) ?? id)]))
        #expect(envelopes.count == afterFirst + 1, "a new driver is a change")
        #expect(envelopes.last?.contains("bob") == true)
    }

    @Test("closing a port drops its presence — a reopened id inherits no driver")
    func closeForgetsTheLease() async throws {
        let (state, id) = try makeWorld()
        let alice = principal("alice", "alice"), bob = principal("bob", "bob")
        _ = try await state.runBridgeMethod("port.rename", principal: alice,
                                            args: BridgeArgs(["id": id, "title": "a", PortActivity.expectParam: state.portInput.token(for: state.portKey(for: id) ?? id)]))
        state.portWindows.close(id)

        _ = state.portWindows.registerInlinePort(
            id: id, html: "<html><body>again</body></html>",
            spaceId: nil, createdBy: nil, title: "t", anchorMessageId: nil)
        let udid = try #require(state.portWindows.panels.first(where: { $0.id == id })?.udid)
        // Nobody is driving the new port. Under R1 this no longer shows up as a blocked write, so
        // the table is the assertion: a reused id must not inherit the dead port's driver and show
        // a stale name in the new port's header.
        #expect(state.portInput.driver(of: udid, now: Date()) == nil)
        #expect(state.portInput.driver(of: id, now: Date()) == nil)

        _ = try await state.runBridgeMethod("port.rename", principal: bob,
                                            args: BridgeArgs(["id": id, "title": "b", PortActivity.expectParam: state.portInput.token(for: state.portKey(for: id) ?? id)]))
        #expect(state.portWindows.panels.first(where: { $0.id == id })?.userTitle == "b")
    }

    // MARK: - L2.d: the human is a driver too

    func makeWorldWithUser() throws -> (AppState, String) {
        let (state, id) = try makeWorld()
        let user = AppUser.createForTesting(displayName: "gordon")
        try state.db.saveUser(user)
        state.currentUser = user
        return (state, id)
    }

    @Test("the human is a principal — until right-of-way, the person had none")
    func humanPrincipalExists() throws {
        let (state, _) = try makeWorldWithUser()
        let p = try #require(state.humanPrincipal)
        #expect(p.kind == .human)
        #expect(p.id == state.currentUser?.id)
        #expect(p.displayName == "gordon")
    }

    @Test("focusing a port names the human as its driver")
    func focusClaimsForHuman() async throws {
        let (state, id) = try makeWorldWithUser()
        let udid = try #require(state.portWindows.panels.first(where: { $0.id == id })?.udid)
        state.recordHumanFocus(portId: id)
        #expect(state.portInput.driver(of: udid, now: Date())?.name == "gordon")

        // A companion writing to a port you are focused on is NOT BLOCKED (R1): it becomes the
        // driver, because it acted most recently. R5 amended the SLOGAN, not the substance — the
        // write must now say what it composed against, and once it does it always lands.
        //
        // The difference from the lease R1 removed: that refused you regardless, you could not argue
        // with it, and a vanished holder left a port stuck, which is why it could never cross the
        // wire. This asks you to declare state and hands you the answer when you have not.
        _ = try await state.runBridgeMethod("port.rename", principal: principal("echo", "echo"),
                                            args: BridgeArgs(["id": id, "title": "echo's", PortActivity.expectParam: state.portInput.token(for: state.portKey(for: id) ?? id)]))
        #expect(state.portWindows.panels.first(where: { $0.id == id })?.userTitle == "echo's")
        #expect(state.portInput.driver(of: udid, now: Date())?.name == "echo")
    }

    @Test("focus takes presence back from a companion; a token gets anyone through (R1 + R5)")
    func focusMovesPresenceBothWays() async throws {
        let (state, id) = try makeWorldWithUser()
        let udid = try #require(state.portWindows.panels.first(where: { $0.id == id })?.udid)
        // Echo is driving first.
        _ = try await state.runBridgeMethod("port.rename", principal: principal("echo", "echo"),
                                            args: BridgeArgs(["id": id, "title": "echo's", PortActivity.expectParam: state.portInput.token(for: state.portKey(for: id) ?? id)]))
        // The human focuses it. Under the old gate this was deliberately a no-op so focus could not
        // seize the pen; with nothing to seize, the honest answer is that the human is now driving.
        state.recordHumanFocus(portId: id)
        #expect(state.portInput.driver(of: udid, now: Date())?.name == "gordon")
        // And echo is still free to write, which is the point of the demotion.
        _ = try await state.runBridgeMethod("port.rename", principal: principal("echo", "echo"),
                                            args: BridgeArgs(["id": id, "title": "still echo's", PortActivity.expectParam: state.portInput.token(for: state.portKey(for: id) ?? id)]))
        #expect(state.portWindows.panels.first(where: { $0.id == id })?.userTitle == "still echo's")
        #expect(state.portInput.driver(of: udid, now: Date())?.name == "echo")
    }

    @Test("typing in a port names you the driver — native input reaches no dispatcher without this")
    func interactionClaims() async throws {
        let (state, id) = try makeWorldWithUser()
        // The signal the surfaces fire on keydown/pointerdown. Keyed on udid, as the surfaces key it.
        let udid = try #require(state.portWindows.panels.first(where: { $0.id == id })?.udid)
        state.humanInteracted(with: udid)
        #expect(state.portInput.driver(of: udid, now: Date())?.name == "gordon")
    }

    @Test("a TAKEOVER is never throttled — your input wins the label back instantly")
    func takeoverIsNeverThrottled() async throws {
        let (state, id) = try makeWorldWithUser()
        let udid = try #require(state.portWindows.panels.first(where: { $0.id == id })?.udid)

        state.humanInteracted(with: udid)
        #expect(state.portInput.driver(of: udid, now: Date())?.name == "gordon")

        // A companion writes: it becomes the driver.
        _ = try await state.runBridgeMethod("port.rename", principal: principal("echo", "echo"),
                                            args: BridgeArgs(["id": id, "title": "echo's", PortActivity.expectParam: state.portInput.token(for: state.portKey(for: id) ?? id)]))
        #expect(state.portInput.driver(of: udid, now: Date())?.name == "echo")

        // You touch it again IMMEDIATELY — far inside the ~5s throttle window opened by your first
        // interaction. GM found this live: with a companion writing every 2s against a 5s throttle,
        // the human could never win the chip back, because the throttle was dropping the very event
        // that should have moved it. A takeover is a CHANGE, not a refresh.
        state.humanInteracted(with: udid)
        #expect(state.portInput.driver(of: udid, now: Date())?.name == "gordon")
    }

    @Test("a REFRESH is still throttled — holding it does not spam the topic per keystroke")
    func refreshIsStillThrottled() async throws {
        let (state, id) = try makeWorldWithUser()
        let udid = try #require(state.portWindows.panels.first(where: { $0.id == id })?.udid)

        var envelopes: [String] = []
        let sub = state.notifyBus.subscribe(topic: "port:\(udid)") { envelopes.append($0) }
        defer { state.notifyBus.unsubscribe(id: sub, topic: "port:\(udid)") }

        // A burst of typing while nobody else is driving. The first is a change; the rest are
        // refreshes of presence you already have, which is exactly what the throttle is for.
        for _ in 1...10 { state.humanInteracted(with: udid) }
        #expect(envelopes.count == 1, "a burst of keystrokes must publish once, not ten times")

        // A companion takes it, then you take it straight back: two more CHANGES, neither throttled.
        _ = try await state.runBridgeMethod("port.rename", principal: principal("echo", "echo"),
                                            args: BridgeArgs(["id": id, "title": "echo's", PortActivity.expectParam: state.portInput.token(for: state.portKey(for: id) ?? id)]))
        state.humanInteracted(with: udid)
        #expect(envelopes.count == 3)
        #expect(envelopes.last?.contains("gordon") == true)
    }

    @Test("interaction before setup is a no-op — no user, no claim")
    func interactionNeedsAHuman() throws {
        let (state, id) = try makeWorld()          // no currentUser
        state.humanInteracted(with: id)
        #expect(state.portInput.driver(of: id, now: Date()) == nil)
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
        shell.syncDriverSubscriptions()

        // A companion takes the pen → the shell should hear it and show it.
        _ = try await state.runBridgeMethod("port.rename", principal: principal("echo", "echo"),
                                            args: BridgeArgs(["id": id, "title": "echo's", PortActivity.expectParam: state.portInput.token(for: state.portKey(for: id) ?? id)]))
        // Only ports on the desktop are subscribed, so drive the parse directly for the headless case.
        shell.applyDriverEnvelopeForTesting(
            #"{"topic":"port:\#(udid)","kind":"driver","payload":{"driver":"echo","driverName":"echo","until":\#(Date().addingTimeInterval(30).timeIntervalSince1970)}}"#,
            port: udid)
        #expect(shell.otherDriver(of: udid)?.name == "echo")

        // The HUMAN holding it is not news — the chrome stays silent about you.
        shell.applyDriverEnvelopeForTesting(
            #"{"topic":"port:\#(udid)","kind":"driver","payload":{"driver":"\#(state.currentUser!.id)","driverName":"gordon","until":\#(Date().addingTimeInterval(30).timeIntervalSince1970)}}"#,
            port: udid)
        #expect(shell.otherDriver(of: udid) == nil)
    }

    @Test("an expired badge stops showing — the chip does not outlive the lease")
    func expiredBadgeIsSilent() throws {
        let (state, id) = try makeWorldWithUser()
        let shell = ShellState(appState: state)
        let udid = try #require(state.portWindows.panels.first(where: { $0.id == id })?.udid)
        shell.applyDriverEnvelopeForTesting(
            #"{"topic":"port:\#(udid)","kind":"driver","payload":{"driver":"echo","driverName":"echo","until":\#(Date().addingTimeInterval(-1).timeIntervalSince1970)}}"#,
            port: udid)
        #expect(shell.otherDriver(of: udid) == nil)
    }

    // MARK: - R2: the activity token, wired at the same seam

    @Test("every bridge write bumps the port's token")
    func bridgeWritesBump() async throws {
        let (state, id) = try makeWorld()
        let udid = try #require(state.portWindows.panels.first(where: { $0.id == id })?.udid)
        #expect(state.portInput.seq(for: udid) == 0)

        for title in ["a", "b"] {
            _ = try await state.runBridgeMethod("port.rename", principal: principal("alice", "alice"),
                                                args: BridgeArgs(["id": id, "title": title, PortActivity.expectParam: state.portInput.token(for: state.portKey(for: id) ?? id)]))
        }
        #expect(state.portInput.seq(for: udid) == 2)
        // Same key as presence and the Notify topic — three tables that must never disagree about
        // which port they mean.
        #expect(state.portKey(for: id) == udid)
    }

    @Test("a READ does not bump — reading is not changing")
    func readsDoNotBump() async throws {
        let (state, id) = try makeWorld()
        let udid = try #require(state.portWindows.panels.first(where: { $0.id == id })?.udid)
        _ = try await state.runBridgeMethod("ports.list", principal: principal("bob", "bob"),
                                            args: BridgeArgs([:]))
        #expect(state.portInput.seq(for: udid) == 0)
    }

    @Test("an unresolvable target bumps nothing — no token on a port that does not exist")
    func unknownTargetDoesNotBump() async throws {
        let (state, _) = try makeWorld()
        _ = try? await state.runBridgeMethod("port.rename", principal: principal("alice", "alice"),
                                             args: BridgeArgs(["id": "no-such-port", "title": "x"]))
        #expect(state.portInput.seq(for: "no-such-port") == 0)
    }

    @Test("human input bumps EVERY time — the presence throttle must not reach the token")
    func humanInputBumpsUnthrottled() throws {
        let (state, id) = try makeWorldWithUser()
        let udid = try #require(state.portWindows.panels.first(where: { $0.id == id })?.udid)

        // A burst well inside the ~5s claim throttle. Presence records once; the token must move
        // per keystroke, or a companion's 4-second-old write would pass CAS against a line you have
        // been typing into — the exact splice R5 exists to stop.
        for _ in 1...10 { state.humanInteracted(with: udid) }
        #expect(state.portInput.seq(for: udid) == 10)
        #expect(state.portInput.driver(of: udid, now: Date())?.name == "gordon")
    }

    @Test("input before setup still bumps — the port changed whether or not we know who did it")
    func inputWithoutIdentityStillBumps() throws {
        let (state, id) = try makeWorld()          // no currentUser
        state.humanInteracted(with: id)
        #expect(state.portInput.seq(for: id) == 1)
        #expect(state.portInput.driver(of: id, now: Date()) == nil)
    }

    @Test("the surface only reports TRUSTED input, so a port cannot bump its own token")
    func onlyTrustedInputReachesTheHook() throws {
        // The web claim is an injected listener, so the guard lives in JS and no Swift test can
        // exercise it. What a test CAN pin is that the guard is still there: it was added after a
        // live failure (the onboarding shader fired its own pointer events and held the human's
        // lease forever), and deleting it would now also let a port forge activity — silently
        // invalidating every honest writer's token. See R7 for the real fix, a native monitor.
        let src = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Port42Lib/Views/PortWindowManager.swift")
        let text = try String(contentsOf: src, encoding: .utf8)
        #expect(text.contains("e.isTrusted !== true"),
                "the portInput listener must drop synthetic events")
    }

    // MARK: - The declaration cannot rot

    @Test("every write verb declares writesTarget, and no read verb does")
    func declarationsAreComplete() throws {
        let db = try DatabaseService(inMemory: true)
        let registry = buildBridgeRegistry(AppState(db: db))

        // ADD A NEW WRITE VERB? Add it here. This list failing is the reminder. `writesTarget`
        // survived the demotion unchanged — it now means "which port does this touch", and R3 hangs
        // the state-token check off the same declaration.
        let writes = ["port.push", "port.exec", "port.patch", "port.update",
                      "port.rename", "port.move", "port.restore", "port.manage"]
        for name in writes {
            let m = try #require(registry[name], "missing method \(name)")
            #expect(m.writesTarget == "id", "\(name) must declare writesTarget or it escapes presence")
        }

        // Reading is not driving.
        for name in ["port.getHtml", "port.history", "port.info", "port.position", "ports.list"] {
            #expect(registry[name]?.writesTarget == nil, "\(name) is a read and must not record a driver")
        }
    }
}
