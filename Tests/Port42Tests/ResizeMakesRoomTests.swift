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

    // Imagine's grid of four, 10 points apart (wider than the desktop's 8, which a push closes to).
    let a = CGRect(x: 0, y: 0, width: 400, height: 300)
    let b = CGRect(x: 410, y: 0, width: 400, height: 300)
    let c = CGRect(x: 0, y: 310, width: 400, height: 300)
    let d = CGRect(x: 410, y: 310, width: 400, height: 300)

    /// The desktop for these: a grid of four fills it to its right and bottom edges.
    let bounds = CGRect(x: 0, y: 0, width: 810, height: 610)

    @Test("growing one of a grid of four: the neighbors slide, then shrink only at the desktop's edge, in order, 8 points away")
    func gridOfFour() {
        let grown = CGRect(x: 0, y: 0, width: 600, height: 450)
        let out = ShellState.makeRoom(from: a, to: grown, others: ["b": b, "c": c, "d": d], bounds: bounds)
        #expect(out["b"] == CGRect(x: 608, y: 0, width: 202, height: 300))
        #expect(out["c"] == CGRect(x: 0, y: 458, width: 400, height: 152))
        // The diagonal one goes the way it is overlapped least: down (147 points in) rather than right (197).
        #expect(out["d"] == CGRect(x: 410, y: 458, width: 400, height: 152))
        for f in out.values { #expect(!f.intersects(grown), "a neighbor is still covered: \(f)") }
        #expect(out["b"]!.minX > grown.maxX && out["c"]!.minY > grown.maxY, "the order changed")
    }

    @Test("with room to spare a neighbor slides at its own size and does not shrink (Gordon: they collapsed too soon)")
    func slidesBeforeShrinking() {
        let wide = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let out = ShellState.makeRoom(from: a, to: CGRect(x: 0, y: 0, width: 600, height: 300), others: ["b": b], bounds: wide)
        #expect(out["b"] == CGRect(x: 608, y: 0, width: 400, height: 300), "it shrank with room to slide: \(String(describing: out["b"]))")
        let down = ShellState.makeRoom(from: a, to: CGRect(x: 0, y: 0, width: 400, height: 500), others: ["c": c], bounds: wide)
        #expect(down["c"] == CGRect(x: 0, y: 508, width: 400, height: 300))
        // Slid as far as the edge, then only the part past it is taken off.
        let edge = ShellState.makeRoom(from: a, to: CGRect(x: 0, y: 0, width: 1000, height: 300), others: ["b": b], bounds: wide)
        #expect(edge["b"] == CGRect(x: 1008, y: 0, width: 400, height: 300))
        let past = ShellState.makeRoom(from: a, to: CGRect(x: 0, y: 0, width: 1300, height: 300), others: ["b": b], bounds: wide)
        #expect(past["b"] == CGRect(x: 1308, y: 0, width: 292, height: 300))
    }

    @Test("a wide gap closes to the desktop's 8 points before anything is pushed (Gordon: the gap was giant)")
    func minimalGap() {
        let far = CGRect(x: 500, y: 0, width: 300, height: 300)            // 100 points away
        let wide = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        #expect(ShellState.makeRoom(from: a, to: CGRect(x: 0, y: 0, width: 480, height: 300), others: ["far": far], bounds: wide).isEmpty)
        let out = ShellState.makeRoom(from: a, to: CGRect(x: 0, y: 0, width: 520, height: 300), others: ["far": far], bounds: wide)
        #expect(out["far"]?.minX == 520 + ShellPlacement.tileGap, "the old 100-point gap was kept: \(String(describing: out["far"]))")
    }

    @Test("a neighbor too small to shrink further keeps its size and moves aside")
    func minimumSize() {
        let grown = CGRect(x: 0, y: 0, width: 760, height: 300)
        let out = ShellState.makeRoom(from: a, to: grown, others: ["b": b], bounds: bounds)
        #expect(out["b"] == CGRect(x: 768, y: 0, width: ShellState.makeRoomMin.width, height: 300))
    }

    @Test("a neighbor not covered, or one the person already overlapped, is left alone")
    func handsOff() {
        let grown = CGRect(x: 0, y: 0, width: 402, height: 300)     // still more than 8 short of b
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

    /// A tile's frame on the world's desktop, read through a window that shows that space. Since #189 a
    /// second shell is another window, which shows nothing until it is given a space.
    func frame(_ w: ParityWorld, _ id: String) -> CGRect? {
        let window = ShellState(appState: w.state)
        window.show(spaceId: w.space.id)
        return window.desktopFrames()[id]
    }

    @Test("letting go keeps the layout; one action puts it back")
    func keepAndPutBack() throws {
        let w = try makeParityWorld()
        let (built, team) = try twoTiles(w)
        let shell = ShellState(appState: w.state)
        let grown = CGRect(x: 0, y: 0, width: 600, height: 300)

        shell.previewMakeRoom(resizing: built, from: a, to: grown)
        // The desktop (1440 wide) has room, so the neighbor slides at its own size.
        #expect(shell.makeRoomPreview[team] == CGRect(x: 608, y: 0, width: 400, height: 300), "no live preview")
        shell.endMakeRoom(resizing: built, from: a, keep: true)
        w.state.portWindows.updateTileFrame(id: built, position: grown.origin, size: grown.size, on: w.space.id)
        #expect(shell.makeRoomPreview.isEmpty)
        #expect(frame(w, team) == CGRect(x: 608, y: 0, width: 400, height: 300), "the new layout was not kept")

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

/// Gordon, 2026-09-30: "I don't always want the others to move". A plain resize covers; ⇧ makes room.
@Suite("Resize makes room only with ⇧")
struct ResizeMakesRoomModifierTests {
    @Test("only ⇧ pushes the neighbors; a plain resize, or ⌥ or ⌘ alone, does not")
    func shiftOnly() {
        #expect(ShellState.resizeMakesRoom([.shift]))
        #expect(ShellState.resizeMakesRoom([.shift, .option]))
        #expect(!ShellState.resizeMakesRoom([]))
        #expect(!ShellState.resizeMakesRoom([.option]))
        #expect(!ShellState.resizeMakesRoom([.command]))
    }

    @Test("the hint and Put the layout back sit above the dock, not across it")
    func pillClearsTheDock() {
        // The dock is a 40-point chip row with its name and padding, 24 points off the bottom: about 100.
        #expect(ShellState.layoutPillBottom >= ShellPlacement.dockClearance + 20)
    }
}

/// Gordon, 2026-09-30: a pushed neighbor at its smallest, against any edge of the screen, stops the drag.
@Suite("Make room stops at the screen's edges")
@MainActor
struct MakeRoomLimitTests {
    let a = CGRect(x: 0, y: 0, width: 400, height: 300)
    let b = CGRect(x: 410, y: 0, width: 400, height: 300)
    let c = CGRect(x: 0, y: 310, width: 400, height: 300)
    let bounds = CGRect(x: 0, y: 0, width: 810, height: 610)
    var minW: CGFloat { ShellState.makeRoomMin.width }
    var minH: CGFloat { ShellState.makeRoomMin.height }

    @Test("pushing right: the edge stops where the neighbor, at its smallest, meets the right edge")
    func right() {
        let r = ShellState.limitForRoom(from: a, to: CGRect(x: 0, y: 0, width: 800, height: 300), others: ["b": b], bounds: bounds)
        #expect(r.maxX == bounds.maxX - minW - ShellPlacement.tileGap)
        let room = ShellState.makeRoom(from: a, to: r, others: ["b": b], bounds: bounds)
        #expect(room["b"]!.maxX <= bounds.maxX, "the neighbor went off the screen")
    }

    @Test("pushing left: the edge stops where the neighbor meets the left edge")
    func left() {
        let r = ShellState.limitForRoom(from: b, to: CGRect(x: 0, y: 0, width: 810, height: 300), others: ["a": a], bounds: bounds)
        #expect(r.minX == bounds.minX + minW + ShellPlacement.tileGap)
        #expect(r.maxX == b.maxX, "the far edge moved")
    }

    @Test("pushing down and up: the same at the bottom and top edges")
    func vertical() {
        let down = ShellState.limitForRoom(from: a, to: CGRect(x: 0, y: 0, width: 400, height: 600), others: ["c": c], bounds: bounds)
        #expect(down.maxY == bounds.maxY - minH - ShellPlacement.tileGap)
        let up = ShellState.limitForRoom(from: c, to: CGRect(x: 0, y: 0, width: 400, height: 610), others: ["a": a], bounds: bounds)
        #expect(up.minY == bounds.minY + minH + ShellPlacement.tileGap)
        #expect(up.maxY == c.maxY)
    }

    @Test("nothing in the way: the resize is not limited")
    func unlimited() {
        let grown = CGRect(x: 0, y: 0, width: 400, height: 600)
        #expect(ShellState.limitForRoom(from: a, to: grown, others: ["b": b], bounds: bounds) == grown)
    }

    @Test("a limited resize maps back to the drag that gives it, from any corner or side")
    func deltaInverse() {
        let f = CGRect(x: 100, y: 100, width: 300, height: 200)
        for (corner, d) in [(ShellTile.Corner.se, CGSize(width: 40, height: 30)), (.nw, CGSize(width: -20, height: -10)),
                            (.e, CGSize(width: 50, height: 0)), (.n, CGSize(width: 0, height: -25))] {
            let target = ShellTile.resized(f, corner: corner, by: d)
            #expect(ShellTile.delta(from: f, to: target, corner: corner) == d, "\(corner)")
        }
    }
}

@Suite("Make room uses the whole desktop")
@MainActor
struct MakeRoomBoundsTests {
    @Test("a pushed port may go down to the bottom of the space, beneath the dock, and to the folded rail")
    func wholeDesktop() {
        let area = CGSize(width: 1728, height: 1000)
        let b = ShellState.makeRoomBounds(in: area)
        #expect(b.maxY == area.height - ShellPlacement.tileGap, "it stopped above the dock")
        #expect(b.maxY > ShellPlacement.workArea(in: area).maxY)
        #expect(b.maxX == area.width - ShellState.railFoldedWidth - ShellPlacement.tileGap)
        #expect(b.minX == ShellPlacement.tileGap && b.minY == ShellPlacement.tileGap)
    }
}

/// Gordon, 2026-09-30: grow right past a port that sits below and to the right, then down into it: it
/// should go down, not pop to the right.
@Suite("Make room pushes a diagonal neighbor the way the drag went into it")
@MainActor
struct MakeRoomDiagonalTests {
    let a = CGRect(x: 0, y: 0, width: 400, height: 300)
    let diag = CGRect(x: 420, y: 320, width: 300, height: 200)       // below and to the right
    let wide = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    @Test("right past it, then down into it: it goes down")
    func rightThenDown() {
        let grown = CGRect(x: 0, y: 0, width: 600, height: 340)     // well past its left edge, just into its top
        let out = ShellState.makeRoom(from: a, to: grown, others: ["d": diag], bounds: wide)
        #expect(out["d"]?.minX == diag.minX, "it was pushed sideways: \(String(describing: out["d"]))")
        #expect(out["d"]?.minY == grown.maxY + ShellPlacement.tileGap)
    }

    @Test("down past it, then right into it: it goes right")
    func downThenRight() {
        let grown = CGRect(x: 0, y: 0, width: 440, height: 500)
        let out = ShellState.makeRoom(from: a, to: grown, others: ["d": diag], bounds: wide)
        #expect(out["d"]?.minY == diag.minY, "it was pushed down: \(String(describing: out["d"]))")
        #expect(out["d"]?.minX == grown.maxX + ShellPlacement.tileGap)
    }

    @Test("a neighbor only to the right is still pushed right")
    func straightRight() {
        let beside = CGRect(x: 410, y: 0, width: 300, height: 300)
        #expect(ShellState.pushSide(of: beside, from: a, to: CGRect(x: 0, y: 0, width: 500, height: 600)) == .right)
    }
}
