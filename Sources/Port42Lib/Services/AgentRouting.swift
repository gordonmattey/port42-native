import Foundation

// MARK: - Companion handle

/// A companion's name has to be TYPEABLE, because the only way to reach one is `@name`.
///
/// Auto-registered CLI terminals took the port's TITLE verbatim, and a title is prose. The live
/// teleport run produced a companion called `teleport: main`, and codex terminals produced
/// `codex probe` and `codex 146`. All of them joined the space correctly and none of them could be
/// addressed, because `MentionParser` accepts `@[a-zA-Z][a-zA-Z0-9-]*` and stops at the first space
/// or colon. It read as "the session never became a companion" when it had.
///
/// This is the inverse of the parser, and it lives beside it so the two cannot drift: whatever the
/// parser accepts is what this must produce. `Space.create` already does the same thing to space
/// names (spaces to hyphens); this extends the rule to the other addressable noun.
public enum CompanionName {

    /// Fold a human title into something `@mentionable`, or nil if nothing usable survives.
    ///
    /// Every run of characters the parser rejects becomes a single hyphen, and a leading non-letter
    /// is dropped, because the parser demands a letter first — a companion called `146` could not be
    /// addressed no matter how it was spelled.
    public static func mentionable(_ raw: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var out = ""
        var lastWasHyphen = true          // leading hyphens are never useful
        for scalar in raw.unicodeScalars {
            if allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                out.append("-")
                lastWasHyphen = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        while let f = out.first, !f.isLetter { out.removeFirst() }
        return out.isEmpty ? nil : out
    }
}

// MARK: - Companion protocol

/// **The rules every companion follows, stated ONCE.**
///
/// They reach two different surfaces by two different routes, which is why they escaped having a
/// home and were nearly written twice:
///
///   - **claude** gets them per session, as a system prompt, via `--append-system-prompt` (baked by
///     `AppState.bakeCompanionPrompt`, injected by the shim from `PORT42_COMPANION_PROMPT`).
///   - **codex** has no system-prompt flag, so it gets them from the global instruction file
///     `<CODEX_HOME>/AGENTS.md`, maintained by `InstructionService` (verified 2026-08-01: codex reads
///     that file; it does NOT follow `@file` imports, so the text must be inline).
///
/// Two prose copies of one protocol drift, and the drift is invisible until a companion misbehaves
/// in a way nobody can trace to a stale sentence. `CompanionProtocolTests` asserts both surfaces
/// carry this text, so a change here cannot reach one and miss the other.
public enum CompanionProtocol {

    /// The behavioural core, identical for every companion and every CLI. Deliberately verbatim from
    /// the wording claude has been running with, so extracting it changes nothing about how claude
    /// behaves — this is a de-duplication, not a rewrite.
    public static let rules = """
    Respond to space messages directly and conversationally. Messages arrive prefixed with [@name]: \
    — this prefix only tells you who sent the message; never copy that leading prefix into your \
    reply, just write your reply text. REPLYING: to reply to a message addressed to you, just write \
    your response normally — it is delivered back to the chat it came from automatically. Do NOT also post that reply \
    via the API, or it will appear twice. ADDRESSING ANOTHER COMPANION: when you want another \
    companion to act, answer, or take a hand-off, you MUST write their name with a leading @ (for \
    example @Critic or @Maker). That @mention is the ONLY thing that delivers your message to them — \
    a bare name like "Critic" is just text they never receive. So end a hand-off with the @mention, \
    e.g. "Built the login form, @Critic please review."
    """

    /// How chats work, taught to every companion (GM's multi-agent test, 2026-09-25: agents did not
    /// know which room to use, and one searched the file system to find out where it was). One source
    /// for Claude's system prompt and Codex's AGENTS.md, like `rules`. `gatewayPort` is the live
    /// instance's, so the example curls reach it.
    public static func chats(gatewayPort: Int) -> String {
        let call = "curl -s http://127.0.0.1:\(gatewayPort)/call -H \"Authorization: Bearer $(cat \"$PORT42_TOKEN_FILE\")\""
        return """
        FIRST, FIND OUT WHO AND WHERE YOU ARE: \(call) -d '{"method":"whoami"}' returns your name, your \
        space, your terminal port and its chat, and the companions you can @mention. \
        CHATS: every port in Port42 has a chat, and so does every space. A message reaches you as \
        [@sender in <where>]: text, where <where> is the chat it came from: a #space, your terminal's \
        chat, or a port's chat with its id. Work on a port belongs in that port's chat: read it with \
        \(call) -d '{"method":"chat.read","args":{"port":"<port id>"}}' and post to it with \
        \(call) -d '{"method":"chat.post","args":{"port":"<port id>","text":"..."}}', which is posted as \
        you. To reach another companion, @mention it by name in a chat; whoami lists who is here. \
        WHEN YOU MAKE OR CHANGE A PORT, CHECK IT WORKS before you say it is done: read its console \
        (\(call) -d '{"method":"port.console","args":{"id":"<port id>"}}') for errors, and its DOM \
        (port.getDom) for the controls you added, then say what you checked.
        """
    }

    /// The EXACT text claude has been running with, kept as a literal so the extraction can be
    /// proved to have changed nothing. Extracting shared prose is a refactor; a refactor that
    /// quietly reworded a live system prompt would be a behaviour change wearing a refactor's
    /// clothes. `CompanionProtocolTests` compares `rules` against this, character for character.
    static let historicalRules = "Respond to space messages directly and conversationally. Messages arrive prefixed with [@name]: — this prefix only tells you who sent the message; never copy that leading prefix into your reply, just write your reply text. REPLYING: to reply to a message addressed to you, just write your response normally — it is delivered back to the chat it came from automatically. Do NOT also post that reply via the API, or it will appear twice. ADDRESSING ANOTHER COMPANION: when you want another companion to act, answer, or take a hand-off, you MUST write their name with a leading @ (for example @Critic or @Maker). That @mention is the ONLY thing that delivers your message to them — a bare name like \"Critic\" is just text they never receive. So end a hand-off with the @mention, e.g. \"Built the login form, @Critic please review.\""

    /// The sentence fragments a surface must carry to count as stating the protocol. Used by the
    /// anti-drift test rather than comparing whole strings, so wording can be improved in one place
    /// without the gate becoming a copy of the thing it guards.
    static let loadBearingPhrases = [
        "never copy that leading prefix",
        "it is delivered back to the chat it came from automatically",
        "the ONLY thing that delivers your message",
    ]
}

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
    /// and space membership.
    /// If explicit @mentions are present, ONLY those companions respond.
    /// Namespaced mentions like `@Echo@gordon` only match if the owner matches `localOwner`.
    /// Bare mentions like `@Echo` match local agents directly (unless `requireNamespace` is true).
    /// Otherwise, space members and global listeners respond.
    /// - `requireNamespace`: When true, bare @mentions are ignored (used for remote messages
    ///   where the sender's app handles bare mentions).
    public static func findTargetAgents(
        content: String,
        agents: [AgentConfig],
        spaceAgentIds: Set<String> = [],
        localOwner: String? = nil,
        requireNamespace: Bool = false
    ) -> [AgentConfig] {
        let mentions = MentionParser.extractMentions(from: content)
            .map { String($0.dropFirst()).lowercased() } // strip leading @

        // @all targets every space member
        if mentions.contains("all") {
            return agents.filter { spaceAgentIds.contains($0.id) }
        }

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
            // If mentions were present but none matched, don't fall through to space routing
            return matched
        }

        // No @mentions: only space members respond
        return agents.filter { spaceAgentIds.contains($0.id) }
    }
}
