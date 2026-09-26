import Testing
import Foundation
@testable import Port42Lib

// The Port42 skills load in every Port42 terminal, for that session only (nautilus Phase 5.3): the
// shim hands claude the plugin (`--plugin-dir`, from PORT42_SKILLS_DIR), and codex finds the skills
// in its own home. Nothing is written into the user's ~/.claude or ~/.codex.
@Suite("Skills load per session")
struct SkillLoadingTests {

    @Test("every terminal names the running app's skills plugin")
    func terminalNamesPlugin() {
        let session = TerminalSessionBootstrap.make(
            sessionId: "ABCDEF12-3456-7890-ABCD-\(UUID().uuidString.suffix(12))",
            spaceId: "s", spaceName: "demo", shimPath: nil, claudePath: "/usr/bin/true",
            skillsPlugin: "/app/port42-skills")
        #expect(session.env["PORT42_SKILLS_DIR"] == "/app/port42-skills")
    }

    @Test("a codex home holds the user's skills and Port42's; Port42's wins a clash; ~/.codex/skills untouched")
    func codexHomeSkills() throws {
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "p42-skills-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: root) }
        let home = "\(root)/home", dir = "\(root)/port", ours = "\(root)/app/skills"
        for d in ["\(home)/.codex/skills/my-skill", "\(home)/.codex/skills/port42", "\(ours)/port42", "\(ours)/port42-ports", dir] {
            try fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        try "old".write(toFile: "\(home)/.codex/skills/port42/SKILL.md", atomically: true, encoding: .utf8)
        let before = try fm.contentsOfDirectory(atPath: "\(home)/.codex/skills").sorted()

        _ = CLIHookProducer.codex.prepare(.init(
            tempDir: dir, socketPath: "\(dir)/h.sock", sessionId: "p", spaceId: "s", companionId: nil,
            cwd: "/tmp", shimPath: "/x/shim", homeOverride: home, skillsDir: ours))

        let skills = "\(dir)/codex-home/skills"
        #expect((try? fm.destinationOfSymbolicLink(atPath: skills)) == nil, "the skills folder must be the home's own, not a link to ~/.codex/skills")
        #expect(try fm.destinationOfSymbolicLink(atPath: "\(skills)/my-skill") == "\(home)/.codex/skills/my-skill")
        #expect(try fm.destinationOfSymbolicLink(atPath: "\(skills)/port42") == "\(ours)/port42", "the app's own skill must win a clash")
        #expect(try fm.destinationOfSymbolicLink(atPath: "\(skills)/port42-ports") == "\(ours)/port42-ports")
        #expect(try fm.contentsOfDirectory(atPath: "\(home)/.codex/skills").sorted() == before, "~/.codex/skills was written")
    }
}
