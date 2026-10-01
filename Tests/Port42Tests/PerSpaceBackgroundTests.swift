import Testing
import Foundation
@testable import Port42Lib

// The background is per space (Gordon, 2026-09-30: "it should be per space"): each space has its own
// backdrop, a port is the backdrop of one space at a time, and port.manage background/unbackground
// name the space.

@Suite("per-space backgrounds", .serialized)
@MainActor
struct PerSpaceBackgroundTests {
    static let keys = ["shell.backgroundPorts", "shell.backgroundPortId"]
    func clean() { for k in Self.keys { UserDefaults.standard.removeObject(forKey: k) } }

    struct World { let shell: ShellState; let w: ParityWorld; let a: Space; let b: Space }

    func world() throws -> World {
        clean()
        let w = try makeParityWorld()
        let shell = ShellState(appState: w.state)
        w.state.shell = shell
        let b = Space.create(name: "second")
        try w.state.db.saveSpace(b)
        w.state.spaces.append(b)
        w.state.currentSpace = w.space
        return World(shell: shell, w: w, a: w.space, b: b)
    }
    func port(_ x: World, _ id: String, in space: Space) {
        _ = x.w.state.portWindows.registerTiledPort(id: id, html: "<title>\(id)</title><div/>", spaceId: space.id,
                                                    createdBy: nil, title: nil, position: nil)
    }
    func presentation(_ x: World, _ id: String) -> String? { x.w.state.portWindows.panels.first { $0.id == id }?.presentation }

    @Test("each space has its own backdrop, and clearing one leaves the other")
    func perSpace() throws {
        let x = try world(); defer { clean() }
        port(x, "p1", in: x.a); port(x, "p2", in: x.b)
        x.shell.setBackgroundPort(id: "p1", in: x.a.id)
        x.shell.setBackgroundPort(id: "p2", in: x.b.id)
        #expect(x.shell.backgroundPortId == "p1", "space a shows \(String(describing: x.shell.backgroundPortId))")
        x.w.state.currentSpace = x.b
        #expect(x.shell.backgroundPortId == "p2", "space b shows \(String(describing: x.shell.backgroundPortId))")
        x.shell.setBackgroundPort(id: nil, in: x.b.id)
        #expect(x.shell.hasBackgroundPort == false, "space b still has a backdrop")
        x.w.state.currentSpace = x.a
        #expect(x.shell.backgroundPortId == "p1", "clearing b took a's backdrop")
        #expect(presentation(x, "p2") == "tiled", "the cleared port did not return to a tile")
    }

    @Test("a space's new backdrop returns the old one to a tile, and one port is the backdrop of one space")
    func oneAtATime() throws {
        let x = try world(); defer { clean() }
        port(x, "p1", in: x.a); port(x, "p3", in: x.a)
        x.shell.setBackgroundPort(id: "p1", in: x.a.id)
        x.shell.setBackgroundPort(id: "p3", in: x.a.id)
        #expect(presentation(x, "p1") == "tiled", "the replaced backdrop stayed hidden")
        #expect(x.shell.backgroundPortId == "p3")
        x.shell.setBackgroundPort(id: "p3", in: x.b.id)
        #expect(x.shell.backgroundPorts[x.a.id] == nil, "one port was the backdrop of two spaces")
        #expect(x.shell.backgroundPorts[x.b.id] == "p3")
    }

    @Test("backdrops are remembered per space, and the old single setting lands on its port's space")
    func restore() throws {
        let x = try world(); defer { clean() }
        port(x, "p1", in: x.a); port(x, "p2", in: x.b)
        x.shell.setBackgroundPort(id: "p1", in: x.a.id)
        x.shell.setBackgroundPort(id: "p2", in: x.b.id)
        let fresh = ShellState(appState: x.w.state)
        fresh.restoreBackgroundPort()
        #expect(fresh.backgroundPorts == [x.a.id: "p1", x.b.id: "p2"], "restored \(fresh.backgroundPorts)")

        clean()
        UserDefaults.standard.set("p2", forKey: "shell.backgroundPortId")
        let migrated = ShellState(appState: x.w.state)
        migrated.restoreBackgroundPort()
        #expect(migrated.backgroundPorts == [x.b.id: "p2"], "the old setting went to \(migrated.backgroundPorts)")
        #expect(UserDefaults.standard.string(forKey: "shell.backgroundPortId") == nil)
    }

    @Test("a background restored before its port has loaded still lands on the port's own space, and goes live when it loads")
    func restoreBeforeLoad() throws {
        let x = try world(); defer { clean() }
        // The port exists only as a stored row, as at launch before the panels are restored.
        port(x, "late", in: x.b)
        let made = try #require(x.w.state.portWindows.panels.first { $0.id == "late" })
        try x.w.state.db.savePortPanel(PersistedPortPanel(from: made))
        x.w.state.portWindows.panels.removeAll { $0.id == "late" }
        UserDefaults.standard.set("late", forKey: "shell.backgroundPortId")
        x.w.state.currentSpace = x.a
        let fresh = ShellState(appState: x.w.state)
        fresh.restoreBackgroundPort()
        #expect(fresh.backgroundHtmls[x.b.id]?.id == "late", "it landed on \(fresh.backgroundHtmls.keys), not the port's own space")
        #expect(fresh.backgroundHtmls[x.a.id] == nil, "it landed on the space that happened to be current")
        port(x, "late", in: x.b)
        fresh.adoptLoadedBackgrounds()
        #expect(fresh.backgroundPorts[x.b.id] == "late", "the loaded port did not take over")
        #expect(fresh.backgroundHtmls.isEmpty)
    }

    func call(_ x: World, _ args: [String: Any]) async throws -> BridgeValue {
        try await x.w.state.runBridgeMethod("port.manage", principal: .peer(id: "cli", displayName: "cli"), args: BridgeArgs(args))
    }

    @Test("port.manage background and unbackground name the space, and unbackground refuses a port that is not one")
    func api() async throws {
        let x = try world(); defer { clean() }
        port(x, "p1", in: x.a)
        let tok = { x.w.state.portInput.token(for: "p1") }
        _ = try await call(x, ["id": "p1", "action": "background", "token": tok()])
        #expect(x.shell.backgroundPorts[x.a.id] == "p1", "background went to \(x.shell.backgroundPorts)")
        await #expect(throws: BridgeError.self) { _ = try await self.call(x, ["id": "p1", "action": "background", "space_id": x.b.id, "token": tok()]) }
        #expect(x.shell.backgroundPorts[x.b.id] == nil, "a port was made the backdrop of a space it is not on")
        _ = try await call(x, ["id": "p1", "action": "unbackground", "token": tok()])
        #expect(x.shell.backgroundPorts.isEmpty)
        #expect(presentation(x, "p1") == "tiled")
        await #expect(throws: BridgeError.self) { _ = try await self.call(x, ["id": "p1", "action": "unbackground", "token": tok()]) }
    }
}
