import Foundation

// The claude producer. Extracted verbatim from `TerminalSessionBootstrap.make`, which is why the
// comments read as history — they are the ones that were earned there.
extension CLIHookProducer {

    /// Canonical name of the secret holding the `claude` CLI's OAuth token. Decoupled from the env
    /// var name: this secret's value is injected as `CLAUDE_CODE_OAUTH_TOKEN`.
    public static let claudeOAuthSecretName = "claude-oauth"

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

                if TerminalSessionBootstrap.writeZshIntegration(tempDir: ctx.tempDir) {
                    out.env["ZDOTDIR"] = ctx.tempDir
                    out.env["PORT42_REAL_ZDOTDIR"] = TerminalSessionBootstrap.realZdotdir(
                        inherited: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
                }
            }

            // CLI auth: an OAuth token from the SECRETS STORE (NOT the in-app LLM resolver, which
            // holds an API key for a different connection). Absent → the CLI falls back to its own
            // login.
            if let token = ctx.tokenOverride
                ?? Port42AuthStore.shared.loadSecretValue(name: claudeOAuthSecretName),
               !token.isEmpty {
                out.env["CLAUDE_CODE_OAUTH_TOKEN"] = token
            }

            return out
        })
}
