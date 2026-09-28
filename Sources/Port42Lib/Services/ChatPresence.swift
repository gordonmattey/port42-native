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

    /// As the API gives it (`presence.list`, the `presence` event): `{name, state, since}`, with `why`
    /// when it is waiting for the person and said why. `since` is seconds since 1970.
    /// What it is doing right now, from the CLI's tool events (Claude Code reports them; Codex does
    /// not yet). nil between tools.
    public var doing: Activity? = nil

    /// One tool call, said two ways (GM, 2026-09-28: "see what it's doing, files and stuff"). `detail`
    /// names the file or command and stays on this Mac; `summary` says only what sort of thing it is, and
    /// is all another machine is told (GM chose this: a file name or command can say too much).
    public struct Activity: Equatable {
        public let summary: String
        public let detail: String
    }

    public var bridgeValue: BridgeValue { bridgeValue(detail: true) }

    /// `detail: false` for anything that can leave this Mac: another machine's `presence.list`, and the
    /// `presence` event, which remote subscribers hear too.
    public func bridgeValue(detail: Bool) -> BridgeValue {
        var o: [String: BridgeValue] = ["name": .string(name), "since": .int(Int(since.timeIntervalSince1970))]
        if let doing { o["doing"] = .string(detail ? doing.detail : doing.summary) }
        switch state {
        case .received: o["state"] = .string("received")
        case .working: o["state"] = .string("working")
        case .waiting(let why):
            o["state"] = .string("waiting")
            if !why.isEmpty { o["why"] = .string(why) }
        }
        return .object(o)
    }
}

extension ChatPresence {
    /// Read back from the API's form, as another machine sends it. nil for anything malformed.
    public init?(wire: Any) {
        guard let o = wire as? [String: Any], let name = o["name"] as? String, !name.isEmpty,
              let state = o["state"] as? String else { return nil }
        switch state {
        case "received": self.state = .received
        case "working": self.state = .working
        case "waiting": self.state = .waiting(o["why"] as? String ?? "")
        default: return nil
        }
        self.name = name
        self.since = Date(timeIntervalSince1970: (o["since"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970)
        if let d = o["doing"] as? String, !d.isEmpty { self.doing = Activity(summary: d, detail: d) }
    }

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
    @Published public private(set) var byChat: [String: [ChatPresence]] = [:] {
        didSet {
            for chat in Set(oldValue.keys).union(byChat.keys) where oldValue[chat] != byChat[chat] { onChange?(chat) }
        }
    }
    /// A chat's presence changed: the app publishes it on that chat's port topic.
    var onChange: ((String) -> Void)?
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

    /// What the agent is doing now (a tool started), or nil (it finished). Wherever it is listed.
    public func doing(_ name: String, _ activity: ChatPresence.Activity?) {
        for (chat, list) in byChat {
            if let i = list.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
               list[i].doing != activity {
                var next = list
                next[i].doing = activity
                byChat[chat] = next
            }
        }
    }

    /// The turn ended (its reply landed) or the CLI stopped.
    public func done(_ name: String) { remove(name) }

    public func entries(_ chat: String) -> [ChatPresence] { (byChat[chat] ?? []) + (remoteByChat[chat] ?? []) }

    /// Presence on a tile of another machine's port, as that machine reports it (its `presence` event).
    /// Kept apart from this machine's own: the host's companions are not ours, so a local agent of the
    /// same name must neither move them nor be moved by them. Replaced whole, as the host sends it.
    @Published public private(set) var remoteByChat: [String: [ChatPresence]] = [:]

    public func setRemote(_ chat: String, _ list: [ChatPresence]) {
        if remoteByChat[chat] != (list.isEmpty ? nil : list) { remoteByChat[chat] = list.isEmpty ? nil : list }
    }

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
        case .working: return "is working" + (p.doing.map { ": \($0.detail)" } ?? "") + for_
        case .waiting(let why): return why.isEmpty ? "is waiting for you in its terminal" : "is waiting for you: \(why)"
        }
    }
}

// MARK: - Activity from a tool call

extension ChatPresence.Activity {
    /// Say what a tool call is doing, from Claude Code's tool name and input (the hook's `tool_input`,
    /// as JSON). The one place this is decided: a file by its name, never its path; a command by its
    /// first line, cut short; the rest by what they search or fetch.
    public static func from(tool: String, input: String) -> ChatPresence.Activity {
        let args = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any] ?? [:]
        func str(_ k: String) -> String? {
            (args[k] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        func short(_ s: String, _ n: Int = 48) -> String {
            let line = s.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? s
            return line.count > n ? String(line.prefix(n - 1)) + "…" : line
        }
        func file(_ k: String = "file_path") -> String? { str(k).map { ($0 as NSString).lastPathComponent } }
        switch tool {
        case "Read":
            return .init(summary: "reading a file", detail: file().map { "reading \($0)" } ?? "reading a file")
        case "Edit", "MultiEdit":
            return .init(summary: "editing a file", detail: file().map { "editing \($0)" } ?? "editing a file")
        case "Write":
            return .init(summary: "writing a file", detail: file().map { "writing \($0)" } ?? "writing a file")
        case "NotebookEdit":
            return .init(summary: "editing a notebook", detail: file("notebook_path").map { "editing \($0)" } ?? "editing a notebook")
        case "Bash":
            return .init(summary: "running a command", detail: str("command").map { "running \(short($0))" } ?? "running a command")
        case "Grep":
            return .init(summary: "searching", detail: str("pattern").map { "searching for \(short($0, 32))" } ?? "searching")
        case "Glob":
            return .init(summary: "finding files", detail: str("pattern").map { "finding \(short($0, 32))" } ?? "finding files")
        case "WebFetch":
            let host = str("url").flatMap { URL(string: $0)?.host }
            return .init(summary: "reading a web page", detail: host.map { "reading \($0)" } ?? "reading a web page")
        case "WebSearch":
            return .init(summary: "searching the web", detail: str("query").map { "searching the web for \(short($0, 32))" } ?? "searching the web")
        case "Task", "Agent":
            return .init(summary: "starting a helper", detail: str("description").map { "starting a helper: \(short($0, 32))" } ?? "starting a helper")
        case "TodoWrite":
            return .init(summary: "updating its plan", detail: "updating its plan")
        default:
            if tool.hasPrefix("mcp__") {
                let name = tool.split(separator: "_", omittingEmptySubsequences: true).last.map(String.init) ?? tool
                return .init(summary: "using a tool", detail: "using \(name)")
            }
            return .init(summary: "using a tool", detail: tool.isEmpty ? "using a tool" : "using \(tool)")
        }
    }
}
