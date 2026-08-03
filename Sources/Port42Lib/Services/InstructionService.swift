import Foundation

/// Manages the Port42 block in CLI instruction files (Claude Code's CLAUDE.md, Gemini CLI's
/// GEMINI.md, Codex-convention AGENTS.md).
///
/// Knowledge item C: the block is a SLIM POINTER — how to call the gateway, `help` for the API
/// reference, `help(topic:"ports")` for the port manual, and the published llms.txt as the
/// offline fallback. The method inventory is never embedded (that was the install-time drift bug:
/// a snapshot of the registry, fresh at click time, stale forever after). `refreshInstalled()`
/// rewrites any already-installed block from the live template at every app boot.
@MainActor
public final class InstructionService: ObservableObject {
    public static let shared = InstructionService()

    /// (tool key, human name, instruction file path relative to home)
    private static let targets: [(tool: String, name: String, relPath: String)] = [
        ("claude", "Claude Code", ".claude/CLAUDE.md"),
        ("gemini", "Gemini CLI", ".gemini/GEMINI.md"),
        ("codex", "Codex", ".codex/AGENTS.md"),
    ]

    private let home: String

    @Published public var hasClaudeInstructions = false
    @Published public var hasGeminiInstructions = false
    @Published public var hasCodexInstructions = false

    init(homeDirectory: String = NSHomeDirectory()) {
        self.home = homeDirectory
        refresh()
    }

    private func path(for tool: String) -> String? {
        Self.targets.first { $0.tool == tool.lowercased() }
            .map { (home as NSString).appendingPathComponent($0.relPath) }
    }

    public func refresh() {
        hasClaudeInstructions = path(for: "claude").map { FileManager.default.fileExists(atPath: $0) } ?? false
        hasGeminiInstructions = path(for: "gemini").map { FileManager.default.fileExists(atPath: $0) } ?? false
        hasCodexInstructions = path(for: "codex").map { FileManager.default.fileExists(atPath: $0) } ?? false
    }

    private static let blockStart = "<!-- port42:start -->"
    private static let blockEnd   = "<!-- port42:end -->"

    // MARK: - Install

    /// Installs or updates the Port42 section in the tool's instruction file.
    /// Preserves any existing content outside the port42 block.
    public func installInstructions(for tool: String) {
        guard let target = Self.targets.first(where: { $0.tool == tool.lowercased() }),
              let mdPath = path(for: tool) else { return }

        let dir = (mdPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // The companion section goes ONLY to a CLI that has no system-prompt channel.
        // claude receives `CompanionProtocol.rules` per session as a real system prompt (the shim
        // turns PORT42_COMPANION_PROMPT into --append-system-prompt), so repeating it in CLAUDE.md
        // is dead weight in a block whose whole discipline is staying a pointer. codex has no such
        // flag, which is the entire reason the section exists.
        let block = "\(Self.blockStart)\n\(buildMarkdown(toolName: target.name, companionProtocol: target.tool == "codex"))\n\(Self.blockEnd)"

        // Read existing file if present
        let existing = (try? String(contentsOfFile: mdPath, encoding: .utf8)) ?? ""

        let updated: String
        if let startRange = existing.range(of: Self.blockStart),
           let endRange = existing.range(of: Self.blockEnd),
           startRange.lowerBound <= endRange.upperBound {
            // Replace the existing port42 block in place
            let fullRange = startRange.lowerBound..<endRange.upperBound
            updated = existing.replacingCharacters(in: fullRange, with: block)
        } else if existing.isEmpty {
            updated = block
        } else {
            // Append after a blank line separator
            let separator = existing.hasSuffix("\n\n") ? "" : existing.hasSuffix("\n") ? "\n" : "\n\n"
            updated = existing + separator + block
        }

        try? updated.write(toFile: mdPath, atomically: true, encoding: .utf8)
        refresh()
    }

    /// Rewrite the port42 block in every instruction file that already carries one. Called at app
    /// boot, so an installed block is always as fresh as the running app — the install-time drift
    /// class dies here. Files without a block (never installed, or user-removed) are not touched.
    public func refreshInstalled() {
        for target in Self.targets {
            guard let mdPath = path(for: target.tool),
                  let existing = try? String(contentsOfFile: mdPath, encoding: .utf8),
                  existing.contains(Self.blockStart) else { continue }
            installInstructions(for: target.tool)
        }
    }

    // MARK: - Markdown content

    /// The slim pointer block. API facts live behind `help` / llms.txt (generated, cannot drift);
    /// port craft lives behind `help(topic:"ports")`. Nothing here enumerates methods.
    /// Internal rather than private so the C3 gate can scan it: every generated example that calls
    /// the gateway must carry a credential, and a hand-checked list of documents would rot.
    func buildMarkdown(toolName: String, companionProtocol: Bool = false) -> String {
        """
# Port42 Instructions

You are running as \(toolName) alongside Port42 — a macOS companion computing platform. \
Port42 exposes its device and space APIs to you via a local HTTP gateway.

## Calling Port42 APIs

```bash
curl -s http://127.0.0.1:\(GatewayProcess.shared.port)/call \\
  -H "Authorization: Bearer $(cat \"$PORT42_TOKEN_FILE\")" \\
  -d '{"method":"<method>","args":{...}}'
```

Response: `{"content": "..."}` — the result as a string or JSON. A port is a live interactive \
surface in the user's chat (web HTML/CSS/JS, or a native terminal), created with `port.create`.

## Who you are when you call

**Every call must name a caller, and you have your own.** If Port42 started this session, \
`$PORT42_TOKEN_FILE` holds the path to your token and `$PORT42_CLIENT_ID` is the name Port42 knows \
you by. Read the file at call time rather than caching it: it is re-issued when the app restarts.

If `$PORT42_TOKEN_FILE` is not set, Port42 did not start this session and you have no credential \
here. Ask the user to add a client in **Port42 Settings → Access** and to give you its token. Note \
that each Port42 instance mints its own, so a token from one instance is refused by another.

**Do not read another tool's token file.** They sit at predictable paths and they will work, and \
that is exactly the problem: the permission prompt then names that tool instead of you, the grant \
lands on it, and revoking your access breaks whatever it belonged to. A borrowed credential is not \
a shortcut, it is a wrong answer that looks right.

**Every write to a port must carry that port's `token`**, and every write, `ports.list` and \
`port.create` return one — so you thread it and never re-read a port just to write to it again. \
A write without one is refused with `token_required`, and a write composed against stale state with \
`stale_write`; both carry `current`, so one retry with that value lands. This is what stops two \
callers silently overwriting each other.

## Learning the platform (on demand, always current)

```bash
# The full API reference — every method, params, permissions (generated from the live registry)
curl -s http://127.0.0.1:\(GatewayProcess.shared.port)/call \\
  -H "Authorization: Bearer $(cat \"$PORT42_TOKEN_FILE\")" -d '{"method":"help"}'

# The port-authoring manual — REQUIRED READING before building or updating any port
curl -s http://127.0.0.1:\(GatewayProcess.shared.port)/call \\
  -H "Authorization: Bearer $(cat \"$PORT42_TOKEN_FILE\")" -d '{"method":"help","args":{"topic":"ports"}}'
```

If Port42 is not running, the same reference is published at:
https://raw.githubusercontent.com/gordonmattey/port42-native/main/llms.txt

## Permissions

Port42 prompts the user on first use of a sensitive API (terminal, screen, clipboard, files, \
camera, automation, browser, REST). Denials are never permanent — a later call re-asks. \
A granted permission is per caller, and the user can see and revoke it in Port42 Settings → Access.
\(companionProtocol ? Self.companionSection : "")
"""
    }

    /// The companion briefing, for a CLI that cannot be handed a system prompt.
    ///
    /// **Only codex gets this.** claude receives `CompanionProtocol.rules` per session as a real
    /// system prompt — the shim turns `PORT42_COMPANION_PROMPT` into `--append-system-prompt` — so
    /// putting it in CLAUDE.md too would be a second copy of something claude already has, in a
    /// block whose entire discipline is remaining a pointer. Codex has no such flag, which is the
    /// whole reason this exists.
    ///
    /// Kept out of `buildMarkdown` so the general block's slimness gate measures the general block.
    private static let companionSection = """


## If you were launched as a SPACE COMPANION

Applies only when `PORT42_SPACE_ID` is set, which Port42 does for a companion terminal. If it is \
unset, ignore this section.

**Your space is `$PORT42_SPACE_ID` and you must PASS IT** — look it up for the name and roster:

```bash
curl -s -H "Authorization: Bearer $(cat \\"$PORT42_TOKEN_FILE\\")" \\\\
  http://127.0.0.1:\(GatewayProcess.shared.port)/call \\\\
  -d '{"method":"space.current","args":{"space_id":"'"$PORT42_SPACE_ID"'"}}'
```

**Never call it without `space_id`.** Bare, it returns the space the USER is looking at, which is not \
yours and changes when they switch. Your space is fixed for life; only the name and roster change, \
so ask again rather than remembering.

**How to behave:** \(CompanionProtocol.rules)
"""
}
