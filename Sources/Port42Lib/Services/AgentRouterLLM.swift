import Foundation

// MARK: - Route Decision

public enum RouteAction: String {
    case respond  // generate a full response
    case act      // use tools silently, maybe respond
    case silent   // do nothing
}

public struct RouteDecision {
    public let agentId: String
    public let action: RouteAction
    public let directive: String?
}

// MARK: - LLM Router

/// Lightweight LLM pre-check that decides which companions should respond
/// to a message before full generation starts. Uses haiku for speed (~1-2s).
public final class AgentRouterLLM {

    /// Route a message to determine which companions should respond.
    /// Returns nil on failure (caller should fall back to deterministic routing).
    public func route(
        message: String,
        senderName: String,
        companions: [AgentConfig],
        recentMessages: [(sender: String, content: String)] = []
    ) async -> [RouteDecision]? {
        guard companions.count >= 2 else { return nil }

        let prompt = buildPrompt(
            message: message,
            senderName: senderName,
            companions: companions,
            recentMessages: recentMessages
        )

        let systemPrompt = """
            You are a message router. Given a message and a list of companions, decide who should respond. \
            Output one line per companion: NAME: respond|act|silent [optional one-line directive]. \
            At most 2 should respond or act. Default is silent. Be decisive.
            """

        guard let response = await LLMEngine.oneShot(
            prompt: prompt,
            systemPrompt: systemPrompt
        ) else {
            return nil
        }

        NSLog("[Router] Response: %@", response)
        return parseResponse(response, companions: companions)
    }

    // MARK: - Prompt Construction

    private func buildPrompt(
        message: String,
        senderName: String,
        companions: [AgentConfig],
        recentMessages: [(sender: String, content: String)]
    ) -> String {
        var parts: [String] = []

        parts.append("Companions:")
        for companion in companions {
            let summary = firstSentence(of: companion.systemPrompt ?? companion.displayName)
            parts.append("- \(companion.displayName): \(summary)")
        }

        if !recentMessages.isEmpty {
            parts.append("")
            parts.append("Recent:")
            for msg in recentMessages.suffix(3) {
                let truncated = String(msg.content.prefix(100))
                parts.append("  \(msg.sender): \(truncated)")
            }
        }

        parts.append("")
        parts.append("Message from \(senderName): \"\(String(message.prefix(300)))\"")
        parts.append("")
        parts.append("For each companion, one line: NAME: respond|act|silent [directive]")
        parts.append("At most 2 should respond or act. Default is silent.")

        return parts.joined(separator: "\n")
    }

    private func firstSentence(of text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        for (i, char) in cleaned.enumerated() {
            if char == "." || char == "!" || char == "?" {
                let end = cleaned.index(cleaned.startIndex, offsetBy: min(i + 1, cleaned.count))
                let sentence = String(cleaned[cleaned.startIndex..<end])
                if sentence.count > 10 { return sentence }
            }
        }
        return String(cleaned.prefix(80))
    }

    // MARK: - Response Parsing

    private func parseResponse(_ response: String, companions: [AgentConfig]) -> [RouteDecision] {
        let companionNames = Set(companions.map { $0.displayName.lowercased() })
        let companionIds = Dictionary(uniqueKeysWithValues: companions.map { ($0.displayName.lowercased(), $0.id) })

        var decisions: [RouteDecision] = []

        for line in response.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { continue }

            guard let colonIndex = trimmed.firstIndex(of: ":") else { continue }
            let name = trimmed[trimmed.startIndex..<colonIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "- ", with: "")

            guard companionNames.contains(name),
                  let agentId = companionIds[name] else { continue }

            let rest = trimmed[trimmed.index(after: colonIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let action: RouteAction
            var directive: String? = nil

            if rest.hasPrefix("respond") {
                action = .respond
                let after = rest.dropFirst("respond".count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !after.isEmpty { directive = after }
            } else if rest.hasPrefix("act") {
                action = .act
                let after = rest.dropFirst("act".count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !after.isEmpty { directive = after }
            } else {
                action = .silent
            }

            decisions.append(RouteDecision(agentId: agentId, action: action, directive: directive))
        }

        guard !decisions.isEmpty else { return [] }
        return decisions
    }
}
