import Testing
import Foundation
import CoreGraphics
@testable import Port42Lib

/// The gate for Phase 1 of "the desktop rearranges itself".
///
/// GM, twice, in his own words: "adding ports does too much rearranging", and later, watching a
/// fourth tile arrive, "it moved a tile from the left side of the screen to the right side, why?"
/// The answer was that a birth called `applyArrange`, which re-computed every tile's origin from
/// scratch and dealt cells by `z`, so the tile he had touched most recently was thrown furthest.
///
/// This suite pins the property that replaces it: **a birth moves nothing that already has a
/// position.** It runs the real `ShellState` against a real (in-memory) store, so it fails if the
/// wiring regresses even when `place` itself is still correct.
@Suite("A spawn places, it does not rearrange")
struct SpawnMovesNothingTests {

    @MainActor
    private func makeDesktop(tiles: Int) throws -> (ShellState, AppState, CGSize) {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let shell = ShellState(appState: state)
        state.currentSpace = Space(id: "s1", name: "s", type: "team", createdAt: Date())
        for i in 0..<tiles {
            state.portWindows.registerTiledPort(id: "t\(i)", html: "<div/>", spaceId: "s1",
                                                createdBy: nil, title: "t\(i)", position: nil)
        }
        let area = CGSize(width: 1728, height: 1035)
        shell.placeUnpositioned(area: area)
        return (shell, state, area)
    }

    @MainActor
    private func positions(_ state: AppState) -> [String: CGPoint] {
        Dictionary(uniqueKeysWithValues: state.portWindows.panels.compactMap { p in
            p.position.map { (p.id, $0) }
        })
    }

    @Test("placing gives every unplaced tile a spot, and they do not overlap")
    @MainActor
    func placesEveryUnpositionedTile() throws {
        let (_, state, _) = try makeDesktop(tiles: 4)
        let frames = state.portWindows.panels.compactMap { p in p.position.map { CGRect(origin: $0, size: p.size) } }

        #expect(frames.count == 4)
        for i in 0..<frames.count { for j in (i + 1)..<frames.count {
            #expect(!frames[i].intersects(frames[j]))
        } }
    }

    @Test("a spawn moves NO existing tile — the whole point of Phase 1")
    @MainActor
    func spawnMovesNothing() throws {
        let (shell, state, area) = try makeDesktop(tiles: 3)
        let before = positions(state)
        #expect(before.count == 3)

        state.portWindows.registerTiledPort(id: "new", html: "<div/>", spaceId: "s1",
                                            createdBy: nil, title: "new", position: nil)
        shell.placeUnpositioned(area: area)

        let after = positions(state)
        #expect(after.count == 4)                          // the newborn got a spot
        for (id, p) in before {
            #expect(after[id] == p, "tile \(id) moved on a spawn: \(p) → \(String(describing: after[id]))")
        }
    }

    @Test("a HAND-PLACED tile survives a spawn, wherever the user put it")
    @MainActor
    func handPlacedTileSurvivesASpawn() throws {
        let (shell, state, area) = try makeDesktop(tiles: 3)
        // GM's exact case: a tile dragged to the left edge, then a fourth port spawned.
        let hand = CGPoint(x: 147, y: 520)
        state.portWindows.updateTileFrame(id: "t0", position: hand, size: nil)
        state.portWindows.setZ(id: "t0", z: 999)           // dragging brings it to front — the old trigger

        state.portWindows.registerTiledPort(id: "new", html: "<div/>", spaceId: "s1",
                                            createdBy: nil, title: "new", position: nil)
        shell.placeUnpositioned(area: area)

        #expect(state.portWindows.panels.first { $0.id == "t0" }?.position == hand)
    }

    @Test("closing a tile leaves a hole — the survivors do not re-flow")
    @MainActor
    func closeLeavesAHole() throws {
        let (shell, state, area) = try makeDesktop(tiles: 4)
        let before = positions(state)

        state.portWindows.close("t1")
        shell.placeUnpositioned(area: area)                // what the count change now calls

        let after = positions(state)
        #expect(after["t1"] == nil)
        for id in ["t0", "t2", "t3"] {
            #expect(after[id] == before[id], "tile \(id) moved when a sibling closed")
        }
    }

    @Test("placing twice is idempotent — a placed tile is never re-placed")
    @MainActor
    func placingIsIdempotent() throws {
        let (shell, state, area) = try makeDesktop(tiles: 3)
        let before = positions(state)
        shell.placeUnpositioned(area: area)
        shell.placeUnpositioned(area: area)
        #expect(positions(state) == before)
    }

    @Test("a tile stranded by a smaller window is clamped back into reach, and only that tile")
    @MainActor
    func clampRescuesOnlyTheStranded() throws {
        let (shell, state, _) = try makeDesktop(tiles: 3)
        let small = CGSize(width: 900, height: 700)
        // Strand one tile beyond the smaller window, leave the others alone.
        state.portWindows.updateTileFrame(id: "t2", position: CGPoint(x: 1500, y: 60), size: nil)
        let before = positions(state)

        shell.clampTilesIntoView(area: small)

        let after = positions(state)
        let work = ShellPlacement.workArea(in: small)
        let t2 = try #require(after["t2"])
        #expect(work.contains(CGRect(origin: t2, size: ShellPlacement.defaultTileSize)) || t2.x < 1500)
        #expect(after["t0"] == before["t0"])              // in view, so untouched
        #expect(after["t1"] == before["t1"])
    }
}
