import Testing
import Foundation
@testable import Port42Lib

// Phase 1, batch 4: identity / spaces / companions / messages / bus. Read-mostly, DB-backed. Clean
// contract: reads are structured arrays/objects, sends return {ok} and are checked by side effect.

@Suite("Bridge — comms")
struct BridgeCommsTests {

    @MainActor
    func call(_ w: ParityWorld, _ canonical: String, _ input: [String: Any]) async throws -> BridgeValue {
        let method = try #require(w.registry[canonical])
        return try await method.run(w.principal, BridgeArgs(input))
    }

    @Test("user.get returns the signed-in user; none throws")
    @MainActor
    func userGet() async throws {
        let w = try makeParityWorld()
        let u = try await call(w, "user.get", [:])
        guard case let .object(o) = u else { Issue.record("expected object"); return }
        #expect(o["displayName"] == .string("Alice"))
        w.state.currentUser = nil
        await #expect(throws: BridgeError.self) { _ = try await call(w, "user.get", [:]) }
    }

    @Test("space.list returns id+name objects for all spaces")
    @MainActor
    func spaceList() async throws {
        let w = try makeParityWorld()
        let listed = try await call(w, "space.list", [:])
        guard case let .array(items) = listed else { Issue.record("expected array"); return }
        #expect(items.contains(.object(["id": .string(w.space.id), "name": .string(w.space.name)])))
    }

    @Test("space.current reports the space and member count")
    @MainActor
    func spaceCurrent() async throws {
        let w = try makeParityWorld()
        w.state.currentSpace = w.space
        let cur = try await call(w, "space.current", ["space_id": w.space.id])
        guard case let .object(o) = cur else { Issue.record("expected object"); return }
        #expect(o["id"] == .string(w.space.id))
        #expect(o["name"] == .string(w.space.name))
        if case .array = o["members"] {} else { Issue.record("members should be an array") }
    }

    @Test("companions.list + companions.get")
    @MainActor
    func companions() async throws {
        let w = try makeParityWorld()
        let got = try await call(w, "companions.get", ["id": w.companion.id])
        guard case let .object(o) = got else { Issue.record("expected object"); return }
        #expect(o["id"] == .string(w.companion.id))
        #expect(o["name"] == .string(w.companion.displayName))
        await #expect(throws: BridgeError.self) { _ = try await call(w, "companions.get", ["id": "nope"]) }
    }

    @Test("messages.recent returns seeded chat messages in order")
    @MainActor
    func messagesRecent() async throws {
        let w = try makeParityWorld()
        try w.state.db.saveMessage(Message.create(spaceId: w.space.id, senderId: "u1", senderName: "Alice", content: "first", topic: "chat"))
        try w.state.db.saveMessage(Message.create(spaceId: w.space.id, senderId: "u1", senderName: "Alice", content: "second", topic: "chat"))
        let recent = try await call(w, "messages.recent", ["space_id": w.space.id])
        guard case let .array(items) = recent, items.count == 2 else { Issue.record("expected 2"); return }
        guard case let .object(last) = items[1] else { Issue.record("expected object"); return }
        #expect(last["content"] == .string("second"))
        #expect(last["sender"] == .string("Alice"))
    }

    @Test("bus.publish then bus.read round-trips on a topic")
    @MainActor
    func busRoundTrip() async throws {
        let w = try makeParityWorld()
        w.state.currentSpace = w.space
        let pub = try await call(w, "bus.publish", ["topic": "signals", "payload": "ping", "space_id": w.space.id])
        #expect(pub == .object(["ok": .bool(true), "topic": .string("signals")]))
        let read = try await call(w, "bus.read", ["topic": "signals", "space_id": w.space.id])
        guard case let .array(items) = read, case let .object(m) = items.last else { Issue.record("expected a bus message"); return }
        #expect(m["content"] == .string("ping"))
        #expect(m["topic"] == .string("signals"))
    }

    @Test("bus.read requires a topic")
    @MainActor
    func busReadRequiresTopic() async throws {
        let w = try makeParityWorld()
        await #expect(throws: BridgeError.self) { _ = try await call(w, "bus.read", [:]) }
    }

    @Test("messages.send persists a message to the space")
    @MainActor
    func messagesSend() async throws {
        let w = try makeParityWorld()
        w.state.currentSpace = w.space
        let sent = try await call(w, "messages.send", ["text": "hello there", "space_id": w.space.id])
        #expect(sent == .object(["ok": .bool(true)]))
        let msgs = try w.state.db.getMessages(spaceId: w.space.id, topic: "chat")
        #expect(msgs.contains { $0.content == "hello there" })
    }
}
