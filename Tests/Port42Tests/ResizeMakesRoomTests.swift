import Testing
import Foundation
@testable import Port42Lib

/// **Resizing a port makes room** (#196).
///
/// Imagine lays out a grid of four: the port being built and three terminals. Growing the port used
/// to cover its neighbors. Now they give way, keeping their order; letting go keeps the new layout,
/// ⌥ held is only a look, and one action puts it back. Only a resize by the person does this: a new
/// port still moves nothing.
@Suite("Resize makes room (#196)")
@MainActor
struct ResizeMakesRoomTests {

    // Imagine's grid of four, 10 points apart.
    let a = CGRect(x: 0, y: 0, width: 400, height: 300)
    let b = CGRect(x: 410, y: 0, width: 400, height: 300)
    let c = CGRect(x: 0, y: 310, width: 400, height: 300)
    let d = CGRect(x: 410, y: 310, width: 400, height: 300)

    @Test("growing one of a grid of four: the neighbors shrink to fit, keep their order and their gap")
    func gridOfFour() {
        let grown = CGRect(x: 0, y: 0, width: 600, height: 450)
        let out = ShellState.makeRoom(from: a, to: grown, others: ["b": b, "c": c, "d": d])
        #expect(out["b"] == CGRect(x: 610, y: 0, width: 200, height: 300))
        #expect(out["c"] == CGRect(x: 0, y: 460, width: 400, height: 150))
        #expect(out["d"] == CGRect(x: 610, y: 310, width: 200, height: 300))
        for f in out.values { #expect(!f.intersects(grown), "a neighbor is still covered: \(f)") }
        #expect(out["b"]!.minX > grown.maxX && out["c"]!.minY > grown.maxY, "the order changed")
    }

    @Test("a neighbor too small to shrink further keeps its size and moves aside")
    func minimumSize() {
        let grown = CGRect(x: 0, y: 0, width: 760, height: 300)
        let out = ShellState.makeRoom(from: a, to: grown, others: ["b": b])
        #expect(out["b"] == CGRect(x: 770, y: 0, width: ShellState.makeRoomMin.width, height: 300))
    }

    @Test("a neighbor not covered, or one the person already overlapped, is left alone")
    func handsOff() {
        let grown = CGRect(x: 0, y: 0, width: 405, height: 300)     // still short of b's gap
        #expect(ShellState.makeRoom(from: a, to: grown, others: ["b": b]).isEmpty)
        let overlapping = CGRect(x: 350, y: 50, width: 300, height: 200)
        #expect(ShellState.makeRoom(from: a, to: CGRect(x: 0, y: 0, width: 600, height: 300),
                                    others: ["x": overlapping]).isEmpty)
    }

    /// Two tiles side by side on the world's desktop.
    func twoTiles(_ w: ParityWorld) throws -> (String, String) {
        w.state.currentSpace = w.space
        func make(_ title: String, _ f: CGRect) throws -> String {
            let created = w.state.createPort(type: "web", title: title, html: "<title>\(title)</title>", command: nil,
                                             cwd: nil, systemPrompt: nil, spaceId: w.space.id, createdBy: w.companion.id,
                                             createdByName: w.companion.displayName, presentation: "tiled")
            let udid = try #require(created["id"] as? String)
            let id = try #require(w.state.portWindows.findPort(by: udid)?.id)
            w.state.portWindows.updateTileFrame(id: id, position: f.origin, size: f.size, on: w.space.id)
            return id
        }
        return (try make("built", a), try make("team", b))
    }

    func frame(_ w: ParityWorld, _ id: String) -> CGRect? { ShellState(appState: w.state).desktopFrames()[id] }

    @Test("letting go keeps the layout; one action puts it back")
    func keepAndPutBack() throws {
        let w = try makeParityWorld()
        let (built, team) = try twoTiles(w)
        let shell = ShellState(appState: w.state)
        let grown = CGRect(x: 0, y: 0, width: 600, height: 300)

        shell.previewMakeRoom(resizing: built, from: a, to: grown)
        #expect(shell.makeRoomPreview[team] == CGRect(x: 610, y: 0, width: 200, height: 300), "no live preview")
        shell.endMakeRoom(resizing: built, from: a, keep: true)
        w.state.portWindows.updateTileFrame(id: built, position: grown.origin, size: grown.size, on: w.space.id)
        #expect(shell.makeRoomPreview.isEmpty)
        #expect(frame(w, team) == CGRect(x: 610, y: 0, width: 200, height: 300), "the new layout was not kept")

        shell.putLayoutBack()
        #expect(frame(w, team) == b && frame(w, built) == a, "putting it back did not restore the layout")
        #expect(shell.layoutUndo == nil)
    }

    @Test("a quick look (⌥) leaves every tile where it was")
    func quickLook() throws {
        let w = try makeParityWorld()
        let (built, team) = try twoTiles(w)
        let shell = ShellState(appState: w.state)
        shell.previewMakeRoom(resizing: built, from: a, to: CGRect(x: 0, y: 0, width: 600, height: 300))
        shell.endMakeRoom(resizing: built, from: a, keep: false)
        #expect(frame(w, team) == b)
        #expect(shell.layoutUndo == nil && shell.makeRoomPreview.isEmpty)
    }

    @Test("a new port moves nothing: making room happens only on a resize")
    func newPortMovesNothing() throws {
        let w = try makeParityWorld()
        let (_, team) = try twoTiles(w)
        _ = w.state.createPort(type: "web", title: "new", html: "<title>new</title>", command: nil, cwd: nil,
                               systemPrompt: nil, spaceId: w.space.id, createdBy: w.companion.id,
                               createdByName: w.companion.displayName, presentation: "tiled")
        #expect(frame(w, team) == b)
    }
}
