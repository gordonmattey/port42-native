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

    nonisolated static let blockStart = "<!-- port42:start -->"
    nonisolated static let blockEnd   = "<!-- port42:end -->"

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
        let block = Self.block(toolName: target.name, companionProtocol: target.tool == "codex")
        let existing = (try? String(contentsOfFile: mdPath, encoding: .utf8)) ?? ""
        try? Self.merged(existing: existing, block: block).write(toFile: mdPath, atomically: true, encoding: .utf8)
        refresh()
    }

    /// The whole marked block for one tool, markers included.
    nonisolated static func block(toolName: String, companionProtocol: Bool) -> String {
        "\(blockStart)\n\(markdown(toolName: toolName, companionProtocol: companionProtocol))\n\(blockEnd)"
    }

    /// `existing` with the port42 block replaced in place, or appended after a blank line.
    /// Content outside the block is the user's and is kept exactly.
    nonisolated static func merged(existing: String, block: String) -> String {
        if let startRange = existing.range(of: blockStart),
           let endRange = existing.range(of: blockEnd),
           startRange.lowerBound <= endRange.upperBound {
            return existing.replacingCharacters(in: startRange.lowerBound..<endRange.upperBound, with: block)
        }
        if existing.isEmpty { return block }
        let separator = existing.hasSuffix("\n\n") ? "" : existing.hasSuffix("\n") ? "\n" : "\n\n"
        return existing + separator + block
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
        Self.markdown(toolName: toolName, companionProtocol: companionProtocol)
    }

    nonisolated static func markdown(toolName: String, companionProtocol: Bool = false) -> String {
        """
# Port42 Instructions

You are running as \(toolName) alongside Port42 — a macOS companion computing platform. \
Port42 exposes its device and space APIs to you via a local HTTP gateway.

## Calling Port42

Use the `port42` command. It calls as you, on the Port42 that started your session: \
`port42 whoami`, `port42 <method> key=value` (`key:=<json>` for numbers and objects, `key=@<file>` \
for a file's contents), `port42 help api` for every method, `port42 help ports` for the port manual. \
A port is a live interactive surface in the user's chat (web HTML/CSS/JS, or a native terminal), \
created with `port42 port.create`. Each call is an HTTP POST the command makes for you:

```bash
curl -s http://127.0.0.1:\(CompanionProtocol.envGateway)/call \\
  -H "Authorization: Bearer $(cat \"$PORT42_TOKEN_FILE\")" \\
  -d '{"method":"<method>","args":{...}}'
```

## Who you are when you call

**Every call must name a caller, and you have your own.** If Port42 started this session, \
`$PORT42_TOKEN_FILE` holds the path to your token and `$PORT42_CLIENT_ID` is the name Port42 knows \
you by. Read the file at call time rather than caching it: it is re-issued when the app restarts.

If `$PORT42_TOKEN_FILE` is not set, Port42 did not start this session, and `port42` calls as the \
port42 CLI, the credential Port42 gave the command when it installed it. Each Port42 instance mints \
its own, so a token from one instance is refused by another.

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

`port42 help api` prints the full API reference, every method with its arguments and permission,
generated from the live registry. `port42 help ports` is the port-authoring manual: REQUIRED READING
before building or updating any port.

If Port42 is not running, the same reference is published at:
https://raw.githubusercontent.com/gordonmattey/port42-native/main/llms.txt

## Permissions

Port42 prompts the user on first use of a sensitive API (terminal, screen, clipboard, files, \
camera, automation, browser, REST). Denials are never permanent — a later call re-asks. \
A granted permission is per caller, and the user can see and revoke it in Port42 Settings → Access.
\(companionProtocol ? companionSection : "")
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
    private nonisolated static let companionSection = """


## If you were launched as a SPACE COMPANION

Applies only when `PORT42_TOKEN_FILE` is set, which Port42 does for every terminal it starts. If it \
is unset, ignore this section.

\(CompanionProtocol.chats(gateway: CompanionProtocol.envGateway))

**How to behave:** \(CompanionProtocol.rules)
"""
}
