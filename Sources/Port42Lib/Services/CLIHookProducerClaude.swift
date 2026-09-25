import Foundation

// The claude producer. Extracted verbatim from `TerminalSessionBootstrap.make`, which is why the
// comments read as history — they are the ones that were earned there.
extension CLIHookProducer {

    public static let claude = CLIHookProducer(
        name: "claude",
        matches: { $0.lowercased().contains("claude") },
        prepare: { ctx in
            var out = Output()

            // Per-port claude session id (docs/plan-companion-cwd.md): a deterministic UUIDv5 of
            // space:companion (ad-hoc terminals key on the panel id). The shim reads this and pins
            // --session-id / --resume, so command companions sharing one space working dir land on
            // DISTINCT transcripts instead of colliding on the shared cwd's.
            out.env["PORT42_CLAUDE_SESSION_ID"] = ClaudeSessionId.derive(
                spaceId: ctx.spaceId, companionId: ctx.companionId, panelId: ctx.sessionId)

            // Real claude path so the shim execs it directly and can never find itself.
            if let real = ctx.binaryPathOverride ?? ClaudeCodeSetup.findBinary("claude") {
                out.env["PORT42_CLAUDE_PATH"] = real
            }

            // Intercept `claude` so it routes through the shim. TWO mechanisms, because a PATH entry
            // alone LOSES to the user's interactive shell startup re-prepending its own dirs (e.g.
            // `.zshrc` doing `export PATH="$HOME/.local/bin:$PATH"`):
            //   1. PRIMARY (zsh): a `claude` shell FUNCTION defined via ZDOTDIR. A shell function
            //      always wins over PATH lookup, so it survives any PATH reordering.
            //   2. FALLBACK (non-zsh): a `claude` symlink in a PATH-prepended dir.
            // Both call the same shim, which injects --settings and execs the real claude.
            if let shimPath = ctx.shimPath {
                out.env["PORT42_CLAUDE_SHIM"] = shimPath

                let link = "\(ctx.tempDir)/claude"
                try? FileManager.default.removeItem(atPath: link)
                do {
                    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: shimPath)
                    out.pathPrefix = ctx.tempDir
                } catch {
                    NSLog("[hooks] failed to symlink claude shim: \(error)")
                }

                // The function itself is contributed as a LINE; the assembler writes the file and
                // owns ZDOTDIR. Claude used to write the zshrc from in here, which meant the shared
                // helper hard-coded `claude()` and a second CLI needing shell setup would have had
                // to edit a file it does not own.
                out.shellLines = [
                    "# Port42: intercept `claude` with a function — wins over any PATH entry.",
                    "if [ -n \"$PORT42_CLAUDE_SHIM\" ]; then",
                    "  claude() { \"$PORT42_CLAUDE_SHIM\" \"$@\"; }",
                    "fi",
                ]
            }

            // NO CREDENTIAL IS INJECTED (D9, nautilus Phase 1 step 3). This used to put an OAuth token
            // from Port42's own store into `CLAUDE_CODE_OAUTH_TOKEN`. Port42 reads no provider
            // credential now: claude signs in with its own login, in its own terminal.

            return out
        })
}
