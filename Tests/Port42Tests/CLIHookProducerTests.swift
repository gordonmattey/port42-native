import Testing
import Foundation
@testable import Port42Lib

@Suite("CLI hook producers")
struct CLIHookProducerTests {

    // MARK: - The table

    @Test("a startup command selects its producer, and an unknown one selects none")
    func selection() {
        #expect(CLIHookProducer.forCommand("claude")?.name == "claude")
        #expect(CLIHookProducer.forCommand("/Users/x/.local/bin/claude --resume abc")?.name == "claude")
        #expect(CLIHookProducer.forCommand("codex")?.name == "codex")
        #expect(CLIHookProducer.forCommand("codex --enable hooks")?.name == "codex")
        #expect(CLIHookProducer.forCommand("htop") == nil)
        #expect(CLIHookProducer.forCommand("zsh") == nil)
        // gemini was removed: no producer, so no claim of capability.
        #expect(CLIHookProducer.forCommand("gemini") == nil)
    }

    @Test("hooks-capability is DERIVED from the table, so it cannot drift from it")
    func hooksCapableFollowsTheTable() {
        for producer in CLIHookProducer.all {
            #expect(GhosttyTerminalController.isHooksCapable(producer.name),
                    "\(producer.name) has a producer but is not reported hooks-capable")
        }
        #expect(!GhosttyTerminalController.isHooksCapable("htop"))
        #expect(!GhosttyTerminalController.isHooksCapable("gemini"))
    }

    // MARK: - claude

    @Test("claude is intercepted: a shim symlink, a PATH prefix and a pinned session id")
    func claudePrepares() throws {
        let dir = NSTemporaryDirectory() + "p42-prod-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let out = CLIHookProducer.claude.prepare(.init(
            tempDir: dir, socketPath: "\(dir)/h.sock", sessionId: "panel-1", spaceId: "space-1",
            companionId: "comp-1", cwd: "/tmp", shimPath: "/x/port42-claude-shim",
            binaryPathOverride: "/usr/local/bin/claude", tokenOverride: "tok"))

        #expect(out.env["PORT42_CLAUDE_SHIM"] == "/x/port42-claude-shim")
        #expect(out.env["PORT42_CLAUDE_PATH"] == "/usr/local/bin/claude")
        #expect(out.env["CLAUDE_CODE_OAUTH_TOKEN"] == "tok")
        #expect(out.env["PORT42_CLAUDE_SESSION_ID"]?.isEmpty == false)
        // The interceptor has to be FIRST on PATH, which is what the prefix is for.
        #expect(out.pathPrefix == dir)
        // The symlink is the non-zsh fallback; the zsh function is the primary.
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: "\(dir)/claude")
        #expect(link == "/x/port42-claude-shim")
    }

    // MARK: - codex

    @Test("codex is NOT intercepted: a config home instead of a PATH prefix")
    func codexPrepares() throws {
        let dir = NSTemporaryDirectory() + "p42-prod-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let out = CLIHookProducer.codex.prepare(.init(
            tempDir: dir, socketPath: "\(dir)/h.sock", sessionId: "panel-1", spaceId: "space-1",
            companionId: nil, cwd: "/tmp/work", shimPath: "/x/port42-claude-shim"))

        #expect(out.env["CODEX_HOME"] == "\(dir)/codex-home")
        // Nothing is intercepted, so nothing goes on PATH. This is the difference the producer
        // abstraction exists to express.
        #expect(out.pathPrefix.isEmpty)
        #expect(out.env["PORT42_CLAUDE_SHIM"] == nil)

        // The home MIRRORS the user's real one, entry by entry, owning only config.toml. Linking a
        // hand-picked subset left codex on a first-run setup screen swallowing input — silently.
        let real = (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
        let realEntries = Set((try? FileManager.default.contentsOfDirectory(atPath: real)) ?? [])
        for entry in realEntries where entry != "config.toml" {
            let dest = try? FileManager.default.destinationOfSymbolicLink(
                atPath: "\(dir)/codex-home/\(entry)")
            #expect(dest == "\(real)/\(entry)", "\(entry) is not mirrored")
        }
        // config.toml is OURS: a real file, not a link to the user's.
        let configIsLink = (try? FileManager.default.destinationOfSymbolicLink(
            atPath: "\(dir)/codex-home/config.toml")) != nil
        #expect(!configIsLink, "config.toml must be ours, not a link to the user's own")
    }

    @Test("the codex config carries all four things it needs to work")
    func codexConfigContents() {
        let toml = CLIHookProducer.codexConfig(shimPath: "/x/shim", cwd: "/tmp/work")

        // Hooks are OFF by default — this was one failed spike run.
        #expect(toml.contains("[features]"))
        #expect(toml.contains("hooks = true"))
        // codex_hooks is the deprecated spelling; codex warns and ignores it.
        #expect(!toml.contains("codex_hooks"))
        // Without trust codex refuses to START, which looks exactly like hooks failing.
        #expect(toml.contains("[projects.\"/tmp/work\"]"))
        #expect(toml.contains("trust_level = \"trusted\""))
        // The turn-end event, routed to the shim in notify mode.
        #expect(toml.contains("[[hooks.Stop]]"))
        #expect(toml.contains("command = \"'/x/shim' notify turnComplete\""))
        #expect(toml.contains("command = \"'/x/shim' notify sessionStarted\""))
    }

    @Test("an empty cwd still yields a trusted directory rather than a broken table")
    func codexConfigWithoutCwd() {
        let toml = CLIHookProducer.codexConfig(shimPath: "/x/shim", cwd: "")
        #expect(toml.contains("[projects.\"\(NSHomeDirectory())\"]"))
    }

    /// Codex resolves symlinks before checking trust, and `/tmp` is a symlink to `/private/tmp` on
    /// macOS. Trusting only the path we were handed made codex EXIT before starting — which from
    /// Port42's side looked like hooks not firing, because the port opened and bound a surface with
    /// no process ever behind it.
    @Test("a symlinked cwd is trusted in BOTH forms, or codex refuses to start")
    func codexTrustsResolvedPaths() {
        let both = CLIHookProducer.trustedDirectories(for: "/tmp")
        #expect(both.contains("/tmp"))
        #expect(both.contains("/private/tmp"))

        let toml = CLIHookProducer.codexConfig(shimPath: "/x/shim", cwd: "/tmp")
        #expect(toml.contains("[projects.\"/tmp\"]"))
        #expect(toml.contains("[projects.\"/private/tmp\"]"))

        // A path that is not a symlink is listed once, not twice.
        #expect(CLIHookProducer.trustedDirectories(for: "/usr/local") == ["/usr/local"])
    }

    @Test("no shim means no hooks, not a broken config")
    func codexWithoutShimDegrades() throws {
        let dir = NSTemporaryDirectory() + "p42-prod-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let out = CLIHookProducer.codex.prepare(.init(
            tempDir: dir, socketPath: "\(dir)/h.sock", sessionId: "p", spaceId: "s",
            companionId: nil, cwd: "/tmp", shimPath: nil))

        #expect(out.env.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: "\(dir)/codex-home/config.toml"))
    }
}
