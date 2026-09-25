import Testing
import Foundation
@testable import Port42Lib

/// ⌘L and the re-grid behind it are gone (nautilus Phase 2 step 1, GM 2026-09-25): a birth places
/// without moving anything and off-screen ports are clamped back, so a re-grid could only overwrite
/// positions the person chose. This gate fails if any path that re-grids comes back.
@Suite("No re-grid")
struct NoRegridTests {

    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    @Test("no source re-grids the desktop")
    func noRegridInSource() throws {
        var hits: [String] = []
        let files = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for needle in ["applyArrange", "bumpArrange", "arrangeBump", "ArrangeTile"] where text.contains(needle) {
                hits.append("\(url.lastPathComponent): \(needle)")
            }
        }
        #expect(hits.isEmpty, "a re-grid path is back: \(hits)")
    }

    @Test("⌘L is no longer a shell chord")
    func cmdLIsNotAChord() {
        #expect(ShellState.shellGlobalChord(keyCode: 37, characters: "l", command: true, shift: false,
                                            option: false, control: false) == nil)
    }

    @MainActor
    @Test("placing a new port moves no port that already has a spot")
    func placingMovesNothing() throws {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let shell = ShellState(appState: state)
        let space = Space.create(name: "main")
        state.spaces = [space]; state.currentSpace = space
        let area = CGSize(width: 1600, height: 1000)
        _ = state.portWindows.registerTiledPort(id: "a", html: "<title>a</title>", spaceId: space.id,
                                                createdBy: nil, title: "a", position: CGPoint(x: 400, y: 300))
        _ = state.portWindows.registerTiledPort(id: "b", html: "<title>b</title>", spaceId: space.id,
                                                createdBy: nil, title: "b", position: nil)
        shell.placeUnpositioned(area: area)
        let a = state.portWindows.panels.first { $0.id == "a" }?.position(on: space.id)
        let b = state.portWindows.panels.first { $0.id == "b" }?.position(on: space.id)
        #expect(a == CGPoint(x: 400, y: 300), "the placed port must not move")
        #expect(b != nil, "the new port gets a spot")
        withExtendedLifetime(state) {}
    }
}
