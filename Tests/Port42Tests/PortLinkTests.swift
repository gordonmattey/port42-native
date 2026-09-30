import Testing
import Foundation
@testable import Port42Lib

// #213: a port42:// link to a port, clicked in another port, did nothing. The navigation blocker
// cancelled it (a port may only load its own document) and the deep-link handler logged port
// addresses as unhandled. A clicked port link now goes to the deep-link handler, which takes the
// person to the port: its space, back on the desktop, in front and in focus.

@Suite("Port links (#213)")
struct PortLinkTests {

    @MainActor
    private func makeWorld() throws -> (AppState, ShellState, Space, Space) {
        let state = AppState(db: try DatabaseService(inMemory: true))
        let shell = ShellState(appState: state)
        state.shell = shell
        let home = Space.create(name: "home"), other = Space.create(name: "other")
        state.spaces = [home, other]; state.currentSpace = home
        return (state, shell, home, other)
    }

    @MainActor
    private func addPort(_ id: String, to space: Space, in state: AppState) {
        _ = state.portWindows.registerTiledPort(id: id, html: "<title>\(id)</title><div/>", spaceId: space.id,
                                                createdBy: nil, title: nil, position: nil)
    }

    @Test("a port address is a link target; an invite or imagine link is not")
    func target() {
        let peer = String(repeating: "a", count: 52)
        #expect(PortLinkTarget.of(URL(string: "port42://space/S/p1")!, localPeerID: nil) == .local("p1"))
        #expect(PortLinkTarget.of(URL(string: "port42://space/_/p1")!, localPeerID: nil) == .local("p1"))
        #expect(PortLinkTarget.of(URL(string: "port42://\(peer)/p1")!, localPeerID: nil) == .remote(peer: peer, port: "p1"))
        #expect(PortLinkTarget.of(URL(string: "port42://\(peer)/p1")!, localPeerID: peer) == .local("p1"))
        #expect(PortLinkTarget.of(URL(string: "port42://imagine?prompt=x")!, localPeerID: nil) == nil)
        #expect(PortLinkTarget.of(URL(string: "https://example.com/p1")!, localPeerID: nil) == nil)
    }

    @Test("a clicked port42 link goes to the app; a scripted location change does not; the port stays on its document")
    func navigationHandsOffClicks() {
        let link = URL(string: "port42://space/_/p1")!
        #expect(PortNavigationBlocker.portLink(link, activated: true) == link)
        #expect(PortNavigationBlocker.portLink(link, activated: false) == nil)
        #expect(PortNavigationBlocker.portLink(URL(string: "https://example.com")!, activated: true) == nil)
        #expect(!PortNavigationBlocker.allows(link))
    }

    @Test("a link to a port in another space goes there and focuses it")
    @MainActor
    func revealsAcrossSpaces() throws {
        let (state, shell, _, other) = try makeWorld()
        addPort("p1", to: other, in: state)

        #expect(state.openPortLink(URL(string: "port42://space/\(other.id)/p1")!))
        #expect(state.currentSpace?.id == other.id)
        #expect(shell.selectedTileId == "p1")
        #expect(shell.zoom == .focus("p1"))
    }

    @Test("a link brings back a port that is running off the desktop, parked or closed")
    @MainActor
    func bringsPortsBack() throws {
        let (state, shell, home, _) = try makeWorld()
        addPort("run", to: home, in: state); addPort("park", to: home, in: state); addPort("gone", to: home, in: state)
        state.portWindows.minimize("run")
        state.portWindows.park(id: "park")
        state.portWindows.close("gone")

        #expect(state.openPortLink(URL(string: "port42://space/_/run")!))
        #expect(state.portWindows.panels.first { $0.id == "run" }?.isBackground == false)
        #expect(state.openPortLink(URL(string: "port42://space/_/park")!))
        #expect(state.portWindows.panels.first { $0.id == "park" }?.presentation == "tiled")
        #expect(state.openPortLink(URL(string: "port42://space/_/gone")!))
        #expect(state.portWindows.panels.contains { $0.id == "gone" })
        #expect(shell.zoom == .focus("gone"))
    }

    @Test("a link to no known port, or a remote port nobody shared, opens nothing")
    @MainActor
    func unknownOpensNothing() throws {
        let (state, shell, home, _) = try makeWorld()
        #expect(!state.openPortLink(URL(string: "port42://space/_/nope")!))
        #expect(!state.openPortLink(URL(string: "port42://\(String(repeating: "b", count: 52))/p1")!))
        #expect(state.currentSpace?.id == home.id)
        #expect(shell.zoom == .space)
    }
}
