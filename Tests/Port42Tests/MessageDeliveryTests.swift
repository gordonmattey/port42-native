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
    func controller() async -> (GhosttyTerminalController, () -> [TerminalWrite]) {
        let c = GhosttyTerminalController(panelId: "p1", config: Self.config, post: { _ in })
        var writes: [TerminalWrite] = []
        c.bindSurface { w, done in writes.append(w); done() }
        c.readyQuiet = 0.05
        c.handleEvent(.sessionStarted(cli: "claude"))       // a running CLI: messages go straight in
        await c.waitUntilInputReady()
        return (c, { writes })
    }

    // MARK: - Not before the CLI is running (2026-09-26)

    /// A controller whose CLI has NOT reported SessionStart yet.
    func starting(startup: String = "claude") -> (GhosttyTerminalController, () -> [TerminalWrite], () -> [String]) {
        let cfg = TerminalPortConfig(command: "/bin/zsh", args: [], startupCommand: startup, cwd: "/tmp",
                                     spaceId: "space-1", spaceName: "Demo", companionName: "echo", createdBy: "u1",
                                     companionPrompt: "")
        var posted: [String] = []
        let c = GhosttyTerminalController(panelId: "p1", config: cfg, post: { posted.append($0) })
        c.readyQuiet = 0.05
        var writes: [TerminalWrite] = []
        c.bindSurface { w, done in writes.append(w); done() }
        return (c, { writes }, { posted })
    }

    @Test("a message sent while the CLI is starting waits for SessionStart, then goes in order and gets its reply posted")
    func heldUntilRunning() async {
        let (c, writes, posted) = starting()
        c.inject("[@gordon in #demo]: one")
        c.inject("[@gordon in #demo]: two")
        #expect(writes().isEmpty, "typed into a shell whose CLI had not started: it lands as typeahead, unsent")
        c.handleEvent(.sessionStarted(cli: "claude"))
        #expect(writes().isEmpty, "typed at SessionStart, while claude is still starting")
        await c.waitUntilInputReady()
        #expect(writes().map(\.text) == ["[@gordon in #demo]: one", "[@gordon in #demo]: two"])
        #expect(writes().allSatisfy { $0.submit })
        c.handleEvent(.turnComplete(text: "hi", exitCode: 0))
        #expect(posted() == ["hi"])
        c.teardown()
    }

    @Test("after SessionStart, a message waits while the CLI is still drawing, and goes once its screen is quiet")
    func waitsForQuietScreen() async throws {
        let (c, writes, _) = starting()
        var t = Date(timeIntervalSince1970: 1_000)              // time passes only when this test says
        c.now = { t }
        c.readyQuiet = 0.8
        c.inject("[@gordon in #demo]: hi")
        c.handleEvent(.sessionStarted(cli: "claude"))
        for _ in 0..<10 {                                      // claude drawing its first screen
            t += 0.5
            c.receiveTee("\u{1b}[2K drawing")
            try await Task.sleep(nanoseconds: 150_000_000)     // let the readiness check look
            #expect(writes().isEmpty, "typed while the CLI was still drawing")
        }
        t += 1                                                 // quiet for longer than readyQuiet
        await c.waitUntilInputReady(timeout: 10)
        #expect(writes().map(\.text) == ["[@gordon in #demo]: hi"])
        c.teardown()
    }

    @Test("claude: Enter is pressed again until the submit is confirmed, and not after")
    func enterUntilSubmitted() async throws {
        let (c, writes, _) = starting()
        c.submitConfirmWait = 0.2
        c.handleEvent(.sessionStarted(cli: "claude"))
        await c.waitUntilInputReady()
        c.inject("[@gordon in #demo]: hi")
        for _ in 0..<40 where writes().count < 2 { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(writes().count >= 2, "no second Enter for an unconfirmed message")
        #expect(writes().dropFirst().allSatisfy { $0.text.isEmpty && $0.submit }, "a retry must be a bare Enter")
        c.handleEvent(.inputSubmitted(prompt: "hi"))
        let n = writes().count
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(writes().count == n, "kept pressing Enter after the submit was confirmed")
        c.teardown()
    }

    @Test("claude: a message confirmed at once gets no extra Enter; codex, which reports none, never does")
    func noRetryWhenConfirmedOrCodex() async throws {
        let (c, writes, _) = starting()
        c.submitConfirmWait = 0.2
        c.handleEvent(.sessionStarted(cli: "claude"))
        await c.waitUntilInputReady()
        c.inject("[@gordon in #demo]: hi")
        c.handleEvent(.inputSubmitted(prompt: "hi"))
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(writes().count == 1)
        let (x, xw, _) = starting()
        x.submitConfirmWait = 0.2
        x.handleEvent(.sessionStarted(cli: "codex"))
        await x.waitUntilInputReady()
        x.inject("[@gordon in #demo]: hi")
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(xw().count == 1, "codex got an extra Enter it cannot confirm")
        c.teardown(); x.teardown()
    }

    @Test("after the CLI exits, a message is held rather than typed into the bare shell")
    func notIntoTheBareShell() {
        let (c, writes, _) = starting()
        c.handleEvent(.sessionStarted(cli: "claude"))
        c.handleEvent(.sessionEnded)
        c.inject("[@gordon in #demo]: rm -rf is not a message")
        #expect(writes().isEmpty)
        c.teardown()
    }

    @Test("a CLI whose SessionStart never comes still gets its message, after the fallback")
    func fallbackReleases() async throws {
        let (c, writes, _) = starting()
        c.heldFallback = 0.2
        c.inject("[@gordon in #demo]: hello")
        #expect(writes().isEmpty)
        for _ in 0..<50 where writes().isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(writes().map(\.text) == ["[@gordon in #demo]: hello"])
        c.teardown()
    }

    @Test("a terminal with no hooks (a plain shell) is typed into at once, as before")
    func plainShellImmediate() {
        let (c, writes, _) = starting(startup: "")
        c.inject("echo hi")
        #expect(writes().count == 1)
        c.teardown()
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
    func deliveredWhole() async {
        let (c, writes) = await controller()
        let body = "[@a in #s]: " + String(repeating: "line of text\n", count: 100) + "end"
        c.inject(body + "\r")
        #expect(writes().count == 1)
        #expect(writes().first?.text == body, "the body must arrive intact (trailing Enter trimmed only)")
        #expect(writes().first?.submit == true)
    }

    @Test("an unsent first-run prefill is cleared before the next message, once")
    func prefillCleared() async {
        let (c, writes) = await controller()
        c.notePrefill()
        c.inject("[@gordon]: hi\r")
        c.inject("[@gordon]: again\r")
        #expect(writes().map(\.clearFirst) == [true, false])
    }

    @Test("a prefill the person already sent is not cleared")
    func sentPrefillKept() async {
        let (c, writes) = await controller()
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
