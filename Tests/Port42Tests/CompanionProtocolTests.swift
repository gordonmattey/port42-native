import Testing
import Foundation
@testable import Port42Lib

/// **One protocol, two delivery routes, and a gate so they cannot drift** (2026-08-01).
///
/// The rules a companion follows reach two surfaces by different means, which is how they nearly
/// ended up written twice in prose:
///
///   - claude: per session, as a real system prompt, via `--append-system-prompt`
///   - codex: no system-prompt flag exists, so via the global `<CODEX_HOME>/AGENTS.md` that
///     `InstructionService` maintains (verified live: codex reads that file, and does NOT follow
///     `@file` imports, so the text has to be inline)
///
/// GM caught the duplication as it was being introduced: llms.txt is generated from the registry and
/// gated on freshness, while this was about to become two hand-written copies of one thing. Drift
/// here is invisible — it surfaces as a companion misbehaving, with nothing pointing at the stale
/// sentence that caused it.
@Suite("Companion protocol has one source")
struct CompanionProtocolTests {

    /// THE REGRESSION GUARD FOR CLAUDE. Extracting shared prose is a refactor; a refactor that
    /// quietly reworded a live system prompt is a behaviour change in disguise. The first attempt at
    /// this extraction did exactly that — it lowercased `@Critic`/`@Maker` to `@critic`/`@maker`,
    /// an unannounced edit to the prompt claude has been running with. Caught in review, not by a
    /// test, which is why the test exists now.
    @Test("the extracted protocol is character-for-character what claude already had")
    func extractionChangedNothing() {
        #expect(CompanionProtocol.rules == CompanionProtocol.historicalRules)
    }

    @Test("the protocol states its three load-bearing rules")
    func rulesAreComplete() {
        for phrase in CompanionProtocol.loadBearingPhrases {
            #expect(CompanionProtocol.rules.contains(phrase),
                    "the protocol no longer says: \(phrase)")
        }
    }

    @Test("claude's system prompt carries the protocol, not a copy of it")
    @MainActor
    func claudePromptCarriesIt() throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        state.createSpace(name: "general")
        let id = state.spaces.first(where: { $0.name == "general" })!.id

        let baked = state.bakeCompanionPrompt(name: "scout", spaceId: id, systemPrompt: nil)

        // The shared text itself, so an edit to CompanionProtocol reaches claude.
        #expect(baked.contains(CompanionProtocol.rules))
        // And the parts only this surface knows: identity, space, self-post.
        #expect(baked.contains("You are scout"))
        #expect(baked.contains("#general"))
        #expect(baked.contains("chat.post"))
    }

    @Test("the CLI instruction block carries the protocol, not a copy of it")
    @MainActor
    func instructionBlockCarriesIt() {
        // Written to a temp home so the test never touches the user's real ~/.codex or ~/.claude —
        // the daily-driver rule.
        let home = NSTemporaryDirectory() + "p42-instr-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }

        let svc = InstructionService(homeDirectory: home)
        svc.installInstructions(for: "codex")

        let md = (try? String(contentsOfFile: (home as NSString)
            .appendingPathComponent(".codex/AGENTS.md"), encoding: .utf8)) ?? ""
        #expect(!md.isEmpty, "the codex instruction file was not written")
        #expect(md.contains(CompanionProtocol.rules))
    }

    /// THE GATE. Both surfaces must carry the same rules, phrase for phrase. Asserted on the
    /// PHRASES rather than by comparing the two documents, so the wording can be improved in one
    /// place without this test becoming a second copy of the thing it guards.
    @Test("both surfaces state every rule — an edit cannot reach one and miss the other")
    @MainActor
    func neitherSurfaceCanDrift() throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        state.createSpace(name: "general")
        let id = state.spaces.first(where: { $0.name == "general" })!.id
        let claudePrompt = state.bakeCompanionPrompt(name: "scout", spaceId: id, systemPrompt: nil)

        let home = NSTemporaryDirectory() + "p42-instr-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let svc = InstructionService(homeDirectory: home)
        svc.installInstructions(for: "codex")
        let codexDoc = (try? String(contentsOfFile: (home as NSString)
            .appendingPathComponent(".codex/AGENTS.md"), encoding: .utf8)) ?? ""

        for phrase in CompanionProtocol.loadBearingPhrases {
            #expect(claudePrompt.contains(phrase), "claude's prompt is missing: \(phrase)")
            #expect(codexDoc.contains(phrase), "the CLI instruction block is missing: \(phrase)")
        }
    }

    /// Only a CLI that cannot be handed a system prompt gets the section.
    ///
    /// claude receives `CompanionProtocol.rules` per session via `--append-system-prompt`, so
    /// repeating it in CLAUDE.md would be a second copy of something claude already has, inside a
    /// block whose whole discipline is remaining a pointer — and it pushed that block past its own
    /// slimness gate, which is how the redundancy was noticed.
    @Test("claude's block does NOT carry the companion section; codex's does")
    @MainActor
    func onlyCodexCarriesTheSection() {
        let home = NSTemporaryDirectory() + "p42-instr-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let svc = InstructionService(homeDirectory: home)
        svc.installInstructions(for: "claude")
        svc.installInstructions(for: "codex")

        func read(_ rel: String) -> String {
            (try? String(contentsOfFile: (home as NSString).appendingPathComponent(rel),
                         encoding: .utf8)) ?? ""
        }
        #expect(!read(".claude/CLAUDE.md").contains("SPACE COMPANION"),
                "claude already gets the protocol as a system prompt")
        #expect(read(".codex/AGENTS.md").contains("SPACE COMPANION"),
                "codex has no system-prompt channel, so this is its only route")
    }

    @Test("the companion section is CONDITIONAL — that file is global, not companion-only")
    @MainActor
    func companionSectionIsGated() {
        let home = NSTemporaryDirectory() + "p42-instr-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let svc = InstructionService(homeDirectory: home)
        svc.installInstructions(for: "codex")
        let md = (try? String(contentsOfFile: (home as NSString)
            .appendingPathComponent(".codex/AGENTS.md"), encoding: .utf8)) ?? ""

        // A codex the user runs normally also reads this file. It must be told when the section
        // applies, rather than being informed it lives in a space it has never heard of.
        #expect(md.contains("PORT42_SPACE_ID"),
                "the companion section must name the env var that gates it")
    }

    /// A companion's space is FIXED at spawn. `space.current` called bare returns the space the USER
    /// is looking at right now, so a companion in #general would report whatever space was on screen
    /// and would change its answer whenever the human switched. GM caught this in the instructions
    /// before it shipped: true at the moment I tested it, false the moment anyone navigated.
    @Test("the space lookup passes space_id — bare, it returns the USER's current space")
    @MainActor
    func spaceLookupIsScopedToTheCompanion() {
        let home = NSTemporaryDirectory() + "p42-instr-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let svc = InstructionService(homeDirectory: home)
        svc.installInstructions(for: "codex")
        let md = (try? String(contentsOfFile: (home as NSString)
            .appendingPathComponent(".codex/AGENTS.md"), encoding: .utf8)) ?? ""

        #expect(md.contains("\"space_id\""),
                "the example must pass space_id, or it reports the wrong space")
        // And the example must feed it the companion's OWN id rather than a literal.
        #expect(md.contains("$PORT42_SPACE_ID"))
        // The warning matters as much as the example: an agent that reads only the code block and
        // drops the argument gets a plausible, wrong answer with nothing to flag it.
        #expect(md.lowercased().contains("never call it without"))
    }
}
