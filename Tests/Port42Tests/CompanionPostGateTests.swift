import Testing
@testable import Port42Lib

@Suite("Companion Post Gate")
struct CompanionPostGateTests {

    // MARK: armed gate (hooks companions)

    @Test("turnComplete does NOT post unless a space message was injected (armed)")
    func turnCompleteRequiresArming() {
        var gate = CompanionPostGate(hooksCapable: true)
        #expect(gate.onTurnComplete("private terminal reply") == [])   // never armed
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

    @Test("turnComplete still never posts before any message is injected")
    func unarmedNeverPosts() {
        var gate = CompanionPostGate(hooksCapable: true)
        #expect(gate.onTurnComplete("private, nothing injected yet") == [])
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

    @Test("isHooksCapable matches claude / gemini startup commands")
    func hooksCapableDetection() {
        #expect(GhosttyTerminalController.isHooksCapable("claude") == true)
        #expect(GhosttyTerminalController.isHooksCapable("/Users/x/.local/bin/claude --continue") == true)
        #expect(GhosttyTerminalController.isHooksCapable("gemini") == true)
        #expect(GhosttyTerminalController.isHooksCapable("bash -c 'echo hi'") == false)
        #expect(GhosttyTerminalController.isHooksCapable("python repl.py") == false)
    }
}
