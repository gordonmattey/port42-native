import Testing
import Foundation

// #254: a port's companion bar (who is in its chat, and the unread count) sat at the right of its
// header, among the console and the "…" button, while a space's sits at the left, next to its name.
// It is next to the port's title now. Layout is not reachable headlessly, so this reads the header's
// source: the bar is in the title's group, before the spacer that pushes the controls right.
@Suite("A port's chat bar sits left of its header, as a space's does (#254)")
struct ChatBarPlacementTests {
    static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Port42Lib/Views/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("in a port's title bar, the chat bar comes before the spacer; in the space's chrome, right after its name")
    func barIsLeft() throws {
        let desktop = try Self.source("ShellDesktop.swift")
        let titleBar = try #require(desktop.range(of: "private var titleBar: some View {"))
        let rest = desktop[titleBar.upperBound...]
        let spacer = try #require(rest.range(of: "Spacer(minLength: 8)"))
        let bar = try #require(rest.range(of: "PortChatBar("), "the port header has no chat bar")
        #expect(bar.lowerBound < spacer.lowerBound, "the port's chat bar is right of the spacer, not next to its title")
        let chrome = try #require(desktop.range(of: "Text(shell.space?.name"))
        let spaceBar = try #require(desktop[chrome.upperBound...].range(of: "PortChatBar("))
        let spaceSpacer = try #require(desktop[chrome.upperBound...].range(of: "Spacer()"))
        #expect(spaceBar.lowerBound < spaceSpacer.lowerBound)
    }
}
