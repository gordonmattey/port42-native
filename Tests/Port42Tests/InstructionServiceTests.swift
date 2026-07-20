import Testing
import Foundation
@testable import Port42Lib

// Knowledge item C: instruction files are SLIM POINTERS, not embedded inventories; every
// instruction-file ecosystem gets one (CLAUDE.md, GEMINI.md, Codex's AGENTS.md); and the app
// rewrites any installed block at boot so install-time artifacts can no longer drift.
@Suite("InstructionService (slim block, AGENTS.md, boot refresh)")
@MainActor
struct InstructionServiceTests {

    func tempHome() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p42-instr-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("the installed block is a pointer, not an embedded inventory")
    func blockIsSlim() throws {
        let home = try tempHome()
        let svc = InstructionService(homeDirectory: home)
        svc.installInstructions(for: "claude")

        let md = try String(contentsOfFile: home + "/.claude/CLAUDE.md", encoding: .utf8)
        #expect(md.contains("port42:start"))
        #expect(md.contains("127.0.0.1:4242/call"), "the curl how-to must survive")
        #expect(md.contains("\"method\":\"help\""), "help is the API reference path")
        #expect(md.contains("\"topic\":\"ports\""), "the port manual pointer must be present")
        #expect(md.contains("llms.txt"), "the offline fallback URL must be present")
        // The inventory lives behind help/llms.txt now — embedding it here is the drift bug.
        #expect(!md.contains("### automation"), "no embedded method inventory")
        #expect(md.components(separatedBy: "\n").count < 60, "the block must stay slim")
    }

    @Test("codex installs to .codex/AGENTS.md")
    func codexTarget() throws {
        let home = try tempHome()
        let svc = InstructionService(homeDirectory: home)
        svc.installInstructions(for: "codex")
        let md = try String(contentsOfFile: home + "/.codex/AGENTS.md", encoding: .utf8)
        #expect(md.contains("port42:start"))
        #expect(md.contains("Codex"), "the block names the tool it briefs")
        #expect(svc.hasCodexInstructions)
    }

    @Test("boot refresh rewrites an installed block, leaves everything else alone")
    func bootRefresh() throws {
        let home = try tempHome()
        let svc = InstructionService(homeDirectory: home)

        // An installed-but-stale block, with the user's own content around it.
        let stale = "user preamble\n\n<!-- port42:start -->\nOLD DRIFTED BLOCK\n<!-- port42:end -->\n\nuser trailer\n"
        try FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        try stale.write(toFile: home + "/.claude/CLAUDE.md", atomically: true, encoding: .utf8)
        // A file with NO port42 block must not be touched.
        try FileManager.default.createDirectory(atPath: home + "/.gemini", withIntermediateDirectories: true)
        try "my own gemini notes\n".write(toFile: home + "/.gemini/GEMINI.md", atomically: true, encoding: .utf8)

        svc.refreshInstalled()

        let claude = try String(contentsOfFile: home + "/.claude/CLAUDE.md", encoding: .utf8)
        #expect(!claude.contains("OLD DRIFTED BLOCK"), "the stale block must be rewritten")
        #expect(claude.contains("\"topic\":\"ports\""), "rewritten from the live template")
        #expect(claude.contains("user preamble") && claude.contains("user trailer"),
                "content outside the block is preserved")
        let gemini = try String(contentsOfFile: home + "/.gemini/GEMINI.md", encoding: .utf8)
        #expect(gemini == "my own gemini notes\n", "a file without a block is untouched")
        // A tool never installed must not appear.
        #expect(!FileManager.default.fileExists(atPath: home + "/.codex/AGENTS.md"))
    }
}
