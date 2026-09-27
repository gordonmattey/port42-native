import Testing
import Foundation
import CoreGraphics
@testable import Port42Lib

/// Pinning a port (GM, 2026-09-27): in its space it stays above the other tiles; in every space it
/// shows on every desktop, above the others, at one position.
@Suite("Pinning ports")
@MainActor
struct PortPinTests {

    func world() throws -> (ShellState, AppState, DatabaseService) {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let shell = ShellState(appState: state)
        state.spaces = [Space(id: "home", name: "home", type: "team", createdAt: Date()),
                        Space(id: "away", name: "away", type: "team", createdAt: Date())]
        state.currentSpace = state.spaces[0]
        state.portWindows.setDatabase(db)
        for id in ["a", "b", "c"] {
            state.portWindows.registerTiledPort(id: id, html: "<div/>", spaceId: "home", createdBy: nil, title: id, position: nil)
        }
        return (shell, state, db)
    }

    @Test("a pinned tile paints above unpinned ones, however recently they were raised")
    func stacking() throws {
        let (_, state, _) = try world()
        state.portWindows.setZ(id: "a", z: 1)
        state.portWindows.setZ(id: "b", z: 50)
        state.portWindows.setZ(id: "c", z: 9_999)
        state.portWindows.setPin(id: "a", .space)
        let rank = ShellState.stackRank(state.portWindows.panels)
        #expect(rank["a"]! > rank["c"]! && rank["c"]! > rank["b"]!)
        #expect(rank.values.max() == 3, "a rank, so tiles never climb over the shell's own layers")
    }

    @Test("pinned in every space: on every desktop, at one position; unpinned: home only")
    func everywhere() throws {
        let (shell, state, _) = try world()
        state.portWindows.updateTileFrame(id: "a", position: CGPoint(x: 120, y: 80), size: nil, on: "home")
        state.portWindows.setPin(id: "a", .everywhere)
        state.currentSpace = state.spaces[1]
        #expect(shell.desktopTilePanels.map(\.id) == ["a"])
        // Moving it on another desktop moves it everywhere.
        state.portWindows.updateTileFrame(id: "a", position: CGPoint(x: 400, y: 300), size: nil, on: "away")
        let a = try #require(state.portWindows.panels.first { $0.id == "a" })
        #expect(a.position(on: "home") == CGPoint(x: 400, y: 300))
        #expect(a.isAlwaysOnTop, "pinned everywhere is pinned")
        state.portWindows.setPin(id: "a", .none)
        #expect(shell.desktopTilePanels.isEmpty)
    }

    @Test("pins survive a restart")
    func persisted() throws {
        let (_, state, db) = try world()
        state.portWindows.setPin(id: "a", .space)
        state.portWindows.setPin(id: "b", .everywhere)
        let fresh = PortWindowManager()
        fresh.setDatabase(db)
        fresh.restoreFromDB(appState: state)
        #expect(fresh.panels.first { $0.id == "a" }?.pin == .space)
        #expect(fresh.panels.first { $0.id == "b" }?.pin == .everywhere)
        #expect(fresh.panels.first { $0.id == "c" }?.pin == PortPin.none)
    }

    @Test("port.manage pins, pins everywhere and unpins")
    func api() async throws {
        let (_, state, _) = try world()
        let udid = try #require(state.portWindows.panels.first { $0.id == "a" }?.udid)
        // A write carries the port's token: take the current one from the refusal, as a caller would.
        func manage(_ action: String) async throws {
            let call = { (args: [String: Any]) in
                try await state.runBridgeMethod("port.manage", principal: .peer(id: "t", displayName: "t"), args: BridgeArgs(args))
            }
            do { _ = try await call(["id": udid, "action": action]) }
            catch let e as BridgeError where e.code == "token_required" || e.code == "stale_write" {
                let current = try #require(e.details["current"])
                _ = try await call(["id": udid, "action": action, "token": current])
            }
        }
        try await manage("pinEverywhere")
        #expect(state.portWindows.panels.first { $0.id == "a" }?.pin == .everywhere)
        try await manage("pin")
        #expect(state.portWindows.panels.first { $0.id == "a" }?.pin == .space)
        try await manage("unpin")
        #expect(state.portWindows.panels.first { $0.id == "a" }?.pin == PortPin.none)
    }
}
