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

    /// A fake home with a populated `~/.codex`, so this suite does not depend on whether the machine
    /// running it happens to use codex. Returns (home, realCodexDir).
    func fakeCodexHome() throws -> (home: String, codex: String) {
        let home = NSTemporaryDirectory() + "p42-home-\(UUID().uuidString)"
        let codex = "\(home)/.codex"
        try FileManager.default.createDirectory(atPath: codex, withIntermediateDirectories: true)
        try "{}".write(toFile: "\(codex)/auth.json", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: "\(codex)/sessions",
                                                withIntermediateDirectories: true)
        return (home, codex)
    }

    @Test("codex is NOT intercepted: a config home instead of a PATH prefix")
    func codexPrepares() throws {
        let dir = NSTemporaryDirectory() + "p42-prod-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let (home, real) = try fakeCodexHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        let out = CLIHookProducer.codex.prepare(.init(
            tempDir: dir, socketPath: "\(dir)/h.sock", sessionId: "panel-1", spaceId: "space-1",
            companionId: nil, cwd: "/tmp/work", shimPath: "/x/port42-claude-shim",
            homeOverride: home))

        #expect(out.env["CODEX_HOME"] == "\(dir)/codex-home")
        // Nothing is intercepted, so nothing goes on PATH. This is the difference the producer
        // abstraction exists to express.
        #expect(out.pathPrefix.isEmpty)
        #expect(out.env["PORT42_CLAUDE_SHIM"] == nil)

        // The home MIRRORS the user's real one, entry by entry, owning only config.toml. Linking a
        // hand-picked subset left codex on a first-run setup screen swallowing input — silently.
        let realEntries = Set((try? FileManager.default.contentsOfDirectory(atPath: real)) ?? [])
        #expect(!realEntries.isEmpty)
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

    // MARK: - Every CLI is wired into every terminal (2026-07-31)
    //
    // GM, measured live: typing `claude` into a Port42 terminal auto-registers it as a space
    // companion; typing `codex` into the same terminal does nothing. Both have producers, both emit
    // SessionStart, and `makeTerminalController` wires `onSessionStarted` for every terminal panel,
    // so nothing in the companion path was missing.
    //
    // The divergence was SELECTION. A terminal passed `forCommand(startupCommand)`, a plain
    // `/bin/zsh` matches nothing, and `make` fell back to CLAUDE. That fallback's reasoning was
    // right — a plain shell must still be wired for a CLI typed in later, which is what makes ad-hoc
    // terminals become companions at all — but it named one CLI, and only claude's mechanism
    // survives being typed later, because a shell function beats PATH. Codex is configured by
    // CODEX_HOME, whose producer never ran, so a typed `codex` read the user's own config with no
    // Port42 hooks in it.

    @Test("env collision: the FIRST producer keeps the variable, and the loss is not silent")
    func envCollisionFirstWins() {
        let a = CLIHookProducer.Output(env: ["SHARED": "from-a", "ONLY_A": "a"])
        let b = CLIHookProducer.Output(env: ["SHARED": "from-b", "ONLY_B": "b"])
        let merged = CLIHookProducer.merge([("a", a), ("b", b)])

        // Last-write-wins would make the outcome depend on table order and surface much later.
        #expect(merged.env["SHARED"] == "from-a")
        #expect(merged.env["ONLY_A"] == "a")
        #expect(merged.env["ONLY_B"] == "b")
    }

    @Test("path prefixes are all kept, in producer order — prepending is not exclusive")
    func pathPrefixesJoin() {
        let merged = CLIHookProducer.merge([
            ("a", .init(pathPrefix: "/one")),
            ("b", .init(pathPrefix: "")),        // a CLI needing no interception contributes nothing
            ("c", .init(pathPrefix: "/two")),
        ])
        #expect(merged.pathPrefix == "/one:/two")
    }

    @Test("shell lines concatenate in producer order")
    func shellLinesConcatenate() {
        let merged = CLIHookProducer.merge([
            ("a", .init(shellLines: ["# a", "export A=1"])),
            ("b", .init(shellLines: ["# b"])),
        ])
        #expect(merged.shellLines == ["# a", "export A=1", "# b"])
    }

    @Test("a PLAIN SHELL wires BOTH CLIs — claude as before, codex which used to be missed")
    func plainShellWiresEveryCLI() throws {
        let dir = NSTemporaryDirectory() + "p42-prod-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let (home, _) = try fakeCodexHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        // `/bin/zsh` matches no producer: under the old rule this reached claude by fallback and
        // codex not at all.
        #expect(CLIHookProducer.forCommand("/bin/zsh") == nil)

        let out = CLIHookProducer.prepareAll(.init(
            tempDir: dir, socketPath: "\(dir)/h.sock", sessionId: "panel-1", spaceId: "space-1",
            companionId: nil, cwd: "/tmp", shimPath: "/tmp/fake-port42-shim",
            binaryPathOverride: "/usr/bin/true", tokenOverride: "", homeOverride: home))

        // Claude's guarantee is unchanged. Losing this would stop ad-hoc terminals becoming
        // companions, which is the thing the old fallback existed to protect.
        #expect(out.env["PORT42_CLAUDE_SHIM"] == "/tmp/fake-port42-shim")
        #expect(out.shellLines.contains { $0.contains("claude() {") })

        // Codex now gets the same treatment by its own mechanism. The EXPORT is the load-bearing
        // half: the process env alone only covers codex as a startup command, while a codex typed
        // into the shell later reads what the shell exports.
        #expect(out.env["CODEX_HOME"] == "\(dir)/codex-home")
        #expect(out.shellLines.contains { $0.contains("export CODEX_HOME=") })
    }

    /// The hook that never ran, and why.
    ///
    /// Codex "records trust against the hook's current hash, so new or changed hooks are marked for
    /// review and SKIPPED until trusted" (published reference). Skipped, not prompted for, while
    /// `/hooks` still reports the hook active — which is what made this read as "codex ignores
    /// SessionStart" across 0.140.0 and 0.146.0. SessionStart also fires before the TUI can ask, so
    /// an interactive grant can never arrive in time for it.
    ///
    /// Measured 2026-07-31: without the flag, zero `sessionStarted` on every run of both versions;
    /// with it, the event lands and a companion registers with no interactive step.
    @Test("codex is NOT launched with hook trust bypassed — the flag hides the review it needs")
    func codexDoesNotBypassHookTrust() throws {
        let dir = NSTemporaryDirectory() + "p42-prod-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let (home, _) = try fakeCodexHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        let out = CLIHookProducer.codex.prepare(.init(
            tempDir: dir, socketPath: "\(dir)/h.sock", sessionId: "p", spaceId: "s",
            companionId: nil, cwd: "/tmp", shimPath: "/x/shim", homeOverride: home))

        // Tried and removed the same day. The `/hooks` table has three columns — Installed, Active,
        // Review — and the flag addresses none of them: it suppresses the startup review PROMPT
        // without enabling or trusting the hook, so the one interaction that would actually turn it
        // on can never happen. Measured: with the flag, no prompt and no hook; without it, the
        // prompt appears and answering once writes `enabled = true` and a `trusted_hash` into the
        // config, which is the state that matters.
        #expect(!out.shellLines.contains { $0.contains("--dangerously-bypass-hook-trust") },
                "the flag hides the review the hook needs, so it must not be injected")
        // The export is the part that IS load-bearing, and must survive this removal.
        #expect(out.shellLines.contains { $0.contains("export CODEX_HOME=") })
    }

    @Test("codex prepares NOTHING on a machine with no ~/.codex")
    func codexInertWithoutRealHome() throws {
        let dir = NSTemporaryDirectory() + "p42-prod-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let emptyHome = NSTemporaryDirectory() + "p42-home-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: emptyHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: emptyHome) }

        // Now that this producer runs for EVERY terminal, being inert here is what stops the fix
        // becoming a worse bug: pointing CODEX_HOME at a home with no onboarding state makes codex
        // treat it as a first run, sit on its setup screen and swallow every keystroke pushed at it.
        let out = CLIHookProducer.codex.prepare(.init(
            tempDir: dir, socketPath: "\(dir)/h.sock", sessionId: "p", spaceId: "s",
            companionId: nil, cwd: "/tmp", shimPath: "/x/shim", homeOverride: emptyHome))

        #expect(out.env["CODEX_HOME"] == nil)
        #expect(out.shellLines.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: "\(dir)/codex-home/config.toml"))
    }

    /// THE REGRESSION GUARD, at the seam a terminal actually goes through.
    ///
    /// `prepareAll` being right is not the same as the terminal reaching it. Reverting
    /// `GhosttyTerminalController` to `producer: forCommand(config.startupCommand)` broke NOTHING in
    /// this suite when it was first written, because every other test called `prepareAll` directly.
    /// This one goes through `TerminalSessionBootstrap.make` with no producer, which is exactly what
    /// the controller now passes, and fails if the per-command fallback comes back.
    @Test("a terminal built with NO producer wires every CLI, not just claude")
    func makeWithoutProducerWiresEveryCLI() throws {
        let (home, _) = try fakeCodexHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        // A temp stable dir. Without this seam the bootstrap resolves the REAL Application Support
        // path and the test writes into the running daily driver's state.
        let stable = NSTemporaryDirectory() + "p42-stable-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: stable, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: stable) }

        let session = TerminalSessionBootstrap.make(
            sessionId: "ALLPROD0-1111-2222-3333-444444444444",
            spaceId: "s", spaceName: "n", shimPath: "/tmp/fake-port42-shim",
            claudePath: "/usr/bin/true", oauthToken: "", home: home, stableDir: stable)
        defer { TerminalSessionBootstrap.cleanup(tempDir: session.tempDir) }

        // Claude, as the old fallback already guaranteed.
        #expect(session.env["PORT42_CLAUDE_SHIM"] == "/tmp/fake-port42-shim")
        // Codex, which the old fallback silently skipped — the whole bug. Its home is the STABLE
        // dir, not the per-port one, so hook trust survives.
        #expect(session.env["CODEX_HOME"] == "\(stable)/codex-home")

        // And both mechanisms reach the shell, which is what makes a CLI TYPED IN LATER work.
        let zshrc = try String(contentsOfFile: "\(session.tempDir)/.zshrc", encoding: .utf8)
        #expect(zshrc.contains("claude() {"))
        #expect(zshrc.contains("export CODEX_HOME="))
    }

    /// THE PATH MUST NOT MOVE. Codex keys hook trust by the defining config's path, so a home under
    /// the per-port `tempDir` presented a hook it had never seen on every spawn — reviewed, then
    /// skipped. Two ports must land on ONE codex-home.
    @Test("codex-home is per-INSTANCE, not per-port, so hook trust can persist")
    func codexHomeIsStableAcrossPorts() throws {
        let stable = NSTemporaryDirectory() + "p42-stable-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: stable, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: stable) }
        let (home, _) = try fakeCodexHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        func prepare(port: String) -> CLIHookProducer.Output {
            let dir = NSTemporaryDirectory() + "p42-prod-\(port)-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            return CLIHookProducer.codex.prepare(.init(
                tempDir: dir, socketPath: "\(dir)/h.sock", sessionId: port, spaceId: "s",
                companionId: nil, cwd: "/tmp", shimPath: "/x/shim",
                homeOverride: home, stableDir: stable))
        }

        let a = prepare(port: "panel-A"), b = prepare(port: "panel-B")
        #expect(a.env["CODEX_HOME"] == "\(stable)/codex-home")
        #expect(a.env["CODEX_HOME"] == b.env["CODEX_HOME"],
                "two ports must share one codex-home, or trust is re-reviewed every spawn")
    }

    @Test("without a stableDir it still works, falling back to the per-port temp dir")
    func codexHomeFallsBackToTempDir() throws {
        let dir = NSTemporaryDirectory() + "p42-prod-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let (home, _) = try fakeCodexHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        let out = CLIHookProducer.codex.prepare(.init(
            tempDir: dir, socketPath: "\(dir)/h.sock", sessionId: "p", spaceId: "s",
            companionId: nil, cwd: "/tmp", shimPath: "/x/shim", homeOverride: home))
        #expect(out.env["CODEX_HOME"] == "\(dir)/codex-home")
    }

    @Test("a second spawn preserves the hook trust codex wrote into the first")
    func trustSurvivesRespawn() throws {
        let stable = NSTemporaryDirectory() + "p42-stable-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: stable, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: stable) }
        let (home, _) = try fakeCodexHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        func prepare(cwd: String) {
            let dir = NSTemporaryDirectory() + "p42-prod-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            _ = CLIHookProducer.codex.prepare(.init(
                tempDir: dir, socketPath: "\(dir)/h.sock", sessionId: "p", spaceId: "s",
                companionId: nil, cwd: cwd, shimPath: "/x/shim",
                homeOverride: home, stableDir: stable))
        }
        let cfg = "\(stable)/codex-home/config.toml"

        prepare(cwd: "/tmp/one")
        // Stand in for codex granting trust: it appends its state to the config we generated.
        let granted = (try String(contentsOfFile: cfg, encoding: .utf8)) + """

        [hooks.state]

        [hooks.state."\(cfg):session_start:0:0"]
        trusted_hash = "sha256:granted"
        """
        try granted.write(toFile: cfg, atomically: true, encoding: .utf8)

        // A different terminal, different cwd, same instance.
        prepare(cwd: "/tmp/two")
        let after = try String(contentsOfFile: cfg, encoding: .utf8)
        #expect(after.contains("sha256:granted"),
                "regeneration must not discard the trust codex recorded, or the hook is skipped again")
        #expect(after.contains("[projects.\"/tmp/two\"]"), "the new cwd is trusted too")
    }

    // MARK: - A codex companion is briefed through its starting prompt
    //
    // Codex does NOT run SessionStart at launch: it holds hooks pending and runs them inside the
    // first turn (`run_pending_session_start_hooks` under `session_task.run:run_turn`, dispatched
    // from `user_input`). Measured 2026-07-31 on Dev2: launch and wait registers nothing, ever, on
    // 0.140.0 and 0.146.0, under every combination of trust state, config path and CLI flag. One
    // turn registers it immediately.
    //
    // So the briefing is not a nicety, it is the mechanism. Claude receives its identity invisibly
    // via `--append-system-prompt`; codex's only channel is the `[PROMPT]` positional, and that
    // same turn is what fires the hook.

    @Test("codex gets the companion briefing as its starting prompt")
    func codexIsBriefedViaPrompt() {
        let out = CLIHookProducer.startupCommand(base: "codex", companionPrompt: "You are scout.")
        #expect(out == "codex 'You are scout.'")
    }

    /// A LONG briefing survives being typed, so codex gets the same text claude does.
    ///
    /// This existed briefly as the opposite assertion. A spawn carrying the full ~1200-char prompt
    /// appeared to fail, and I concluded the line was too long to type and shortened it. It was a
    /// misdiagnosis twice over: the spawn had actually SUCCEEDED and simply took longer to register
    /// than the test's polling window, because a longer prompt means a longer first model call.
    /// Measured afterwards: a 1400-char line reaches the shell intact, and the `'\''` escaping
    /// round-trips. GM called the short prompt a workaround before any of that was known, and was
    /// right.
    @Test("a long briefing is passed whole — no abridging, no length workaround")
    func longBriefingSurvives() {
        let long = String(repeating: "the quick brown fox. ", count: 60)   // ~1260 chars
        let out = CLIHookProducer.startupCommand(base: "codex", companionPrompt: long)
        #expect(out.contains(long), "the briefing must be passed whole")
        #expect(out.hasPrefix("codex '"))
    }

    @Test("a prompt with quotes is escaped, not broken")
    func codexPromptIsQuoted() {
        let out = CLIHookProducer.startupCommand(base: "codex",
                                                 companionPrompt: "don't guess; ask")
        // Naive quoting ends the string at the apostrophe and the rest becomes shell words.
        #expect(out == "codex 'don'\\''t guess; ask'")
    }

    @Test("claude is UNTOUCHED — its briefing already travels invisibly via the shim")
    func claudeKeepsItsOwnChannel() {
        #expect(CLIHookProducer.startupCommand(base: "claude",
                                               companionPrompt: "You are scout.") == "claude")
    }

    @Test("a plain shell and an unknown tool are untouched")
    func nonCLIsAreUntouched() {
        #expect(CLIHookProducer.startupCommand(base: "/bin/zsh", companionPrompt: "x") == "/bin/zsh")
        #expect(CLIHookProducer.startupCommand(base: "htop", companionPrompt: "x") == "htop")
    }

    @Test("no companion prompt means no injected prompt — an ad-hoc codex is left alone")
    func adHocCodexIsUntouched() {
        // A user typing `codex` in a plain terminal must not get our text in their session. They
        // register on their own first turn instead, which costs nothing.
        #expect(CLIHookProducer.startupCommand(base: "codex", companionPrompt: "") == "codex")
    }

    @Test("a caller that already supplied its own arguments is not overridden")
    func explicitArgsWin() {
        // `codex --resume abc` or `codex "do the thing"` is a deliberate act; appending a second
        // positional would change what the caller asked for.
        #expect(CLIHookProducer.startupCommand(base: "codex --resume abc",
                                               companionPrompt: "You are scout.") == "codex --resume abc")
        #expect(CLIHookProducer.startupCommand(base: "codex 'their prompt'",
                                               companionPrompt: "You are scout.") == "codex 'their prompt'")
    }

    // MARK: - The assembler owns the zshrc

    @Test("the zshrc helper is CLI-AGNOSTIC: with no producer lines it names no CLI")
    func zshHelperIsAgnostic() throws {
        let dir = NSTemporaryDirectory() + "p42-zsh-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        #expect(TerminalSessionBootstrap.writeZshIntegration(tempDir: dir, producerLines: []))
        let zshrc = try String(contentsOfFile: "\(dir)/.zshrc", encoding: .utf8)

        // The `claude()` function used to be hard-coded HERE, which made one CLI's mechanism the
        // property of a shared helper and left a second CLI nowhere to put its own setup.
        #expect(!zshrc.contains("claude"), "a shared helper must not know any CLI's name")
        #expect(zshrc.contains("source"))            // still sources the user's real .zshrc
        #expect(zshrc.contains("PORT42_CWD_FILE"))   // cwd tracking is true of any terminal
    }

    @Test("contributed lines reach the written zshrc")
    func contributedLinesAreWritten() throws {
        let dir = NSTemporaryDirectory() + "p42-zsh-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        #expect(TerminalSessionBootstrap.writeZshIntegration(
            tempDir: dir, producerLines: ["# marker", "export MADE_UP=1"]))
        let zshrc = try String(contentsOfFile: "\(dir)/.zshrc", encoding: .utf8)
        #expect(zshrc.contains("# marker"))
        #expect(zshrc.contains("export MADE_UP=1"))
    }
}
