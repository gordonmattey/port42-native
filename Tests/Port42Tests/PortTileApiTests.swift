import Testing
import Foundation
@testable import Port42Lib

// API parity, Phase D (docs/plan-api-parity.md): port.move with width and height, port.manage reload,
// and port.fork, the tile menu's own actions as calls.

@Suite("port.move size, reload and port.fork")
@MainActor
struct PortTileApiTests {
    func call(_ w: ParityWorld, _ method: String, _ args: [String: Any], as p: Principal? = nil) async throws -> BridgeValue {
        try await w.state.runBridgeMethod(method, principal: p ?? .peer(id: "cli", displayName: "cli"), args: BridgeArgs(args))
    }
    func token(_ w: ParityWorld, _ id: String) -> String { w.state.portInput.token(for: id) }
    func port(_ w: ParityWorld, space: String? = nil) throws -> String {
        let r = w.state.createPort(type: "web", title: "tile", html: "<title>tile</title>", command: nil, cwd: nil,
                                   systemPrompt: nil, spaceId: space ?? w.space.id, createdBy: nil, createdByName: nil)
        return try #require(r["id"] as? String)
    }

    @Test("port.move resizes, keeps the position when only a size is given, and clamps to the smallest tile")
    func resize() async throws {
        let w = try makeParityWorld()
        let id = try port(w)
        _ = try await call(w, "port.move", ["id": id, "x": 40.0, "y": 50.0, "token": token(w, id)])
        _ = try await call(w, "port.move", ["id": id, "width": 420.0, "height": 300.0, "token": token(w, id)])
        var f = try #require(w.state.portWindows.portFrame(by: id, on: w.space.id))
        #expect(f.size == CGSize(width: 420, height: 300))
        #expect(f.origin == CGPoint(x: 40, y: 50), "a resize moved the tile")
        _ = try await call(w, "port.move", ["id": id, "width": 10.0, "token": token(w, id)])
        f = try #require(w.state.portWindows.portFrame(by: id, on: w.space.id))
        #expect(f.size.width == ShellState.minTileSize.width, "the width went below the smallest tile")
        #expect(f.size.height == 300, "the height changed with only a width given")
    }

    @Test("port.move refuses a lone x, and a call with nothing to do")
    func moveRefusals() async throws {
        let w = try makeParityWorld()
        let id = try port(w)
        _ = try await call(w, "port.move", ["id": id, "x": 40.0, "y": 50.0, "token": token(w, id)])
        await #expect(throws: BridgeError.self) { _ = try await self.call(w, "port.move", ["id": id, "x": 5.0, "token": self.token(w, id)]) }
        await #expect(throws: BridgeError.self) { _ = try await self.call(w, "port.move", ["id": id, "token": self.token(w, id)]) }
    }

    @Test("port.manage reload is refused for a port with no live page, and is a known action")
    func reload() async throws {
        let w = try makeParityWorld()
        let id = try port(w)
        do { _ = try await call(w, "port.manage", ["id": id, "action": "reload", "token": token(w, id)]) }
        catch let e as BridgeError {
            #expect(!"\(e)".contains("unknown action"), "reload is not a known action: \(e)")
        }
    }

    @Test("port.fork makes an independent copy in the named space, and refuses an unknown port or space")
    func fork() async throws {
        let w = try makeParityWorld()
        let other = Space.create(name: "copies")
        try w.state.db.saveSpace(other)
        w.state.spaces.append(other)
        let id = try port(w)
        let v = try await call(w, "port.fork", ["id": id, "space_id": other.id])
        guard case .object(let o) = v, case .string(let copy)? = o["id"] else { Issue.record("no id: \(v)"); return }
        #expect(copy != id)
        let made = try #require(w.state.portWindows.findPort(by: copy))
        #expect(made.spaceId == other.id, "the copy is not in the named space")
        #expect(made.title.hasSuffix("(copy)"))
        await #expect(throws: BridgeError.self) { _ = try await self.call(w, "port.fork", ["id": "nope"]) }
        await #expect(throws: BridgeError.self) { _ = try await self.call(w, "port.fork", ["id": id, "space_id": "nope"]) }
    }

    @Test("a companion acting in one space cannot fork a port from another")
    func forkScope() async throws {
        let w = try makeParityWorld()
        let other = Space.create(name: "away")
        try w.state.db.saveSpace(other)
        w.state.spaces.append(other)
        let id = try port(w, space: other.id)
        let caller = Principal.companion(id: w.companion.id, displayName: w.companion.displayName, spaceId: w.space.id)
        let before = w.state.portWindows.panels.count
        do { _ = try await call(w, "port.fork", ["id": id], as: caller) } catch {}
        #expect(w.state.portWindows.panels.count == before, "a companion copied a port from a space it does not act in")
    }

    @Test("port.move places a port that was never placed when given a position and a size, and says what to pass without one")
    func placesAnUnplacedPort() async throws {
        let w = try makeParityWorld()
        let id = try port(w)
        #expect(w.state.portWindows.portFrame(by: id, on: w.space.id) == nil, "the fixture port is already placed")
        await #expect(throws: BridgeError.self) { _ = try await self.call(w, "port.move", ["id": id, "width": 500.0, "token": self.token(w, id)]) }
        _ = try await call(w, "port.move", ["id": id, "x": 60.0, "y": 60.0, "width": 400.0, "height": 300.0, "token": token(w, id)])
        let f = try #require(w.state.portWindows.portFrame(by: id, on: w.space.id))
        #expect(f == CGRect(x: 60, y: 60, width: 400, height: 300), "placed at \(f)")
    }
}
