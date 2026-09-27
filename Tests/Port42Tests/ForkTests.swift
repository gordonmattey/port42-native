import Testing
import Foundation
@testable import Port42Lib

/// Nautilus Phase 4, step 4.6b: fork. A copy of a port becomes a new port of this instance, independent
/// of the original. A port someone shared is copied only when they allowed it (Gordon, option A: their
/// leave, honoured by Port42, not a lock).
@Suite("Fork (Phase 4, 4.6b)")
@MainActor
struct ForkTests {

    func here(_ state: AppState) throws {
        let space = Space.create(name: "here")
        try state.db.saveSpace(space)
        state.spaces = [space]
        state.currentSpace = space
    }

    @Test("forking your own port makes an independent copy beside it")
    func localFork() async throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        try here(state)
        _ = state.portWindows.registerTiledPort(id: "o", html: "<p>original</p>", spaceId: state.currentSpace?.id,
                                                createdBy: "author-1", title: "chart", position: nil)
        let copy = try await state.forkPort("o")
        let panel = try #require(state.portWindows.panels.first { $0.id == copy })
        #expect(panel.id != "o" && panel.title == "chart (copy)")
        #expect(panel.html == "<p>original</p>")
        _ = await state.portWindows.updatePort(idOrTitle: "o", html: "<p>changed</p>")
        #expect(state.portWindows.panels.first { $0.id == copy }?.html == "<p>original</p>", "the copy followed the original")
    }

    @Test("a shared port is forked only when its sharer allowed a copy")
    func remoteFork() async throws {
        let rt = RemoteTileTests()
        var allowed = ["see", "use"]
        let (state, gw) = try rt.world()
        try here(state)
        gw.reply = { method, _ in
            switch method {
            case "invite.redeem": return [RemotePortTests.response(["port": "P", "title": "shared chart", "rights": allowed])]
            case "port.getHtml": return [RemotePortTests.response("<p>theirs</p>")]
            case "port.subscribe": return []
            default: return [["type": "error", "code": "transport_failed", "error": "unscripted \(method)"]]
            }
        }
        let tile = try await rt.accept(state)
        let before = state.portWindows.panels.count
        do { _ = try await state.forkPort(tile); Issue.record("a port was copied without leave") }
        catch let e as BridgeError { #expect(e.code == "not_granted") }
        #expect(state.portWindows.panels.count == before, "a copy was made anyway")
        state.leaveRemotePort(tile: tile)

        allowed = ["see", "use", "fork"]
        let tile2 = try await rt.accept(state)
        let copy = try await state.forkPort(tile2)
        let panel = try #require(state.portWindows.panels.first { $0.id == copy })
        #expect(panel.html == "<p>theirs</p>" && panel.title == "shared chart (copy)")
        #expect(state.mirroredRemote(copy) == nil, "the copy is still theirs")
        state.leaveRemotePort(tile: tile2)
    }
}
