import Foundation

// MARK: - Invite Link Data

public struct AgentInviteData {
    public let displayName: String
    public let systemPrompt: String
    public let provider: AgentProvider
    public let model: String

    public init(displayName: String, systemPrompt: String, provider: AgentProvider, model: String) {
        self.displayName = displayName
        self.systemPrompt = systemPrompt
        self.provider = provider
        self.model = model
    }
}

// MARK: - Errors

public enum AgentInviteError: Error {
    case commandAgentNotShareable
    case invalidLink
    case missingField(String)
}

// MARK: - Invite Link Generator/Parser

public enum AgentInvite {

    /// Generate a port42://agent? invite link from an LLM agent config.
    /// Returns empty string for command agents (not shareable).
    public static func generateLink(from config: AgentConfig) -> String {
        guard config.mode == .llm,
              let systemPrompt = config.systemPrompt,
              let provider = config.provider,
              let model = config.model else {
            return ""
        }

        var components = URLComponents()
        components.scheme = "port42"
        components.host = "agent"
        components.queryItems = [
            URLQueryItem(name: "name", value: config.displayName),
            URLQueryItem(name: "prompt", value: systemPrompt),
            URLQueryItem(name: "provider", value: provider.rawValue),
            URLQueryItem(name: "model", value: model),
        ]

        return components.string ?? ""
    }

    /// Parse a port42://agent? invite link back into agent invite data.
    public static func parse(link: String) throws -> AgentInviteData {
        guard let components = URLComponents(string: link),
              components.scheme == "port42",
              components.host == "agent" else {
            throw AgentInviteError.invalidLink
        }

        let items = components.queryItems ?? []
        let dict = Dictionary(items.compactMap { item in
            item.value.map { (item.name, $0) }
        }, uniquingKeysWith: { _, last in last })

        guard let name = dict["name"] else {
            throw AgentInviteError.missingField("name")
        }
        guard let prompt = dict["prompt"] else {
            throw AgentInviteError.missingField("prompt")
        }
        guard let providerStr = dict["provider"],
              let provider = AgentProvider(rawValue: providerStr) else {
            throw AgentInviteError.missingField("provider")
        }
        guard let model = dict["model"] else {
            throw AgentInviteError.missingField("model")
        }

        return AgentInviteData(
            displayName: name,
            systemPrompt: prompt,
            provider: provider,
            model: model
        )
    }
}
