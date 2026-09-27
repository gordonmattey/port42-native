import Testing
import Foundation
@testable import Port42Lib

// Companions watch ports (nautilus Phase 3.3), through the API and the real event bus, with the
// delivery to a terminal captured instead of typed.
@Suite("Companions watch ports")
@MainActor
struct CompanionWatchTests {

    struct World {
        let w: ParityWorld
        let udid: String
        let topic: String
        var sent: [(String, String, String)] { box.sent }
        let box: Box
        final class Box { var sent: [(String, String, String)] = [] }
    }

    func world() throws -> World {
        let w = try makeParityWorld(companionName: "scout")
        w.state.portWindows.registerTiledPort(id: "p", html: "<title>feed</title>", spaceId: w.space.id,
                                              createdBy: nil, title: "feed", position: CGPoint(x: 40, y: 40))
        let udid = w.state.portWindows.panels.first { $0.id == "p" }!.udid
        let box = World.Box()
        w.state.companionWatches.deliver = { c, msg, port in box.sent.append((c.displayName, msg, port)) }
        let topic = PortNotify.topic(forPortKey: w.state.resolvePortRef(udid)?.key ?? udid)
        return World(w: w, udid: udid, topic: topic, box: box)
    }

    var me: Principal { .companion(id: "", displayName: "", spaceId: nil) }

    func asCompanion(_ x: World) -> Principal { .companion(id: x.w.companion.id, displayName: "scout", spaceId: x.w.space.id) }

    func call(_ x: World, _ method: String, _ args: [String: Any], as p: Principal? = nil) async throws -> BridgeValue {
        try await x.w.state.runBridgeMethod(method, principal: p ?? asCompanion(x), args: BridgeArgs(args))
    }

    func publish(_ x: World, _ kind: String) {
        x.w.state.notifyBus.publish(topic: x.topic, kind: kind, payload: .object(["n": .int(1)]))
    }

    func settle() async throws { try await Task.sleep(nanoseconds: 1_400_000_000) }   // past the 1 s gather

    @Test("a watched port's event wakes its watcher once, with the port named, the reply bound for its chat")
    func wakes() async throws {
        let x = try world()
        _ = try await call(x, "companions.watch", ["port": x.udid])
        publish(x, "port.tick"); publish(x, "port.tick")
        try await settle()
        #expect(x.sent.count == 1, "a burst of two woke \(x.sent.count) times")
        let (who, msg, port) = try #require(x.sent.first)
        #expect(who == "scout" && port == x.udid)
        #expect(msg.contains("port.tick") && msg.contains(x.udid) && msg.contains("2 events"))
    }

    @Test("a kind not named, and the keystroke stream, never wake")
    func unnamedKindsDoNot() async throws {
        let x = try world()
        _ = try await call(x, "companions.watch", ["port": x.udid])
        publish(x, "console"); publish(x, "terminal.output")
        try await settle()
        #expect(x.sent.isEmpty)
        await #expect(throws: BridgeError.self) {
            _ = try await call(x, "companions.watch", ["port": x.udid, "kinds": ["terminal.output"]])
        }
    }

    @Test("the watcher's own write does not wake it")
    func noSelfWake() async throws {
        let x = try world()
        _ = try await call(x, "companions.watch", ["port": x.udid, "kinds": ["port", "state"]])
        x.w.state.companionWatches.turnStarted(companionName: "scout")
        let tok = x.w.state.portInput.token(for: x.udid)
        _ = try await call(x, "port.update", ["id": x.udid, "html": "<title>feed</title>v2", "token": tok])
        publish(x, "state")
        // The turn ends after its events have landed, as it does for real (a turn ends seconds after
        // its last write). Ending it on the same tick raced the bus's delivery: on a loaded machine the
        // events arrived after the turn and read as someone else's, and this failed 3 times of many.
        try await Task.sleep(nanoseconds: 500_000_000)
        x.w.state.companionWatches.turnEnded(companionName: "scout")
        try await settle()
        #expect(x.sent.isEmpty, "woke on its own edit: \(x.sent.map(\.1))")
    }

    @Test("unwatch stops it; a stored watch comes back at launch; deleting the port removes it")
    func lifecycle() async throws {
        let x = try world()
        _ = try await call(x, "companions.watch", ["port": x.udid])
        let again = CompanionWatchService(appState: x.w.state)
        again.start()
        #expect(again.watches.map(\.portUdid) == [x.udid], "a watch does not survive a restart")

        _ = try await call(x, "companions.unwatch", ["port": x.udid])
        publish(x, "port.tick")
        try await settle()
        #expect(x.sent.isEmpty)
        #expect(try x.w.state.db.companionWatches().isEmpty)

        _ = try await call(x, "companions.watch", ["port": x.udid])
        x.w.state.portWindows.deleteForever("p")
        #expect(try x.w.state.db.companionWatches().isEmpty, "a deleted port kept its watch")
    }

    @Test("a caller that is no companion must say whose watch it sets")
    func needsACompanion() async throws {
        let x = try world()
        let person = Principal.peer(id: "cli", displayName: "cli", spaceId: nil)
        await #expect(throws: BridgeError.self) { _ = try await call(x, "companions.watch", ["port": x.udid], as: person) }
        _ = try await call(x, "companions.watch", ["port": x.udid, "companion": "scout"], as: person)
        guard case .array(let list) = try await call(x, "companions.watches", ["companion": "*"], as: person) else {
            Issue.record("not a list"); return
        }
        #expect(list.count == 1)
    }
}
