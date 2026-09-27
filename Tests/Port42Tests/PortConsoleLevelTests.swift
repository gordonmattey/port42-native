import Testing
import Foundation
@testable import Port42Lib

/// Checking a port costs what it needs (GM, 2026-09-27): the count to know whether there are errors or
/// warnings, the errors and warnings to deal with them, the whole log only to debug. It used to return
/// the last 100 lines of up to 4,000 characters each on every check.
@Suite("Console levels")
@MainActor
struct PortConsoleLevelTests {

    func line(_ level: String, _ text: String) -> PortConsole.Line { .init(level: level, text: text, at: Date()) }

    @Test("problems: only errors and warnings, the most recent, long ones cut; the counts cover all")
    func problems() {
        var all = (1...300).map { line("log", "frame \($0)") }
        all.insert(line("error", String(repeating: "x", count: 5_000)), at: 10)
        all.append(line("warn", "slow"))
        let v = PortConsole.view(all, problemsOnly: true, tail: 20)
        #expect(v.lines.map(\.level) == ["error", "warn"])
        #expect(v.lines[0].text.count == PortConsole.problemLineLength + 1, "an error's text is cut")
        #expect(v.errors == 1 && v.warnings == 1)
        #expect(v.omitted == 300)
    }

    @Test("all: every level, the most recent tail")
    func all() {
        let lines = (1...80).map { line($0 % 2 == 0 ? "log" : "warn", "l\($0)") }
        let v = PortConsole.view(lines, problemsOnly: false, tail: 50)
        #expect(v.lines.count == 50 && v.lines.last?.text == "l80")
        #expect(v.omitted == 30)
    }

    @Test("port.console: count gives numbers only; the default is problems; all reads everything; an unknown level is refused")
    func bridge() async throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        defer { withExtendedLifetime(state) {} }
        state.portWindows.registerTiledPort(id: "q", html: "<title>q</title>", spaceId: "s", createdBy: nil,
                                            title: "q", position: CGPoint(x: 40, y: 40))
        let panel = try #require(state.portWindows.panels.first { $0.id == "q" })
        let key = PortConsole.key(udid: panel.udid, id: panel.id, messageId: panel.messageId)
        PortConsole.shared.clear(portId: key)
        for i in 1...200 { PortConsole.shared.append(portId: key, level: "log", text: "frame \(i)") }
        PortConsole.shared.append(portId: key, level: "error", text: "boom")
        func call(_ args: [String: Any]) async throws -> [String: Any] {
            let v = try await state.runBridgeMethod("port.console", principal: .peer(id: "t", displayName: "t"),
                                                    args: BridgeArgs(args.merging(["id": key]) { a, _ in a }))
            return try #require(v.toJSONObject() as? [String: Any])
        }
        let count = try await call(["level": "count"])
        #expect(count["errors"] as? Int == 1 && count["lines"] == nil, "count carries no text")
        let problems = try await call([:])
        #expect((problems["lines"] as? [[String: Any]])?.map { $0["message"] as? String } == ["boom"])
        #expect(problems["omitted"] as? Int == 200)
        let all = try await call(["level": "all"])
        #expect((all["lines"] as? [Any])?.count == 50)
        await #expect(throws: BridgeError.self) { _ = try await call(["level": "loud"]) }
        PortConsole.shared.clear(portId: key)
    }
}
