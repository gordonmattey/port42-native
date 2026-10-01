import AppKit
import SwiftUI

// MARK: - Spaces on several displays (#189)
//
// GM (2026-09-29): "multi displays hardware, so when you arrange you can have multiple spaces on
// multiple screens, so its space to desktop display mapping." Design: docs/design-display-spaces.md.
//
// The main window stays on the main display and shows the space the person is in. Every other display
// the person puts a space on gets a window of its own, full-display, drawing its own shell. The map of
// display to space is kept, so a display that is unplugged and plugged back in, or an app that is
// quit and relaunched, comes back on the same space.

/// Which space each extra display shows, by the display's stable UUID. Pure, so the rules are tested
/// without hardware.
public struct DisplayMap: Equatable, Codable {
    public private(set) var spaces: [String: String] = [:]   // display UUID -> space id

    public init(_ spaces: [String: String] = [:]) { self.spaces = spaces }

    /// Put a space on a display. A space is on one display at a time, so a display that showed it
    /// before gives it up and takes this display's old space instead (a swap), or goes empty.
    public mutating func put(_ spaceId: String, on display: String) {
        let old = spaces[display]
        for (d, s) in spaces where s == spaceId && d != display { spaces[d] = old }
        spaces[display] = spaceId
    }

    /// A display stops showing anything.
    public mutating func clear(_ display: String) { spaces[display] = nil }

    /// A space is shown in the main window now: no extra display keeps it.
    public mutating func release(_ spaceId: String) {
        for (d, s) in spaces where s == spaceId { spaces[d] = nil }
    }

    /// The space a display shows, if any.
    public func space(on display: String) -> String? { spaces[display] }

    static let defaultsKey = "port42DisplaySpaces"

    static func load(_ defaults: UserDefaults = .standard) -> DisplayMap {
        guard let data = defaults.data(forKey: defaultsKey),
              let map = try? JSONDecoder().decode(DisplayMap.self, from: data) else { return DisplayMap() }
        return map
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// A connected display, as the person and the map name it.
public struct ConnectedDisplay: Equatable, Identifiable {
    public let id: String        // stable UUID
    public let name: String      // NSScreen.localizedName
    public let isMain: Bool
}

extension NSScreen {
    /// The display's stable UUID, which survives reboots and reconnection.
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

/// Opens, closes and restores the windows on extra displays.
@MainActor
public final class DisplaySpaces {
    private unowned let appState: AppState
    private(set) var map: DisplayMap
    private var windows: [String: NSWindow] = [:]      // display UUID -> its window
    private var screenObserver: NSObjectProtocol?

    init(appState: AppState) {
        self.appState = appState
        self.map = DisplayMap.load()
    }

    /// The displays connected now. The main display is the one the main window is on.
    public func connected() -> [ConnectedDisplay] {
        let mainScreen = appState.shells.first(where: { !$0.isDisplayWindow })?.window?.screen ?? NSScreen.main
        return NSScreen.screens.compactMap { screen in
            guard let id = screen.displayUUID else { return nil }
            return ConnectedDisplay(id: id, name: screen.localizedName, isMain: screen == mainScreen)
        }
    }

    /// Put a space on a display: open that display's window on it, or switch it there. The space
    /// leaves any display that showed it before.
    public func put(_ spaceId: String, on display: String) {
        guard connected().contains(where: { $0.id == display && !$0.isMain }) else { return }
        let old = map.space(on: display)
        // A window that shows the space now (the main one, or another display's) takes this
        // display's old space instead: a swap. With no old space, it moves to one no window shows.
        for other in appState.shells where other.spaceId == spaceId && other.window !== windows[display] {
            let next = old ?? freeSpace(excluding: spaceId)
            if other.isKey, let next, let s = appState.spaces.first(where: { $0.id == next }) {
                appState.selectSpace(s)
            } else { other.show(spaceId: next) }
            record(other)
        }
        map.put(spaceId, on: display); map.save()
        if let window = windows[display], let shell = shell(of: window) {
            shell.show(spaceId: spaceId)
        } else {
            open(display: display, spaceId: spaceId)
        }
    }

    /// A working space no window shows, if there is one.
    private func freeSpace(excluding: String) -> String? {
        let shown = Set(appState.shells.compactMap(\.spaceId)).union([excluding])
        return appState.workingSpaces.first { !shown.contains($0.id) }?.id
    }

    /// Keep the map in step with a display window's space when it changes from inside (the galaxy,
    /// ⌘K, a swap). The main window is not in the map: it shows the space the person is in.
    func record(_ shell: ShellState) {
        guard shell.isDisplayWindow, let display = windows.first(where: { $0.value === shell.window })?.key else { return }
        if let sid = shell.spaceId { map.put(sid, on: display) } else { map.clear(display) }
        map.save()
    }

    /// The display a shell's window is on, when it is one of these windows.
    public func display(of shell: ShellState) -> String? {
        windows.first(where: { $0.value === shell.window })?.key
    }

    /// Stop showing anything on a display, and close its window.
    public func clear(_ display: String) {
        map.clear(display); map.save()
        windows.removeValue(forKey: display)?.close()
    }

    /// Open the window of every connected display that has a space, and follow displays coming and
    /// going from now on.
    public func restore() {
        for d in connected() where !d.isMain {
            if let sid = map.space(on: d.id), windows[d.id] == nil,
               appState.spaces.contains(where: { $0.id == sid }) {
                open(display: d.id, spaceId: sid)
            }
        }
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    /// A display was unplugged: its window closes and its space keeps running; the map keeps it, so
    /// plugging it back in brings the window back on the same space.
    private func screensChanged() {
        let now = Set(connected().map(\.id))
        for (display, window) in windows where !now.contains(display) {
            window.close(); windows[display] = nil
        }
        restore()
    }

    private func open(display: String, spaceId: String) {
        guard let screen = NSScreen.screens.first(where: { $0.displayUUID == display }) else { return }
        // The visible frame, below the menu bar macOS draws on every display (and clear of its Dock).
        let window = DisplaySpaceWindow(contentRect: screen.visibleFrame, styleMask: [.borderless, .closable],
                                        backing: .buffered, defer: false, screen: screen)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenAuxiliary, .managed]
        window.contentView = NSHostingView(rootView:
            ShellView(appState: appState, displayWindow: true, spaceId: spaceId)
                .environmentObject(appState)
                .background(Port42Theme.bgPrimary)
                .preferredColorScheme(.dark))
        window.setFrame(screen.visibleFrame, display: true)
        window.orderFront(nil)
        windows[display] = window
    }

    private func shell(of window: NSWindow?) -> ShellState? {
        guard let window else { return nil }
        return appState.shells.first { $0.window === window }
    }
}

/// A display's window. Borderless, so AppKit would never let it become the key window, and then a click
/// on that display never made it the window in use: the galaxy's pick, keys and the dock all acted on the
/// main window's space (Gordon, 2026-10-01). It can become key and main like any window.
final class DisplaySpaceWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
