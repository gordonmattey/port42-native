import Testing
@testable import Port42Lib

@Suite("Companion Post Gate")
struct CompanionPostGateTests {

    // MARK: armed gate (hooks companions)

    /// GM's multi-agent test, 2026-09-25: a turn typed straight into the terminal was never posted,
    /// so its @mention hand-off went nowhere. Every turn posts now; the app picks the chat.
    @Test("a turn typed straight into the terminal is posted too")
    func unarmedTurnPosts() {
        var gate = CompanionPostGate(hooksCapable: true)
        #expect(gate.onTurnComplete("done, @nimble-wren take a pass") == ["done, @nimble-wren take a pass"])
    }

    @Test("arming stays armed so a multi-turn reply posts every turn")
    func armStaysAcrossTurns() {
        var gate = CompanionPostGate(hooksCapable: true)
        gate.arm()
        // One injected message can produce several turns (edit → build → respond → continue);
        // each must post, not just the first.
        #expect(gate.onTurnComplete("first turn") == ["first turn"])
        #expect(gate.onTurnComplete("second turn of the same reply") == ["second turn of the same reply"])
    }

    @Test("the same reply is still posted once, armed or not")
    func unarmedStillDeduped() {
        var gate = CompanionPostGate(hooksCapable: true)
        #expect(gate.onTurnComplete("same") == ["same"])
        #expect(gate.onTurnComplete("same") == [])
    }

    @Test("strips a leading [name]: prefix the companion echoes onto its own reply")
    func stripsEchoedPrefix() {
        var gate = CompanionPostGate(hooksCapable: true)
        gate.arm()
        #expect(gate.onTurnComplete("[claude7]: hey gordon 👋") == ["hey gordon 👋"])
        gate.arm()
        #expect(gate.onTurnComplete("no prefix here") == ["no prefix here"])  // unaffected
    }

    @Test("strips an echoed sender label even when the LLM omits the colon")
    func stripsEchoedPrefixNoColon() {
        var gate = CompanionPostGate(hooksCapable: true)
        gate.arm()
        // The LLM sometimes writes "[@gordon] reply" with no colon — must still be stripped.
        #expect(gate.onTurnComplete("[@gordon] the directory is empty") == ["the directory is empty"])
    }

    @Test("turnComplete preserves whitespace (clean transcript, not mangled tee)")
    func turnCompleteKeepsSpaces() {
        var gate = CompanionPostGate(hooksCapable: true)
        gate.arm()
        #expect(gate.onTurnComplete("  Hello space — great to connect  ") == ["Hello space — great to connect"])
    }

    // MARK: <p42> tee fallback gate

    @Test("tee <p42> tags are suppressed for hooks-capable companions")
    func teeSuppressedForHooks() {
        var gate = CompanionPostGate(hooksCapable: true)
        #expect(gate.onTag("hello from claude tag") == [])
    }

    @Test("tee <p42> tags post for non-hooks tools, with no arming required")
    func teePostsForNonHooks() {
        var gate = CompanionPostGate(hooksCapable: false)
        #expect(gate.onTag("hello from bash") == ["hello from bash"])  // deliberate tag, not gated
    }

    // MARK: dedup

    @Test("identical content is posted at most once across paths")
    func dedup() {
        var gate = CompanionPostGate(hooksCapable: false)
        #expect(gate.onTag("dup") == ["dup"])
        #expect(gate.onTag("dup") == [])      // same content again → suppressed
        #expect(gate.onTag("other") == ["other"])
    }

    @Test("empty / whitespace-only content never posts")
    func emptyNeverPosts() {
        var gate = CompanionPostGate(hooksCapable: false)
        #expect(gate.onTag("   \n  ") == [])
        var hooks = CompanionPostGate(hooksCapable: true)
        hooks.arm()
        #expect(hooks.onTurnComplete("") == [])
    }

    // MARK: hooks-capable detection

    @Test("isHooksCapable matches claude, and ONLY claude")
    func hooksCapableDetection() {
        #expect(GhosttyTerminalController.isHooksCapable("claude") == true)
        #expect(GhosttyTerminalController.isHooksCapable("/Users/x/.local/bin/claude --continue") == true)
        // gemini asserted a capability nothing implemented: declared hooks-capable, emitted no
        // events. Removed with its CLIPreset (2026-07-29).
        #expect(GhosttyTerminalController.isHooksCapable("gemini") == false)
        #expect(GhosttyTerminalController.isHooksCapable("bash -c 'echo hi'") == false)
        #expect(GhosttyTerminalController.isHooksCapable("python repl.py") == false)
    }
}
