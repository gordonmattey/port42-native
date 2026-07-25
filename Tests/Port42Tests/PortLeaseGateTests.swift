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
