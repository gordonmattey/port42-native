import Testing
import Foundation
@testable import Port42Lib

/// **A port can be see-through** (#195).
///
/// While a port is dragged or resized its body goes semi-transparent, so the person can see what is
/// behind it and place it well, and it comes back when they let go. Each port also keeps its own
/// level, set from its menu. Only the body fades: the title bar and chat stay solid and readable,
/// and opacity does not change where clicks go.
@Suite("Port transparency (#195)")
@MainActor
struct PortTransparencyTests {

    @Test("while moving, the body goes semi-transparent; when let go it is back to its own level")
    func whileMoving() {
        #expect(ShellState.bodyOpacity(level: 1, moving: false) == 1)
        #expect(ShellState.bodyOpacity(level: 1, moving: true) == ShellState.movingOpacity)
        #expect(ShellState.movingOpacity < 1)
        // A port already more see-through than that is not made more solid by moving it.
        #expect(ShellState.bodyOpacity(level: 0.3, moving: true) == 0.3)
    }

    @Test("a saved level stays readable: never below the floor, never above solid")
    func clamped() {
        #expect(ShellState.portOpacity(0) == ShellState.minPortOpacity)
        #expect(ShellState.portOpacity(2) == 1)
        #expect(ShellState.portOpacity(.nan) == 1)
        #expect(ShellState.portOpacityChoices.allSatisfy { ShellState.portOpacity($0) == $0 },
                "every level the menu offers is a readable one")
    }

    @Test("a port's level is saved with it and comes back after a restart")
    func persisted() throws {
        let w = try makeParityWorld()
        let created = w.state.createPort(type: "web", title: "ref", html: "<title>ref</title>", command: nil,
                                         cwd: nil, systemPrompt: nil, spaceId: w.space.id, createdBy: w.companion.id,
                                         createdByName: w.companion.displayName, presentation: "tiled")
        let udid = try #require(created["id"] as? String)
        let id = try #require(w.state.portWindows.findPort(by: udid)?.id)

        w.state.portWindows.setOpacity(id: id, 0.5)
        #expect(w.state.portWindows.findPort(by: udid)?.opacity == 0.5)
        let row = try #require(try w.state.db.fetchPortPanels().first { $0.id == id })
        #expect(row.opacity == 0.5, "the level was not saved with the port")

        w.state.portWindows.setOpacity(id: id, 0.05)
        #expect(w.state.portWindows.findPort(by: udid)?.opacity == ShellState.minPortOpacity,
                "a level too faint to read was kept")
    }

    /// The readability rule, held in the view: the fade is applied to the port's body alone, after it
    /// is laid out and before the chat and state card are drawn over it, and the title bar is not
    /// inside it.
    @Test("only the body fades; the title bar and chat stay solid")
    func onlyTheBodyFades() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let s = try String(contentsOf: root.appendingPathComponent("Sources/Port42Lib/Views/ShellDesktop.swift"), encoding: .utf8)
        let body = try #require(s.range(of: "ShellTileBody(shell: shell, appState: appState, tile: tile)\n            .frame("))
        let fade = try #require(s.range(of: ".opacity(ShellState.bodyOpacity(level:"))
        let card = try #require(s.range(of: "if showsCard, let panel = tile.panel {"))
        let title = try #require(s.range(of: "if isPeeking, let peek { peekHeader(peek) } else { titleBar }"))
        #expect(title.lowerBound < body.lowerBound && body.lowerBound < fade.lowerBound && fade.lowerBound < card.lowerBound,
                "the fade must sit on the body, before the card and chat, and never wrap the title bar")
        #expect(s.components(separatedBy: ".opacity(ShellState.bodyOpacity(").count == 2, "the fade is applied once")
    }
}
