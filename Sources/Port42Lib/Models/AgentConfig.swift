import Foundation
import GRDB

// MARK: - Enums

public enum AgentMode: String, Codable, Equatable {
    case llm
    case command
    case remote  // Python SDK / CLI agent connected via WebSocket
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

    public var createdAt: Date

    public init(
        id: String, ownerId: String, displayName: String, mode: AgentMode,
        trigger: AgentTrigger, systemPrompt: String?, provider: AgentProvider?,
        providerBaseURL: String? = nil,
        model: String?, thinkingEnabled: Bool = false, thinkingEffort: String = "low",
        command: String?, args: [String]?, workingDir: String?,
        envVars: [String: String]?, openInTerminal: Bool = false, createdAt: Date
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
        self.createdAt = createdAt
    }

    // MARK: - Factory Methods

    public static func createLLM(
        ownerId: String,
        displayName: String,
        systemPrompt: String,
        provider: AgentProvider,
        model: String,
        trigger: AgentTrigger
    ) -> AgentConfig {
        AgentConfig(
            id: UUID().uuidString,
            ownerId: ownerId,
            displayName: displayName,
            mode: .llm,
            trigger: trigger,
            systemPrompt: systemPrompt,
            provider: provider,
            model: model,
            command: nil,
            args: nil,
            workingDir: nil,
            envVars: nil,
            createdAt: Date()
        )
    }

    public static func createRemote(
        ownerId: String,
        displayName: String,
        ownerName: String
    ) -> AgentConfig {
        AgentConfig(
            id: UUID().uuidString,
            ownerId: ownerId,
            displayName: displayName,
            mode: .remote,
            trigger: .mentionOnly,
            systemPrompt: nil,
            provider: nil,
            model: nil,
            command: nil,
            args: nil,
            workingDir: nil,
            envVars: nil,
            createdAt: Date()
        )
    }

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
    public enum CLIPreset: String, CaseIterable {
        case claude
        case gemini

        /// Single-word name used as @mention handle and companion display name
        public var displayName: String {
            switch self {
            case .claude: return "claude"
            case .gemini: return "gemini"
            }
        }

        /// Human-readable label for UI buttons
        public var label: String {
            switch self {
            case .claude: return "Claude Code"
            case .gemini: return "Gemini CLI"
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
            case .gemini:
                candidates = [
                    "/usr/local/bin/gemini",
                    "/opt/homebrew/bin/gemini",
                    "/usr/bin/gemini"
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
            case .claude: return ["--continue"]
            case .gemini: return []
            }
        }

        public var systemPrompt: String {
            switch self {
            case .claude:
                return """
                    You are {{NAME}}, a channel companion in Port42 connected to #{{CHANNEL}}. \
                    Channel messages arrive prefixed with [name]: — respond to them directly. \
                    To post to the channel, output a code block containing p42 tags — this is the ONLY output method, do NOT use curl or any API call:
                    ```
                    <p42>your response here</p42>
                    ```
                    Only content inside p42 tags reaches the channel. Keep responses concise and conversational.
                    """
            case .gemini:
                return """
                    You are {{NAME}}, a channel companion in Port42 connected to #{{CHANNEL}}. \
                    Channel messages arrive prefixed with [name]: — respond to them directly. \
                    To post to the channel, output a code block containing p42 tags — this is the ONLY output method, do NOT use curl or any API call:
                    ```
                    <p42>your response here</p42>
                    ```
                    Only content inside p42 tags reaches the channel. Keep responses concise and conversational.
                    """
            }
        }
    }
}
