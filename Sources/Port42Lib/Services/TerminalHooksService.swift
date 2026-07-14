import Foundation
import Darwin

// Port42-owned terminal hooks infrastructure (Step 7).
//
// The RECEIVER (`TerminalHooksService`) is completely general: it listens on a Unix domain
// socket and decodes Port42's NORMALIZED event JSON. It has no knowledge of Claude (or any
// CLI) internals — translation from a CLI's raw hook payload to this vocabulary happens in
// the per-CLI notifier (for Claude: `port42-claude-shim notify <event>`).
//
// The SENDER side is bootstrapped by `TerminalSessionBootstrap`, which assembles the per-
// session environment (shim-on-PATH, socket path, real-claude path, space identity, and the
// CLI OAuth token from the secrets store) that Port42 injects into the Ghostty surface.

// MARK: - Normalized event vocabulary

/// Port42's CLI-agnostic hook events. A notifier translates each CLI's raw events into these.
public enum TerminalHookEvent: Sendable, Equatable {
    case turnComplete(text: String, exitCode: Int)
    case toolStarting(tool: String, input: String)
    case toolFinished(tool: String, output: String)
    case approvalRequired(tool: String, input: String, sessionId: String)
    case inputSubmitted(prompt: String)
    case sessionStarted
    case sessionEnded
}

// MARK: - Receiver

/// General hooks receiver. One per terminal session. Owns a Unix domain socket; each hook
/// invocation is a short-lived connection carrying one normalized event JSON object.
public actor TerminalHooksService {
    public let socketPath: String

    private var fd: Int32 = -1
    private var continuation: AsyncStream<TerminalHookEvent>.Continuation?
    private var stream: AsyncStream<TerminalHookEvent>?
    private let queue = DispatchQueue(label: "com.port42.terminalhooks")

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Convenience: derive a short `/tmp` socket path from a session id (keeps within the
    /// 104-char `sockaddr_un.sun_path` limit).
    public init(sessionId: String) {
        let shortId = String(sessionId.replacingOccurrences(of: "-", with: "").prefix(8))
        self.socketPath = "/tmp/p42h-\(shortId).sock"
    }

    /// Begin listening (idempotent) and return the event stream.
    public func events() -> AsyncStream<TerminalHookEvent> {
        if let stream { return stream }
        let (s, c) = AsyncStream.makeStream(of: TerminalHookEvent.self)
        self.stream = s
        self.continuation = c
        startListening()
        return s
    }

    public func stop() {
        continuation?.finish()
        continuation = nil
        if fd >= 0 { close(fd); fd = -1 }
        unlink(socketPath)
    }

    private func startListening() {
        let f = socket(AF_UNIX, SOCK_STREAM, 0)
        guard f >= 0 else {
            NSLog("[hooks] socket() failed errno=\(errno)")
            return
        }
        unlink(socketPath)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let copied: Bool = socketPath.withCString { cstr in
            let n = strlen(cstr)
            guard n < MemoryLayout.size(ofValue: addr.sun_path) else {
                NSLog("[hooks] socket path too long (\(n)): \(socketPath)")
                return false
            }
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(n) + 1) { dst in
                    memcpy(dst, cstr, n)
                    dst[Int(n)] = 0
                }
            }
            return true
        }
        guard copied else { close(f); return }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(f, $0, len) }
        }
        guard bindRes == 0 else {
            NSLog("[hooks] bind(\(socketPath)) failed errno=\(errno)")
            close(f)
            return
        }
        guard listen(f, 16) == 0 else {
            NSLog("[hooks] listen failed errno=\(errno)")
            close(f)
            return
        }
        self.fd = f
        NSLog("[hooks] listening on \(socketPath)")

        let cont = continuation
        queue.async { Self.acceptLoop(fd: f, continuation: cont) }
    }

    // Runs off the actor on `queue`. Touches no actor state — only the (Sendable) fd +
    // continuation. Exits when the listen fd is closed by `stop()` (accept returns < 0).
    private nonisolated static func acceptLoop(fd: Int32, continuation: AsyncStream<TerminalHookEvent>.Continuation?) {
        while true {
            let cfd = accept(fd, nil, nil)
            if cfd < 0 { break }
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = buf.withUnsafeMutableBytes { recv(cfd, $0.baseAddress, $0.count, 0) }
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            close(cfd)
            if let event = decode(data) { continuation?.yield(event) }
        }
        continuation?.finish()
    }

    // MARK: wire decode (Port42 normalized JSON → TerminalHookEvent)

    private struct Wire: Decodable {
        let event: String
        var text: String?
        var exitCode: Int?
        var tool: String?
        var input: String?
        var output: String?
        var prompt: String?
        var sessionId: String?
    }

    private nonisolated static func decode(_ data: Data) -> TerminalHookEvent? {
        guard !data.isEmpty, let w = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        switch w.event {
        case "turnComplete":   return .turnComplete(text: w.text ?? "", exitCode: w.exitCode ?? 0)
        case "toolStarting":   return .toolStarting(tool: w.tool ?? "", input: w.input ?? "")
        case "toolFinished":   return .toolFinished(tool: w.tool ?? "", output: w.output ?? "")
        case "approvalRequired": return .approvalRequired(tool: w.tool ?? "", input: w.input ?? "", sessionId: w.sessionId ?? "")
        case "inputSubmitted": return .inputSubmitted(prompt: w.prompt ?? "")
        case "sessionStarted": return .sessionStarted
        case "sessionEnded":   return .sessionEnded
        default:               return nil
        }
    }
}

// MARK: - Sender-side session bootstrap

/// The per-session environment Port42 injects into a Ghostty surface so the bundled `claude`
/// shim and hooks socket are wired up. Owned by the caller (debug harness in Step 7, AppState
/// in Step 8), which is responsible for `cleanup` when the terminal closes.
public struct TerminalHookSession: Sendable {
    public let socketPath: String
    public let tempDir: String
    public let env: [String: String]
}

public enum TerminalSessionBootstrap {
    /// Canonical name of the secret in `Port42AuthStore` holding the `claude` CLI's OAuth
    /// token. Decoupled from the env var name: this secret's value is injected as the env
    /// var `CLAUDE_CODE_OAUTH_TOKEN`. Setup-time credential handling must use this same name.
    public static let claudeOAuthSecretName = "claude-oauth"

    /// Resolve the bundled shim binary (`Contents/MacOS/port42-claude-shim`).
    public static func bundledShimPath() -> String? {
        Bundle.main.url(forAuxiliaryExecutable: "port42-claude-shim")?.path
    }

    /// Build a per-session temp dir + `claude` shim symlink + hooks socket path + env vars.
    /// If the shim is unavailable, PATH is left unmodified and `claude` falls back to the
    /// user's own login (no hooks) — graceful degradation, not an error.
    /// `claudePath` / `oauthToken` are nil in production (resolved via `ClaudeCodeSetup`
    /// and the Keychain); tests pass them explicitly to avoid the slow `which` spawn and
    /// the Keychain access (which can block or prompt in a test process).
    public static func make(sessionId: String,
                            spaceId: String,
                            spaceName: String,
                            companionPrompt: String? = nil,
                            customEnv: [String: String] = [:],
                            shimPath: String? = bundledShimPath(),
                            claudePath: String? = nil,
                            oauthToken: String? = nil) -> TerminalHookSession {
        let shortId = String(sessionId.replacingOccurrences(of: "-", with: "").prefix(8))
        let tempDir = "/tmp/port42-shim-\(shortId)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        let socketPath = "\(tempDir)/h.sock"

        // Caller-supplied custom env (port.create({type:"terminal", env:{…}})) is the BASE; the
        // Port42 hooks/identity vars below overlay it, so a caller can extend the environment but
        // can NEVER clobber the socket, space identity, shim PATH, or ZDOTDIR the hooks integration
        // depends on. (PATH is recomputed unconditionally further down, so it always wins too.)
        var env: [String: String] = customEnv
        env["PORT42_HOOKS_SOCKET"] = socketPath
        env["PORT42_SPACE_ID"] = spaceId
        env["PORT42_SPACE_NAME"] = spaceName

        // Companion identity injected into the CLI via the shim's --append-system-prompt.
        // Replaces the old CLAUDE.md mutation (which clobbered project files / polluted home).
        if let companionPrompt, !companionPrompt.isEmpty {
            env["PORT42_COMPANION_PROMPT"] = companionPrompt
        }

        // Real claude path so the shim execs it directly and can never find itself.
        if let real = claudePath ?? ClaudeCodeSetup.findBinary("claude") {
            env["PORT42_CLAUDE_PATH"] = real
        }

        // Live-cwd tracking: the injected zshrc writes $PWD here on every cd (chpwd hook),
        // so a rebuilt terminal (app restart) reopens in the directory the user was actually
        // in — not the spawn cwd. Keyed by port id (sessionId == panelId), survives restarts.
        if let cwdFile = liveCwdFile(portId: sessionId) {
            env["PORT42_CWD_FILE"] = cwdFile
        }

        // Intercept `claude` so it routes through the shim. Two mechanisms, because a PATH
        // entry alone LOSES to the user's interactive shell startup re-prepending its own
        // dirs (e.g. `.zshrc` doing `export PATH="$HOME/.local/bin:$PATH"`):
        //   1. PRIMARY (zsh): a `claude` shell FUNCTION defined via ZDOTDIR. A shell
        //      function always wins over PATH lookup, so it survives any PATH reordering.
        //   2. FALLBACK (non-zsh): a `claude` symlink in a PATH-prepended dir.
        // Both call the same shim, which injects --settings and execs the real claude.
        var pathPrefix = ""
        if let shimPath {
            env["PORT42_CLAUDE_SHIM"] = shimPath

            // (2) symlink fallback
            let link = "\(tempDir)/claude"
            try? FileManager.default.removeItem(atPath: link)
            do {
                try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: shimPath)
                pathPrefix = tempDir
            } catch {
                NSLog("[hooks] failed to symlink claude shim: \(error)")
            }

            // (1) zsh function via ZDOTDIR
            if writeZshIntegration(tempDir: tempDir) {
                env["ZDOTDIR"] = tempDir
                env["PORT42_REAL_ZDOTDIR"] = ProcessInfo.processInfo.environment["ZDOTDIR"] ?? NSHomeDirectory()
            }
        }
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = [pathPrefix, existing, "/opt/homebrew/bin"].filter { !$0.isEmpty }.joined(separator: ":")

        // CLI auth: an OAuth token from the SECRETS STORE (NOT the in-app LLM resolver, which
        // holds an API key for a different connection). The store secret is named
        // `claude-oauth`; its value is injected as CLAUDE_CODE_OAUTH_TOKEN (what the claude
        // CLI reads). Absent → CLI falls back to its own login.
        if let token = oauthToken ?? Port42AuthStore.shared.loadSecretValue(name: claudeOAuthSecretName), !token.isEmpty {
            env["CLAUDE_CODE_OAUTH_TOKEN"] = token
        }

        return TerminalHookSession(socketPath: socketPath, tempDir: tempDir, env: env)
    }

    /// Write the zsh startup files into `dir` (used as ZDOTDIR). Each sources the user's
    /// real equivalent (from `$PORT42_REAL_ZDOTDIR`, default `$HOME`); `.zshrc` additionally
    /// defines the `claude()` interceptor. Returns false if any write fails (caller then
    /// relies on the PATH-symlink fallback). zsh-only: bash/fish ignore ZDOTDIR.
    private static func writeZshIntegration(tempDir dir: String) -> Bool {
        let real = "${PORT42_REAL_ZDOTDIR:-$HOME}"
        func sourceLine(_ f: String) -> String { "[ -f \"\(real)/\(f)\" ] && source \"\(real)/\(f)\"\n" }
        let zshrc =
            sourceLine(".zshrc")
            + "# Port42: intercept `claude` with a function — wins over any PATH entry.\n"
            + "if [ -n \"$PORT42_CLAUDE_SHIM\" ]; then\n"
            + "  claude() { \"$PORT42_CLAUDE_SHIM\" \"$@\"; }\n"
            + "fi\n"
            + "# Port42: report the live cwd so a rebuilt terminal reopens where you were.\n"
            + "if [ -n \"$PORT42_CWD_FILE\" ]; then\n"
            + "  __port42_track_cwd() { print -r -- \"$PWD\" >| \"$PORT42_CWD_FILE\" 2>/dev/null }\n"
            + "  typeset -ag chpwd_functions\n"
            + "  chpwd_functions+=(__port42_track_cwd)\n"
            + "  __port42_track_cwd\n"
            + "fi\n"
        let files: [String: String] = [
            ".zshenv":   sourceLine(".zshenv"),
            ".zprofile": sourceLine(".zprofile"),
            ".zlogin":   sourceLine(".zlogin"),
            ".zshrc":    zshrc,
        ]
        for (name, body) in files {
            do { try body.write(toFile: "\(dir)/\(name)", atomically: true, encoding: .utf8) }
            catch { NSLog("[hooks] failed to write \(name): \(error)"); return false }
        }
        return true
    }

    public static func cleanup(tempDir: String) {
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    // MARK: Live cwd (per-port, survives restarts)

    /// The stable file the shell writes its cwd into: `<AppSupport>/<data-dir>/term-cwd/<portId>`.
    /// nil if Application Support is unreachable. Same data-dir resolution as the DB
    /// (`PORT42_DATA_DIR` baked by the dev launcher; "Port42" for the installed app).
    public static func liveCwdFile(portId: String) -> String? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dataDir = ProcessInfo.processInfo.environment["PORT42_DATA_DIR"] ?? "Port42"
        let dir = base.appendingPathComponent(dataDir).appendingPathComponent("term-cwd")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(portId).path
    }

    /// The last cwd the port's shell reported, if it still exists on disk.
    public static func savedLiveCwd(portId: String) -> String? {
        guard let file = liveCwdFile(portId: portId),
              let cwd = try? String(contentsOfFile: file, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !cwd.isEmpty else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else { return nil }
        return cwd
    }

    /// Forget a closed port's cwd record.
    public static func clearLiveCwd(portId: String) {
        guard let file = liveCwdFile(portId: portId) else { return }
        try? FileManager.default.removeItem(atPath: file)
    }
}
