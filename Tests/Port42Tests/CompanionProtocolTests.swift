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

    /// GM's two-agent run, 2026-09-25: an agent @mentioned a companion that does not exist. The rules
    /// illustrated mentions with invented names (@Critic, @Maker), which read as real handles.
    @Test("the rules show no invented @handles an agent could copy")
    func noInventedHandles() {
        // "[@name]" is the message format and "@mention" is the word; both are named here so that
        // any other handle, an invented example, fails.
        let handles = MentionParser.extractMentions(from: CompanionProtocol.rules)
            .filter { !["@name", "@mention"].contains($0) }
        #expect(handles.isEmpty, "example handles in the rules: \(handles)")
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
        // And the parts only this surface knows: identity and space. Posting on your own initiative
        // is in the core and team skills since nautilus Phase 5.
        #expect(baked.contains("You are scout"))
        #expect(baked.contains("#general"))
        #expect(baked.contains(CompanionProtocol.pointer))
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
        // applies. The gate is the token file, which every Port42 terminal has; the space id did not
        // always reach a Codex session's shell, so the section was ignored (2026-09-25).
        #expect(md.contains("PORT42_TOKEN_FILE"), "the companion section must name the env var that gates it")
        #expect(!md.contains("Applies only when `PORT42_SPACE_ID`"), "the old gate must be gone")
    }

    /// A companion's space is FIXED at spawn, and `space.current` called bare returns the space the
    /// USER is looking at. So a companion learns where it is from `whoami`, which answers from its own
    /// credential, never from what is on screen.
    @Test("a companion learns who and where it is from whoami, not a bare space lookup")
    @MainActor
    func whoamiFirst() {
        let home = NSTemporaryDirectory() + "p42-instr-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let svc = InstructionService(homeDirectory: home)
        svc.installInstructions(for: "codex")
        let md = (try? String(contentsOfFile: (home as NSString)
            .appendingPathComponent(".codex/AGENTS.md"), encoding: .utf8)) ?? ""
        #expect(md.contains("port42 whoami"))
        #expect(!md.contains("\"method\":\"space.current\""), "a bare space lookup reports the user's space")
    }

    /// The brief is the six every-turn rules (nautilus Phase 5, GM 2026-09-26): who you are, how a
    /// message reads, replies deliver themselves, @mention by exact name, call as yourself with the
    /// port42 command, and the skills for the rest. Both surfaces carry it; the long chat guidance
    /// moved into the skills (`SkillCatalogTests` checks every rule of it has a home there).
    @Test("both surfaces carry the six every-turn rules and point at the skills, and nothing more")
    @MainActor
    func briefIsTheSixRules() throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        state.createSpace(name: "general")
        let id = state.spaces.first(where: { $0.name == "general" })!.id
        let baked = state.bakeCompanionPrompt(name: "scout", spaceId: id, systemPrompt: nil)
        let home = NSTemporaryDirectory() + "p42-instr-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        InstructionService(homeDirectory: home).installInstructions(for: "codex")
        let md = (try? String(contentsOfFile: (home as NSString)
            .appendingPathComponent(".codex/AGENTS.md"), encoding: .utf8)) ?? ""
        for (surface, text) in [("claude brief", baked), ("codex AGENTS.md", md)] {
            #expect(text.contains(CompanionProtocol.rules), "\(surface) lacks the rules")
            #expect(text.contains(CompanionProtocol.pointer), "\(surface) lacks the pointer")
            for rule in ["never copy that leading prefix", "delivered back to the chat it came from automatically",
                         "the ONLY thing that delivers your message", "port42 whoami",
                         "Never read another tool's token file", "port42-ports", "port42-team"] {
                #expect(text.contains(rule), "\(surface) no longer says: \(rule)")
            }
            // The how-to moved to the skills: none of it rides every turn any more.
            for moved in ["TO CHANGE A PORT", "CHECK IT WORKS", "TO BE WOKEN BY A PORT", "BEFORE YOU MAKE A PORT"] {
                #expect(!text.contains(moved), "\(surface) still carries the how-to: \(moved)")
            }
        }
        #expect(baked.hasPrefix("You are scout, a space companion in Port42 connected to #general."))
        // Budget, from the 5.0 baseline of 4,230 characters.
        #expect(baked.count <= 2_000, "the brief is \(baked.count) characters; the budget is 2,000")
    }
}
