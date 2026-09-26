import Testing
import Foundation
import WebKit
@testable import Port42Lib

// A port that logged a caught error with console.error(err) reached Port42 as "{}": an Error's
// message and stack are not enumerable, so JSON.stringify drops them (a team run, 2026-09-26).
@Suite("A port's logged errors keep their message")
@MainActor
struct ConsoleErrorFormatTests {
    @Test("console.error(new Error(...)) arrives with its name and message, not {}")
    func errorKeepsMessage() async throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        defer { withExtendedLifetime(state) {} }
        let pw = state.portWindows
        pw.registerTiledPort(id: "e", html: """
            <title>e</title><script>
            console.error(new TypeError("boom-42"));
            try { null.x } catch (err) { console.error("caught", err) }
            </script>
            """, spaceId: "s", createdBy: nil, title: "e", position: CGPoint(x: 40, y: 40))
        let panel = try #require(pw.panels.first { $0.id == "e" })
        let key = PortConsole.key(udid: panel.udid, id: panel.id, messageId: panel.messageId)
        var text = ""
        for _ in 0..<60 {
            text = PortConsole.shared.recent(portId: key, tail: 50).map(\.text).joined(separator: "\n")
            if text.contains("boom-42") && text.contains("caught") { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(text.contains("TypeError: boom-42"), "the error lost its name and message: \(text.prefix(300))")
        #expect(text.contains("caught TypeError"), "a caught error logged with a label lost its message: \(text.prefix(300))")
    }
}
