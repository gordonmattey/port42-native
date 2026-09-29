import Testing
import Foundation
@testable import Port42Lib

/// **Port42 says where the person is** (#130).
///
/// The main window never set a title and nothing carried an accessibility label, so VoiceOver and
/// every tool that reads window titles (Watch) saw only "Port42": never the space, never the port in
/// focus. The window's title now names the space and the focused port, and tiles and chats are named.
@Suite("Where the person is (#130)")
@MainActor
struct WhereThePersonIsTests {

    @Test("the window title names the space, and the port in focus")
    func titleRules() {
        #expect(ShellState.windowTitle(locked: false, space: "port42-app", zoom: .space, focusedTitle: nil) == "port42-app")
        #expect(ShellState.windowTitle(locked: false, space: "port42-app", zoom: .focus("p"), focusedTitle: "Drafts")
                == "port42-app · Drafts")
        #expect(ShellState.windowTitle(locked: false, space: "port42-app", zoom: .galaxy, focusedTitle: nil)
                == "Port42 · All spaces")
        #expect(ShellState.windowTitle(locked: false, space: "port42-app", zoom: .focus("p"), focusedTitle: "")
                == "port42-app", "an untitled port falls back to the space")
        #expect(ShellState.windowTitle(locked: false, space: nil, zoom: .space, focusedTitle: nil) == "Port42")
    }

    @Test("the lock screen names no space and no port")
    func lockedSaysNothing() {
        #expect(ShellState.windowTitle(locked: true, space: "secret-project", zoom: .focus("p"), focusedTitle: "Payroll")
                == "Port42")
    }

    @Test("the live title follows the zoom: space, then the focused port by its name")
    func liveTitleFollowsFocus() throws {
        let w = try makeParityWorld()
        w.state.isSetupComplete = true
        w.state.showDreamscape = false
        w.state.currentSpace = w.space
        let created = w.state.createPort(type: "web", title: "Drafts", html: "<title>Drafts</title>", command: nil,
                                         cwd: nil, systemPrompt: nil, spaceId: w.space.id, createdBy: w.companion.id,
                                         createdByName: w.companion.displayName, presentation: "tiled")
        let udid = try #require(created["id"] as? String)
        let panelId = try #require(w.state.portWindows.findPort(by: udid)?.id)
        let shell = ShellState(appState: w.state)

        shell.zoom = .space
        #expect(shell.windowTitle == w.space.name)
        shell.zoom = .focus(panelId)
        #expect(shell.windowTitle == "\(w.space.name) · Drafts")
        w.state.showDreamscape = true
        #expect(shell.windowTitle == "Port42", "locking must hide where the person was")
    }

    @Test("a tile is named by its port and kind, and says when it is in focus")
    func tileLabels() {
        #expect(ShellState.tileAccessibilityLabel(title: "Drafts", portType: "web", focused: false) == "Drafts, port")
        #expect(ShellState.tileAccessibilityLabel(title: "build", portType: "terminal", focused: true)
                == "build, terminal, in focus")
        #expect(ShellState.tileAccessibilityLabel(title: "", portType: "browser", focused: false) == "Untitled, browser")
    }

    @Test("a chat is named by whose it is")
    func chatLabels() {
        let space = Space.create(name: "port42-app")
        #expect(PortChatPanel.accessibilityLabel(key: PortChat.desktopKey, spaces: [space], portTitle: nil) == "Chat, desktop")
        #expect(PortChatPanel.accessibilityLabel(key: space.id, spaces: [space], portTitle: nil) == "Chat, space port42-app")
        #expect(PortChatPanel.accessibilityLabel(key: "udid", spaces: [space], portTitle: "Drafts") == "Chat, Drafts")
    }

    /// The pattern check CI keeps: the views a person navigates by keep their names. Removing a label
    /// or the window's title fails here, rather than being noticed by someone on VoiceOver.
    @Test("tiles, chats and the window keep their accessibility names (CI check)")
    func namesStayInPlace() throws {
        func source(_ file: String) throws -> String {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent("Sources/Port42Lib/Views/\(file)"), encoding: .utf8)
        }
        let desktop = try source("ShellDesktop.swift")
        let start = try #require(desktop.range(of: "struct ShellTile: View {"))
        let tile = String(desktop[start.lowerBound...].prefix(40_000))
        #expect(tile.contains("ShellState.tileAccessibilityLabel("), "the port tile lost its accessibility name")

        let chat = try source("PortChatPanel.swift")
        #expect(chat.contains(".accessibilityLabel(chatLabel)"), "the chat lost its accessibility name")
        #expect(chat.contains(".accessibilityLabel(\"Send\")"), "the chat's send button is an unnamed icon again")

        let shellView = try source("ShellView.swift")
        #expect(shellView.contains("shell.windowTitle"), "the window no longer says where the person is")
    }
}
