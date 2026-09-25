import Foundation

/// How ONE CLI is made to emit Port42's hook events.
///
/// `TerminalHooksService` has always documented the RECEIVER as CLI-agnostic, with translation
/// pushed out to a per-CLI notifier. That was true and it held — a codex spike drove its `Stop`
/// hook through the same shim and socket with no Swift change. But "per-CLI" had exactly one CLI
/// in it, so the seam existed as a comment rather than a structure: hook config generation, the
/// session environment and the interceptor were all claude-shaped and claude-named.
///
/// This is that seam made real. A producer's whole job is to prepare one session so a given CLI
/// starts talking to the hooks socket.
///
/// **The mechanisms genuinely differ, which is why this is a value and not a subclass with a
/// `buildSettings` hook.** Claude has to be INTERCEPTED — the shim stands in for the binary so it
/// can inject `--settings` — which needs a symlink, a shell function and a PATH prefix. Codex needs
/// none of that: point `CODEX_HOME` at a directory holding a `config.toml` and it reads the hooks
/// itself. A producer that only knew how to "build settings" could not express the second.
public struct CLIHookProducer: Sendable {

    /// Everything a producer is allowed to know about the session it is preparing.
    public struct Context: Sendable {
        public let tempDir: String
        public let socketPath: String
        /// The port/panel id. Also the fallback key for a session id when there is no companion.
        public let sessionId: String
        public let spaceId: String
        public let companionId: String?
        /// The terminal's working directory. Needed because codex REFUSES TO RUN in a directory it
        /// does not trust ("Not inside a trusted directory"), so its producer must record trust for
        /// this cwd. Claude ignores it.
        public let cwd: String
        /// The bundled notifier. Absent in a build without it → the producer degrades to no hooks
        /// rather than failing, and the CLI runs as the user's own.
        public let shimPath: String?
        /// Test seams. Production passes nil and the producer resolves for itself; tests pass
        /// values to avoid a `which` spawn.
        public let binaryPathOverride: String?
        /// Test seam for the user's home. Codex mirrors `~/.codex` and, since it now prepares every
        /// terminal rather than only a `codex` one, does nothing at all when that directory is
        /// absent. Without this seam a codex test would pass or fail depending on whether the
        /// machine running it happens to use codex.
        public let homeOverride: String?
        /// A directory that is the SAME for every terminal of this Port42 instance, unlike
        /// `tempDir`, which is per-port.
        ///
        /// Codex keys hook trust by the path of the config that DEFINED the hook. With a per-port
        /// config that path moved on every spawn, so codex met an unrecognised hook every time,
        /// marked it for review and — per its reference — SKIPPED it. That is why a codex companion
        /// never registered, through two versions and every variation of the config. A stable path
        /// makes the hook one identity, trusted once.
        public let stableDir: String?

        public init(tempDir: String, socketPath: String, sessionId: String, spaceId: String,
                    companionId: String?, cwd: String = "", shimPath: String?,
                    binaryPathOverride: String? = nil,
                    homeOverride: String? = nil, stableDir: String? = nil) {
        self.stableDir = stableDir
            self.tempDir = tempDir
            self.socketPath = socketPath
            self.sessionId = sessionId
            self.spaceId = spaceId
            self.companionId = companionId
            self.cwd = cwd
            self.shimPath = shimPath
            self.binaryPathOverride = binaryPathOverride
            self.homeOverride = homeOverride
        }

        /// The user's home, honouring the test seam.
        public var home: String { homeOverride ?? NSHomeDirectory() }
    }

    public struct Output: Sendable {
        public var env: [String: String] = [:]
        /// A directory to PREPEND to PATH — how an interceptor gets in front of the real binary.
        /// Empty for a CLI that needs no interception.
        public var pathPrefix: String = ""
        /// Lines this producer contributes to the injected `.zshrc`.
        ///
        /// Producers do NOT write the file. Claude used to reach into
        /// `TerminalSessionBootstrap.writeZshIntegration` and that helper hard-coded the `claude()`
        /// function, so a second CLI needing shell-level setup would either have edited a shared
        /// helper it does not own or fought over `ZDOTDIR`. The assembler owns the file and
        /// `ZDOTDIR`; a producer owns only its own lines.
        public var shellLines: [String] = []
        public init(env: [String: String] = [:], pathPrefix: String = "", shellLines: [String] = []) {
            self.env = env
            self.pathPrefix = pathPrefix
            self.shellLines = shellLines
        }
    }

    /// Identifies the producer. Also the name matched against a terminal's startup command.
    public let name: String
    /// Does this producer handle that startup command?
    public let matches: @Sendable (String) -> Bool
    /// Prepare the session. May write files under `context.tempDir`.
    public let prepare: @Sendable (Context) -> Output

    public init(name: String,
                matches: @escaping @Sendable (String) -> Bool,
                prepare: @escaping @Sendable (Context) -> Output) {
        self.name = name
        self.matches = matches
        self.prepare = prepare
    }

    // MARK: - The table

    /// Every CLI Port42 can wire hooks for. **Adding a CLI is adding a row**, and a row that is not
    /// here simply runs as itself with no hooks — which is the correct default for `htop`.
    ///
    /// Gemini and antigravity are absent on purpose. Gemini cannot authenticate without a paid key
    /// since Google withdrew the free tier for individuals, and antigravity's credentials do not
    /// survive the per-session config redirect its injection would need. Neither is a hooks problem;
    /// both are tracked in the CLI-parity item.
    public static let all: [CLIHookProducer] = [.claude, .codex]

    /// The producer for a startup command, or nil when nothing handles it.
    public static func forCommand(_ startupCommand: String) -> CLIHookProducer? {
        all.first { $0.matches(startupCommand) }
    }

    /// **A companion's briefing, for a CLI that has no way to receive one out of band.**
    ///
    /// Claude gets its identity through `--append-system-prompt`, injected by the shim from
    /// `PORT42_COMPANION_PROMPT`, invisibly and before the user says anything. Codex has no
    /// equivalent flag — its only channel is the optional `[PROMPT]` positional — so until now a
    /// codex companion never learned it was one.
    ///
    /// Passing it there does a SECOND job, and that one is why codex companions worked at all
    /// (measured 2026-07-31). Codex does not run `SessionStart` hooks at launch: it holds them
    /// PENDING and runs them inside the first turn (`run_pending_session_start_hooks` sits under
    /// `session_task.run:run_turn`, dispatched from `user_input`). So a codex that is launched and
    /// left at its prompt never fires the hook, and never registers as a companion — which is
    /// exactly what "launch and wait" testing showed, for hours, on every version and config. The
    /// briefing IS the first turn, so it registers on spawn.
    ///
    /// The trade-off, stated because it is visible to the user: claude's briefing is hidden in a
    /// system prompt, codex's appears as the first message of the transcript. That is inherent.
    public static func startupCommand(base: String, companionPrompt: String) -> String {
        guard !companionPrompt.isEmpty,
              forCommand(base)?.name == "codex",
              // Only when the caller has not already supplied a prompt of its own.
              base.trimmingCharacters(in: .whitespaces) == "codex"
        else { return base }
        return "codex '\(companionPrompt.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// **EVERY producer prepares EVERY terminal** (2026-07-31), and this replaces a special case
    /// that had become a bug.
    ///
    /// The old rule was "the producer matching the startup command, and if nothing matches, fall
    /// back to claude". The fallback was deliberate and its reason was right: a plain `zsh` terminal
    /// still gets the claude interceptor, so typing `claude` into it LATER is still wired up, which
    /// is what makes ad-hoc terminals auto-register as companions at all.
    ///
    /// But it hard-coded ONE cli into the general case. Claude is intercepted inside the shell (a
    /// function via ZDOTDIR), so it survives being typed later. Codex is configured by `CODEX_HOME`
    /// at spawn, so under the fallback its producer never ran for a plain shell, `CODEX_HOME` was
    /// never exported, and a typed `codex` read the user's real config with no Port42 hooks in it.
    /// It emitted no SessionStart and therefore never became a companion, while claude did.
    /// Measured by GM, 2026-07-31.
    ///
    /// So the rule is now uniform: prepare them all, merge, and let each CLI's own mechanism decide
    /// whether it takes effect. A producer that cannot usefully prepare this machine returns an
    /// empty Output and contributes nothing.
    public static func prepareAll(_ ctx: Context) -> Output {
        merge(all.map { producer in (producer.name, producer.prepare(ctx)) })
    }

    /// Combine producer outputs, with the conflict rules stated ONCE rather than at a call site.
    ///
    /// - env: first writer wins, and a collision is logged. Two producers claiming one variable is a
    ///   design error to be seen, not a last-write-wins race to be discovered later.
    /// - pathPrefix: all of them, in producer order, joined. Prepending is not exclusive.
    /// - shellLines: concatenated in producer order.
    static func merge(_ outputs: [(name: String, out: Output)]) -> Output {
        var merged = Output()
        var claimedBy: [String: String] = [:]
        var prefixes: [String] = []
        for (name, out) in outputs {
            for (k, v) in out.env {
                if let owner = claimedBy[k] {
                    NSLog("[hooks] env collision on %@: '%@' keeps it, '%@' ignored", k, owner, name)
                    continue
                }
                claimedBy[k] = name
                merged.env[k] = v
            }
            if !out.pathPrefix.isEmpty { prefixes.append(out.pathPrefix) }
            merged.shellLines.append(contentsOf: out.shellLines)
        }
        merged.pathPrefix = prefixes.joined(separator: ":")
        return merged
    }
}
