import Testing
import Foundation
import CoreGraphics
@testable import Port42Lib

/// v46 — a port on two desktops has a position on EACH.
///
/// A kept peek renders on its home space and on every space that adopted it, but `position` was one
/// `CGPoint?`, so a tile placed on one desktop moved on the other. Found by reading during the design
/// pass rather than by a bug report, which is why it is pinned here: the failure is invisible until
/// someone adopts a port and switches spaces, and by then the position is already wrong.
/// GM 2026-08-03: "we shouldn't have this."
@Suite("Per-desktop tile positions (v46)")
struct PerDesktopPositionTests {

    @MainActor
    private func makeAdoptedPort() throws -> (ShellState, AppState) {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let shell = ShellState(appState: state)
        state.spaces = [Space(id: "home", name: "home", type: "team", createdAt: Date()),
                        Space(id: "away", name: "away", type: "team", createdAt: Date())]
        state.currentSpace = state.spaces[0]
        state.portWindows.registerTiledPort(id: "p", html: "<div/>", spaceId: "home",
                                            createdBy: nil, title: "p", position: nil)
        state.portWindows.adopt(id: "p", into: "away")     // kept on the other desktop too
        return (shell, state)
    }

    @Test("a position written on one desktop does not move the tile on the other")
    @MainActor
    func positionsAreIndependent() throws {
        let (_, state) = try makeAdoptedPort()

        state.portWindows.updateTileFrame(id: "p", position: CGPoint(x: 100, y: 100), size: nil, on: "home")
        state.portWindows.updateTileFrame(id: "p", position: CGPoint(x: 900, y: 400), size: nil, on: "away")

        let panel = try #require(state.portWindows.panels.first { $0.id == "p" })
        #expect(panel.position(on: "home") == CGPoint(x: 100, y: 100))
        #expect(panel.position(on: "away") == CGPoint(x: 900, y: 400))
    }

    @Test("placing on a NEW desktop leaves the tile where it was on the old one")
    @MainActor
    func placingOnOneDesktopLeavesTheOther() throws {
        let (shell, state) = try makeAdoptedPort()
        let area = CGSize(width: 1728, height: 1035)
        shell.placeUnpositioned(area: area)                                  // placed on "home"
        let home = try #require(state.portWindows.panels.first { $0.id == "p" }?.position(on: "home"))

        state.currentSpace = state.spaces[1]                                 // walk to the other desktop
        shell.placeUnpositioned(area: area)                                  // it is unplaced HERE

        let panel = try #require(state.portWindows.panels.first { $0.id == "p" })
        #expect(panel.position(on: "home") == home, "the home desktop's position changed")
        #expect(panel.position(on: "away") != nil, "the adopted copy was never placed")
    }

    @Test("the home position is what a caller sees when no desktop is named")
    @MainActor
    func homeIsTheDefaultProjection() throws {
        let (_, state) = try makeAdoptedPort()
        state.portWindows.updateTileFrame(id: "p", position: CGPoint(x: 12, y: 34), size: nil, on: "home")
        state.portWindows.updateTileFrame(id: "p", position: CGPoint(x: 800, y: 500), size: nil, on: "away")

        let panel = try #require(state.portWindows.panels.first { $0.id == "p" })
        #expect(panel.position == CGPoint(x: 12, y: 34))          // `position` == the home space
        #expect(state.portWindows.portFrame(by: "p")?.origin == CGPoint(x: 12, y: 34))
        #expect(state.portWindows.portFrame(by: "p", on: "away")?.origin == CGPoint(x: 800, y: 500))
    }

    @Test("clearing the position unplaces the port on EVERY desktop")
    @MainActor
    func clearingUnplacesEverywhere() throws {
        let (_, state) = try makeAdoptedPort()
        state.portWindows.updateTileFrame(id: "p", position: CGPoint(x: 1, y: 1), size: nil, on: "home")
        state.portWindows.updateTileFrame(id: "p", position: CGPoint(x: 2, y: 2), size: nil, on: "away")

        guard let idx = state.portWindows.panels.firstIndex(where: { $0.id == "p" }) else { return }
        state.portWindows.panels[idx].position = nil                 // what the birth paths mean

        #expect(state.portWindows.panels[idx].positions.isEmpty)
    }

    @Test("both desktops' positions survive a save and restore")
    @MainActor
    func positionsRoundTripThroughTheDatabase() throws {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        state.currentSpace = Space(id: "home", name: "home", type: "team", createdAt: Date())
        state.portWindows.setDatabase(db)
        state.portWindows.registerTiledPort(id: "p", html: "<div/>", spaceId: "home",
                                            createdBy: nil, title: "p", position: nil)
        state.portWindows.adopt(id: "p", into: "away")
        state.portWindows.updateTileFrame(id: "p", position: CGPoint(x: 100, y: 100), size: nil, on: "home")
        state.portWindows.updateTileFrame(id: "p", position: CGPoint(x: 900, y: 400), size: nil, on: "away")

        let fresh = PortWindowManager()
        fresh.setDatabase(db)
        fresh.restoreFromDB(appState: state)

        let panel = try #require(fresh.panels.first { $0.id == "p" })
        #expect(panel.position(on: "home") == CGPoint(x: 100, y: 100))
        #expect(panel.position(on: "away") == CGPoint(x: 900, y: 400))
    }

    @Test("a pre-v46 row (posX/posY, no map) restores onto its home desktop")
    @MainActor
    func legacyRowRestoresAsHomePosition() throws {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        state.currentSpace = Space(id: "home", name: "home", type: "team", createdAt: Date())
        state.portWindows.setDatabase(db)
        state.portWindows.registerTiledPort(id: "p", html: "<div/>", spaceId: "home",
                                            createdBy: nil, title: "p", position: nil)
        state.portWindows.updateTileFrame(id: "p", position: CGPoint(x: 55, y: 66), size: nil, on: "home")

        // Simulate the upgrade case the migration handles: the pair is there, the map is not.
        var row = try #require(try db.fetchPortPanels().first)
        row.positions = nil
        try db.savePortPanel(row)

        let fresh = PortWindowManager()
        fresh.setDatabase(db)
        fresh.restoreFromDB(appState: state)

        #expect(fresh.panels.first { $0.id == "p" }?.position(on: "home") == CGPoint(x: 55, y: 66))
    }
}
