import Testing
import Foundation
@testable import Port42Lib

/// #191 (GM, 2026-09-29): "zoom into running ports and pop them up, and then zoom out will pop them
/// back in." A click on the port in zoom view keeps it, as it does for a peek.
@Suite("Running ports: pop up for a look, back on zoom out, kept on a click")
@MainActor
struct PopRunningTests {

    private func world() throws -> (ParityWorld, ShellState, [String]) {
        let w = try makeParityWorld()
        w.state.currentSpace = w.space
        let pw = w.state.portWindows
        for id in ["a", "b", "c"] {
            pw.registerTiledPort(id: id, html: "<title>\(id)</title>", spaceId: w.space.id, createdBy: nil,
                                 title: id, position: CGPoint(x: 100, y: 100))
            pw.minimize(id)
        }
        let shell = ShellState(appState: w.state)
        return (w, shell, pw.hiddenPanels(in: w.space.id).map(\.id))
    }

    private func running(_ w: ParityWorld) -> [String] { w.state.portWindows.hiddenPanels(in: w.space.id).map(\.id) }

    @Test("popping one up zooms to it and takes it out of Running for the look")
    func popZooms() throws {
        let (w, shell, before) = try world()
        #expect(before == ["a", "b", "c"])
        shell.popRunning("b")
        #expect(shell.zoom == .focus("b"))
        #expect(shell.poppedRunning?.id == "b")
        #expect(running(w) == ["a", "c"])
    }

    @Test("zooming out puts it back in the slot it came from")
    func zoomOutReturnsIt() throws {
        let (w, shell, _) = try world()
        shell.popRunning("b")
        shell.zoom = .space
        #expect(running(w) == ["a", "b", "c"], "it did not go back where it was")
        #expect(shell.poppedRunning == nil)
    }

    @Test("a click in zoom view keeps it: zoom out and it stays on the desktop")
    func keepStays() throws {
        let (w, shell, _) = try world()
        shell.popRunning("b")
        shell.keepPopped()
        shell.zoom = .space
        #expect(running(w) == ["a", "c"], "a kept port went back into Running")
        #expect(w.state.portWindows.panels(in: w.space.id).contains { $0.id == "b" })
    }

    @Test("popping a second sends the first back to its slot")
    func oneAtATime() throws {
        let (w, shell, _) = try world()
        shell.popRunning("a")
        shell.popRunning("c")
        #expect(shell.zoom == .focus("c"))
        #expect(running(w) == ["a", "b"], "the first stayed out")
    }
}

@Suite("Running ports: a pinch on a card pops it up")
@MainActor
struct PinchRunningTests {
    @Test("zooming in over a Running card in the open rail pops that port up")
    func pinchPops() throws {
        let w = try makeParityWorld()
        w.state.currentSpace = w.space
        let pw = w.state.portWindows
        for id in ["a", "b"] {
            pw.registerTiledPort(id: id, html: "<title>\(id)</title>", spaceId: w.space.id, createdBy: nil,
                                 title: id, position: CGPoint(x: 100, y: 100))
            pw.minimize(id)
        }
        let shell = ShellState(appState: w.state)
        shell.railHovered = true
        shell.hoveredRunningId = "b"
        shell.zoomIn()
        #expect(shell.zoom == .focus("b"))
        #expect(shell.poppedRunning?.id == "b")
    }

    @Test("with the rail folded a stale hover does not pop anything")
    func foldedIgnoresStaleHover() throws {
        let w = try makeParityWorld()
        w.state.currentSpace = w.space
        w.state.portWindows.registerTiledPort(id: "a", html: "<title>a</title>", spaceId: w.space.id, createdBy: nil,
                                              title: "a", position: CGPoint(x: 100, y: 100))
        w.state.portWindows.minimize("a")
        let shell = ShellState(appState: w.state)
        shell.hoveredRunningId = "a"
        shell.zoomIn()
        #expect(shell.poppedRunning == nil)
    }
}
