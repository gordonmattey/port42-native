import Foundation
import GRDB

// MARK: - Enums

/// Every companion is a command companion: a CLI agent in a terminal port, or a headless command over
/// NDJSON. The in-app LLM mode and the hub's remote mode are gone (nautilus Phase 1 steps 3 and 4);
/// migration v50 deletes companions of either.
public enum AgentMode: String, Codable, Equatable {
    case command
}

public enum AgentTrigger: String, Codable, Equatable {
    case mentionOnly
    case allMessages
}

public enum AgentProvider: String, Codable, Equatable {
    case anthropic
    case gemini
    case compatibleEndpoint  // OpenAI-protocol with custom base URL
}

// MARK: - Model

public struct AgentConfig: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    public static let databaseTableName = "agents"

    public var id: String
    public var ownerId: String
    public var displayName: String
    public var mode: AgentMode
    public var trigger: AgentTrigger

    // LLM mode fields
    public var systemPrompt: String?
    public var provider: AgentProvider?
    public var providerBaseURL: String?  // nil = provider default; set for compatible endpoint
    public var model: String?
    public var thinkingEnabled: Bool
    public var thinkingEffort: String  // "low" | "medium" | "high"

    // Command mode fields
    public var command: String?
    public var args: [String]?
    public var workingDir: String?
    public var envVars: [String: String]?
    public var openInTerminal: Bool  // spawn in a visible terminal port instead of background process

    // Secret access
    public var secretNames: [String]?  // named secrets this companion can use with rest.call

    // Scope
    public var scopePath: String?  // relative path e.g. "scopes/strategy" — nil = no scope

    public var createdAt: Date

    public init(
        id: String, ownerId: String, displayName: String, mode: AgentMode,
        trigger: AgentTrigger, systemPrompt: String?, provider: AgentProvider?,
        providerBaseURL: String? = nil,
        model: String?, thinkingEnabled: Bool = false, thinkingEffort: String = "low",
        command: String?, args: [String]?, workingDir: String?,
        envVars: [String: String]?, openInTerminal: Bool = false,
        scopePath: String? = nil, createdAt: Date
    ) {
        self.id = id
        self.ownerId = ownerId
        self.displayName = displayName
        self.mode = mode
        self.trigger = trigger
        self.systemPrompt = systemPrompt
        self.provider = provider
        self.providerBaseURL = providerBaseURL
        self.model = model
        self.thinkingEnabled = thinkingEnabled
        self.thinkingEffort = thinkingEffort
        self.command = command
        self.args = args
        self.workingDir = workingDir
        self.envVars = envVars
        self.openInTerminal = openInTerminal
        self.scopePath = scopePath
        self.createdAt = createdAt
    }

    // MARK: - Factory Methods

    public static func createCommand(
        ownerId: String,
        displayName: String,
        command: String,
        args: [String]? = nil,
        workingDir: String? = nil,
        envVars: [String: String]? = nil,
        systemPrompt: String? = nil,
        openInTerminal: Bool = false,
        trigger: AgentTrigger
    ) -> AgentConfig {
        AgentConfig(
            id: UUID().uuidString,
            ownerId: ownerId,
            displayName: displayName,
            mode: .command,
            trigger: trigger,
            systemPrompt: systemPrompt,
            provider: nil,
            model: nil,
            command: command,
            args: args,
            workingDir: workingDir,
            envVars: envVars,
            openInTerminal: openInTerminal,
            createdAt: Date()
        )
    }

    // MARK: - CLI Presets

    /// Known command-line AI tools that can run as terminal agents in Port42.
    ///
    /// **Gemini CLI was REMOVED 2026-07-29, and offering it was the defect.** It was a preset with
    /// no working loop behind it: turn detection was never wired, and then Google withdrew the free
    /// sign-in for individuals ("this client is no longer supported for Gemini Code Assist for
    /// individuals"), so a gemini companion now needs a paid API key or Vertex access that nothing
    /// in Port42 asks for. A button that yields a companion which cannot authenticate and could not
    /// have replied anyway is worse than no button.
    ///
    /// Codex is the next preset, and it is not here yet because parity needs one more thing than a
    /// preset: a companion has to be able to RECEIVE a message, which no `port.create` terminal can
    /// today (see the companion-registration bug in `summer2026-todo.md`). Antigravity is parked
    /// separately — its hooks are fine, but its auth does not survive the per-session config
    /// redirect that injection depends on. Both are tracked in the CLI-parity item.
    public enum CLIPreset: String, CaseIterable {
        case claude

        /// Single-word name used as @mention handle and companion display name
        public var displayName: String {
            switch self {
            case .claude: return "claude"
            }
        }

        /// Human-readable label for UI buttons
        public var label: String {
            switch self {
            case .claude: return "Claude Code"
            }
        }

        /// Resolves the binary path by checking common install locations.
        public var resolvedPath: String? {
            let candidates: [String]
            switch self {
            case .claude:
                candidates = [
                    "/Users/\(NSUserName())/.local/bin/claude",
                    "/usr/local/bin/claude",
                    "/opt/homebrew/bin/claude",
                    "/usr/bin/claude"
                ]
            }
            // Also try nvm/nenv paths
            let nmvPrefix = "/Users/\(NSUserName())/.nvm/versions/node"
            if let versions = try? FileManager.default.contentsOfDirectory(atPath: nmvPrefix) {
                let sorted = versions.sorted().reversed()
                let bin = rawValue
                for v in sorted {
                    let p = "\(nmvPrefix)/\(v)/bin/\(bin)"
                    if FileManager.default.fileExists(atPath: p) { return p }
                }
            }
            return candidates.first { FileManager.default.fileExists(atPath: $0) }
        }

        public var args: [String] {
            switch self {
            // No --continue: the shim injects --session-id / --resume per port (deterministic,
            // per-(space,companion)), which both supersedes --continue and would conflict with a
            // pinned session id (docs/plan-companion-cwd.md).
            case .claude: return []
            }
        }

        /// The dialog prefill for a companion's OPTIONAL system prompt (personality/role).
        /// Empty by default: the operational space framing is added under the hood at spawn
        /// (see AppState.spawnTerminalAgentPort), so the user only supplies extra personality.
        public var systemPrompt: String { "" }
    }
}
