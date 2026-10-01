import Testing
import Foundation
@testable import Port42Lib

// #189: several spaces on screen at once, one per display (GM: "space to desktop display mapping").
// A window is a shell; each shows its own space. The window in use shows `currentSpace`, so every
// "switch space" path and every default space follows the person; the others keep theirs, and a
// space is on one window at a time.

@Suite("Spaces on several displays (#189)")
@MainActor
struct DisplaySpacesTests {

    @Test("the display map keeps a space on one display at a time; putting it elsewhere swaps")
    func displayMap() throws {
        var map = DisplayMap()
        map.put("s1", on: "d2")
        map.put("s2", on: "d3")
        #expect(map.space(on: "d2") == "s1" && map.space(on: "d3") == "s2")
        map.put("s1", on: "d3")                     // s1 moves to d3; d2 takes d3's old space
        #expect(map.space(on: "d3") == "s1")
        #expect(map.space(on: "d2") == "s2", "the space was left on two displays, or its old display went blank")
        map.clear("d2")
        #expect(map.space(on: "d2") == nil)
        map.release("s1")
        #expect(map.space(on: "d3") == nil)
        let back = try JSONDecoder().decode(DisplayMap.self, from: JSONEncoder().encode(DisplayMap(["d9": "s9"])))
        #expect(back.space(on: "d9") == "s9", "the map does not survive a relaunch")
    }

    func world() throws -> (AppState, ShellState, ShellState, [Space]) {
        let state = AppState(db: try DatabaseService(inMemory: true))
        let spaces = [Space.create(name: "one"), Space.create(name: "two"), Space.create(name: "three")]
        state.spaces = spaces
        state.selectSpace(spaces[0])
        let main = ShellState(appState: state)            // the first window is the one in use
        let other = ShellState(appState: state)
        other.isDisplayWindow = true
        other.show(spaceId: spaces[1].id)
        return (state, main, other, spaces)
    }

    @Test("each window shows its own space, and the window in use shows currentSpace")
    func ownSpaces() throws {
        let (state, main, other, s) = try world()
        #expect(main.isKey && !other.isKey)
        #expect(main.spaceId == s[0].id && other.spaceId == s[1].id)
        #expect(state.currentSpace?.id == s[0].id)

        state.makeKey(other)                              // the person clicks the other display
        #expect(state.currentSpace?.id == s[1].id, "the default space did not follow the window in use")
        #expect(main.spaceId == s[0].id, "the main window lost its space when the other became key")
        #expect(other.spaceId == s[1].id)

        state.selectSpace(s[2])                           // the galaxy on that display picks another
        #expect(other.spaceId == s[2].id && main.spaceId == s[0].id)
    }

    @Test("switching the window in use to a space another window shows swaps the two")
    func swap() throws {
        let (state, main, other, s) = try world()
        state.selectSpace(s[1])                           // main picks the space `other` shows
        #expect(main.spaceId == s[1].id)
        #expect(other.spaceId == s[0].id, "one space is on two windows at once")
    }

    @Test("a port on two windows is live in the window in use; the other does not take it")
    func sharedPortLiveOnce() throws {
        let (state, main, other, s) = try world()
        _ = state.portWindows.registerTiledPort(id: "p", html: "<title>p</title>", spaceId: s[0].id,
                                                createdBy: nil, title: nil, position: nil)
        state.portWindows.setPin(id: "p", .everywhere)
        #expect(main.hostsLive("p") && !other.hostsLive("p"))
        state.makeKey(other)
        #expect(other.hostsLive("p") && !main.hostsLive("p"), "the live view did not follow the window in use")
        // A port only one window shows is always live there.
        _ = state.portWindows.registerTiledPort(id: "q", html: "<title>q</title>", spaceId: s[0].id,
                                                createdBy: nil, title: nil, position: nil)
        #expect(main.hostsLive("q"))
    }

    @Test("a port on the second display stays visible, whichever window is asked and whichever pushes")
    func presentationAcrossWindows() throws {
        let (state, main, other, s) = try world()       // main (in use) shows one; other shows two
        _ = state.portWindows.registerTiledPort(id: "p2", html: "<title>p2</title>", spaceId: s[1].id,
                                                createdBy: nil, title: nil, position: nil)
        _ = state.portWindows.registerTiledPort(id: "p3", html: "<title>p3</title>", spaceId: s[2].id,
                                                createdBy: nil, title: nil, position: nil)
        let p2 = try #require(state.portWindows.panels.first { $0.id == "p2" })
        // The AI-suspend gate, presentation() and the heartbeat all ask the window in use.
        #expect(main.isVisible(p2), "a port on screen on the second display reads as not visible, so it can be suspended")
        #expect(main.presentation(forPortId: p2.udid)?.visible == true)
        #expect(main.presentationSnapshot()["p2"]?.visible == true)
        // Both windows' pipelines fire; one pushes, and what it pushes says visible.
        other.syncPresentation(); main.syncPresentation()
        #expect(main.lastPresentation["p2"]?.visible == true)
        #expect(other.lastPresentation.isEmpty, "a second window pushed its own, opposite, view of the port")
        // A port in a space no window shows is still not visible.
        let p3 = try #require(state.portWindows.panels.first { $0.id == "p3" })
        #expect(!main.isVisible(p3) && main.presentationSnapshot()["p3"]?.visible == false)
    }

    @Test("with one window, every event is its own, as before")
    func singleWindowUnchanged() throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        let only = ShellState(appState: state)
        let e = try #require(NSEventFactory.keyDown())
        #expect(only.owns(e) && only.isKey)
    }
}

import AppKit
enum NSEventFactory {
    static func keyDown() -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                         context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)
    }
}
