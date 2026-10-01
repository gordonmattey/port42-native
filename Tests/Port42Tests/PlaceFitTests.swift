import Testing
import Foundation
@testable import Port42Lib

/// Gordon, 2026-09-30: a new port should find the best space it can, and go smaller if it has to.
@Suite("A new port finds the best space, smaller if it must")
@MainActor
struct PlaceFitTests {
    let area = CGSize(width: 1400, height: 900)
    let size = ShellPlacement.defaultTileSize

    @Test("a gap that holds it: its own size, in the largest gap")
    func fits() {
        let r = ShellPlacement.placeRect(size, among: [], in: area)
        #expect(r.size == size)
    }

    @Test("no gap holds it: it shrinks into the largest gap there is, instead of landing on top")
    func shrinksIntoTheGap() {
        let work = ShellPlacement.workArea(in: area)
        // Everything taken but a 400 x 300 hole on the right.
        let left = CGRect(x: work.minX, y: work.minY, width: work.width - 400 - ShellPlacement.tileGap, height: work.height)
        let r = ShellPlacement.placeRect(size, among: [left], in: area)
        #expect(r.width < size.width && r.width >= ShellPlacement.fitMinimum.width, "it did not shrink to fit: \(r)")
        for o in [left] { #expect(!r.intersects(o), "it landed on a port: \(r)") }
        #expect(r.maxX <= work.maxX && r.maxY <= work.maxY, "it went off the desktop: \(r)")
    }

    @Test("no room even at the smallest: on top of the others, at its own size")
    func cascades() {
        let work = ShellPlacement.workArea(in: area)
        let r = ShellPlacement.placeRect(size, among: [work], in: area)
        #expect(r.size == size)
    }
}
