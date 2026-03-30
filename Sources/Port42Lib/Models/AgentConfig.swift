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

    // Secret access
    public var secretNames: [String]?  // named secrets this companion can use with rest.call

    public var createdAt: Date

    public init(
        id: String, ownerId: String, displayName: String, mode: AgentMode,
        trigger: AgentTrigger, systemPrompt: String?, provider: AgentProvider?,
        providerBaseURL: String? = nil,
        model: String?, thinkingEnabled: Bool = false, thinkingEffort: String = "low",
        command: String?, args: [String]?, workingDir: String?,
        envVars: [String: String]?, createdAt: Date
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
            createdAt: Date()
        )
    }
}
