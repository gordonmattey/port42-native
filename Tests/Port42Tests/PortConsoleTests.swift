import Testing
import Foundation
@testable import Port42Lib

@Suite("Port console buffer")
@MainActor
struct PortConsoleTests {

    /// A fresh id per test: the buffer is a singleton, so tests that shared an id would see each
    /// other's lines.
    private func newId() -> String { "port-\(UUID().uuidString)" }

    @Test("lines come back oldest first — reading order, not log order")
    func recentIsChronological() {
        let id = newId()
        let c = PortConsole.shared
        c.append(portId: id, level: "log", text: "first")
        c.append(portId: id, level: "warn", text: "second")
        c.append(portId: id, level: "error", text: "third")

        let lines = c.recent(portId: id)
        #expect(lines.map(\.text) == ["first", "second", "third"])
        #expect(lines.map(\.level) == ["log", "warn", "error"])
        c.clear(portId: id)
    }

    @Test("tail returns the most recent N, not the first N")
    func tailTakesTheEnd() {
        let id = newId()
        let c = PortConsole.shared
        for i in 1...10 { c.append(portId: id, level: "out", text: "line \(i)") }

        // The interesting end of a console is the recent one: an error is at the bottom.
        #expect(c.recent(portId: id, tail: 3).map(\.text) == ["line 8", "line 9", "line 10"])
        // Asking for more than exists is not an error.
        #expect(c.recent(portId: id, tail: 999).count == 10)
        c.clear(portId: id)
    }

    @Test("a chatty port cannot grow the buffer without bound")
    func ringBufferCaps() {
        // A port rendering at 60fps and logging each frame would otherwise be a memory leak with a
        // friendly name. The OLDEST lines are the ones dropped.
        let id = newId()
        let c = PortConsole.shared
        for i in 1...(PortConsole.maxLines + 250) { c.append(portId: id, level: "log", text: "\(i)") }

        #expect(c.count(portId: id) == PortConsole.maxLines)
        #expect(c.recent(portId: id, tail: 1).first?.text == "\(PortConsole.maxLines + 250)")
        c.clear(portId: id)
    }

    @Test("one enormous line is truncated rather than retained whole")
    func longLinesAreCapped() {
        // A terminal can emit a megabyte on one line — `cat` of a binary. The buffer is for
        // legibility, not fidelity.
        let id = newId()
        let c = PortConsole.shared
        c.append(portId: id, level: "out", text: String(repeating: "x", count: 50_000))

        let line = try! #require(c.recent(portId: id).first)
        #expect(line.text.count == PortConsole.maxLineLength + 1)   // + the ellipsis
        #expect(line.text.hasSuffix("…"))
        c.clear(portId: id)
    }

    @Test("empty output and an empty port id are both ignored")
    func ignoresNothing() {
        let id = newId()
        let c = PortConsole.shared
        c.append(portId: id, level: "out", text: "")
        c.append(portId: "", level: "out", text: "orphan")
        #expect(c.count(portId: id) == 0)
        #expect(c.count(portId: "") == 0)
    }

    @Test("ports do not see each other's output")
    func portsAreIsolated() {
        let a = newId(), b = newId()
        let c = PortConsole.shared
        c.append(portId: a, level: "out", text: "mine")
        c.append(portId: b, level: "out", text: "yours")

        #expect(c.recent(portId: a).map(\.text) == ["mine"])
        #expect(c.recent(portId: b).map(\.text) == ["yours"])
        c.clear(portId: a); c.clear(portId: b)
    }

    @Test("a closed port's console does not outlive it")
    func clearForgets() {
        let id = newId()
        let c = PortConsole.shared
        c.append(portId: id, level: "out", text: "hello")
        c.clear(portId: id)
        #expect(c.recent(portId: id).isEmpty)
    }

    @Test("asking about a port that never printed is empty, not an error")
    func unknownPortIsEmpty() {
        #expect(PortConsole.shared.recent(portId: newId()).isEmpty)
    }

    /// The writers hold a panel; the reader holds a ref it resolved. If those disagree the buffer
    /// fills under one name and reads empty under another — indistinguishable from capturing
    /// nothing, which is how it first shipped and how the terminal half read as broken.
    @Test("the console key matches PortRef's rule: udid wins, then id, then messageId")
    func keyMatchesTheResolver() {
        #expect(PortConsole.key(udid: "U", id: "I", messageId: "M") == "U")
        #expect(PortConsole.key(udid: nil, id: "I", messageId: "M") == "I")
        #expect(PortConsole.key(udid: nil, id: "", messageId: "M") == "M")
    }
}
