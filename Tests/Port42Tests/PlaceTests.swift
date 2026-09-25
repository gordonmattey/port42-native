import Testing
import Foundation
import CoreGraphics
@testable import Port42Lib

/// Phase 1 of "the desktop rearranges itself": a birth PLACES, it does not re-grid.
///
/// `place` is the half the layout subsystem never had. `arrange` computes every origin from scratch
/// and reads no existing position, so adding one tile moved every tile. `place` reads occupancy and
/// writes exactly one origin. Pure, so all of this is headless.
@Suite("place — one tile, nothing else moves")
struct PlaceTests {

    let area = CGSize(width: 1728, height: 1035)
    var bounds: CGRect { ShellPlacement.workArea(in: area) }
    let tile = CGSize(width: 620, height: 440)

    func rect(_ p: CGPoint, _ s: CGSize) -> CGRect { CGRect(origin: p, size: s) }

    // MARK: work area

    @Test("the work area starts 8pt in, not 70 — the top inset was dead space")
    func workAreaHugsTheEdges() {
        let w = ShellPlacement.workArea(in: area)
        #expect(w.minX == 8)
        #expect(w.minY == 8)                                        // was 70: the desktop already starts under the Chrome
        #expect(w.maxX == area.width - ShellState.parkWidth(area.width) - 8)   // the park rail is a live target
        #expect(w.maxY == area.height - ShellPlacement.dockClearance)          // the dock is a real overlay
    }

    @Test("a tiny window still yields a usable work area rather than a negative one")
    func workAreaNeverInverts() {
        let w = ShellPlacement.workArea(in: CGSize(width: 200, height: 150))
        #expect(w.width >= ShellState.minTileSize.width)
        #expect(w.height >= ShellState.minTileSize.height)
    }

    // MARK: placement

    @Test("on an empty desktop the tile lands inside the work area")
    func emptyDesktop() {
        let p = ShellPlacement.place(tile, among: [], in: area)
        #expect(bounds.contains(rect(p, tile)))
    }

    @Test("with one tile present the newcomer overlaps nothing and keeps the 8pt gap")
    func avoidsTheExistingTile() {
        let existing = CGRect(x: 8, y: 8, width: 620, height: 440)
        let p = ShellPlacement.place(tile, among: [existing], in: area)
        let placed = rect(p, tile)

        #expect(!placed.intersects(existing))
        #expect(bounds.contains(placed))
        // The gap is real, not a shared edge: inflating the existing tile by the gap still misses.
        #expect(!placed.intersects(existing.insetBy(dx: -ShellPlacement.tileGap + 0.5, dy: -ShellPlacement.tileGap + 0.5)))
    }

    @Test("it finds the ONE hole in a wall of tiles")
    func findsTheHole() {
        // Four cells; three taken, so the only gap that fits is the bottom-right.
        let w: CGFloat = 620, h: CGFloat = 440
        let occupied = [
            CGRect(x: 8, y: 8, width: w, height: h),
            CGRect(x: 8 + w + 16, y: 8, width: w, height: h),
            CGRect(x: 8, y: 8 + h + 16, width: w, height: h),
        ]
        let p = ShellPlacement.place(CGSize(width: 400, height: 300), among: occupied, in: area)
        let placed = rect(p, CGSize(width: 400, height: 300))

        for o in occupied { #expect(!placed.intersects(o)) }
        #expect(placed.minX > 8 + w)          // the remaining column
        #expect(placed.minY > 8 + h)          // the remaining row
    }

    @Test("consecutive births on a FULL desktop stagger — they never stack on the same corner")
    func cascadeStaggersOnAFullDesktop() {
        // Measured on Dev2 before this: three births in a row each landed at exactly (8,8), one
        // directly on top of another, title bars coincident and so ungrabbable.
        var occupied = [bounds]                       // one tile filling the work area: nothing fits
        var seen: [CGPoint] = []
        for _ in 0..<4 {
            let p = ShellPlacement.place(tile, among: occupied, in: area)
            #expect(!seen.contains(p), "a birth landed exactly on a previous one at \(p)")
            seen.append(p)
            occupied.append(rect(p, tile))
        }
    }

    @Test("nothing fits: it cascades ON TOP and moves nothing")
    func cascadesWhenFull() {
        // One tile the size of the whole work area leaves no gap at all.
        let full = bounds
        let before = [full]
        let p = ShellPlacement.place(tile, among: before, in: area)
        let placed = rect(p, tile)

        #expect(placed.intersects(full))                 // deliberately on top
        #expect(bounds.contains(placed))                 // but still reachable
        #expect(before == [full])                        // the input is untouched (value type, pinned anyway)
        #expect(p.x > full.minX && p.y > full.minY)      // staggered off the frontmost, not stacked exactly
    }

    @Test("placement is deterministic — same inputs, same origin, every time")
    func deterministic() {
        let occupied = [CGRect(x: 8, y: 8, width: 400, height: 300),
                        CGRect(x: 900, y: 500, width: 300, height: 200)]
        let first = ShellPlacement.place(tile, among: occupied, in: area)
        for _ in 0..<5 {
            #expect(ShellPlacement.place(tile, among: occupied, in: area) == first)
        }
    }

    @Test("two births in a row do not land on each other")
    func consecutiveBirthsDoNotCollide() {
        var occupied: [CGRect] = []
        var placed: [CGRect] = []
        for _ in 0..<4 {
            let p = ShellPlacement.place(tile, among: occupied, in: area)
            let r = rect(p, tile)
            for prior in placed { #expect(!r.intersects(prior)) }
            placed.append(r)
            occupied.append(r)
        }
    }

    @Test("the largest gap wins, not the first one that fits")
    func picksTheLargestGap() {
        // A tall blocker down the middle leaves a narrow left strip and a wide right one. First-fit
        // in reading order would take the left; largest-gap must take the right.
        let blocker = CGRect(x: 8 + 340, y: 8, width: 40, height: bounds.height)
        let small = CGSize(width: 300, height: 300)
        let p = ShellPlacement.place(small, among: [blocker], in: area)
        #expect(p.x > blocker.maxX)
    }

    @Test("a placed tile never lands under the dock or behind the park rail")
    func respectsTheFurniture() {
        for n in 0..<6 {
            let occupied = (0..<n).map { CGRect(x: 8 + CGFloat($0) * 40, y: 8, width: 620, height: 440) }
            let p = ShellPlacement.place(tile, among: occupied, in: area)
            let placed = rect(p, tile)
            #expect(placed.maxY <= area.height - ShellPlacement.dockClearance)
            #expect(placed.maxX <= area.width - ShellState.parkWidth(area.width) - 8)
        }
    }
}
