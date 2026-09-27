import Foundation

/// Who is on a chat's message right now (GM, 2026-09-26: "I can't see that the agent received the
/// message and is working"). Kept per chat, the chat that asked, so the panel that sent a message is
/// the one that shows the agent taking it up.
///
/// Fed by the terminal's own events, not guessed from text: a message typed in (`received`), the CLI
/// confirming it submitted it (`working`; Claude reports this, Codex does not), the CLI saying it needs
/// the person (`waiting`), and the end of its turn (gone). No timeout: the old "typing" indicator
/// cleared itself after 60 s while the agent was still working.
public struct ChatPresence: Equatable {
    public enum State: Equatable {
        case received
        case working
        case waiting(String)
    }
    public let name: String
    public var state: State
    public var since: Date
}

extension ChatPresence {
    /// What the chat says when an agent's turn failed instead of replying (GM, 2026-09-27): who,
    /// what went wrong in words, and what to do. Claude's StopFailure codes; anything else reads as
    /// an error, with the CLI's own words when it gave them.
    public static func failureNotice(name: String, error: String, details: String) -> String {
        let what: String
        switch error {
        case "rate_limit": what = "it was rate limited. Wait a moment and send it again."
        case "overloaded": what = "the API is overloaded. Wait a moment and send it again."
        case "server_error": what = "the API could not be reached (the connection may have dropped). Send it again."
        case "authentication_failed", "oauth_org_not_allowed", "cloud_credential_error":
            what = "its login failed. Sign in again in its terminal."
        case "billing_error": what = "its usage limit is reached. Check its plan."
        case "account_on_hold", "verification_required": what = "its account needs attention. See its terminal."
        case "model_not_found": what = "its model is not available. Check its terminal."
        case "max_output_tokens": what = "its reply ran past the length limit."
        case "invalid_request": what = "the request was refused."
        default: what = "it hit an error."
        }
        let words = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let said = words.isEmpty ? "" : " (\(words.count > 200 ? String(words.prefix(200)) + "…" : words))"
        return "\(name) could not reply: \(what)\(said)"
    }
}

@MainActor
public final class ChatPresenceStore: ObservableObject {
    @Published public private(set) var byChat: [String: [ChatPresence]] = [:]
    /// The clock the "for how long" is read from. Replaceable for tests.
    var now: () -> Date = Date.init

    /// A message was typed into `name`'s terminal from `chat`. It moves there if it was elsewhere.
    public func received(_ name: String, in chat: String) {
        // Already on a message from this chat: another one does not restart what it is doing.
        if entries(chat).contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return }
        remove(name)
        byChat[chat, default: []].append(ChatPresence(name: name, state: .received, since: now()))
    }

    /// The CLI took it up, or needs the person. Wherever the agent is listed.
    public func update(_ name: String, to state: ChatPresence.State) {
        for (chat, list) in byChat {
            if let i = list.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                var next = list
                if next[i].state != state { next[i].state = state; next[i].since = now() }
                byChat[chat] = next
            }
        }
    }

    /// The turn ended (its reply landed) or the CLI stopped.
    public func done(_ name: String) { remove(name) }

    public func entries(_ chat: String) -> [ChatPresence] { byChat[chat] ?? [] }

    private func remove(_ name: String) {
        for (chat, list) in byChat {
            let kept = list.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }
            if kept.count != list.count { byChat[chat] = kept.isEmpty ? nil : kept }
        }
    }

    /// What the panel shows for one agent.
    public static func line(_ p: ChatPresence, now: Date) -> String {
        let secs = max(0, Int(now.timeIntervalSince(p.since)))
        let for_ = secs < 5 ? "" : secs < 60 ? " (\(secs)s)" : " (\(secs / 60)m)"
        switch p.state {
        case .received: return "has your message\(for_)"
        case .working: return "is working\(for_)"
        case .waiting(let why): return why.isEmpty ? "is waiting for you in its terminal" : "is waiting for you: \(why)"
        }
    }
}
