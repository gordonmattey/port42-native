import Foundation

/// Pure decision logic for what a companion terminal broadcasts to the space. Extracted from
/// the controller so the armed-gate / dedup / fallback rules are unit-testable with no surface,
/// socket, or AppState. See the corrected design (plan doc, "Steps 8+9 CORRECTED ARCHITECTURE").
struct CompanionPostGate {
    /// Hooks-capable companions (claude/gemini) reply via the clean `turnComplete` transcript;
    /// their tee `<p42>` output is suppressed (TUI rendering mangles whitespace).
    let hooksCapable: Bool
    /// Armed by an injected space message; consumed by the next turnComplete.
    private(set) var armed = false
    private var recentlyPosted: [String] = []

    init(hooksCapable: Bool) { self.hooksCapable = hooksCapable }

    mutating func arm() { armed = true }

    /// `turnComplete`: broadcast a reply once a message has been injected. Stays armed across
    /// turns — a companion's reply to ONE injected message often spans MULTIPLE turns (iterative
    /// tool work fires a Stop per turn). Disarming on the first turn dropped every later turn (the
    /// "reply drafted but never sent" bug). Re-arming on each new inject is idempotent. (Trade-off:
    /// once talked to via chat, the companion's later turns post too — including, in principle,
    /// text typed directly into its terminal. Acceptable for a chat-driven dev companion.)
    mutating func onTurnComplete(_ text: String) -> [String] {
        guard armed else { return [] }
        return emit(text)
    }

    /// tee `<p42>` tag: FALLBACK for non-hooks tools only. A tag is a deliberate post, so it is
    /// not gated by `armed`. Suppressed entirely for hooks-capable companions.
    mutating func onTag(_ tag: String) -> [String] {
        guard !hooksCapable else { return [] }
        return emit(tag)
    }

    /// Reason the last emit returned empty (for logging/introspection).
    private(set) var lastSkipReason = ""

    private mutating func emit(_ content: String) -> [String] {
        var trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // Companions often echo the inbound "[@name]: " sender prefix onto their own reply.
        // Strip a single leading "[anything]" with an OPTIONAL trailing colon — the LLM
        // sometimes writes "[@gordon] reply" with no colon — since sender attribution is
        // already applied when the message is posted.
        if let r = trimmed.range(of: "^\\[[^\\]]+\\]:?[ \t]*", options: .regularExpression) {
            trimmed = String(trimmed[r.upperBound...])
        }
        if trimmed.isEmpty { lastSkipReason = "empty"; return [] }
        if recentlyPosted.contains(trimmed) { lastSkipReason = "duplicate"; return [] }
        recentlyPosted.append(trimmed)
        if recentlyPosted.count > 32 { recentlyPosted.removeFirst() }
        lastSkipReason = ""
        return [trimmed]
    }
}

/// Owns the per-session plumbing for one native (Ghostty) terminal companion port:
/// the bootstrapped environment, the hooks receiver, and the `<p42>` output processor.
///
/// The companion loop: space message ──inject "[sender]: text\r"──▶ claude ──Stop/turnComplete──▶ post.
/// All posting decisions live in `CompanionPostGate`; this class wires the hooks stream / tee /
/// surface to an injected `post` closure (so it stays testable). Verbosely logged under
/// `[ctl:<name>]` for introspection of the whole event flow.
@MainActor
final class GhosttyTerminalController {
    let panelId: String
    let config: TerminalPortConfig

    private let session: TerminalHookSession
    private let hooks: TerminalHooksService
    private var hooksTask: Task<Void, Never>?
    private let processor: TerminalOutputProcessor

    private let post: (String) -> Void
    /// Publish the terminal's clean output batch (onFlush) to the Notify bus (Phase L1 / backlog 3.4).
    private let onOutput: @MainActor (String) -> Void
    /// Returns (and clears) any space messages that arrived while this terminal was still
    /// (re)spawning, so they can be injected once the CLI is ready. Injected by the caller
    /// (AppState) so the queue stays decoupled and testable. Defaults to no-op for tests.
    private let drainPending: () -> [String]
    /// Fired the first time the CLI signals it has started (SessionStart). AppState uses it to
    /// auto-register an ad-hoc `claude` terminal as a space companion (docs/summer2026-todo.md).
    /// Fires at most once per controller. No-op by default (tests / non-companion terminals).
    private let onSessionStarted: () -> Void
    /// Fired when the CLI signals it has exited (SessionEnd). AppState uses it to remove an
    /// auto-registered CLI companion (it leaves the space when claude exits, even if the terminal
    /// shell stays open). No-op by default.
    private let onSessionEnded: () -> Void
    private var didNotifySessionStart = false
    private var injectToSurface: ((String) -> Void)?
    private var gate: CompanionPostGate
    private let hooksCapable: Bool
    /// True once the CLI has signalled it is ready to receive injected input (SessionStart),
    /// or once the fallback settle window has elapsed for non-hooks tools.
    private var didFlushPending = false

    var env: [String: String] { session.env }
    /// Whether a live Ghostty surface is bound — i.e. inject() can reach the PTY right now.
    var isSurfaceBound: Bool { injectToSurface != nil }

    private func log(_ msg: String) { NSLog("[ctl:%@] %@", config.companionName, msg) }

    init(panelId: String, config: TerminalPortConfig,
         post: @escaping (String) -> Void,
         onOutput: @escaping @MainActor (String) -> Void = { _ in },
         drainPending: @escaping () -> [String] = { [] },
         onSessionStarted: @escaping () -> Void = {},
         onSessionEnded: @escaping () -> Void = {}) {
        self.panelId = panelId
        self.config = config
        self.post = post
        self.onOutput = onOutput
        self.drainPending = drainPending
        self.onSessionStarted = onSessionStarted
        self.onSessionEnded = onSessionEnded
        self.hooksCapable = Self.isHooksCapable(config.startupCommand)
        self.gate = CompanionPostGate(hooksCapable: hooksCapable)

        self.session = TerminalSessionBootstrap.make(
            sessionId: panelId,
            spaceId: config.spaceId,
            spaceName: config.spaceName,
            companionId: config.companionId,
            companionPrompt: config.companionPrompt.isEmpty ? nil : config.companionPrompt,
            customEnv: config.env
        )
        self.hooks = TerminalHooksService(socketPath: session.socketPath)
        NSLog("[ctl:%@] init panel=%@ hooksCapable=%@ socket=%@ space=%@ cwd=%@ startup=%@",
              config.companionName, panelId, hooksCapable ? "Y" : "N", session.socketPath,
              config.spaceId, config.cwd, config.startupCommand)

        // <p42> FALLBACK path (non-hooks tools only — the gate suppresses it otherwise).
        // Phase L1 / backlog 3.4: onFlush's clean output batch publishes to the Notify bus, but only
        // for non-hooks tools (claude/gemini stream via turnComplete; teeing a TUI is redraw garbage —
        // the same coarse guard, no alt-screen probe).
        // Capture the param + a computed flag, NOT self (self.processor is mid-init here).
        self.processor = TerminalOutputProcessor { [onOutput, hc = Self.isHooksCapable(config.startupCommand)] out in
            guard !hc, !out.isEmpty else { return }
            onOutput(out)
        }
        processor.onP42Output = { [weak self] tags in
            guard let self else { return }
            self.log("tee onP42Output: \(tags.count) tag(s)")
            for tag in tags {
                let out = self.gate.onTag(tag)
                if out.isEmpty {
                    self.log("  tag dropped (hooksCapable=\(self.hooksCapable ? "Y" : "N") skip=\(self.gate.lastSkipReason))")
                }
                for c in out { self.deliver(c, via: "p42") }
            }
        }

        let hooksRef = hooks
        hooksTask = Task { [weak self] in
            for await event in await hooksRef.events() {
                guard let self else { break }
                self.handleEvent(event)
            }
            if let self { self.log("hooks stream ended") }
        }
    }

    nonisolated static func isHooksCapable(_ startupCommand: String) -> Bool {
        let c = startupCommand.lowercased()
        return c.contains("claude") || c.contains("gemini")
    }

    /// Handle one normalized hook event. Logs EVERY event for introspection.
    func handleEvent(_ event: TerminalHookEvent) {
        switch event {
        case .turnComplete(let text, let exit):
            log("event=turnComplete armed=\(gate.armed) exit=\(exit) len=\(text.count) preview=\(text.prefix(60).debugDescription)")
            let out = gate.onTurnComplete(text)
            if out.isEmpty {
                log("  turnComplete NOT posted (skip=\(gate.lastSkipReason.isEmpty ? "not-armed" : gate.lastSkipReason))")
            }
            for c in out { deliver(c, via: "turnComplete") }
        case .toolStarting(let tool, let input):
            log("event=toolStarting tool=\(tool) input=\(input.prefix(40).debugDescription)")
        case .toolFinished(let tool, let output):
            log("event=toolFinished tool=\(tool) output=\(output.prefix(40).debugDescription)")
        case .approvalRequired(let tool, _, _):
            log("event=approvalRequired tool=\(tool)")
        case .inputSubmitted(let prompt):
            log("event=inputSubmitted prompt=\(prompt.prefix(40).debugDescription)")
        case .sessionStarted:
            log("event=sessionStarted")
            // CLI is up → deliver any messages queued while it was (re)spawning.
            flushPending(reason: "sessionStarted")
            // First launch → let AppState auto-register this terminal as a companion (once).
            if !didNotifySessionStart {
                didNotifySessionStart = true
                onSessionStarted()
            }
        case .sessionEnded:
            log("event=sessionEnded")
            // Allow re-registration if the user runs claude again in this same terminal.
            didNotifySessionStart = false
            onSessionEnded()
        }
    }

    /// Inject a space message into the terminal and arm the next turnComplete to post.
    func inject(_ line: String) {
        gate.arm()
        log("inject + armed: \(line.prefix(80).debugDescription)")
        if injectToSurface == nil { log("  WARNING: no surface bound — inject dropped") }
        injectToSurface?(line)
    }

    /// Write raw input to the surface WITHOUT arming the post gate. This is the path for
    /// `port.push` / `port_push` to a terminal: a caller driving the terminal directly should not
    /// cause the next `turnComplete` to broadcast (that's reserved for companion message injection
    /// via `inject`).
    /// Returns `false` when no surface is bound, so callers can surface a real "no live surface"
    /// error instead of dropping silently.
    func sendRaw(_ data: String) -> Bool {
        guard let inject = injectToSurface else { return false }
        inject(data)
        return true
    }

    /// Bind (or clear) the surface writer. Called by the view when the surface is created/freed.
    func bindSurface(_ inject: ((String) -> Void)?) {
        log(inject == nil ? "surface unbound" : "surface bound")
        injectToSurface = inject
        guard inject != nil else { return }
        // Fallback for non-hooks tools (no SessionStart event): if nothing has flushed the
        // pending queue shortly after the surface is live, flush it anyway so queued messages
        // aren't stranded. Hooks-capable tools normally flush earlier on sessionStarted.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.flushPending(reason: "surface-bound fallback")
        }
    }

    /// Inject any messages queued while this terminal was (re)spawning. Idempotent: runs at
    /// most once (whichever readiness signal fires first). Each line arms the gate so its
    /// reply is broadcast back to the space, exactly like a live inject.
    private func flushPending(reason: String) {
        guard !didFlushPending else { return }
        // Defer (don't drain) until a surface is bound, so a readiness signal that races ahead
        // of surface binding doesn't lose the queued messages — the bind-time fallback retries.
        guard isSurfaceBound else { return }
        let lines = drainPending()
        guard !lines.isEmpty else { return }
        didFlushPending = true
        log("flushPending (\(reason)): \(lines.count) queued message(s)")
        for line in lines { inject(line) }
    }

    /// Feed raw PTY bytes (from the Ghostty tee) into the `<p42>` extractor.
    func receiveTee(_ str: String) {
        processor.receive(str)
    }

    private func deliver(_ content: String, via: String) {
        log("POST via \(via): \(content.prefix(80).debugDescription)")
        post(content)
    }

    func teardown() {
        hooksTask?.cancel()
        hooksTask = nil
        let h = hooks
        Task { await h.stop() }
        TerminalSessionBootstrap.cleanup(tempDir: session.tempDir)
        log("torn down")
    }
}
