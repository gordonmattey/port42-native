import Testing
import Foundation
import AppKit
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

    @Test("switching space on the main display leaves the other display's companions as they were (Gordon, #189)")
    func companionsStayWithTheirWindow() throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        let spaces = [Space.create(name: "one"), Space.create(name: "two"), Space.create(name: "three")]
        for s in spaces { try state.db.saveSpace(s) }
        state.spaces = spaces
        let owner = AppUser.createLocal(displayName: "Gordon")
        let ada = AgentConfig.createCommand(ownerId: owner.id, displayName: "ada", command: "claude", systemPrompt: nil, trigger: .mentionOnly)
        let bo = AgentConfig.createCommand(ownerId: owner.id, displayName: "bo", command: "claude", systemPrompt: nil, trigger: .mentionOnly)
        state.companions = [ada, bo]
        state.spaceAgentIds = [spaces[1].id: [ada.id], spaces[2].id: [bo.id]]
        state.selectSpace(spaces[0])
        let main = ShellState(appState: state)
        let other = ShellState(appState: state)
        other.isDisplayWindow = true
        other.show(spaceId: spaces[1].id)
        #expect(other.companionsHere.map(\.displayName) == ["ada"])

        state.selectSpace(spaces[2])                       // the person switches the laptop's space
        #expect(main.spaceId == spaces[2].id)
        #expect(other.spaceId == spaces[1].id, "the other display changed space")
        #expect(other.companionsHere.map(\.displayName) == ["ada"], "the other display shows \(other.companionsHere.map(\.displayName)), the main window's crew")
    }

    @Test("a display's window can become the key window, so a click there makes it the window in use")
    func displayWindowCanBeKey() {
        let w = DisplaySpaceWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                   styleMask: [.borderless, .closable], backing: .buffered, defer: true)
        #expect(w.canBecomeKey, "a borderless display window cannot take the keyboard or become the window in use")
        #expect(w.canBecomeMain)
        let plain = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                             styleMask: [.borderless, .closable], backing: .buffered, defer: true)
        #expect(!plain.canBecomeKey, "AppKit changed: a plain borderless window can become key now")
    }
}
