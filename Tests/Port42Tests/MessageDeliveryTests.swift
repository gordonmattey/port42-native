import Testing
import Foundation
@testable import Port42Lib

/// A companion's message reaches its terminal whole and submitted (GM's multi-agent test,
/// 2026-09-25): a long multi-line message typed as keys lost about 1,100 characters, another split at
/// a newline, and the Enter 80ms later was swallowed. And a first-run prefill left in the input box
/// had the next message appended to it.
@Suite("Message delivery to a terminal")
@MainActor
struct MessageDeliveryTests {

    static let config = TerminalPortConfig(
        command: "/bin/zsh", args: [], startupCommand: "claude", cwd: "/tmp",
        spaceId: "space-1", spaceName: "Demo", companionName: "echo", createdBy: "u1",
        companionPrompt: "")

    /// A controller whose surface records every write instead of typing it.
    func controller() -> (GhosttyTerminalController, () -> [TerminalWrite]) {
        let c = GhosttyTerminalController(panelId: "p1", config: Self.config, post: { _ in })
        var writes: [TerminalWrite] = []
        c.bindSurface { w, done in writes.append(w); done() }
        return (c, { writes })
    }

    @Test("a short single line is typed as keys, with the quick Enter that works for it")
    func shortLineAsKeys() {
        let w = TerminalWrite.message("[@gordon in #genesis]: hi")
        #expect(!w.paste)
        #expect(w.submit)
        #expect(w.enterDelay == 0.08)
    }

    @Test("a multi-line message goes as one paste, and Enter waits for it")
    func multiLineAsPaste() {
        let w = TerminalWrite.message("[@nimble-wren in the chat of port 'mic shader']: v3 is live.\n\nWhat I added:\n- FFT")
        #expect(w.paste)
        #expect(w.enterDelay > 0.08)
    }

    @Test("a long single line goes as a paste; the Enter delay grows with length, capped")
    func longLineScales() {
        let mid = TerminalWrite.message(String(repeating: "a", count: 1300))
        let huge = TerminalWrite.message(String(repeating: "a", count: 100_000))
        #expect(mid.paste && huge.paste)
        #expect(mid.enterDelay > TerminalWrite.message(String(repeating: "a", count: 300)).enterDelay)
        #expect(huge.enterDelay == 1.5)
    }

    @Test("the whole message reaches the surface, nothing dropped")
    func deliveredWhole() {
        let (c, writes) = controller()
        let body = "[@a in #s]: " + String(repeating: "line of text\n", count: 100) + "end"
        c.inject(body + "\r")
        #expect(writes().count == 1)
        #expect(writes().first?.text == body, "the body must arrive intact (trailing Enter trimmed only)")
        #expect(writes().first?.submit == true)
    }

    @Test("an unsent first-run prefill is cleared before the next message, once")
    func prefillCleared() {
        let (c, writes) = controller()
        c.notePrefill()
        c.inject("[@gordon]: hi\r")
        c.inject("[@gordon]: again\r")
        #expect(writes().map(\.clearFirst) == [true, false])
    }

    @Test("a prefill the person already sent is not cleared")
    func sentPrefillKept() {
        let (c, writes) = controller()
        c.notePrefill()
        c.handleEvent(.inputSubmitted(prompt: "hey, i'm gordon. what is this place?"))
        c.inject("[@gordon]: hi\r")
        #expect(writes().first?.clearFirst == false)
    }

    /// GM, 2026-09-25: the fixed delay long enough for the biggest paste made every message sit in
    /// the box visibly. A paste's Enter now goes once the TUI has drawn it and gone quiet, capped.
    @Test("a paste's Enter goes once the TUI has echoed and gone quiet, not before, never past the cap")
    func enterWhenQuiet() {
        let cap = 1.5
        #expect(!TerminalWrite.readyToSubmit(elapsed: 0.05, sinceLastOutput: 1.0, maxDelay: cap), "never before the minimum")
        #expect(!TerminalWrite.readyToSubmit(elapsed: 0.3, sinceLastOutput: nil, maxDelay: cap), "nothing echoed yet: wait")
        #expect(!TerminalWrite.readyToSubmit(elapsed: 0.3, sinceLastOutput: 0.05, maxDelay: cap), "still drawing: wait")
        #expect(TerminalWrite.readyToSubmit(elapsed: 0.3, sinceLastOutput: 0.15, maxDelay: cap), "echoed and quiet: go")
        #expect(TerminalWrite.readyToSubmit(elapsed: 1.5, sinceLastOutput: nil, maxDelay: cap), "the cap always fires")
    }
}
