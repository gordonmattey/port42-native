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
        /// values to avoid a `which` spawn and a Keychain read that can block or prompt.
        public let binaryPathOverride: String?
        public let tokenOverride: String?

        public init(tempDir: String, socketPath: String, sessionId: String, spaceId: String,
                    companionId: String?, cwd: String = "", shimPath: String?,
                    binaryPathOverride: String? = nil, tokenOverride: String? = nil) {
            self.tempDir = tempDir
            self.socketPath = socketPath
            self.sessionId = sessionId
            self.spaceId = spaceId
            self.companionId = companionId
            self.cwd = cwd
            self.shimPath = shimPath
            self.binaryPathOverride = binaryPathOverride
            self.tokenOverride = tokenOverride
        }
    }

    public struct Output: Sendable {
        public var env: [String: String] = [:]
        /// A directory to PREPEND to PATH — how an interceptor gets in front of the real binary.
        /// Empty for a CLI that needs no interception.
        public var pathPrefix: String = ""
        public init(env: [String: String] = [:], pathPrefix: String = "") {
            self.env = env
            self.pathPrefix = pathPrefix
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
}
