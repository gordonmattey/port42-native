import Testing
import Foundation
@testable import Port42Lib

// The background is per space (Gordon, 2026-09-30: "it should be per space"): each space has its own
// backdrop, a port is the backdrop of one space at a time, and port.manage background/unbackground
// name the space. App state, so with a window per display (#189) each window shows its own space's.

@Suite("per-space backgrounds", .serialized)
@MainActor
struct PerSpaceBackgroundTests {
    static let keys = ["shell.backgroundPorts", "shell.backgroundPortId"]
    func clean() { for k in Self.keys { UserDefaults.standard.removeObject(forKey: k) } }

    struct World { let shell: ShellState; let w: ParityWorld; let a: Space; let b: Space
        var state: AppState { w.state } }

    func world() throws -> World {
        clean()
        let w = try makeParityWorld()
        w.state.currentSpace = w.space
        let shell = ShellState(appState: w.state)
        let b = Space.create(name: "second")
        try w.state.db.saveSpace(b)
        w.state.spaces.append(b)
        return World(shell: shell, w: w, a: w.space, b: b)
    }
    func port(_ x: World, _ id: String, in space: Space) {
        _ = x.state.portWindows.registerTiledPort(id: id, html: "<title>\(id)</title><div/>", spaceId: space.id,
                                                  createdBy: nil, title: nil, position: nil)
    }
    func presentation(_ x: World, _ id: String) -> String? { x.state.portWindows.panels.first { $0.id == id }?.presentation }
    /// A fresh launch reading what was saved.
    func relaunch(_ x: World) {
        x.state.backgroundPorts = [:]
        x.state.backgroundHtmls = [:]
        x.state.restoreBackgrounds()
    }

    @Test("each space has its own backdrop, and clearing one leaves the other")
    func perSpace() throws {
        let x = try world(); defer { clean() }
        port(x, "p1", in: x.a); port(x, "p2", in: x.b)
        x.state.setBackgroundPort(id: "p1", in: x.a.id)
        x.state.setBackgroundPort(id: "p2", in: x.b.id)
        #expect(x.shell.backgroundPortId == "p1", "space a shows \(String(describing: x.shell.backgroundPortId))")
        x.state.currentSpace = x.b
        #expect(x.shell.backgroundPortId == "p2", "space b shows \(String(describing: x.shell.backgroundPortId))")
        x.shell.setBackgroundPort(id: nil)
        #expect(x.shell.hasBackgroundPort == false, "space b still has a backdrop")
        x.state.currentSpace = x.a
        #expect(x.shell.backgroundPortId == "p1", "clearing b took a's backdrop")
        #expect(presentation(x, "p2") == "tiled", "the cleared port did not return to a tile")
    }

    @Test("with a window per display, each window shows the backdrop of the space it shows")
    func perWindow() throws {
        let x = try world(); defer { clean() }
        port(x, "p1", in: x.a); port(x, "p2", in: x.b)
        let other = ShellState(appState: x.state)          // a second display's window
        other.isDisplayWindow = true
        other.show(spaceId: x.b.id)
        x.state.setBackgroundPort(id: "p1", in: x.a.id)
        other.setBackgroundPort(id: "p2")                     // set from that window: its own space
        #expect(x.shell.backgroundPortId == "p1", "the window in use shows \(String(describing: x.shell.backgroundPortId))")
        #expect(other.backgroundPortId == "p2", "the other display shows \(String(describing: other.backgroundPortId))")
        #expect(x.state.backgroundPorts == [x.a.id: "p1", x.b.id: "p2"])
    }

    @Test("a space's new backdrop returns the old one to a tile, and one port is the backdrop of one space")
    func oneAtATime() throws {
        let x = try world(); defer { clean() }
        port(x, "p1", in: x.a); port(x, "p3", in: x.a)
        x.state.setBackgroundPort(id: "p1", in: x.a.id)
        x.state.setBackgroundPort(id: "p3", in: x.a.id)
        #expect(presentation(x, "p1") == "tiled", "the replaced backdrop stayed hidden")
        #expect(x.shell.backgroundPortId == "p3")
        x.state.setBackgroundPort(id: "p3", in: x.b.id)
        #expect(x.state.backgroundPorts[x.a.id] == nil, "one port was the backdrop of two spaces")
        #expect(x.state.backgroundPorts[x.b.id] == "p3")
    }

    @Test("backdrops are remembered per space, and the old single setting lands on its port's space")
    func restore() throws {
        let x = try world(); defer { clean() }
        port(x, "p1", in: x.a); port(x, "p2", in: x.b)
        x.state.setBackgroundPort(id: "p1", in: x.a.id)
        x.state.setBackgroundPort(id: "p2", in: x.b.id)
        relaunch(x)
        #expect(x.state.backgroundPorts == [x.a.id: "p1", x.b.id: "p2"], "restored \(x.state.backgroundPorts)")

        clean()
        UserDefaults.standard.set("p2", forKey: "shell.backgroundPortId")
        relaunch(x)
        #expect(x.state.backgroundPorts == [x.b.id: "p2"], "the old setting went to \(x.state.backgroundPorts)")
        #expect(UserDefaults.standard.string(forKey: "shell.backgroundPortId") == nil)
    }

    @Test("a background restored before its port has loaded still lands on the port's own space, and goes live when it loads")
    func restoreBeforeLoad() throws {
        let x = try world(); defer { clean() }
        port(x, "late", in: x.b)
        let made = try #require(x.state.portWindows.panels.first { $0.id == "late" })
        try x.state.db.savePortPanel(PersistedPortPanel(from: made))
        x.state.portWindows.panels.removeAll { $0.id == "late" }
        UserDefaults.standard.set("late", forKey: "shell.backgroundPortId")
        x.state.currentSpace = x.a
        relaunch(x)
        #expect(x.state.backgroundHtmls[x.b.id]?.id == "late", "it landed on \(x.state.backgroundHtmls.keys), not the port's own space")
        #expect(x.state.backgroundHtmls[x.a.id] == nil, "it landed on the space that happened to be current")
        port(x, "late", in: x.b)
        x.state.adoptLoadedBackgrounds()
        #expect(x.state.backgroundPorts[x.b.id] == "late", "the loaded port did not take over")
        #expect(x.state.backgroundHtmls.isEmpty)
    }

    func call(_ x: World, _ args: [String: Any]) async throws -> BridgeValue {
        try await x.state.runBridgeMethod("port.manage", principal: .peer(id: "cli", displayName: "cli"), args: BridgeArgs(args))
    }

    @Test("port.manage background and unbackground name the space, need no window, and unbackground refuses a port that is not one")
    func api() async throws {
        let x = try world(); defer { clean() }
        port(x, "p1", in: x.a)
        x.state.shell = nil                                   // no window: the API still works (app state)
        let tok = { x.state.portInput.token(for: "p1") }
        _ = try await call(x, ["id": "p1", "action": "background", "token": tok()])
        #expect(x.state.backgroundPorts[x.a.id] == "p1", "background went to \(x.state.backgroundPorts)")
        await #expect(throws: BridgeError.self) { _ = try await self.call(x, ["id": "p1", "action": "background", "space_id": x.b.id, "token": tok()]) }
        #expect(x.state.backgroundPorts[x.b.id] == nil, "a port was made the backdrop of a space it is not on")
        _ = try await call(x, ["id": "p1", "action": "unbackground", "token": tok()])
        #expect(x.state.backgroundPorts.isEmpty)
        #expect(presentation(x, "p1") == "tiled")
        await #expect(throws: BridgeError.self) { _ = try await self.call(x, ["id": "p1", "action": "unbackground", "token": tok()]) }
    }
}
