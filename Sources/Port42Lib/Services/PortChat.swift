import Foundation

// MARK: - Every port has a chat (nautilus Phase 1 step 5, docs/design-chat-port.md)
//
// A chat belongs to a PORT. A space is a port and the desktop is port 0, so one mechanism serves
// every scope: `chat.post` and `chat.read` take `port`, which is `0`, a space id, or a port's id,
// udid or title.
//
// The transcript lives in the storage table (D1, D3), in a scope no `storage.*` caller can name
// (`PortChat.storageScope`), one row per entry. So an entry is written only through `chat.post`,
// and its sender is always the calling principal. There is no sender-name argument: a post through
// the API speaks as its caller, never as the person (audit F16).
//
// Every post is published on the port's topic as a `chat` event carrying the entry, so a panel, a
// companion's router and a remote guest all learn of it from the same event.

/// One line of a port's chat.
public struct PortChatEntry: Equatable {
    public let seq: Int
    public let at: Date
    public let text: String
    public let fromId: String
    public let fromName: String
    public let fromKind: String
    /// The computer a shared chat shows beside a local author's name (`ChatRouting.labeled`), else nil.
    public let computer: String?

    public init(seq: Int, at: Date, text: String, fromId: String, fromName: String, fromKind: String,
                computer: String? = nil) {
        self.seq = seq
        self.at = at
        self.text = text
        self.fromId = fromId
        self.fromName = fromName
        self.fromKind = fromKind
        self.computer = computer
    }

    /// Who posted, apart: the bare name to match on and @mention, and the computer a shared chat shows beside it.
    /// `from.name` is what people read, `scribe (gordon's Port42)`; code matching on it broke when 1.0.8 began
    /// labeling shared chats (the board dropped its VERIFIED lines, 2026-10-05), so it reads `from.handle`.
    public var sender: (handle: String, computer: String?) {
        if let computer, fromName.hasSuffix(" (\(computer))") {
            return (String(fromName.dropLast(computer.count + 3)), computer)
        }
        // Another computer's author is stored as that chat showed them, with their computer.
        if fromId.contains("/") { let s = ChatRouting.splitLabel(fromName); return (s.name, s.label) }
        return (fromName, computer)
    }

    public var bridgeValue: BridgeValue {
        let (handle, computer) = sender
        var from: [String: BridgeValue] = ["id": .string(fromId), "name": .string(fromName), "kind": .string(fromKind),
                                           "handle": .string(handle)]
        if let computer { from["computer"] = .string(computer) }
        return .object([
            "seq": .int(seq),
            "at": .double(at.timeIntervalSince1970),
            "text": .string(text),
            "from": .object(from),
        ])
    }

    /// An entry as `chat.read` returns it and a `chat` event carries it (`bridgeValue`, as JSON).
    static func fromEvent(_ any: Any?) -> PortChatEntry? {
        guard let o = any as? [String: Any], let seq = o["seq"] as? Int, let text = o["text"] as? String else { return nil }
        let from = o["from"] as? [String: Any] ?? [:]
        return PortChatEntry(seq: seq, at: Date(timeIntervalSince1970: (o["at"] as? Double) ?? 0), text: text,
                             fromId: from["id"] as? String ?? "", fromName: from["name"] as? String ?? "",
                             fromKind: from["kind"] as? String ?? "", computer: from["computer"] as? String)
    }

    /// The stored form, without `seq`: the row's key carries it.
    func storedJSON() -> String {
        let o: [String: Any] = ["at": at.timeIntervalSince1970, "text": text,
                                "fromId": fromId, "fromName": fromName, "fromKind": fromKind]
        let data = (SafeJSON.data(o, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func fromStored(seq: Int, json: String) -> PortChatEntry? {
        guard let data = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = o["text"] as? String else { return nil }
        return PortChatEntry(seq: seq,
                             at: Date(timeIntervalSince1970: (o["at"] as? Double) ?? 0),
                             text: text,
                             fromId: o["fromId"] as? String ?? "",
                             fromName: o["fromName"] as? String ?? "",
                             fromKind: o["fromKind"] as? String ?? "")
    }
}

public enum PortChat {
    /// The storage scope transcripts live in. Not a space id and not `__global__`, so `storage.*`
    /// can neither read nor forge an entry.
    public static let storageScope = "__chat__"
    /// The desktop's chat: port 0, the same key grants use for the machine.
    public static let desktopKey = PortObject.machinePortKey
    /// Longest text one post may carry.
    public static let maxTextLength = 32_000
    /// Default and ceiling for `chat.read`.
    public static let defaultReadLimit = 50
    public static let maxReadLimit = 200

    /// A row key that sorts in seq order as text.
    static func rowKey(_ seq: Int) -> String { String(format: "%012d", seq) }
}

@MainActor
extension AppState {
    /// The chat key a `port` argument names: `0`, a space id, or a port resolved to its one key.
    /// nil when it names nothing that exists.
    func chatKey(for port: String) -> String? {
        if port == PortChat.desktopKey { return port }
        if (try? db.getAllSpaces())?.contains(where: { $0.id == port }) == true { return port }
        return resolvePortRef(port)?.key
    }

    /// Append to a port's chat as `from`, and publish it on the port's topic.
    @discardableResult
    /// `route: false` records and shows the post without waking anyone: a message the person typed
    /// straight into a terminal is already in front of its companion.
    func postToChat(key: String, text: String, from p: Principal, route: Bool = true) throws -> PortChatEntry {
        let who = Self.chatAuthor(p)
        let entry = try db.appendChatEntry(chat: key, text: text, at: Date(),
                                           fromId: who.id, fromName: who.name, fromKind: who.kind)
        chats.received(key, entry)
        noticeMention(key: key, entry: entry)
        notifyBus.publish(topic: PortNotify.topic(forPortKey: key),
                          kind: PortEventKind.chat.wire, payload: outward(entry, key: key).bridgeValue)
        // A caller on another machine wakes this machine's companions only when its invite says so:
        // a companion runs with this machine's terminal, and a wake spends this user's model.
        if route, p.kind != .remote {
            routeChat(key: key, entry: entry)
        } else if route, remoteRights(of: p.id, onPort: key).contains(.wakeAgents) {
            routeRemotePost(key: key, entry: entry, from: p)
        }
        if route { noteWrongMentions(key: key, entry: entry) }
        return entry
    }

    /// Companions on other instances a companion in `space` can @mention, each with the chat it was met
    /// in: in a port here that another instance holds rights on, those who posted from there; in a tile
    /// mirroring a port elsewhere, the companions who posted there that are not this instance's own.
    func companionsElsewhere(space: String) -> [(name: String, port: String)] {
        let shared = Set(((try? db.allRemoteRights()) ?? []).map(\.portKey))
        let mine = localPeerID.map { $0 + "/" }
        var out: [(name: String, port: String)] = [], seen = Set<String>()
        for panel in portWindows.panels where panel.spaceId == space {
            let entries: [PortChatEntry]
            if mirroredRemote(panel.id) != nil {
                entries = (chats.entries[panel.udid] ?? []).filter { e in !(mine.map { e.fromId.hasPrefix($0) } ?? false) }
            } else if shared.contains(panel.udid) {
                entries = ((try? db.chatEntries(chat: panel.udid, after: 0, limit: 200)) ?? []).filter { $0.fromId.contains("/") }
            } else { continue }
            for e in entries where e.fromKind == Principal.Kind.companion.rawValue && seen.insert(e.fromName).inserted {
                out.append((e.fromName, panel.udid))
            }
        }
        return out
    }

    /// Who a post is from. A caller on another instance is recorded as the actor its instance names
    /// (4.6c): `<peer>/<actor>`, labelled with that instance's person unless it is the person, and of
    /// the actor's kind, so routing treats a companion there as a companion here. A claim of `human`
    /// is never this instance's person: its id is the instance's, not `AppUser.id`.
    ///
    /// **EVERY remote author is suffixed, a person too** (NAU-04). The actor's name and kind are the
    /// other instance's claim; only its peer id is attested. A person there used to be shown by the
    /// bare name it gave, so a peer could post as "Alice", this instance's person, and read as her.
    /// The suffix is the peer's enrolled label, its machine's name (Phase 6), always: "(remote)" told
    /// nobody where someone was (Gordon, 2026-10-03). A local post is never suffixed with another machine's
    /// label, so a remote one can never render as a local one.
    static func chatAuthor(_ p: Principal) -> (id: String, name: String, kind: String) {
        guard p.kind == .remote, let a = p.actor else { return (p.id, p.displayName, p.kind.rawValue) }
        let kind: Principal.Kind = a.kind == .port ? .peer : a.kind
        return (p.id + "/" + a.id, "\(a.name) (\(p.displayName))", kind.rawValue)
    }

    /// A line from Port42 itself in a port's chat: a notice, not a message, so it wakes nobody.
    func postSystemChatLine(key: String, text: String) {
        guard let entry = try? db.appendChatEntry(chat: key, text: text, at: Date(), fromId: "port42",
                                                  fromName: "Port42", fromKind: "system") else { return }
        chats.received(key, entry)
        notifyBus.publish(topic: PortNotify.topic(forPortKey: key),
                          kind: PortEventKind.chat.wire, payload: entry.bridgeValue)
    }

    /// A post wakes the companions it addresses (build step 3). Mentions address a companion, and a
    /// terminal port's own companion is addressed by any post in that port's chat, since that chat
    /// is its session. The reply comes back to this chat (`chatReplyTargets`).
    /// `fromAnotherInstance`: the post came from another machine. Its mentions wake companions here, but
    /// never add one to a space (a space's members can act on every port in it).
    /// `allowed`: when set, only these companions (by id) are woken; a post from another instance wakes only
    /// the companions on the port (`routeRemotePost`).
    func routeChat(key: String, entry posted: PortChatEntry, fromAnotherInstance: Bool = false, allowed: Set<String>? = nil) {
        // In a shared chat, a mention of a companion here by its name as the other machine shows it is that companion.
        let entry = PortChatEntry(seq: posted.seq, at: posted.at, text: routingText(posted.text, key: key),
                                  fromId: posted.fromId, fromName: posted.fromName, fromKind: posted.fromKind)
        let panel = portWindows.panels.first { $0.udid == key || $0.id == key }
        let own = panel?.terminalConfig?.companionName
        let spaceId = panel?.spaceId ?? (spaces.contains { $0.id == key } ? key : currentSpace?.id)
        guard let spaceId else { return }
        // A post in a terminal port's own chat wakes its companion without a mention, unless the
        // post is ANOTHER companion's: companions must @mention each other, or two of them replying
        // into each other's chats would wake each other forever.
        // Port42's own notices ("x is waiting at a startup prompt", a watch paused, a budget spent)
        // count as a companion's post here: they reach only whom they @mention. They used to reach
        // every member of the chat as a client's plain post, so each notice in an imagine space woke
        // the whole team (Dev4, 2026-09-26).
        let senderIsCompanion = entry.fromKind == Principal.Kind.companion.rawValue
            || entry.fromId == ChatRouting.port42SenderId
            || companions.contains { $0.displayName.lowercased() == entry.fromName.lowercased() }
        let implicit = ChatRouting.wakesOwnCompanion(senderIsCompanion: senderIsCompanion) ? own.flatMap { name in
            companions.first { $0.displayName.lowercased() == name.lowercased() && $0.openInTerminal }
        } : nil
        // A mention adds that companion to the space, as it always has.
        var members = Set(((try? db.getAgentsForSpace(spaceId: spaceId)) ?? []).map(\.id))
        let mentioned = AgentRouter.findTargetAgents(content: entry.text, agents: companions,
                                                     spaceAgentIds: [], localOwner: currentUser?.displayName)
        // A mention in a space's chat adds that companion to the space, as it always has. In a port's chat it
        // gives the companion that port only (two agents, decision 1); from another instance, only if allowed.
        let isSpaceChat = spaces.contains { $0.id == key }
        if isSpaceChat {
            if !fromAnotherInstance, let space = spaces.first(where: { $0.id == spaceId }) {
                for agent in mentioned where !members.contains(agent.id) {
                    addCompanionToSpace(agent, space: space)
                    members.insert(agent.id)
                }
            }
        } else {
            for agent in mentioned where allowed?.contains(agent.id) ?? true { addPortMember(agent.id, port: key) }
        }
        // Everyone in this chat hears a person's or a client's plain post (never a companion's).
        let inChat = senderIsCompanion ? [] : ChatRouting.members(
            of: (try? db.chatEntries(chat: key, after: 0, limit: 200)) ?? [],
            companions: companions.filter(\.openInTerminal).map(\.displayName))
        routeMentionsToTerminals(content: entry.text, senderName: entry.fromName, spaceId: spaceId,
                                 implicitCompanion: implicit, replyChat: key,
                                 source: chatSourceLabel(key: key, panel: panel), members: inChat, allowed: allowed)
        // Headless companions: the ones mentioned, or every member when a PERSON posts without a
        // mention. A companion's post wakes only whom it names, so two companions cannot loop.
        let headless = ChatRouting.headlessTargets(
            mentioned: mentioned, members: companions.filter { members.contains($0.id) },
            text: entry.text, senderName: entry.fromName, senderIsPerson: entry.fromKind == Principal.Kind.human.rawValue)
            .filter { allowed?.contains($0.id) ?? true }
        guard !headless.isEmpty else { return }
        for agent in headless { typingAgentNamesBySpace[spaceId, default: []].insert(agent.displayName) }
        launchAgents(headless, spaceId: spaceId, spaceAgentIds: members, triggerContent: entry.text,
                     senderId: entry.fromId, senderName: entry.fromName, replyChat: key,
                     joinsSpace: isSpaceChat && !fromAnotherInstance)
    }
}

@MainActor
extension AppState {
    /// Where a post was made, as a companion reads it: the desktop, a space, or a port by title.
    func chatSourceLabel(key: String, panel: PortPanel?) -> String {
        if key == PortChat.desktopKey { return ChatRouting.sourceLabel(desktop: true) }
        if let space = spaces.first(where: { $0.id == key }) { return ChatRouting.sourceLabel(space: space.name) }
        return ChatRouting.sourceLabel(port: panel?.title ?? "port", portId: panel?.udid,
                                       ownTerminal: panel?.terminalConfig?.companionName.isEmpty == false)
    }
}

/// The routing decisions, pure so they are testable without a terminal.
public enum ChatRouting {
    /// The line a companion's terminal receives: who said it, where, and what. A companion reads
    /// which chat a message came from here, and its reply goes back to that chat.
    ///
    /// The sender is written as its mention (`CompanionName.mention`), so an agent that copies it to
    /// reply writes a mention that arrives: "app dev" is `[@app%20dev]`, not `[@app dev]`, which would
    /// be read as a mention of `app`.
    /// A line Port42 typed into a terminal (`terminalLine`): a chat message or a watch wake, already in
    /// a chat. Anything else a terminal submits, the person typed there.
    ///
    /// Recognised by `[…]: ` rather than `[@`: a TUI that rewrote the line on the way in (the `@`
    /// taken by a file picker, #253) still sent Port42's line, and mirroring it into a chat as the
    /// person's carried a message from one space into another.
    public static func isInjectedLine(_ prompt: String) -> Bool {
        let t = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("[") && t.contains("]: ")
    }

    /// A prompt the CLI submitted itself, not the person: Claude Code hands its session background-task
    /// notices, sub-agent reports and messages from other sessions as prompts, each wrapped in its tag.
    public static func isCLIOwnLine(_ prompt: String) -> Bool {
        let t = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("<") else { return false }
        return cliOwnTags.contains { t.hasPrefix("<" + $0) }
    }
    static let cliOwnTags = ["task-notification", "agent-message", "cross-session-message", "system-reminder",
                             "command-name", "command-message", "local-command-stdout", "user-prompt-submit-hook"]

    public static func terminalLine(sender: String, source: String?, text: String) -> String {
        let who = CompanionName.mention(terminalSafe(sender))
        let body = terminalSafe(text)
        guard let source, !source.isEmpty else { return "[\(who)]: \(body)\r" }
        return "[\(who) in \(terminalSafe(source))]: \(body)\r"
    }

    /// Text typed into a companion's terminal is only text: every control character goes (escape
    /// sequences, a carriage return that would submit early, a tab that would complete), and line
    /// breaks stay. The chat's text can come from another machine or a port's page, and a terminal reads
    /// control characters as keys.
    public static func terminalSafe(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0x0A: out.append(u)                                   // newline stays
            case 0x0D, 0x09: out.append(" ")                           // CR and tab become spaces
            case 0x00...0x1F, 0x7F, 0x80...0x9F: continue              // C0, DEL, C1
            default: out.append(u)
            }
        }
        return String(out)
    }

    /// A port's chat names the port's id as well as its title, so a companion can post there
    /// without searching `ports.list` for it (GM's multi-agent test, 2026-09-25).
    public static func sourceLabel(desktop: Bool = false, space: String? = nil,
                                   port: String? = nil, portId: String? = nil,
                                   ownTerminal: Bool = false) -> String {
        if desktop { return "the desktop chat" }
        if let space { return "#\(space)" }
        if ownTerminal { return "your terminal's chat" }
        let title = "the chat of port '\(port ?? "port")'"
        return portId.map { "\(title) (id \($0))" } ?? title
    }

    /// The @name being typed at the end of a draft ("" right after a bare @), or nil if none.
    public static func mentionQuery(in draft: String) -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at > draft.startIndex {
            let before = draft[draft.index(before: at)]
            guard before.isWhitespace else { return nil }       // an email, not a mention
        }
        let tail = draft[draft.index(after: at)...]
        guard tail.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "%" }) else { return nil }
        return String(tail)
    }

    /// A message as a person reads it: an escaped mention (`@app%20dev`) is shown as the name
    /// (`@app dev`). Display only; the stored text keeps the escape, which agents need to write it.
    public static func displayText(_ text: String) -> String {
        guard text.contains("%"), let re = try? NSRegularExpression(
            pattern: #"(?<![a-zA-Z0-9.%])@(?:[a-zA-Z]|%[0-9A-Fa-f]{2})(?:[a-zA-Z0-9-]|%[0-9A-Fa-f]{2})*"#) else { return text }
        var out = text
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let r = Range(m.range, in: out) else { continue }
            let token = String(out[r])
            if token.contains("%"), let decoded = token.removingPercentEncoding { out.replaceSubrange(r, with: decoded) }
        }
        return out
    }

    /// The draft with the @name being typed completed to `name`'s mention (escaped, see
    /// `CompanionName.mention`), followed by a space.
    // MARK: Mentioning anyone in a chat (GM, 2026-09-28)
    //
    // Autocomplete offered only this instance's own companions, so in a shared port's chat nobody could
    // mention the other person, or the other person's companions (named "Ovi (Justin)" there, a name no
    // one types with its escapes).

    /// Everyone who can be mentioned in a chat: this instance's companions, then everyone who has posted
    /// there (people, and another machine's companions), once each, newest first. Never Port42 itself or
    /// the person reading.
    public static func mentionable(companions: [String], people: [String] = [], entries: [PortChatEntry],
                                   me: String?, myName: String? = nil, peopleIds: Set<String> = [],
                                   ownPeer: String? = nil) -> [String] {
        // Never the person reading, by id or by name: you cannot @ yourself (GM, 2026-09-28).
        var seen = Set<String>(myName.map { [$0.lowercased()] } ?? [])
        var out: [String] = []
        func add(_ n: String) {
            let k = n.lowercased()
            guard !n.isEmpty, !seen.contains(k) else { return }
            seen.insert(k); out.append(n)
        }
        companions.forEach(add)
        people.forEach(add)
        // A person already listed in `people` posts under a longer label ("gordon (gordon 3xpo)" for
        // "gordon 3xpo"); their posts would list them twice. Their companions' posts still count.
        // On a tile, this computer's own people and agents post back as "juno (this computer)": they are already
        // listed by name, and were offered twice (Gordon, 2026-10-03). `ownPeer`: this computer's peer id.
        let mine = ownPeer.map { $0 + "/" }
        for e in entries.reversed() where e.fromId != port42SenderId && e.fromId != me
            && !(mine.map { e.fromId.hasPrefix($0) } ?? false)
            && !(e.fromKind == "human" && peopleIds.contains(peerOf(e.fromId))) { add(e.fromName) }
        return out
    }

    /// The machine a remote author's id names: a remote post is attributed "<peer key>/<actor id>", while
    /// the sharing list knows the machine by its peer key alone.
    static func peerOf(_ fromId: String) -> String {
        fromId.split(separator: "/", maxSplits: 1).first.map(String.init) ?? fromId
    }

    /// The names a half-typed mention could mean, by prefix.
    public static func mentionSuggestions(query: String, names: [String]) -> [String] {
        let q = (query.removingPercentEncoding ?? query).lowercased()
        return names.filter { $0.lowercased().hasPrefix(q) }
    }

    /// Whether `text` mentions `name`, however it was spelled (escaped or not, any case).
    public static func mentions(_ text: String, name: String) -> Bool {
        let want = name.lowercased()
        return MentionParser.extractMentions(from: text).contains {
            let n = String($0.dropFirst()).lowercased()
            return n == want || plainName(n) == want
        }
    }

    /// The mentions in `text` that match no one here, so the chat can say so rather than drop them.
    /// A name in a shared chat is `alba (Gordon's MacBook Pro)`: a mention of either form, or of the name with
    /// the wrong machine, is someone here.
    public static func unmatchedMentions(_ text: String, known: [String]) -> [String] {
        let names = Set(known.map { $0.lowercased() } + known.map { plainName($0).lowercased() } + ["all"])
        var out: [String] = []
        for m in MentionParser.extractMentions(from: text) {
            let n = String(m.dropFirst())
            if !names.contains(n.lowercased()), !names.contains(plainName(n).lowercased()), !out.contains(n) { out.append(n) }
        }
        return out
    }

    // MARK: Names in a shared chat (two agents, Phase 6)

    /// The agent a mention that matched nobody most likely meant: the same name with another machine after it,
    /// or a name a letter off (two for a name of six or more). nil when it is nobody's near miss: "sam" is two
    /// letters from "bram", and a person in the story, not a typo.
    public static func nearestAgent(_ mention: String, agents: [String]) -> String? {
        let want = plainName(mention).lowercased()
        var best: (name: String, d: Int)?
        for a in Set(agents.map(plainName)) {
            let d = editDistance(want, a.lowercased())
            if d <= (a.count >= 6 ? 2 : 1), a.count >= 3, best.map({ d < $0.d }) ?? true { best = (a, d) }
        }
        return best?.name
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty else { return y.count }
        guard !y.isEmpty else { return x.count }
        var row = Array(0...y.count)
        for i in 1...x.count {
            var prev = row[0]; row[0] = i
            for j in 1...y.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (x[i - 1] == y[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[y.count]
    }

    /// A name as a shared chat shows it, `alba (Gordon's MacBook Pro)`: the name, and the machine it is on.
    public static func splitLabel(_ s: String) -> (name: String, label: String?) {
        guard s.hasSuffix(")"), let open = s.range(of: " (", options: .backwards) else { return (s, nil) }
        let name = String(s[..<open.lowerBound])
        let label = String(s[open.upperBound..<s.index(before: s.endIndex)])
        return name.isEmpty || label.isEmpty ? (s, nil) : (name, label)
    }

    /// The name without its machine: what to @mention.
    public static func plainName(_ s: String) -> String { splitLabel(s).name }

    /// An entry as a chat shared with another machine shows it: a local author with this machine's name beside
    /// theirs, as the other machine's are beside theirs. Another machine's author, Port42's notices, and every
    /// entry of a chat that is not shared (`label` nil) are unchanged.
    public static func labeled(_ e: PortChatEntry, local label: String?) -> PortChatEntry {
        guard let label, !e.fromName.isEmpty, !e.fromId.contains("/"), e.fromId != port42SenderId,
              e.fromKind != "system" else { return e }
        return PortChatEntry(seq: e.seq, at: e.at, text: e.text, fromId: e.fromId,
                             fromName: "\(e.fromName) (\(label))", fromKind: e.fromKind, computer: label)
    }

    /// A post in a shared chat, as routing on this machine reads it: `@alba` with a machine after it (escaped,
    /// `@alba%20%28gordon11%29`) is this machine's alba, unless an author from the other machine is called
    /// exactly that. An agent cannot know how the other side labels a name, so it guesses, and a wrong guess used
    /// to reach nobody (bram wrote alba's name with his own machine, 2026-10-02). `local`: this machine's
    /// companions; `remote`: the other machine's authors in this chat, as shown.
    public static func localizedMentions(_ text: String, local: [String], remote: [String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: MentionParser.pattern) else { return text }
        let mine = Set(local.map { $0.lowercased() })
        let theirs = Set(remote.map { $0.lowercased() })
        var out = text
        for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let r = Range(m.range, in: out) else { continue }
            let raw = String(out[r].dropFirst())
            let decoded = raw.removingPercentEncoding ?? raw
            let (name, label) = splitLabel(decoded)
            guard label != nil, mine.contains(name.lowercased()), !theirs.contains(decoded.lowercased()) else { continue }
            out.replaceSubrange(r, with: CompanionName.mention(name))
        }
        return out
    }

    public static func complete(_ draft: String, with name: String) -> String {
        guard mentionQuery(in: draft) != nil, let at = draft.lastIndex(of: "@") else { return draft }
        // By the plain name: `bram`, not `bram (Sam's laptop)`, which a shared chat routes to the same agent.
        return String(draft[..<at]) + CompanionName.mention(plainName(name)) + " "
    }

    /// The companions a post addresses, lowercased, once each, in order: its mentions, then the
    /// port's own companion. Never the sender, so a companion cannot wake itself.
    public static func targets(text: String, senderName: String, portCompanion: String?,
                               members: [String] = []) -> [String] {
        var keys = MentionParser.extractMentions(from: text).map { String($0.dropFirst()).lowercased() }
        if let own = portCompanion?.lowercased(), !own.isEmpty { keys.append(own) }
        // A plain post (no mention) reaches everyone in the chat. The caller passes `members` only
        // for a post that may wake them: a person's or a client's, never a companion's.
        if MentionParser.extractMentions(from: text).isEmpty { keys += members.map { $0.lowercased() } }
        var seen = Set<String>()
        return keys.filter { $0 != senderName.lowercased() && seen.insert($0).inserted }
    }

    /// The headless (non-terminal) companions a post wakes: those it mentions; with no mention,
    /// every member, but only when a person posted. Never the sender.
    /// The id Port42 posts its own notices under.
    public static let port42SenderId = "port42"

    public static func headlessTargets(mentioned: [AgentConfig], members: [AgentConfig], text: String,
                                       senderName: String, senderIsPerson: Bool) -> [AgentConfig] {
        let hasMention = !MentionParser.extractMentions(from: text).isEmpty
        let pool = hasMention ? mentioned : (senderIsPerson ? members : [])
        return pool.filter { !$0.openInTerminal && $0.displayName.lowercased() != senderName.lowercased() }
    }

    /// Who is in a chat: the companions @mentioned in it or who have posted in it, in order of first
    /// appearance, restricted to `companions` (the ones that exist). GM, 2026-09-25: once you
    /// @mention someone in a chat, they are in it, so you can talk to all of them without naming each.
    public static func members(of entries: [PortChatEntry], companions: [String]) -> [String] {
        let known = Dictionary(uniqueKeysWithValues: companions.map { ($0.lowercased(), $0) })
        var seen = Set<String>(), out: [String] = []
        func add(_ name: String) {
            let k = name.lowercased()
            if let real = known[k], seen.insert(k).inserted { out.append(real) }
        }
        for e in entries {
            add(e.fromName)
            for m in MentionParser.extractMentions(from: e.text) { add(String(m.dropFirst())) }
        }
        return out
    }

    /// Where a terminal companion's reply is posted: the chat that asked it, else its terminal's own
    /// chat. Never dropped.
    public static func replyDestination(asked: String?, ownTerminalChat: String) -> String {
        asked ?? ownTerminalChat
    }

    /// Whether a post in a terminal port's own chat wakes that terminal's companion without a
    /// mention: yes for a person or an outside client, no for another companion.
    public static func wakesOwnCompanion(senderIsCompanion: Bool) -> Bool { !senderIsCompanion }

    /// Record where a routed companion's next reply goes. A port chat names itself; the old space
    /// chat names nothing, and clears any port chat an earlier mention left, so the latest ask wins.
    public static func recordReply(_ targets: inout [String: String], companion: String, chat: String?) {
        if let chat { targets[companion] = chat } else { targets.removeValue(forKey: companion) }
    }
}

@MainActor
func registerChatMethods(into r: inout BridgeRegistry, appState: AppState) {
    func key(_ args: BridgeArgs) throws -> String {
        let port = try args.requireString("port")
        guard let key = appState.chatKey(for: port) else {
            throw BridgeError.notFound("port '\(port)' (a chat belongs to port 0, a space, or a port)")
        }
        return key
    }

    r["chat.post"] = BridgeMethod(permission: nil, paramNames: ["port", "text"],
        description: "Post to a port's chat. Every port has one: pass port 0 for the desktop, a space id, or a port's id. The entry is attributed to you, the caller, and every subscriber of the port gets a `chat` event carrying it.",
        inputSchema: [
            "type": "object",
            "properties": [
                "port": ["type": "string", "description": "Whose chat: `0` (the desktop), a space id, or a port id / udid / title."],
                "text": ["type": "string", "description": "What to say."],
            ],
            "required": ["port", "text"],
        ]) { p, args in
        // APP-08: a post wakes the companions it reaches, and they act with this machine's grants,
        // so a caller posts only into a chat it may read: the same rule as chat.read (APP-09).
        let k = try appState.requireReadableChat(try args.requireString("port"), by: p)
        let text = try args.requireString("text")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeError.badArg("chat.post needs non-empty text")
        }
        guard text.count <= PortChat.maxTextLength else {
            throw BridgeError.badArg("chat.post text is longer than \(PortChat.maxTextLength) characters")
        }
        // A companion posting through its terminal's credential is the companion, not the terminal's
        // client: one sender, so its own posts and its replies group and color as one (GM, 2026-09-27:
        // echo's three posts read as a different sender from its reply).
        let from = appState.companion(actingAs: p).map {
            Principal.companion(id: $0.id, displayName: $0.displayName, spaceId: p.spaceId)
        } ?? p
        // #238: a port posting into another space's port wakes its companions only with wake_agents.
        let entry = try appState.postToChat(key: k, text: text, from: from,
                                            route: appState.crossSpaceWakes(p, chat: k))
        return .object(["ok": .bool(true), "entry": appState.outward(entry, key: k).bridgeValue])
    }

    r["whoami"] = BridgeMethod(permission: nil,
        description: "Who you are to Port42: your name, your space and who is in it (the companions you can @mention), and, for a companion running in a Port42 terminal, that terminal's port id and chat. `spaces` lists every space you are a member of, [{id, name}]: you can read their chats and ports, and post there. `elsewhere` lists companions on other computers met in the chat of a port shared with them, each with its mention and that port's chat: mention them there. Call it first.",
        inputSchema: ["type": "object", "properties": [String: Any]()]) { p, _ in
        var o: [String: BridgeValue] = ["name": .string(p.displayName), "kind": .string(p.kind.rawValue)]
        var spaceId = p.spaceId
        if let panelId = appState.terminalPanelId(for: p),
           let panel = appState.portWindows.panels.first(where: { $0.id == panelId }) {
            if let name = panel.terminalConfig?.companionName, !name.isEmpty { o["name"] = .string(name) }
            o["terminal_port"] = .string(panel.udid)
            o["chat"] = .string(panel.udid)
            spaceId = panel.spaceId ?? spaceId
        }
        if let sid = spaceId, let space = appState.spaces.first(where: { $0.id == sid }) {
            o["space_id"] = .string(sid)
            o["space_name"] = .string(space.name)
            let me = o["name"]
            let others = appState.companions(forSpace: sid).map(\.displayName).filter { BridgeValue.string($0) != me }
            o["companions"] = .array(others.map { .string($0) })
            // How to @mention each, in the same order: a space or other character is escaped
            // (`app dev` is `@app%20dev`).
            o["mentions"] = .array(others.map { .string(CompanionName.mention($0)) })
            // Companions on other instances, met in the chat of a port shared into or out of this
            // space (4.6c): a mention of one in that port's chat reaches it there.
            let elsewhere = appState.companionsElsewhere(space: sid)
            if !elsewhere.isEmpty {
                o["elsewhere"] = .array(elsewhere.map { e in
                    .object(["name": .string(e.name), "mention": .string(CompanionName.mention(ChatRouting.plainName(e.name))),
                             "port": .string(e.port)])
                })
            }
        }
        // Every space this companion is a member of, and so can read (GM, 2026-09-29): a lead finds
        // the team it coordinates without guessing ids.
        if let c = appState.companion(actingAs: p) {
            o["spaces"] = .array(appState.memberSpaces(of: c.id).map { .object(["id": .string($0.id), "name": .string($0.name)]) })
        }
        return .object(o)
    }

    r["chat.read"] = BridgeMethod(permission: nil, paramNames: ["port", "after", "limit"],
        description: "Read a port's chat, oldest first. Pass `after` (a seq you have seen) to get only what is newer. Returns { entries, last, agents? }. Each entry's `from` is {id, name, kind, handle, computer?}: `name` as people read it, which on a port shared with another computer carries the author's computer, `scribe (gordon's Port42)`; `handle` is the bare name, to match on and @mention; `computer` is set when the chat shows one. `last` is the newest seq in the chat (0 when empty), and `agents`, on a port shared with another computer, names this computer's agents on it as the chat shows them, whether or not they have posted.",
        inputSchema: [
            "type": "object",
            "properties": [
                "port": ["type": "string", "description": "Whose chat: `0` (the desktop), a space id, or a port id / udid / title."],
                "after": ["type": "integer", "description": "Only entries with a seq greater than this."],
                "limit": ["type": "integer", "description": "At most this many, the newest ones (default \(PortChat.defaultReadLimit), max \(PortChat.maxReadLimit))."],
            ],
            "required": ["port"],
        ]) { p, args in
        // APP-09: only a chat in the caller's own space (the APP-10 rule), not any chat by id.
        let k = try appState.requireReadableChat(try args.requireString("port"), by: p)
        let limit = max(1, min(args.int("limit") ?? PortChat.defaultReadLimit, PortChat.maxReadLimit))
        let began = Date()
        let entries = try appState.db.chatEntries(chat: k, after: args.int("after") ?? 0, limit: limit)
        let last = try appState.db.lastChatSeq(chat: k)
        if Date().timeIntervalSince(began) > 0.5 {
            p42log("[db] chat.read read %.1fs (%d entries)", Date().timeIntervalSince(began), entries.count)
        }
        // The label once per read, not per entry: each lookup reads the clients table (300 reads a call, on main).
        let label = appState.sharedSelfLabel(k)
        var out: [String: BridgeValue] = ["entries": .array(entries.map { ChatRouting.labeled($0, local: label).bridgeValue }), "last": .int(last)]
        if let agents = appState.sharedAgents(k) { out["agents"] = .array(agents.map { .string($0) }) }
        return .object(out)
    }

    r["presence.list"] = BridgeMethod(permission: nil, paramNames: ["port"],
        description: "Who is on a chat's messages right now: each companion that has a message from this chat (`received`), is working on it (`working`), or is waiting for the person (`waiting`, with `why` when it said). `doing` says what it is doing right now (\"editing ShellView.swift\", \"running swift test\") when its CLI reports tools (Claude Code does); a caller on another computer is told only the kind (\"editing a file\"). Returns { presence: [{name, handle, computer?, state, since, why?, doing?}] }, `handle` the bare name and `name` as the chat shows it, empty when nobody is. Subscribe to the port for the `presence` event to hear each change; the event carries only the kind of what each is doing.",
        inputSchema: [
            "type": "object",
            "properties": [
                "port": ["type": "string", "description": "Whose chat: a space id, or a port id / udid / title."],
            ],
            "required": ["port"],
        ]) { p, args in
        let k = try key(args)
        // What it is doing names files and commands on this Mac; another machine hears only the kind.
        let detail = p.kind != .remote
        let label = appState.sharedSelfLabel(k)
        return .object(["presence": .array(appState.presence.entries(k).map { $0.bridgeValue(detail: detail, label: label) })])
    }
}

// MARK: - What the shell shows of a chat
//
// The panel, the companion bar and its unread count read this. It is fed by `postToChat`, the one
// place an entry is written, so every surface sees a post the moment it lands, whoever posted it.

@MainActor
public final class PortChatStore: ObservableObject {
    /// The newest entries of each chat the shell has opened or drawn a bar for.
    @Published public private(set) var entries: [String: [PortChatEntry]] = [:]
    /// The last seq the person has seen, per chat. Kept across launches.
    @Published public private(set) var lastRead: [String: Int]

    public static let keep = 200
    static let defaultsKey = "port42ChatLastRead"
    private let defaults: UserDefaults?

    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        lastRead = (defaults?.dictionary(forKey: Self.defaultsKey) as? [String: Int]) ?? [:]
    }

    /// What the person has typed and not sent, per chat (#221). The panel's own state went with it
    /// when the chat was closed, its port or space left, or the tile swapped for its focus view, so a
    /// half-written message was lost. Held here, it comes back when the chat does. Not published: the
    /// panel types into its own state and keeps this current, so a keystroke redraws nothing else.
    private var drafts: [String: String] = [:]

    /// The unsent text of a chat, or "".
    public func draft(_ key: String) -> String { drafts[key] ?? "" }

    /// Keep a chat's unsent text; empty text drops it.
    public func keepDraft(_ text: String, for key: String) {
        drafts[key] = text.isEmpty ? nil : text
    }

    /// Load a chat's newest entries once. A chat already loaded is kept current by `received`.
    public func load(_ key: String, from db: DatabaseService) {
        guard entries[key] == nil else { return }
        entries[key] = (try? db.chatEntries(chat: key, after: 0, limit: Self.keep)) ?? []
    }

    /// A chat kept elsewhere (a tile's, on the instance that holds its port), as that instance has it.
    public func replace(_ key: String, _ list: [PortChatEntry]) {
        entries[key] = Array(list.suffix(Self.keep))
    }

    /// A post landed. Appended only to a loaded chat; an unloaded one reads it from the store later.
    public func received(_ key: String, _ entry: PortChatEntry) {
        unreadCounts[key]?.at = .distantPast               // a new post: the next card asks again
        guard var list = entries[key] else { return }
        guard !list.contains(where: { $0.seq == entry.seq }) else { return }
        list.append(entry)
        if list.count > Self.keep { list.removeFirst(list.count - Self.keep) }
        entries[key] = list
    }

    /// Entries the person has not seen: newer than their last read, and not their own.
    public func unread(_ key: String, me: String?) -> Int {
        let seen = lastRead[key] ?? 0
        return (entries[key] ?? []).filter { $0.seq > seen && $0.fromId != me }.count
    }

    /// Unread in a chat that may not be loaded: a card shows it while the chat bar, which loads it, is
    /// hidden. A view asks this while it draws, so it never reads the database here: it answers the last
    /// count and refreshes it in the background when it is stale. Reading on the main thread froze the
    /// app on a busy disk, one card at a time, every five seconds (daily driver, 2026-09-29).
    public func unread(_ key: String, me: String?, db: DatabaseService, now: Date = Date()) -> Int {
        if entries[key] != nil { return unread(key, me: me) }
        let seen = lastRead[key] ?? 0
        let cached = unreadCounts[key]
        if cached == nil || cached?.seen != seen || now.timeIntervalSince(cached?.at ?? .distantPast) > Self.unreadRefresh {
            refreshUnread(key, me: me, seen: seen, db: db)
        }
        return cached?.count ?? 0
    }

    /// How old a background unread count may get before a card asks for a fresh one.
    public static let unreadRefresh: TimeInterval = 15
    private var unreadCounts: [String: (count: Int, seen: Int, at: Date)] = [:]
    private var unreadReading: Set<String> = []
    /// The refresh in flight, per chat. Kept so a test can await it instead of sleeping.
    private(set) var unreadTasks: [String: Task<Void, Never>] = [:]

    private func refreshUnread(_ key: String, me: String?, seen: Int, db: DatabaseService) {
        guard !unreadReading.contains(key) else { return }
        unreadReading.insert(key)
        unreadTasks[key] = Task.detached(priority: .utility) { [weak self] in
            let list = (try? db.chatEntries(chat: key, after: seen, limit: PortChatStore.keep)) ?? []
            let n = list.filter { $0.seq > seen && $0.fromId != me }.count
            await MainActor.run {
                self?.unreadCounts[key] = (n, seen, Date())
                self?.unreadReading.remove(key)
            }
        }
    }

    public func markRead(_ key: String) {
        guard let last = entries[key]?.last?.seq, last > (lastRead[key] ?? 0) else { return }
        lastRead[key] = last
        defaults?.set(lastRead, forKey: Self.defaultsKey)
    }

    /// Who is in a chat: everyone who has posted, the newest first, once each.
    public func participants(_ key: String) -> [(id: String, name: String)] {
        var seen = Set<String>(), out: [(id: String, name: String)] = []
        // Port42's own notices are not a participant.
        for e in (entries[key] ?? []).reversed() where e.fromId != ChatRouting.port42SenderId && seen.insert(e.fromId).inserted {
            out.append((e.fromId, e.fromName))
        }
        return out
    }
}

@MainActor
extension AppState {
    /// The person posting from a chat panel. Through the registry like every other caller.
    func postToChatAsPerson(key: String, text: String) async throws {
        guard let user = currentUser else { throw BridgeError.badArg("no signed-in person to post as") }
        _ = try await runBridgeMethod("chat.post",
                                      principal: .human(id: user.id, displayName: user.displayName,
                                                        spaceId: currentSpace?.id),
                                      args: BridgeArgs(["port": key, "text": text]))
        // In a tile of someone else's port, the person's own companions answer to their plain names
        // (GM's brother, 2026-09-28: "@Ovi" there reached no one). Only the person's own post does this.
        // Waking this machine's own companions in a tile's chat happens for every local post, in forwardRemote.
    }

    /// The people in a shared port's chat, whether or not they have posted yet: in a tile of someone
    /// else's port, its host; on a port this instance shares, everyone it is shared with. Autocomplete
    /// offered only names that had posted, so a guest could not @ a host who had not spoken (Dev6,
    /// 2026-09-28).
    /// The peers of the people in `chatPeople`, so their own posts are not listed a second time.
    func chatPeopleIds(key: String) -> Set<String> {
        Set((sharing[key]?.people ?? []).map(\.peer))
    }

    func chatPeople(key: String) -> [String] {
        if let tile = portWindows.panels.first(where: { $0.udid == key })?.id, let row = mirroredRemote(tile) {
            return (mirrorAgents[key] ?? []) + [row.hostName]
        }
        return (sharing[key]?.people ?? []).map(\.name)
    }

    /// Someone mentioned the person reading: say so, even when Port42 is not in front (GM, 2026-09-28:
    /// in a shared port's chat nobody could get the other person's attention by name). By their own name,
    /// or, in a tile of someone else's port, by the label that port knows them as.
    func noticeMention(key: String, entry: PortChatEntry) {
        guard let user = currentUser, entry.fromId != user.id, entry.fromId != ChatRouting.port42SenderId else { return }
        var names = [user.displayName]
        if let tile = portWindows.panels.first(where: { $0.udid == key })?.id, let label = mirroredRemote(tile)?.knownAs {
            names.append(label)
        }
        guard names.contains(where: { ChatRouting.mentions(entry.text, name: $0) }) else { return }
        let title = portWindows.panels.first { $0.udid == key || $0.id == key }?.title ?? "a chat"
        lastMentionNotice = (key, entry.fromName)
        guard !AppState.isTestProcess else { return }
        let body = entry.text.count > 160 ? String(entry.text.prefix(159)) + "…" : entry.text
        Task { _ = await mentionNotifier.send(title: "\(entry.fromName) mentioned you in \(title)", body: body, opts: nil) }
    }
}
