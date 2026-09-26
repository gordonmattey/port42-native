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
    /// The CLI is WAITING ON THE HUMAN — a tool needs permission, or it has gone idle at the
    /// prompt. Distinct from `turnComplete`, which fires on every turn whether or not anything is
    /// wanted. `message` is the CLI's own reason, so a peek can say what it is waiting for.
    case needsAttention(message: String)
    case toolStarting(tool: String, input: String)
    case toolFinished(tool: String, output: String)
    case approvalRequired(tool: String, input: String, sessionId: String)
    case inputSubmitted(prompt: String)
    /// The CLI is up. `cli` names which one raised it ("claude", "codex"), when its hook says.
    case sessionStarted(cli: String?)
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
        var transcript: String?
        var transcriptBytes: Int64?
        var cli: String?
    }

    private nonisolated static func decode(_ data: Data) -> TerminalHookEvent? {
        guard !data.isEmpty, let w = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        switch w.event {
        case "turnComplete":
            // Diagnostic for the reply-post bug. Two failure modes, both from the transcript
            // the Stop hook hands over: EMPTY (no post) and STALE (a previous turn's text,
            // posted wrongly). Log the file + size + length on EVERY turn so both are visible.
            NSLog("[hooks] turnComplete: transcript=%@ bytes=%lld len=%d sid=%@",
                  w.transcript ?? "nil", w.transcriptBytes ?? -1, (w.text ?? "").count,
                  w.sessionId ?? "nil")
            return .turnComplete(text: w.text ?? "", exitCode: w.exitCode ?? 0)
        case "needsAttention":
            NSLog("[hooks] needsAttention: %@", w.text ?? "")
            return .needsAttention(message: w.text ?? "")
        case "toolStarting":   return .toolStarting(tool: w.tool ?? "", input: w.input ?? "")
        case "toolFinished":   return .toolFinished(tool: w.tool ?? "", output: w.output ?? "")
        case "approvalRequired": return .approvalRequired(tool: w.tool ?? "", input: w.input ?? "", sessionId: w.sessionId ?? "")
        case "inputSubmitted": return .inputSubmitted(prompt: w.prompt ?? "")
        case "sessionStarted": return .sessionStarted(cli: w.cli)
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
    /// Resolve the bundled shim binary (`Contents/MacOS/port42-claude-shim`).
    public static func bundledShimPath() -> String? {
        Bundle.main.url(forAuxiliaryExecutable: "port42-claude-shim")?.path
    }

    /// Build a per-session temp dir + `claude` shim symlink + hooks socket path + env vars.
    /// If the shim is unavailable, PATH is left unmodified and `claude` falls back to the
    /// user's own login (no hooks) — graceful degradation, not an error.
    /// `claudePath` is nil in production (resolved via `ClaudeCodeSetup`); tests pass it
    /// explicitly to avoid the slow `which` spawn.
    public static func make(sessionId: String,
                            spaceId: String,
                            spaceName: String,
                            companionId: String? = nil,
                            companionPrompt: String? = nil,
                            customEnv: [String: String] = [:],
                            shimPath: String? = bundledShimPath(),
                            claudePath: String? = nil,
                            cwd: String = "",
                            producer: CLIHookProducer? = nil,
                            home: String? = nil,
                            stableDir: String? = nil) -> TerminalHookSession {
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

        // WHO THIS CHILD IS, as a named client (slice-02 half two, step 6).
        //
        // The pooled `local-http` principal dies here: every local process reaching the gateway is
        // currently the SAME grantee, so a grant given to one is inherited by all. A child the app
        // spawned gets its own identity instead, derived rather than random so it survives a respawn
        // with its grants intact (`ClientRegistry.childId`).
        //
        // **The id, never the token.** `ps -E` publishes a subprocess environment to any process
        // running as the user — the measurement that moved the gateway's own secrets to stdin — so a
        // token here would be readable by everything on the machine. The id is not a secret; the
        // token sits in a 0600 file the child reads at a path it can compute from this.
        //
        // Derived here rather than passed in because `childId` is one definition shared with the
        // registration in `AppState.makeTerminalController`: the env and the row cannot disagree
        // about who this child is.
        // **EVERY terminal Port42 spawns gets one, not only a companion** (B, GM 2026-07-31). The
        // credential used to be gated on `companionId` while everything else that makes a session a
        // companion arrived via `companionPrompt`, so a spawn could set the second and omit the
        // first: a session that was a companion in every visible respect and had no identity at all.
        // Measured on 2026-07-31, prod and Dev4 held no child token between them while both ran
        // companion sessions, and one of those sessions went looking for the CLI's token because it
        // had nothing of its own.
        let clientId = ClientRegistry.spawnedTerminalId(companionId: companionId,
                                                        sessionId: sessionId, spaceId: spaceId)
        env["PORT42_CLIENT_ID"] = clientId
        env["PORT42_TOKEN_FILE"] = ClientRegistry.tokenPath(
            id: clientId, instance: ClientRegistry.currentInstance).path

        // Companion identity injected into the CLI via the shim's --append-system-prompt.
        // Replaces the old CLAUDE.md mutation (which clobbered project files / polluted home).
        if let companionPrompt, !companionPrompt.isEmpty {
            env["PORT42_COMPANION_PROMPT"] = companionPrompt
        }

        // Live-cwd tracking: the injected zshrc writes $PWD here on every cd (chpwd hook),
        // so a rebuilt terminal (app restart) reopens in the directory the user was actually
        // in — not the spawn cwd. Keyed by port id (sessionId == panelId), survives restarts.
        if let cwdFile = liveCwdFile(portId: sessionId) {
            env["PORT42_CWD_FILE"] = cwdFile
        }

        // EVERYTHING CLI-SPECIFIC LIVES IN THE PRODUCER. What is left above and below this call is
        // true of any CLI: the socket, the space identity, the child's client id, the companion
        // prompt, the cwd file, PATH.
        //
        // ALL PRODUCERS, ALWAYS (2026-07-31). This used to be "the matching producer, else claude",
        // and the else-claude was what made a typed `claude` work in a plain terminal while a typed
        // `codex` silently did not: codex's wiring is an env var its producer never got to set.
        // `producer:` is now an override for a caller that means ONE cli (and for tests); the
        // default prepares them all. See `CLIHookProducer.prepareAll`.
        let ctx = CLIHookProducer.Context(
            tempDir: tempDir, socketPath: socketPath, sessionId: sessionId, spaceId: spaceId,
            companionId: companionId, cwd: cwd, shimPath: shimPath,
            binaryPathOverride: claudePath, homeOverride: home,
            // Test seam, and not a cosmetic one: without it a test reaches the REAL Application
            // Support directory and writes into the daily driver's state. Same lesson as the
            // credential-store fix — a test that touches a live instance is a bug in the test.
            stableDir: stableDir ?? stableSupportDir())
        let out = producer.map { CLIHookProducer.merge([($0.name, $0.prepare(ctx))]) }
            ?? CLIHookProducer.prepareAll(ctx)
        env.merge(out.env) { _, new in new }

        // The injected zshrc, assembled from whatever the producers contributed. Written here
        // rather than inside a producer, so ZDOTDIR has exactly one owner.
        if writeZshIntegration(tempDir: tempDir, producerLines: out.shellLines) {
            env["ZDOTDIR"] = tempDir
            env["PORT42_REAL_ZDOTDIR"] = realZdotdir(
                inherited: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
        }

        let existing = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = [out.pathPrefix, existing, "/opt/homebrew/bin"].filter { !$0.isEmpty }.joined(separator: ":")

        return TerminalHookSession(socketPath: socketPath, tempDir: tempDir, env: env)
    }

    /// The USER'S real zsh dotfile location for a spawned shell — never a Port42 shim.
    /// When this app was itself launched from inside a Port42 terminal (`open(1)` propagates
    /// the caller's environment), the inherited ZDOTDIR is that terminal's shim dir; treating
    /// it as "real" makes every new shim source the old shim, whose own source line resolves
    /// to ITSELF in the child (its PORT42_REAL_ZDOTDIR is the same dir) → infinite source
    /// recursion, surfacing as zsh's "job table full or recursion limit exceeded" on every
    /// startup file. Prefer the inherited PORT42_REAL_ZDOTDIR (the true original, carried
    /// through the same terminal env), else a NON-shim ZDOTDIR, else $HOME. Pure → headless.
    static func realZdotdir(inherited: [String: String], home: String) -> String {
        func nonShim(_ path: String?) -> String? {
            guard let path, !path.hasPrefix("/tmp/port42-shim-") else { return nil }
            return path
        }
        return nonShim(inherited["PORT42_REAL_ZDOTDIR"]) ?? nonShim(inherited["ZDOTDIR"]) ?? home
    }

    /// Write the zsh startup files into `dir` (used as ZDOTDIR). Each sources the user's
    /// real equivalent (from `$PORT42_REAL_ZDOTDIR`, default `$HOME`); `.zshrc` additionally
    /// carries whatever the PRODUCERS contributed, plus the cwd tracking that is true of any
    /// terminal. Returns false if any write fails (caller then relies on the PATH-symlink
    /// fallback). zsh-only: bash/fish ignore ZDOTDIR.
    ///
    /// `producerLines` used to be a hard-coded `claude()` function in this file, which made a
    /// per-CLI mechanism the property of a shared helper. Producers now own their own lines and
    /// this owns the file (2026-07-31).
    static func writeZshIntegration(tempDir dir: String, producerLines: [String] = []) -> Bool {
        let real = "${PORT42_REAL_ZDOTDIR:-$HOME}"
        func sourceLine(_ f: String) -> String { "[ -f \"\(real)/\(f)\" ] && source \"\(real)/\(f)\"\n" }
        let zshrc =
            sourceLine(".zshrc")
            + (producerLines.isEmpty ? "" : producerLines.joined(separator: "\n") + "\n")
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

    /// A per-INSTANCE directory that outlives any one terminal, beside the database.
    ///
    /// `tempDir` is per-port and is deleted with it, which is correct for a socket and a shim
    /// symlink and wrong for anything a CLI is expected to remember. Codex keys hook trust by the
    /// path of the config that defined the hook, so a per-port config meant a hook codex had never
    /// seen on every single spawn — reviewed, then skipped, and no companion ever registered.
    ///
    /// Same data-dir resolution as `liveCwdFile` and the DB (`PORT42_DATA_DIR` baked by the dev
    /// launcher, "Port42" for the installed app), so dev instances stay isolated from each other and
    /// from the daily driver.
    static func stableSupportDir() -> String? {
        // NEVER IN A TEST PROCESS. `PORT42_DATA_DIR` is baked by the dev launcher and is UNSET under
        // `swift test`, so this resolves to "Port42" — the DAILY DRIVER's data directory — and a
        // test run writes a codex-home into it. Observed: GM deleted that directory and the next
        // `swift test` put it straight back.
        //
        // The first attempt at this was a `stableDir:` parameter threaded through the one test that
        // caught it. That is the wrong shape: it fixed 3 of 8 call sites and left the other 5 free
        // to escape, which is exactly how this reached the daily driver twice. Refusing at the
        // source makes it structural — a test falls back to its own `tempDir` and cannot reach real
        // state however it calls in. Same lesson as the credential-store fix (1de6a57).
        guard !AppState.isTestProcess else { return nil }
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dataDir = ProcessInfo.processInfo.environment["PORT42_DATA_DIR"] ?? "Port42"
        let dir = base.appendingPathComponent(dataDir).appendingPathComponent("cli-state")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
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
