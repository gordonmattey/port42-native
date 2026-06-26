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

    /// `turnComplete`: broadcast the reply ONLY if it answered an injected message, then disarm.
    mutating func onTurnComplete(_ text: String) -> [String] {
        guard armed else { return [] }
        armed = false
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
        // Companions often echo the inbound "[name]: " convention onto their own reply.
        // Strip a single leading "[anything]: " — sender attribution is already applied.
        if let r = trimmed.range(of: "^\\[[^\\]]+\\]:[ \t]*", options: .regularExpression) {
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
    private var injectToSurface: ((String) -> Void)?
    private var gate: CompanionPostGate
    private let hooksCapable: Bool

    var env: [String: String] { session.env }

    private func log(_ msg: String) { NSLog("[ctl:%@] %@", config.companionName, msg) }

    init(panelId: String, config: TerminalPortConfig, post: @escaping (String) -> Void) {
        self.panelId = panelId
        self.config = config
        self.post = post
        self.hooksCapable = Self.isHooksCapable(config.startupCommand)
        self.gate = CompanionPostGate(hooksCapable: hooksCapable)

        self.session = TerminalSessionBootstrap.make(
            sessionId: panelId,
            spaceId: config.spaceId,
            spaceName: config.spaceName,
            companionPrompt: config.companionPrompt.isEmpty ? nil : config.companionPrompt
        )
        self.hooks = TerminalHooksService(socketPath: session.socketPath)
        NSLog("[ctl:%@] init panel=%@ hooksCapable=%@ socket=%@ space=%@ cwd=%@ startup=%@",
              config.companionName, panelId, hooksCapable ? "Y" : "N", session.socketPath,
              config.spaceId, config.cwd, config.startupCommand)

        // <p42> FALLBACK path (non-hooks tools only — the gate suppresses it otherwise).
        self.processor = TerminalOutputProcessor { _ in }
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
        case .sessionEnded:
            log("event=sessionEnded")
        }
    }

    /// Inject a space message into the terminal and arm the next turnComplete to post.
    func inject(_ line: String) {
        gate.arm()
        log("inject + armed: \(line.prefix(80).debugDescription)")
        if injectToSurface == nil { log("  WARNING: no surface bound — inject dropped") }
        injectToSurface?(line)
    }

    /// Bind (or clear) the surface writer. Called by the view when the surface is created/freed.
    func bindSurface(_ inject: ((String) -> Void)?) {
        log(inject == nil ? "surface unbound" : "surface bound")
        injectToSurface = inject
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
