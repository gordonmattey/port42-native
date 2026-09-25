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

    public init(seq: Int, at: Date, text: String, fromId: String, fromName: String, fromKind: String) {
        self.seq = seq
        self.at = at
        self.text = text
        self.fromId = fromId
        self.fromName = fromName
        self.fromKind = fromKind
    }

    public var bridgeValue: BridgeValue {
        .object([
            "seq": .int(seq),
            "at": .double(at.timeIntervalSince1970),
            "text": .string(text),
            "from": .object(["id": .string(fromId), "name": .string(fromName), "kind": .string(fromKind)]),
        ])
    }

    /// The stored form, without `seq`: the row's key carries it.
    func storedJSON() -> String {
        let o: [String: Any] = ["at": at.timeIntervalSince1970, "text": text,
                                "fromId": fromId, "fromName": fromName, "fromKind": fromKind]
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8)
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
    func postToChat(key: String, text: String, from p: Principal) throws -> PortChatEntry {
        let entry = try db.appendChatEntry(chat: key, text: text, at: Date(),
                                           fromId: p.id, fromName: p.displayName, fromKind: p.kind.rawValue)
        chats.received(key, entry)
        notifyBus.publish(topic: PortNotify.topic(forPortKey: key),
                          kind: PortEventKind.chat.wire, payload: entry.bridgeValue)
        return entry
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
        let k = try key(args)
        let text = try args.requireString("text")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeError.badArg("chat.post needs non-empty text")
        }
        guard text.count <= PortChat.maxTextLength else {
            throw BridgeError.badArg("chat.post text is longer than \(PortChat.maxTextLength) characters")
        }
        let entry = try appState.postToChat(key: k, text: text, from: p)
        return .object(["ok": .bool(true), "entry": entry.bridgeValue])
    }

    r["chat.read"] = BridgeMethod(permission: nil, paramNames: ["port", "after", "limit"],
        description: "Read a port's chat, oldest first. Pass `after` (a seq you have seen) to get only what is newer. Returns { entries, last }, where `last` is the newest seq in the chat (0 when empty).",
        inputSchema: [
            "type": "object",
            "properties": [
                "port": ["type": "string", "description": "Whose chat: `0` (the desktop), a space id, or a port id / udid / title."],
                "after": ["type": "integer", "description": "Only entries with a seq greater than this."],
                "limit": ["type": "integer", "description": "At most this many, the newest ones (default \(PortChat.defaultReadLimit), max \(PortChat.maxReadLimit))."],
            ],
            "required": ["port"],
        ]) { _, args in
        let k = try key(args)
        let limit = max(1, min(args.int("limit") ?? PortChat.defaultReadLimit, PortChat.maxReadLimit))
        let entries = try appState.db.chatEntries(chat: k, after: args.int("after") ?? 0, limit: limit)
        let last = try appState.db.lastChatSeq(chat: k)
        return .object(["entries": .array(entries.map(\.bridgeValue)), "last": .int(last)])
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

    public func isLoaded(_ key: String) -> Bool { entries[key] != nil }

    /// Load a chat's newest entries once. A chat already loaded is kept current by `received`.
    public func load(_ key: String, from db: DatabaseService) {
        guard entries[key] == nil else { return }
        entries[key] = (try? db.chatEntries(chat: key, after: 0, limit: Self.keep)) ?? []
    }

    /// A post landed. Appended only to a loaded chat; an unloaded one reads it from the store later.
    public func received(_ key: String, _ entry: PortChatEntry) {
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

    public func markRead(_ key: String) {
        guard let last = entries[key]?.last?.seq, last > (lastRead[key] ?? 0) else { return }
        lastRead[key] = last
        defaults?.set(lastRead, forKey: Self.defaultsKey)
    }

    /// Who is in a chat: everyone who has posted, the newest first, once each.
    public func participants(_ key: String) -> [(id: String, name: String)] {
        var seen = Set<String>(), out: [(id: String, name: String)] = []
        for e in (entries[key] ?? []).reversed() where seen.insert(e.fromId).inserted {
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
    }
}
