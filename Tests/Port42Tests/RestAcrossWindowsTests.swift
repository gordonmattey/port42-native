import Testing
import Foundation
@testable import Port42Lib

// Resting a space clears its peeks in every window, not only the one in use (#189 with #132's space.rest:
// a window per display, each with its own peek strip).

@Suite("rest across windows")
@MainActor
struct RestAcrossWindowsTests {
    @Test("resting a space drops its peeks in every window")
    func restClearsEveryWindow() throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        let spaces = [Space.create(name: "one"), Space.create(name: "two"), Space.create(name: "three")]
        for s in spaces { try state.db.saveSpace(s) }
        state.spaces = spaces
        state.selectSpace(spaces[0])
        let main = ShellState(appState: state)
        let other = ShellState(appState: state)
        other.isDisplayWindow = true
        other.show(spaceId: spaces[1].id)
        let peek = ShellState.PeekPort(id: "p", spaceId: spaces[2].id, spaceName: "three", title: "p")
        main.peekingPorts = [peek]
        other.peekingPorts = [peek]

        main.restSpace(spaces[2])
        #expect(state.spaces.first { $0.id == spaces[2].id }?.isResting == true)
        #expect(main.peekingPorts.isEmpty, "the window in use kept a rested space's peek")
        #expect(other.peekingPorts.isEmpty, "the other display kept a rested space's peek")
    }
}
