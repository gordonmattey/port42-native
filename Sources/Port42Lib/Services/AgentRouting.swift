import Foundation

// MARK: - Mention Parser

public enum MentionParser {

    /// Extract @mentions from message content.
    /// Ignores email addresses (word@domain). Deduplicates results.
    public static func extractMentions(from content: String) -> [String] {
        let pattern = #"(?<![a-zA-Z0-9.])@([a-zA-Z][a-zA-Z0-9-]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, range: range)

        var seen = Set<String>()
        var result: [String] = []

        for match in matches {
            guard let fullRange = Range(match.range, in: content) else { continue }
            let mention = String(content[fullRange])
            if !seen.contains(mention) {
                seen.insert(mention)
                result.append(mention)
            }
        }

        return result
    }

    /// Find agents matching a partial @query for autocomplete.
    public static func autocomplete(query: String, agents: [AgentConfig]) -> [AgentConfig] {
        let lowered = query.lowercased()
        if lowered == "@" { return agents }
        return agents.filter { $0.displayName.lowercased().hasPrefix(lowered) }
    }
}

// MARK: - Agent Router

public enum AgentRouter {

    /// Find agents that should receive this message based on mentions, trigger mode,
    /// and channel membership.
    /// If explicit @mentions are present, ONLY those companions respond.
    /// Otherwise, channel members and global listeners respond.
    public static func findTargetAgents(
        content: String,
        agents: [AgentConfig],
        channelAgentIds: Set<String> = []
    ) -> [AgentConfig] {
        let mentionNames = MentionParser.extractMentions(from: content)
            .map { $0.dropFirst().lowercased() }

        // If someone is explicitly @mentioned, only they respond
        if !mentionNames.isEmpty {
            return agents.filter { agent in
                mentionNames.contains(agent.displayName.lowercased())
            }
        }

        // No @mentions: channel members and global listeners respond
        return agents.filter { agent in
            if channelAgentIds.contains(agent.id) {
                return true
            }
            if agent.trigger == .allMessages {
                return true
            }
            return false
        }
    }
}
