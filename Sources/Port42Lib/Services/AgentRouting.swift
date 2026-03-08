import Foundation

// MARK: - Mention Parser

public enum MentionParser {

    /// Extract @mentions from message content.
    /// Supports both `@Name` and namespaced `@Name@Owner` formats.
    /// Ignores email addresses (word@domain). Deduplicates results.
    public static func extractMentions(from content: String) -> [String] {
        // Match @Name or @Name@Owner (but not email: requires non-word char before @)
        let pattern = #"(?<![a-zA-Z0-9.])@([a-zA-Z][a-zA-Z0-9-]*(?:@[a-zA-Z][a-zA-Z0-9-]*)?)"#
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
        // Strip leading @ since displayName doesn't include it
        let stripped = lowered.hasPrefix("@") ? String(lowered.dropFirst()) : lowered
        return agents.filter { $0.displayName.lowercased().hasPrefix(stripped) }
    }
}

// MARK: - Agent Router

public enum AgentRouter {

    /// Find agents that should receive this message based on mentions, trigger mode,
    /// and channel membership.
    /// If explicit @mentions are present, ONLY those companions respond.
    /// Namespaced mentions like `@Echo@gordon` only match if the owner matches `localOwner`.
    /// Bare mentions like `@Echo` match local agents directly (unless `requireNamespace` is true).
    /// Otherwise, channel members and global listeners respond.
    /// - `requireNamespace`: When true, bare @mentions are ignored (used for remote messages
    ///   where the sender's app handles bare mentions).
    public static func findTargetAgents(
        content: String,
        agents: [AgentConfig],
        channelAgentIds: Set<String> = [],
        localOwner: String? = nil,
        requireNamespace: Bool = false
    ) -> [AgentConfig] {
        let mentions = MentionParser.extractMentions(from: content)
            .map { String($0.dropFirst()).lowercased() } // strip leading @

        if !mentions.isEmpty {
            let matched = agents.filter { agent in
                let agentName = agent.displayName.lowercased()
                return mentions.contains { mention in
                    if mention.contains("@") {
                        // Namespaced: @Echo@gordon -> only match if owner matches
                        let parts = mention.split(separator: "@", maxSplits: 1)
                        guard parts.count == 2 else { return false }
                        let name = String(parts[0])
                        let owner = String(parts[1])
                        return agentName == name && owner == (localOwner?.lowercased() ?? "")
                    } else if !requireNamespace {
                        // Bare: @Echo -> match local agent by name
                        return agentName == mention
                    } else {
                        return false
                    }
                }
            }
            // If mentions were present but none matched, don't fall through to channel routing
            return matched
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
