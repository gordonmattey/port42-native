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
