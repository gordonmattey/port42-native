import Testing
import Foundation
@testable import Port42Lib

// Several Port42 instances share one home. Instruction files used to carry the launching
// instance's gateway port, and every instance rewrote them at launch, so the last one launched
// decided which gateway EVERY session called: Dev3's 4245 reached prod's Codex sessions, and prod's
// Claude sessions read 4245 in ~/.claude/CLAUDE.md. A file names the port as an env expression now,
// each terminal carries its own instance's port, and Codex's AGENTS.md is written into its own
// per-instance home instead of the user's.
@Suite("Instructions across instances")
struct MultiInstanceInstructionsTests {

    /// What a shell makes of the block's gateway expression, with and without the env var.
    func expand(_ expr: String, port: String?) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-fc", "print -r -- \(expr)"]
        var env = ["PATH": "/usr/bin:/bin"]
        if let port { env["PORT42_GATEWAY_PORT"] = port }
        p.environment = env
        let out = Pipe(); p.standardOutput = out
        try p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("the gateway expression reaches the instance that started the session, else prod")
    func expressionExpands() throws {
        #expect(try expand(CompanionProtocol.envGateway, port: "4245") == "4245")
        #expect(try expand(CompanionProtocol.envGateway, port: nil) == "4242")
    }

    @Test("no instruction file names an instance's port")
    func blockNamesNoPort() {
        for companion in [false, true] {
            let md = InstructionService.markdown(toolName: "Codex", companionProtocol: companion)
            let urls = md.components(separatedBy: "http://127.0.0.1:").dropFirst()
            #expect(!urls.isEmpty, "no gateway URL at all: the check would pass vacuously")
            for u in urls {
                #expect(u.hasPrefix(CompanionProtocol.envGateway + "/call"),
                        "a gateway URL with a baked port: \(u.prefix(30))")
            }
        }
    }

    @Test("every terminal carries its own instance's gateway port")
    func terminalEnvCarriesPort() {
        let session = TerminalSessionBootstrap.make(
            sessionId: "ABCDEF12-3456-7890-ABCD-EF1234567890",
            spaceId: "space-1", spaceName: "demo", shimPath: nil, claudePath: "/usr/bin/true")
        #expect(session.env["PORT42_GATEWAY_PORT"] == String(GatewayProcess.configuredPort))
    }

    @Test("codex gets its own AGENTS.md: the user's content plus the block; the user's file is untouched")
    func codexHomeOwnsAgents() throws {
        let fm = FileManager.default
        let dir = NSTemporaryDirectory() + "p42-agents-\(UUID().uuidString)"
        let home = NSTemporaryDirectory() + "p42-home-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: dir); try? fm.removeItem(atPath: home) }
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: "\(home)/.codex", withIntermediateDirectories: true)
        // The user's own file, carrying a stale block an old install left there.
        let users = "my rules\n\n<!-- port42:start -->\ncurl http://127.0.0.1:4245/call\n<!-- port42:end -->\n"
        try users.write(toFile: "\(home)/.codex/AGENTS.md", atomically: true, encoding: .utf8)

        for _ in 0..<2 {   // a second spawn replaces the first's file, it does not stack blocks
            _ = CLIHookProducer.codex.prepare(.init(
                tempDir: dir, socketPath: "\(dir)/h.sock", sessionId: "panel-1", spaceId: "space-1",
                companionId: nil, cwd: "/tmp/work", shimPath: "/x/port42-claude-shim",
                homeOverride: home))
        }

        let path = "\(dir)/codex-home/AGENTS.md"
        #expect((try? fm.destinationOfSymbolicLink(atPath: path)) == nil, "a link would share it again")
        let ours = try String(contentsOfFile: path, encoding: .utf8)
        #expect(ours.hasPrefix("my rules"), "the user's own instructions are kept")
        #expect(ours.components(separatedBy: "<!-- port42:start -->").count == 2, "one block")
        #expect(!ours.contains("4245"), "the stale block is replaced")
        #expect(ours.contains("SPACE COMPANION"), "codex gets the companion section")
        #expect(try String(contentsOfFile: "\(home)/.codex/AGENTS.md", encoding: .utf8) == users,
                "the user's file is never written")
    }

    /// `~/.local/bin/port42` belongs to whichever instance installed last, and a user's startup
    /// files usually put `~/.local/bin` first. A terminal must still run its OWN instance's CLI, in
    /// an interactive shell (Claude's Bash tool) and a login shell (how Codex runs a command).
    @Test("a terminal runs its own instance's port42, even when the user's rc puts another first")
    func ownCLIWinsOnPath() throws {
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "p42-cli-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: root) }
        let ours = "\(root)/app/port42-cli", decoy = "\(root)/decoy"
        for dir in ["\(root)/app", decoy, "\(root)/home"] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        for f in [ours, "\(decoy)/port42"] {
            try "#!/bin/sh\necho \(f)\n".write(toFile: f, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f)
        }
        // The user's own startup files, prepending the decoy the way `~/.local/bin` usually is.
        for rc in [".zshrc", ".zprofile"] {
            try "export PATH=\"\(decoy):$PATH\"\n".write(toFile: "\(root)/home/\(rc)", atomically: true, encoding: .utf8)
        }
        let session = TerminalSessionBootstrap.make(
            sessionId: "ABCDEF12-3456-7890-ABCD-\(UUID().uuidString.suffix(12))",
            spaceId: "space-1", spaceName: "demo", shimPath: nil, claudePath: "/usr/bin/true", cliPath: ours)
        defer { try? fm.removeItem(atPath: session.env["ZDOTDIR"] ?? "/nonexistent") }

        for flags in ["-ic", "-lc"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = [flags, "port42"]
            var env = session.env
            env["PORT42_REAL_ZDOTDIR"] = "\(root)/home"
            env["HOME"] = "\(root)/home"
            p.environment = env
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            let ran = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(ran == ours, "zsh \(flags) ran \(ran), not this instance's CLI")
        }
    }
}

/// Port42 wrote instruction blocks before the markers existed, and those survive every refresh.
/// They name a fixed loopback port, carry no `Authorization` header, and point at a Settings section
/// that is gone, so an agent that reads a file top to bottom follows the broken copy and is refused
/// with `auth_required`, which names the wrong problem. Measured on a real machine: `~/.gemini/GEMINI.md`
/// held exactly that above a correct managed block.
///
/// The managed block therefore goes FIRST when unmanaged call instructions are present, and nowhere
/// near a deletion: the user's content is preserved byte for byte.
@Suite("Legacy instruction blocks lose precedence, and survive")
struct LegacyInstructionBlockTests {

    let legacy = """
    # My notes

    ```bash
    curl -s http://127.0.0.1:4242/call \\
      -d '{"method":"<method>","args":{...}}'
    ```

    Pre-approve categories in Port42 Settings -> Remote Access.
    """

    @Test("unmanaged call instructions are detected")
    func detectsLegacy() {
        #expect(InstructionService.hasUnmanagedCallInstructions(legacy))
        #expect(!InstructionService.hasUnmanagedCallInstructions("# My notes\n\nNothing about ports here."))
    }

    @Test("a managed block does not count as unmanaged, however it is written")
    func managedBlockIsNotLegacy() {
        let managed = "# Notes\n\n<!-- port42:start -->\ncurl http://127.0.0.1:4242/call\n<!-- port42:end -->\n"
        #expect(!InstructionService.hasUnmanagedCallInstructions(managed))
    }

    @Test("with legacy content present the block goes first, and nothing is deleted")
    func blockWinsPrecedence() {
        let block = "<!-- port42:start -->\nfresh\n<!-- port42:end -->"
        let out = InstructionService.merged(existing: legacy, block: block)

        #expect(out.hasPrefix(block), "the authoritative block must be read before the stale one")
        #expect(out.contains("# My notes"), "the user's content must survive")
        #expect(out.contains("Pre-approve categories"), "even the stale part is the user's file, not ours to delete")
    }

    @Test("without legacy content the block still appends, which is the polite position")
    func appendsWhenClean() {
        let block = "<!-- port42:start -->\nfresh\n<!-- port42:end -->"
        let out = InstructionService.merged(existing: "# My notes\n", block: block)
        #expect(out.hasSuffix(block))
        #expect(out.hasPrefix("# My notes"))
    }

    @Test("an existing managed block is still replaced in place, wherever it sits")
    func replacesInPlace() {
        let existing = "# Top\n\n<!-- port42:start -->\nold\n<!-- port42:end -->\n\n# Bottom\n"
        let block = "<!-- port42:start -->\nnew\n<!-- port42:end -->"
        let out = InstructionService.merged(existing: existing, block: block)
        #expect(out.contains("new") && !out.contains("old"))
        #expect(out.hasPrefix("# Top") && out.contains("# Bottom"))
    }
}
