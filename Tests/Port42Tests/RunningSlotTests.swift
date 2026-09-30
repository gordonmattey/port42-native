import Testing
import Foundation
@testable import Port42Lib

/// Dragging a tile onto Running lets you choose its place among the cards (GM, 2026-09-29).
@Suite("Running cards keep an order and take a slot")
@MainActor
struct RunningSlotTests {

    @Test("a port hidden at a slot lands there; one shown again closes the gap")
    func order() throws {
        let w = try makeParityWorld()
        let pw = w.state.portWindows
        for id in ["a", "b", "c", "d"] {
            pw.registerTiledPort(id: id, html: "<title>\(id)</title>", spaceId: w.space.id, createdBy: nil,
                                 title: id, position: CGPoint(x: 40, y: 40))
        }
        pw.minimize("a"); pw.minimize("b"); pw.minimize("c")
        #expect(pw.hiddenPanels(in: w.space.id).map(\.id) == ["a", "b", "c"])
        pw.minimize("d", at: 1)
        #expect(pw.hiddenPanels(in: w.space.id).map(\.id) == ["a", "d", "b", "c"], "dropped between a and b")
        _ = pw.restore("d")
        #expect(pw.hiddenPanels(in: w.space.id).map(\.id) == ["a", "b", "c"])
        #expect(pw.panels.first { $0.id == "d" }?.railOrder == nil, "a shown port holds no slot")
    }

    @Test("a point maps to a slot below Paused and the Running header, open or folded")
    func slotForPoint() {
        let pitch = ShellState.railCardHeight + ShellState.railCardSpacing
        let top = ShellState.parkZoneHeight + ShellState.railHeaderHeight
        #expect(ShellState.runningSlot(forY: top, pausedHeight: 0, count: 3) == 0)
        #expect(ShellState.runningSlot(forY: top + pitch, pausedHeight: 0, count: 3) == 1)
        #expect(ShellState.runningSlot(forY: top + 10 * pitch, pausedHeight: 0, count: 3) == 3, "past the last: after it")
        let open = ShellState.pausedCardsHeight(open: true, count: 2)
        #expect(ShellState.runningSlot(forY: top + open + pitch, pausedHeight: open, count: 3) == 1,
                "an open Paused section pushes the cards down")
    }

    @Test("with Paused open, its cards are a drop zone for pausing, not for hiding")
    func openPausedIsPark() {
        let area = CGSize(width: 1440, height: 900)
        let open = ShellState.pausedCardsHeight(open: true, count: 2)
        let y = ShellState.parkZoneHeight + open / 2
        #expect(ShellState.parkZone(at: CGPoint(x: area.width - 5, y: y), in: area, pausedHeight: open) == .park)
        #expect(ShellState.parkZone(at: CGPoint(x: area.width - 5, y: y), in: area) == .hide, "folded, that point is Running")
    }
}
