import AppKit
import SwiftUI

// MARK: - Spaces on several displays (#189)
//
// GM (2026-09-29): "multi displays hardware, so when you arrange you can have multiple spaces on
// multiple screens, so its space to desktop display mapping." Design: docs/design-display-spaces.md.
//
// The main window shows the space the person is in. Any other space can be open in a window of its own
// (a space window), on any screen, several to a screen (Gordon, 2026-10-01: the window is the unit, not
// the display; docs/plan-space-windows.md). Each space window remembers its screen, position and size, so
// a display unplugged and plugged back in, or an app quit and relaunched, brings it back where it was.

/// Which space each extra display showed, by the display's stable UUID: the model before space windows,
/// kept to read an older install's saved map (it migrates to `SpaceWindowMap`).
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

/// One space window: the space it shows, the screen it is on (the display's stable UUID) and its frame
/// in screen coordinates.
public struct SpaceWindowRecord: Codable, Equatable, Identifiable {
    public let id: String
    public var spaceId: String
    public var display: String
    public var frame: CGRect
}

/// Every space window and where it is. Pure, so the rules are tested without hardware.
public struct SpaceWindowMap: Codable, Equatable {
    public private(set) var windows: [SpaceWindowRecord] = []

    public init(_ windows: [SpaceWindowRecord] = []) { self.windows = windows }

    /// The window that shows a space, if one does. A space is in one window at a time.
    public func window(showing spaceId: String) -> SpaceWindowRecord? { windows.first { $0.spaceId == spaceId } }

    /// The windows on a screen.
    public func windows(on display: String) -> [SpaceWindowRecord] { windows.filter { $0.display == display } }

    public func record(_ id: String) -> SpaceWindowRecord? { windows.first { $0.id == id } }

    /// Open a space in a window on a screen. A window that already shows the space moves there instead,
    /// so the space stays in one window. Returns the window's id.
    @discardableResult
    public mutating func open(_ spaceId: String, on display: String, frame: CGRect, id: String = UUID().uuidString) -> String {
        if let i = windows.firstIndex(where: { $0.spaceId == spaceId }) {
            windows[i].display = display
            windows[i].frame = frame
            return windows[i].id
        }
        windows.append(SpaceWindowRecord(id: id, spaceId: spaceId, display: display, frame: frame))
        return id
    }

    /// A window now shows another space (the galaxy, ⌘K, a swap). The swap itself happens among the
    /// windows' shells; this keeps the record in step.
    public mutating func assign(_ id: String, to spaceId: String) {
        guard let i = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[i].spaceId = spaceId
    }

    /// The person moved or resized a window, perhaps onto another screen.
    public mutating func place(_ id: String, on display: String, frame: CGRect) {
        guard let i = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[i].display = display
        windows[i].frame = frame
    }

    /// A window closed for good.
    public mutating func close(_ id: String) { windows.removeAll { $0.id == id } }

    /// A space went (deleted): no window keeps it.
    public mutating func release(_ spaceId: String) { windows.removeAll { $0.spaceId == spaceId } }

    /// A remembered frame, kept inside a screen's visible frame: no larger than it, and on it. A frame
    /// that was never set (an older install's display map) fills it.
    public static func clamp(_ frame: CGRect, into visible: CGRect) -> CGRect {
        guard frame.width > 0, frame.height > 0, frame.intersects(visible) else { return visible }
        let w = min(frame.width, visible.width), h = min(frame.height, visible.height)
        let x = min(max(frame.minX, visible.minX), visible.maxX - w)
        let y = min(max(frame.minY, visible.minY), visible.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// An older install's display map: each display's space becomes a window filling that screen.
    public static func migrated(from old: DisplayMap) -> SpaceWindowMap {
        var map = SpaceWindowMap()
        for (display, space) in old.spaces.sorted(by: { $0.key < $1.key }) { map.open(space, on: display, frame: .zero) }
        return map
    }

    static let defaultsKey = "port42SpaceWindows"

    static func load(_ defaults: UserDefaults = .standard) -> SpaceWindowMap {
        if let data = defaults.data(forKey: defaultsKey),
           let map = try? JSONDecoder().decode(SpaceWindowMap.self, from: data) { return map }
        let migrated = migrated(from: DisplayMap.load(defaults))
        defaults.removeObject(forKey: DisplayMap.defaultsKey)
        return migrated
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

/// Opens, closes, restores and follows the space windows.
@MainActor
public final class DisplaySpaces {
    private unowned let appState: AppState
    private(set) var map: SpaceWindowMap
    private var windows: [String: NSWindow] = [:]      // space window id -> its window
    private var observers: [String: [NSObjectProtocol]] = [:]
    private var screenObserver: NSObjectProtocol?
    /// Windows closing because their display went: they are kept, to come back when it returns.
    private var closingKept: Set<String> = []

    init(appState: AppState) {
        self.appState = appState
        self.map = SpaceWindowMap.load()
    }

    /// The displays connected now. The main display is the one the main window is on.
    public func connected() -> [ConnectedDisplay] {
        let mainScreen = mainWindowScreen
        return NSScreen.screens.compactMap { screen in
            guard let id = screen.displayUUID else { return nil }
            return ConnectedDisplay(id: id, name: screen.localizedName, isMain: screen == mainScreen)
        }
    }

    private var mainWindowScreen: NSScreen? {
        appState.shells.first(where: { !$0.isDisplayWindow })?.window?.screen ?? NSScreen.main
    }

    /// Whether a space is open in a window on a display.
    public func isShowing(_ spaceId: String, on display: String) -> Bool {
        map.window(showing: spaceId)?.display == display
    }

    /// Show a space on a display: in a window filling that screen. A window that shows the space now moves
    /// there; if the main window shows it, the main window takes a space no window shows.
    public func put(_ spaceId: String, on display: String) {
        guard let screen = NSScreen.screens.first(where: { $0.displayUUID == display }) else { return }
        show(spaceId, on: display, frame: screen.visibleFrame)
    }

    /// Open a space in a new window on the screen the person is using (the key window's), else the main one.
    public func openInNewWindow(_ spaceId: String) {
        guard let screen = NSApp.keyWindow?.screen ?? mainWindowScreen, let display = screen.displayUUID else { return }
        let v = screen.visibleFrame
        let frame = CGRect(x: v.minX + v.width * 0.08, y: v.minY + v.height * 0.08,
                           width: v.width * 0.6, height: v.height * 0.7)
        show(spaceId, on: display, frame: frame)
    }

    private func show(_ spaceId: String, on display: String, frame: CGRect) {
        // The main window (not a space window) showing the space takes another, so the space is in one window.
        for other in appState.shells where !other.isDisplayWindow && other.spaceId == spaceId {
            if let next = freeSpace(excluding: spaceId), let s = appState.spaces.first(where: { $0.id == next }) {
                if other.isKey { appState.selectSpace(s) } else { other.show(spaceId: next) }
            }
        }
        let id = map.open(spaceId, on: display, frame: frame)
        map.save()
        if let window = windows[id] {
            if let shell = shell(of: window), shell.spaceId != spaceId { shell.show(spaceId: spaceId) }
            window.setFrame(frame, display: true)
            window.makeKeyAndOrderFront(nil)
        } else if let record = map.record(id) {
            open(record)
        }
    }

    /// Stop showing a space on a display: its window closes and is forgotten.
    public func stopShowing(_ spaceId: String, on display: String) {
        guard let record = map.window(showing: spaceId), record.display == display else { return }
        windows[record.id]?.close()           // willClose forgets it
        map.close(record.id); map.save()
    }

    /// Whether a space is open in a window of its own (not the main window).
    public func hasWindow(_ spaceId: String) -> Bool { map.window(showing: spaceId) != nil }

    /// Close the window a space is open in, wherever it is, and forget it. The space keeps running.
    public func closeWindow(of spaceId: String) {
        guard let record = map.window(showing: spaceId) else { return }
        windows[record.id]?.close()           // willClose forgets it
        map.close(record.id); map.save()
    }

    /// The space File → New Window opens when a window is already open: the first working space no window
    /// shows, or nil when every one is shown.
    public func spaceForNewWindow() -> String? {
        let shown = Set(appState.shells.compactMap(\.spaceId))
        return appState.workingSpaces.first { !shown.contains($0.id) }?.id
    }

    /// File → New Window with a window already open: another Port42 window, on a space no window shows.
    /// It never makes a space (Gordon); when every space is already in a window it says so.
    public func openAnotherWindow() {
        guard let sid = spaceForNewWindow() else {
            appState.toastMessage = "Every space is already open in a window"
            return
        }
        openInNewWindow(sid)
    }

    /// A space was deleted: its window closes and is forgotten.
    public func forget(_ spaceId: String) {
        if let record = map.window(showing: spaceId) { windows[record.id]?.close() }
        map.release(spaceId); map.save()
    }

    /// A working space no window shows, if there is one.
    private func freeSpace(excluding: String) -> String? {
        let shown = Set(appState.shells.compactMap(\.spaceId)).union([excluding])
        return appState.workingSpaces.first { !shown.contains($0.id) }?.id
    }

    /// Keep the map in step with a space window's space when it changes from inside (the galaxy, ⌘K, a swap).
    func record(_ shell: ShellState) {
        guard shell.isDisplayWindow, let id = windows.first(where: { $0.value === shell.window })?.key else { return }
        if let sid = shell.spaceId { map.assign(id, to: sid) } else { map.close(id) }
        map.save()
    }

    /// The display a shell's window is on, when it is a space window.
    public func display(of shell: ShellState) -> String? {
        windows.first(where: { $0.value === shell.window }).flatMap { map.record($0.key)?.display }
    }

    /// Open every remembered window whose screen is connected, and follow displays coming and going.
    public func restore() {
        let now = Set(connected().map(\.id))
        for record in map.windows where windows[record.id] == nil && now.contains(record.display)
            && appState.spaces.contains(where: { $0.id == record.spaceId }) {
            open(record)
        }
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    /// A display was unplugged: its windows close and their spaces keep running; the map keeps them, so
    /// plugging it back in brings them back where they were.
    private func screensChanged() {
        let now = Set(connected().map(\.id))
        for record in map.windows where !now.contains(record.display) {
            if let window = windows[record.id] { closingKept.insert(record.id); window.close() }
        }
        restore()
    }

    private func open(_ record: SpaceWindowRecord) {
        guard let screen = NSScreen.screens.first(where: { $0.displayUUID == record.display }) else { return }
        let frame = SpaceWindowMap.clamp(record.frame, into: screen.visibleFrame)
        // The main window's windowed look (ShellMode.restoreWindow): titled with the title hidden and no
        // traffic lights, movable and resizable like any window.
        let window = DisplaySpaceWindow(contentRect: frame,
                                        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                        backing: .buffered, defer: false, screen: screen)
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovable = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.collectionBehavior = [.managed, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView:
            ShellView(appState: appState, displayWindow: true, spaceId: record.spaceId)
                .environmentObject(appState)
                .background(Port42Theme.bgPrimary)
                .preferredColorScheme(.dark))
        window.setFrame(frame, display: true)
        window.orderFront(nil)
        windows[record.id] = window
        follow(window, id: record.id)
    }

    /// Record a window's moves, resizes and screen changes as they happen, and forget it when it closes.
    private func follow(_ window: NSWindow, id: String) {
        let center = NotificationCenter.default
        let placed: (Notification) -> Void = { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window, let display = window.screen?.displayUUID else { return }
                self.map.place(id, on: display, frame: window.frame)
                self.map.save()
            }
        }
        var tokens: [NSObjectProtocol] = []
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            tokens.append(center.addObserver(forName: name, object: window, queue: .main, using: placed))
        }
        tokens.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A window whose display went is kept for when it returns; any other close forgets it.
                if self.closingKept.remove(id) == nil { self.map.close(id); self.map.save() }
                self.windows[id] = nil
                for t in self.observers.removeValue(forKey: id) ?? [] { center.removeObserver(t) }
            }
        })
        observers[id] = tokens
    }

    private func shell(of window: NSWindow?) -> ShellState? {
        guard let window else { return nil }
        return appState.shells.first { $0.window === window }
    }
}

/// A space window. Titled now (it was borderless, which AppKit never makes key, so a click there never
/// made it the window in use; Gordon, 2026-10-01); it says outright that it can become key and main.
final class DisplaySpaceWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
