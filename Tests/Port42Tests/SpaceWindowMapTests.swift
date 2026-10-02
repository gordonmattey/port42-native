import Testing
import Foundation
@testable import Port42Lib

// Space windows (#189, docs/plan-space-windows.md): the window is the unit, not the display. Any number of
// windows on any screen, each remembering its screen and frame; a space is in one window at a time.

@Suite("space window map")
struct SpaceWindowMapTests {
    let laptop = "LAPTOP", dell = "DELL"
    let frame = CGRect(x: 100, y: 100, width: 800, height: 600)

    @Test("several spaces can be open in windows on one screen")
    func severalOnOneScreen() {
        var map = SpaceWindowMap()
        map.open("s1", on: dell, frame: frame)
        map.open("s2", on: dell, frame: frame.offsetBy(dx: 50, dy: 50))
        map.open("s3", on: laptop, frame: frame)
        #expect(map.windows(on: dell).map(\.spaceId) == ["s1", "s2"])
        #expect(map.windows(on: laptop).map(\.spaceId) == ["s3"])
    }

    @Test("a space is in one window: opening it again moves that window instead of making a second")
    func oneWindowPerSpace() {
        var map = SpaceWindowMap()
        let id = map.open("s1", on: laptop, frame: frame)
        let again = map.open("s1", on: dell, frame: frame.offsetBy(dx: 10, dy: 0))
        #expect(again == id)
        #expect(map.windows.count == 1)
        #expect(map.window(showing: "s1")?.display == dell, "the window did not move to the new screen")
    }

    @Test("dragging and resizing are remembered, onto another screen too; closing forgets the window")
    func moveAndClose() {
        var map = SpaceWindowMap()
        let id = map.open("s1", on: laptop, frame: frame)
        let moved = CGRect(x: 2000, y: 40, width: 900, height: 700)
        map.place(id, on: dell, frame: moved)
        #expect(map.record(id) == SpaceWindowRecord(id: id, spaceId: "s1", display: dell, frame: moved))
        map.assign(id, to: "s2")
        #expect(map.window(showing: "s2")?.id == id && map.window(showing: "s1") == nil)
        map.close(id)
        #expect(map.windows.isEmpty)
    }

    @Test("a deleted space leaves no window behind")
    func release() {
        var map = SpaceWindowMap()
        map.open("s1", on: dell, frame: frame)
        map.open("s2", on: dell, frame: frame)
        map.release("s1")
        #expect(map.windows.map(\.spaceId) == ["s2"])
    }

    @Test("a remembered frame is kept on its screen and no larger than it; an unset one fills it")
    func clamp() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        #expect(SpaceWindowMap.clamp(frame, into: visible) == frame, "a frame that fits was changed")
        #expect(SpaceWindowMap.clamp(.zero, into: visible) == visible, "an unset frame does not fill the screen")
        #expect(SpaceWindowMap.clamp(CGRect(x: 5000, y: 5000, width: 800, height: 600), into: visible) == visible,
                "a frame off the screen was not brought back")
        let big = SpaceWindowMap.clamp(CGRect(x: -100, y: 0, width: 3000, height: 2000), into: visible)
        #expect(big == visible, "a frame larger than the screen was not fitted: \(big)")
        let hanging = SpaceWindowMap.clamp(CGRect(x: 1000, y: 0, width: 800, height: 600), into: visible)
        #expect(hanging == CGRect(x: 640, y: 0, width: 800, height: 600), "a frame hanging off the edge was not pulled in: \(hanging)")
    }

    @Test("an older install's display map becomes one window per display, filling it, and the old key goes")
    func migration() throws {
        let defaults = try #require(UserDefaults(suiteName: "SpaceWindowMapTests-\(UUID().uuidString)"))
        DisplayMap([dell: "s1", "LG": "s2"]).save(defaults)
        let map = SpaceWindowMap.load(defaults)
        #expect(Set(map.windows.map { "\($0.display)=\($0.spaceId)" }) == ["DELL=s1", "LG=s2"])
        #expect(map.windows.allSatisfy { $0.frame == .zero }, "a migrated window should fill its screen when opened")
        #expect(defaults.data(forKey: DisplayMap.defaultsKey) == nil, "the old map was not retired")
        map.save(defaults)
        #expect(SpaceWindowMap.load(defaults) == map, "the window map does not survive a relaunch")
    }
}

@Suite("new window")
@MainActor
struct NewWindowSpaceTests {
    /// The laptop's window on space one, and a new window (File → New Window) waiting in its galaxy.
    func world() throws -> (AppState, ShellState, ShellState, [Space]) {
        let state = AppState(db: try DatabaseService(inMemory: true))
        let spaces = [Space.create(name: "one"), Space.create(name: "two"), Space.create(name: "three")]
        state.spaces = spaces
        state.selectSpace(spaces[0])
        let main = ShellState(appState: state)
        let fresh = ShellState(appState: state)
        fresh.isDisplayWindow = true
        fresh.show(spaceId: nil); fresh.awaitingSpace = true
        state.makeKey(fresh)                                    // it opens in front, the window in use
        return (state, main, fresh, spaces)
    }

    @Test("a new window waits in its galaxy with no space; the laptop keeps its own")
    func waits() throws {
        let (state, main, fresh, s) = try world()
        #expect(fresh.isKey && fresh.spaceId == nil, "the new window shows a space before one was picked")
        #expect(main.spaceId == s[0].id, "the laptop lost its space")
        #expect(state.spaces.count == 3, "a space was made")
    }

    @Test("picking a free space gives the new window that space")
    func picksFree() throws {
        let (state, main, fresh, s) = try world()
        state.selectSpace(s[1])
        #expect(fresh.spaceId == s[1].id && !fresh.awaitingSpace)
        #expect(main.spaceId == s[0].id)
    }

    @Test("picking the laptop's space moves it to the new window, and the laptop waits in its galaxy")
    func takesFromAnother() throws {
        let (state, main, fresh, s) = try world()
        state.selectSpace(s[0])
        #expect(fresh.spaceId == s[0].id, "the new window did not take the space")
        #expect(main.spaceId == nil && main.awaitingSpace && main.zoom == .galaxy, "the laptop still shows the space it gave up")
        state.makeKey(main)                                     // the person clicks the laptop
        #expect(main.spaceId == nil, "the laptop shows the space the new window now has: one space in two windows")
        #expect(fresh.spaceId == s[0].id)
    }
}
