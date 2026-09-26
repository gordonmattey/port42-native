import Testing
import Foundation
@testable import Port42Lib

/// Parking places exactly (nautilus Phase 2 step 3): the rail keeps the order it is given, per
/// space, across a restart.
@Suite("Rail order")
@MainActor
struct RailOrderTests {

    func world() throws -> (AppState, DatabaseService, Space, Space) {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let a = Space.create(name: "a"), b = Space.create(name: "b")
        try db.saveSpace(a); try db.saveSpace(b)
        state.spaces = [a, b]; state.currentSpace = a
        for id in ["p1", "p2", "p3", "p4"] {
            state.portWindows.registerTiledPort(id: id, html: "<title>\(id)</title>", spaceId: a.id,
                                                createdBy: nil, title: id, position: nil)
        }
        state.portWindows.registerTiledPort(id: "b1", html: "<title>b1</title>", spaceId: b.id,
                                            createdBy: nil, title: "b1", position: nil)
        return (state, db, a, b)
    }

    @Test("a drop at slot 1 of 3 lands at slot 1; no slot appends")
    func parkAtSlot() throws {
        let (state, _, a, _) = try world()
        let pw = state.portWindows
        pw.park(id: "p1"); pw.park(id: "p2"); pw.park(id: "p3")
        #expect(pw.railIds(in: a.id) == ["p1", "p2", "p3"])
        pw.park(id: "p4", at: 1)
        #expect(pw.railIds(in: a.id) == ["p1", "p4", "p2", "p3"])
        withExtendedLifetime(state) {}
    }

    @Test("unparking closes the gap; a chip moves within the rail")
    func unparkAndReorder() throws {
        let (state, _, a, _) = try world()
        let pw = state.portWindows
        for id in ["p1", "p2", "p3"] { pw.park(id: id) }
        pw.unpark(id: "p2")
        #expect(pw.railIds(in: a.id) == ["p1", "p3"])
        #expect(pw.panels.first { $0.id == "p2" }?.railOrder == nil)
        pw.moveInRail(id: "p3", to: 0)
        #expect(pw.railIds(in: a.id) == ["p3", "p1"])
        withExtendedLifetime(state) {}
    }

    @Test("the rail order survives a restart")
    func survivesRestart() throws {
        let (state, db, a, _) = try world()
        for id in ["p1", "p2", "p3"] { state.portWindows.park(id: id) }
        state.portWindows.moveInRail(id: "p3", to: 0)
        let reborn = AppState(db: db)
        reborn.portWindows.restoreFromDB(appState: reborn)
        #expect(reborn.portWindows.railIds(in: a.id) == ["p3", "p1", "p2"])
        withExtendedLifetime(state) {}
        withExtendedLifetime(reborn) {}
    }

    @Test("each space keeps its own rail")
    func perSpace() throws {
        let (state, _, a, b) = try world()
        let pw = state.portWindows
        pw.park(id: "p1"); pw.park(id: "p2")
        pw.park(id: "b1", at: 0)
        #expect(pw.railIds(in: a.id) == ["p1", "p2"])
        #expect(pw.railIds(in: b.id) == ["b1"])
        withExtendedLifetime(state) {}
    }

    @Test("a point on the rail maps to a slot, clamped to the chips there")
    func slotForPoint() {
        let top = ShellState.railFirstChipTop, pitch = ShellState.railChipHeight + ShellState.railChipSpacing
        #expect(ShellState.railSlot(forY: top, count: 3) == 0)
        #expect(ShellState.railSlot(forY: top + pitch, count: 3) == 1)
        #expect(ShellState.railSlot(forY: top + 10 * pitch, count: 3) == 3, "below the chips appends")
        #expect(ShellState.railSlot(forY: 0, count: 3) == 0)
        #expect(PortWindowManager.railInserting("x", into: ["a", "b"], at: 99) == ["a", "b", "x"])
    }

    @Test("the drop gap sits before the chip it will precede, counting only the other chips")
    func gapIndex() {
        let ids = ["a", "b", "c"]
        #expect(ShellState.railGapIndex(ids: ids, dragging: nil, slot: 0) == 0)
        #expect(ShellState.railGapIndex(ids: ids, dragging: nil, slot: 3) == nil, "past the end: after the last")
        // Dragging "a" down to between b and c: slot 1 among [b, c] is c, drawn at index 2.
        #expect(ShellState.railGapIndex(ids: ids, dragging: "a", slot: 1) == 2)
        #expect(ShellState.railGapIndex(ids: ids, dragging: "a", slot: 2) == nil)
    }
}
