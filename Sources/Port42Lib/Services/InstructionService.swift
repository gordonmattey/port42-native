import Foundation

/// Manages global instruction files for CLI tools.
@MainActor
public final class InstructionService: ObservableObject {
    public static let shared = InstructionService()

    private let claudeMDPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/CLAUDE.md")
    private let geminiMDPath = (NSHomeDirectory() as NSString).appendingPathComponent(".gemini/GEMINI.md")

    @Published public var hasClaudeInstructions = false
    @Published public var hasGeminiInstructions = false

    private init() { refresh() }

    public func refresh() {
        hasClaudeInstructions = FileManager.default.fileExists(atPath: claudeMDPath)
        hasGeminiInstructions = FileManager.default.fileExists(atPath: geminiMDPath)
    }

    private static let blockStart = "<!-- port42:start -->"
    private static let blockEnd   = "<!-- port42:end -->"

    // MARK: - Install

    /// Installs or updates the Port42 section in the tool's instruction file.
    /// Preserves any existing content outside the port42 block.
    public func installInstructions(for tool: String) {
        let isClaude = tool.lowercased() == "claude"
        let mdPath = isClaude ? claudeMDPath : geminiMDPath

        let dir = (mdPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let block = "\(Self.blockStart)\n\(buildMarkdown(for: tool))\n\(Self.blockEnd)"

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

    // MARK: - Markdown content

    private func buildMarkdown(for tool: String) -> String {
        let apiDocs: String
        // CLI tools get the slim API reference (HTTP methods only, no JS bridge or port examples)
        if let url = Bundle.port42.url(forResource: "cli-context", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            apiDocs = text
        } else if let url = Bundle.port42.url(forResource: "ports-context", withExtension: "txt"),
                  let text = try? String(contentsOf: url, encoding: .utf8) {
            apiDocs = text
        } else {
            apiDocs = "(API reference unavailable — reinstall from Port42 Settings → Remote Access)"
        }

        let toolName = tool.lowercased() == "claude" ? "Claude Code" : "Gemini CLI"

        return """
# Port42 Instructions

You are running as \(toolName) alongside Port42 — a macOS companion computing platform. \
Port42 exposes all its device and channel APIs to you via a local HTTP gateway.

## Calling Port42 APIs

Use `curl` to call any API. Port42 must be running.

```bash
curl -s http://127.0.0.1:4242/call \\
  -d '{"method":"<method>","args":{...}}'
```

Response: `{"content": "..."}` — the result as a string or JSON.

Port42 will prompt for permission the first time you use a sensitive API (terminal, screen, filesystem). \
Pre-approve categories in Port42 Settings → Remote Access to skip future prompts.

## Quick examples

```bash
# Read clipboard
curl -s http://127.0.0.1:4242/call -d '{"method":"clipboard.read"}'

# Run a shell command
curl -s http://127.0.0.1:4242/call -d '{"method":"terminal.exec","args":{"command":"ls ~/Desktop"}}'

# Take a screenshot
curl -s http://127.0.0.1:4242/call -d '{"method":"screen_capture","args":{"scale":0.5}}'

# Send a message to the current channel
curl -s http://127.0.0.1:4242/call -d '{"method":"messages.send","args":{"text":"hello from \(toolName)"}}'

# Read recent channel messages
curl -s http://127.0.0.1:4242/call -d '{"method":"messages.recent","args":{"count":10}}'

# List all channels
curl -s http://127.0.0.1:4242/call -d '{"method":"channel.list"}'

# List companions
curl -s http://127.0.0.1:4242/call -d '{"method":"companions.list"}'

# Get current user
curl -s http://127.0.0.1:4242/call -d '{"method":"user.get"}'
```

## API Reference

All method names below work as-is with the `curl` pattern above.

---

\(apiDocs)
"""
    }
}
