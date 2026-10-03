import Testing
import Foundation
import AppKit
@testable import Port42Lib

/// **A ⇧ resize snaps the port it touches** (#251, Gordon): "if you touch the edge of a window it should
/// snap the window you touch width wise too and you can press command to unsnap it". A snapped port keeps
/// its far edge and gives up width (or height) to stay one gap from the edge being dragged, and follows
/// it back. ⇧⌘ is the unsnapped make-room: the port slides at its own size, as #196 built.
@Suite("Resize snaps the port it touches (#251)")
@MainActor
struct ResizeSnapTests {
    let a = CGRect(x: 0, y: 0, width: 400, height: 300)
    let b = CGRect(x: 410, y: 0, width: 400, height: 300)          // right of a, its far edge at 810
    let c = CGRect(x: 0, y: 310, width: 400, height: 300)          // below a
    let bounds = CGRect(x: 0, y: 0, width: 1200, height: 900)

    @Test("⇧ snaps, ⇧⌘ unsnaps, no ⇧ makes no room")
    func modifiers() {
        #expect(ShellState.resizeSnaps([.shift]))
        #expect(!ShellState.resizeSnaps([.shift, .command]) && ShellState.resizeMakesRoom([.shift, .command]))
        #expect(!ShellState.resizeSnaps([]) && !ShellState.resizeMakesRoom([]))
    }

    @Test("growing into a neighbor: snapped, it gives up width and keeps its far edge; unsnapped, it slides")
    func growInto() {
        let grown = CGRect(x: 0, y: 0, width: 550, height: 300)
        let snapped = ShellState.makeRoom(from: a, to: grown, others: ["b": b], bounds: bounds, snap: true)
        #expect(snapped["b"] == CGRect(x: 558, y: 0, width: 252, height: 300), "the touched port did not snap width-wise")
        let slid = ShellState.makeRoom(from: a, to: grown, others: ["b": b], bounds: bounds, snap: false)
        #expect(slid["b"] == CGRect(x: 558, y: 0, width: 400, height: 300), "⌘ did not unsnap: the port should slide at its own size")
    }

    @Test("a joined neighbor follows the edge back: shrinking the port grows the snapped one")
    func followsBack() {
        let shrunk = CGRect(x: 0, y: 0, width: 300, height: 300)
        let out = ShellState.makeRoom(from: a, to: shrunk, others: ["b": b], bounds: bounds, snap: true)
        #expect(out["b"] == CGRect(x: 308, y: 0, width: 502, height: 300))
        #expect(ShellState.makeRoom(from: a, to: shrunk, others: ["b": b], bounds: bounds, snap: false).isEmpty)
    }

    @Test("height-wise below; a port too small to give more slides at its smallest; one far away is left")
    func belowSmallestAndFar() {
        let taller = CGRect(x: 0, y: 0, width: 400, height: 400)
        #expect(ShellState.makeRoom(from: a, to: taller, others: ["c": c], bounds: bounds, snap: true)["c"]
                == CGRect(x: 0, y: 408, width: 400, height: 202))
        let wide = CGRect(x: 0, y: 0, width: 700, height: 300)       // b would keep only 102 points
        let out = ShellState.makeRoom(from: a, to: wide, others: ["b": b], bounds: bounds, snap: true)
        #expect(out["b"]?.minX == 708 && out["b"]?.width == 400, "a port below its smallest should slide, not shrink")
        let far = CGRect(x: 700, y: 0, width: 300, height: 300)
        #expect(ShellState.makeRoom(from: a, to: CGRect(x: 0, y: 0, width: 300, height: 300),
                                    others: ["far": far], bounds: bounds, snap: true).isEmpty)
    }

    // Gordon's follow-up: lined-up edges follow, and ⇧ while moving does the same.

    @Test("dragging a bottom edge down: the port beside it whose bottom was level follows, and the row below keeps its gap")
    func linedUpEdgesFollow() {
        let d = CGRect(x: 410, y: 310, width: 400, height: 300)       // the grid's fourth, below b
        let taller = CGRect(x: 0, y: 0, width: 400, height: 400)
        let out = ShellState.makeRoom(from: a, to: taller, others: ["b": b, "c": c, "d": d], bounds: bounds, snap: true)
        #expect(out["b"] == CGRect(x: 410, y: 0, width: 400, height: 400), "b's level bottom did not follow")
        #expect(out["c"] == CGRect(x: 0, y: 408, width: 400, height: 202))
        #expect(out["d"] == CGRect(x: 410, y: 408, width: 400, height: 202), "the row below b did not keep its gap")
        // ⌘ (unsnapped): nothing lined up moves; only c, which it covers, slides.
        let slid = ShellState.makeRoom(from: a, to: taller, others: ["b": b, "c": c, "d": d], bounds: bounds, snap: false)
        #expect(slid["b"] == nil && slid["d"] == nil && slid["c"]?.height == 300)
        // A port level with it but across the desktop, joined to nothing, stays.
        let far = CGRect(x: 1000, y: 0, width: 150, height: 300)
        #expect(ShellState.makeRoom(from: a, to: taller, others: ["far": far], bounds: bounds, snap: true).isEmpty)
    }

    @Test("⇧ moving carries the ports joined to it; one it runs into snaps; ⌘ moves it alone and slides; the move stops at the edge")
    func shiftMove() {
        // b is joined to a (10 points away): it moves with a, either way a goes.
        let moved = a.offsetBy(dx: 150, dy: 40)
        #expect(ShellState.makeRoom(from: a, to: moved, others: ["b": b], bounds: bounds, snap: true, moving: true)["b"]
                == b.offsetBy(dx: 150, dy: 40), "the port next to it did not move with it")
        #expect(ShellState.makeRoom(from: a, to: a.offsetBy(dx: 0, dy: 100), others: ["c": c], bounds: bounds, snap: true, moving: true)["c"]
                == c.offsetBy(dx: 0, dy: 100), "the port below it did not move with it")
        // A port across a gap is not joined: run into, it snaps, keeping its far edge.
        let e = CGRect(x: 600, y: 0, width: 400, height: 300)
        let into = a.offsetBy(dx: 300, dy: 0)
        #expect(ShellState.makeRoom(from: a, to: into, others: ["e": e], bounds: bounds, snap: true, moving: true)["e"]
                == CGRect(x: 708, y: 0, width: 292, height: 300), "a moved port did not snap what it ran into")
        // ⌘: nothing is carried, and what it runs into slides at its own size.
        #expect(ShellState.makeRoom(from: a, to: moved, others: ["b": b], bounds: bounds, snap: false, moving: true)["b"]
                == CGRect(x: 558, y: 0, width: 400, height: 300))
        // The move stops before the carried group or a pushed port leaves the desktop.
        let tight = CGRect(x: 0, y: 0, width: 1000, height: 900)
        #expect(ShellState.limitForMove(from: a, to: a.offsetBy(dx: 500, dy: 0), others: ["b": b], bounds: tight).minX == 190,
                "the move carried b off the screen")
        let stopped = ShellState.limitForMove(from: a, to: a.offsetBy(dx: 500, dy: 0), others: ["e": e], bounds: tight)
        #expect(stopped.minX == 1000 - ShellState.makeRoomMin.width - 8 - a.width, "a ⇧ move pushed a port off the screen")
    }

    @Test("a port moved clear of the one it was over, next to another, then given ⇧: that one moves with it")
    func shiftFromWhereItIs() {
        let start = CGRect(x: 420, y: 0, width: 400, height: 300)       // picked up on top of b
        let clear = CGRect(x: 0, y: 0, width: 400, height: 300)         // moved into free space beside b, then ⇧
        let on = clear.offsetBy(dx: 0, dy: 80)
        // Measured from the drag's start, b was underneath: the person's own layout, left alone.
        #expect(ShellState.makeRoom(from: start, to: on, others: ["b": b], bounds: bounds, snap: true, moving: true).isEmpty)
        // From where ⇧ went down, b is next to it, and moves with it.
        #expect(ShellState.makeRoom(from: clear, to: on, others: ["b": b], bounds: bounds, snap: true, moving: true)["b"]
                == b.offsetBy(dx: 0, dy: 80))
    }

    @Test("a port that started over another, pulled clear, then given ⇧: its edge pushes that one (from where ⇧ went down)")
    func resizeFromWhereItIs() {
        let start = CGRect(x: 300, y: 0, width: 400, height: 300)      // its left edge over a (a ends at 400)
        let clear = CGRect(x: 420, y: 0, width: 280, height: 300)      // left edge pulled clear, then ⇧ down
        let back = CGRect(x: 320, y: 0, width: 380, height: 300)       // and dragged back over a
        // From the drag's start a was underneath: left alone, and the edge goes over it.
        #expect(ShellState.makeRoom(from: start, to: back, others: ["a": a], bounds: bounds, snap: true).isEmpty)
        // From where ⇧ went down, a is a neighbor: it snaps, keeping its far edge.
        #expect(ShellState.makeRoom(from: clear, to: back, others: ["a": a], bounds: bounds, snap: true)["a"]
                == CGRect(x: 0, y: 0, width: 312, height: 300), "⇧ did nothing: the edge went over the port below")
    }
}
