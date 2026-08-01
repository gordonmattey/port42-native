import Testing
import Foundation
@testable import Port42Lib

/// **A companion's name is an address** (2026-07-31).
///
/// Auto-registered CLI terminals take the port's TITLE as their companion name, and a title is prose.
/// The live teleport run produced a companion called `teleport: main`; codex terminals produced
/// `codex probe` and `codex 146`. Every one of them joined its space correctly, and not one could be
/// reached, because `MentionParser` accepts `@[a-zA-Z][a-zA-Z0-9-]*` and stops dead at the first
/// space or colon.
///
/// That is what made the teleport bug look like a membership failure. The doc's proposed fix was a
/// companion opt-in flag on `port.create` — machinery for a problem that was never there. The
/// session DID register; it just had a name nobody could type.
@Suite("Companion handles are mentionable")
struct CompanionNameTests {

    @Test("the two names that caused this, folded")
    func theRealCases() {
        // GM's live teleport run.
        #expect(CompanionName.mentionable("teleport: main") == "teleport-main")
        // Today's codex terminals.
        #expect(CompanionName.mentionable("codex probe") == "codex-probe")
        #expect(CompanionName.mentionable("codex 146") == "codex-146")
        // Already fine, and must come through untouched.
        #expect(CompanionName.mentionable("scout") == "scout")
        #expect(CompanionName.mentionable("claude-code") == "claude-code")
    }

    @Test("a run of rejected characters collapses to ONE hyphen")
    func runsCollapse() {
        #expect(CompanionName.mentionable("a   b") == "a-b")
        #expect(CompanionName.mentionable("a: :b") == "a-b")
        #expect(CompanionName.mentionable("main (fix)") == "main-fix")
    }

    @Test("leading and trailing junk is dropped, not hyphenated into place")
    func edgesAreTrimmed() {
        #expect(CompanionName.mentionable("  spaced  ") == "spaced")
        #expect(CompanionName.mentionable(":leading") == "leading")
        #expect(CompanionName.mentionable("trailing:") == "trailing")
    }

    @Test("a name must START with a letter, because the parser demands one")
    func mustStartWithALetter() {
        // `146` could not be addressed however it was spelled, so the digits are dropped rather
        // than left to produce a handle that silently never matches.
        #expect(CompanionName.mentionable("146 codex") == "codex")
        #expect(CompanionName.mentionable("2fast") == "fast")
    }

    @Test("nothing usable yields nil, so the caller keeps the original rather than an empty name")
    func nothingUsable() {
        #expect(CompanionName.mentionable("") == nil)
        #expect(CompanionName.mentionable("   ") == nil)
        #expect(CompanionName.mentionable("123") == nil)
        #expect(CompanionName.mentionable("!!!") == nil)
    }

    /// THE GATE. Anything this produces must be something the parser actually matches — otherwise
    /// the two definitions drift and we are back to companions that exist and cannot be addressed,
    /// which is the whole bug.
    @Test("round trip: every folded handle is matched by MentionParser")
    func roundTripsThroughTheParser() {
        let titles = ["teleport: main", "codex probe", "codex 146", "scout", "main (fix)",
                      "a   b", "  spaced  ", "146 codex", "claude-code", "Deploy Bot 3000"]
        for title in titles {
            guard let handle = CompanionName.mentionable(title) else { continue }
            let found = MentionParser.extractMentions(from: "hey @\(handle) look at this")
            #expect(found == ["@\(handle)"],
                    "'\(title)' folded to '\(handle)', which the parser does not match")
        }
    }

    @Test("a raw title is NOT matched — the thing being fixed")
    func rawTitlesFail() {
        // Proof the fold is load-bearing rather than cosmetic: mentioning the unfolded name gets
        // you the fragment before the space, which matches no companion.
        #expect(MentionParser.extractMentions(from: "hey @teleport: main") == ["@teleport"])
        #expect(MentionParser.extractMentions(from: "hey @codex probe") == ["@codex"])
    }
}
