import Foundation

// MARK: - Companions watch ports (nautilus Phase 3.3)
//
// Until now a companion woke only when someone @mentioned it. A watch makes an event on a port wake
// it: "fix this port when its console throws", "review every edit", "tell me when the scraper finds
// something". Its answer goes to that port's chat, through the reply routing that posts every turn.
//
// Three rules, from GM's decisions (docs/plan-nautilus-phase3.md):
// - The watch names the event kinds it wakes on; the default is the port's own published events.
// - One turn at a time. Events that arrive during a turn are held and delivered together when it
//   ends, and the first event after a quiet spell waits one second so a burst is one turn.
// - No default floor between wakes (a watch may set its own), and a ceiling against runaway: past
//   `ceilingPerHour` wakes in an hour the watch pauses and says so in the port's chat.

/// One companion watching one port.
public struct CompanionWatch: Codable, Equatable, Identifiable {
    public var id: String { "\(companionId)|\(portUdid)" }
    public let companionId: String
    public let portUdid: String
    /// What wakes it (see `WatchKinds`).
    public var kinds: [String]
    /// The least time between two wakes, in seconds. Nil: none.
    public var every: Int?
    public var paused: Bool
    public var createdAt: Date
}

/// Which events a watch wakes on.
public enum WatchKinds {
    /// The port's own published events (`port.publish`), which arrive namespaced as `port.<kind>`.
    public static let defaultKinds = ["port"]
    /// Never a trigger: they fire on every keystroke or frame, and each wake is a full model turn.
    public static let never: Set<String> = [PortEventKind.terminalOutput.wire, PortEventKind.screenFrame.wire,
                                            PortEventKind.cameraFrame.wire]

    /// Does an event of `kind` wake a watch on `watched`? "port" matches every `port.*` event; any
    /// other name matches that kind exactly (`console`, `state`, `chat`, or one port event such as
    /// `port.alert`).
    public static func matches(kind: String, watched: [String]) -> Bool {
        guard !never.contains(kind) else { return false }
        return watched.contains { w in w == kind || (w == "port" && kind.hasPrefix("port.")) }
    }

    /// A requested kind list, checked: every name is a kind or "port", and none is a never-trigger.
    public static func validate(_ kinds: [String]) throws -> [String] {
        let bad = kinds.filter { never.contains($0) }
        if !bad.isEmpty {
            throw BridgeError.badArg("\(bad.joined(separator: ", ")) cannot wake a companion: it fires on every "
                                     + "keystroke or frame, and each wake is a full model turn")
        }
        return kinds.isEmpty ? defaultKinds : kinds
    }
}

// MARK: - The wake queue (pure)

/// Turns a stream of events for one companion into turns: one at a time, a burst as one, each
/// watch's floor and ceiling applied. Pure: the service feeds it events and turn boundaries and does
/// what it answers, so every rule is tested without an app, a timer or a model.
public struct WakeQueue: Equatable {
    public struct Event: Equatable {
        public let watchId: String
        public let kind: String
        public let payload: String
        public let at: Date
        public init(watchId: String, kind: String, payload: String, at: Date) {
            self.watchId = watchId; self.kind = kind; self.payload = payload; self.at = at
        }
    }

    public enum Action: Equatable {
        /// Call `tick` at this time.
        case wakeAt(Date)
        /// Start one turn carrying these events.
        case deliver([Event])
        /// This watch hit its ceiling and is paused.
        case paused(watchId: String)
    }

    /// How long the first event after a quiet spell waits, so a burst arriving together is one turn.
    public var gather: TimeInterval = 1
    /// Wakes per watch per hour before it pauses.
    public var ceilingPerHour: Int = 60
    /// A turn that never reports its end (a closed terminal) stops counting as running after this.
    public var turnTimeout: TimeInterval = 15 * 60

    public private(set) var busySince: Date?
    public private(set) var pending: [Event] = []
    public private(set) var paused: Set<String> = []
    private var dueAt: Date?
    private var wakes: [String: [Date]] = [:]
    /// Each watch's floor (`every`), seconds.
    public var floors: [String: TimeInterval] = [:]

    public init() {}

    public var isBusy: Bool { busySince != nil }

    /// An event arrived. Held while a turn runs; otherwise it starts the gather.
    public mutating func receive(_ e: Event) -> [Action] {
        guard !paused.contains(e.watchId) else { return [] }
        pending.append(e)
        if let since = busySince {
            // Held for the turn's end. If that never comes (its terminal closed), the turn times out
            // and these go then, rather than waiting for an end that is not coming.
            guard dueAt == nil else { return [] }
            let due = since.addingTimeInterval(turnTimeout)
            dueAt = due
            return [.wakeAt(due)]
        }
        if dueAt == nil {
            let due = e.at.addingTimeInterval(gather)
            dueAt = due
            return [.wakeAt(due)]
        }
        return []
    }

    /// Time passed: deliver what is due, applying each watch's floor and ceiling.
    public mutating func tick(now: Date) -> [Action] {
        if let since = busySince, now.timeIntervalSince(since) >= turnTimeout { busySince = nil }
        guard !isBusy, let due = dueAt, now >= due, !pending.isEmpty else { return [] }
        dueAt = nil
        var actions: [Action] = []
        var ready: [Event] = []
        var held: [Event] = []
        var nextDue: Date?
        var order: [String] = []
        for e in pending where !order.contains(e.watchId) { order.append(e.watchId) }
        for w in order {
            let events = pending.filter { $0.watchId == w }
            var recent = (wakes[w] ?? []).filter { now.timeIntervalSince($0) < 3600 }
            wakes[w] = recent
            if paused.contains(w) { continue }
            if let floor = floors[w], let last = recent.last, now < last.addingTimeInterval(floor) {
                held += events
                let at = last.addingTimeInterval(floor)
                nextDue = min(nextDue ?? at, at)
            } else if recent.count >= ceilingPerHour {
                paused.insert(w)
                actions.append(.paused(watchId: w))
            } else {
                ready += events
                recent.append(now)
                wakes[w] = recent
            }
        }
        pending = held
        if let nextDue { dueAt = nextDue; actions.append(.wakeAt(nextDue)) }
        if !ready.isEmpty {
            busySince = now
            actions.insert(.deliver(ready), at: 0)
        }
        return actions
    }

    /// A turn began that the queue did not start (a chat mention): hold events until it ends.
    public mutating func turnStarted(now: Date) { busySince = now }

    /// The turn ended: what arrived during it goes now, as one.
    public mutating func turnEnded(now: Date) -> [Action] {
        busySince = nil
        guard !pending.isEmpty else { return [] }
        dueAt = min(dueAt ?? now, now)
        return tick(now: now)
    }

    /// Resume a paused watch, with a fresh hour.
    public mutating func resume(_ watchId: String) {
        paused.remove(watchId)
        wakes[watchId] = []
    }

    /// Forget a watch entirely.
    public mutating func remove(_ watchId: String) {
        paused.remove(watchId)
        wakes[watchId] = nil
        floors[watchId] = nil
        pending.removeAll { $0.watchId == watchId }
    }
}

// MARK: - The service

/// Keeps every watch subscribed to its port and each companion's wake queue fed.
@MainActor
public final class CompanionWatchService {
    weak var appState: AppState?
    private(set) var watches: [CompanionWatch] = []
    private var queues: [String: WakeQueue] = [:]            // companion id
    /// Events that reached a watch of a kind it watches, kept or dropped (tests wait on it rather than
    /// on a guessed delay for the bus to deliver).
    private(set) var receivedCount = 0
    private var subscriptions: [String: (topic: String, id: Int)] = [:]   // watch id
    private var timers: [String: DispatchWorkItem] = [:]     // companion id
    var ceilingPerHour = 60
    var now: () -> Date = Date.init

    /// Start a companion's turn with a message; its reply goes to the port's chat. Replaceable in
    /// tests; the default types it into the companion's terminal (or launches a headless one).
    var deliver: (_ companion: AgentConfig, _ message: String, _ portUdid: String) -> Void = { _, _, _ in }
    /// Say in the port's chat that a watch paused at its ceiling.
    var pauseNotice: (_ watch: CompanionWatch, _ companion: AgentConfig) -> Void = { _, _ in }

    init(appState: AppState) { self.appState = appState }

    /// Load every stored watch and subscribe it. Called once ports are restored.
    func start() {
        guard let db = appState?.db else { return }
        watches = (try? db.companionWatches()) ?? []
        for w in watches { subscribe(w) }
    }

    @discardableResult
    func watch(companion: AgentConfig, portUdid: String, kinds: [String], every: Int?) throws -> CompanionWatch {
        let kinds = try WatchKinds.validate(kinds)
        var w = CompanionWatch(companionId: companion.id, portUdid: portUdid, kinds: kinds, every: every,
                               paused: false, createdAt: now())
        if let existing = watches.first(where: { $0.id == w.id }) { w.createdAt = existing.createdAt }
        try appState?.db.saveCompanionWatch(w)
        watches.removeAll { $0.id == w.id }
        watches.append(w)
        queues[companion.id, default: WakeQueue()].resume(w.id)   // watching again resumes a paused watch
        subscribe(w)
        return w
    }

    @discardableResult
    func unwatch(companionId: String, portUdid: String) throws -> Bool {
        let id = "\(companionId)|\(portUdid)"
        guard watches.contains(where: { $0.id == id }) else { return false }
        try appState?.db.deleteCompanionWatch(companionId: companionId, portUdid: portUdid)
        watches.removeAll { $0.id == id }
        unsubscribe(id)
        queues[companionId]?.remove(id)
        return true
    }

    /// The port is gone for good, or the companion is: its watches go with it.
    func removeAll(portUdid: String? = nil, companionId: String? = nil) {
        for w in watches where (portUdid.map { $0 == w.portUdid } ?? false) || (companionId.map { $0 == w.companionId } ?? false) {
            try? unwatch(companionId: w.companionId, portUdid: w.portUdid)
        }
    }

    /// A turn began for this companion from somewhere else (a chat mention).
    func turnStarted(companionName: String) {
        guard let c = companion(named: companionName) else { return }
        queues[c.id, default: WakeQueue()].turnStarted(now: now())
    }

    /// The companion finished a turn: what its watches held goes now.
    func turnEnded(companionName: String) {
        guard let c = companion(named: companionName), var q = queues[c.id] else { return }
        let actions = q.turnEnded(now: now())
        queues[c.id] = q
        perform(actions, for: c)
    }

    // MARK: internals

    private func companion(named name: String) -> AgentConfig? {
        appState?.companions.first { $0.displayName.lowercased() == name.lowercased() }
    }

    private func subscribe(_ w: CompanionWatch) {
        unsubscribe(w.id)
        guard let app = appState else { return }
        let topic = PortNotify.topic(forPortKey: app.resolvePortRef(w.portUdid)?.key ?? w.portUdid)
        let id = app.notifyBus.subscribe(topic: topic) { [weak self] json in self?.received(json, for: w.id) }
        subscriptions[w.id] = (topic, id)
    }

    private func unsubscribe(_ watchId: String) {
        if let s = subscriptions.removeValue(forKey: watchId) { appState?.notifyBus.unsubscribe(id: s.id, topic: s.topic) }
    }

    /// One event on a watched port's topic.
    func received(_ json: String, for watchId: String) {
        guard let w = watches.first(where: { $0.id == watchId }), !w.paused,
              let c = appState?.companions.first(where: { $0.id == w.companionId }),
              let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let kind = obj["kind"] as? String,
              WatchKinds.matches(kind: kind, watched: w.kinds) else { return }
        receivedCount += 1
        var q = queues[c.id, default: WakeQueue()]
        q.ceilingPerHour = ceilingPerHour
        q.floors[w.id] = w.every.map(TimeInterval.init)
        // NO SELF-WAKE. While the watcher's turn runs, an event on a port it last wrote to is its own
        // doing: an agent fixing a port on `console` would otherwise wake on the log line its own fix
        // produced, and loop.
        if q.isBusy, let driver = appState?.portInput.driver(of: w.portUdid, now: now()),
           identities(of: c).contains(driver.ref.principal) { return }
        let payload = obj["payload"].flatMap { (SafeJSON.data($0, options: [.fragmentsAllowed])) }
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        let actions = q.receive(.init(watchId: w.id, kind: kind, payload: payload, at: now()))
        queues[c.id] = q
        perform(actions, for: c)
    }

    /// Every id a companion writes as: its own, and each terminal credential it runs under.
    private func identities(of c: AgentConfig) -> Set<String> {
        var ids: Set<String> = [c.id]
        guard let app = appState else { return ids }
        for (client, panelId) in app.terminalClientPanels {
            if let cfg = app.portWindows.panels.first(where: { $0.id == panelId })?.terminalConfig,
               cfg.companionId == c.id || cfg.companionName.lowercased() == c.displayName.lowercased() {
                ids.insert(client)
            }
        }
        return ids
    }

    private func perform(_ actions: [WakeQueue.Action], for c: AgentConfig) {
        for a in actions {
            switch a {
            case .wakeAt(let at):
                timers[c.id]?.cancel()
                let item = DispatchWorkItem { [weak self] in self?.tick(companionId: c.id) }
                timers[c.id] = item
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0, at.timeIntervalSince(now())), execute: item)
            case .deliver(let events):
                // One turn per watched port: group by port, the reply for each goes to that port's chat.
                var byPort: [String: [WakeQueue.Event]] = [:]
                var order: [String] = []
                for e in events {
                    let port = String(e.watchId.split(separator: "|").last ?? "")
                    if byPort[port] == nil { order.append(port) }
                    byPort[port, default: []].append(e)
                }
                for port in order { deliver(c, message(for: byPort[port]!, port: port, companion: c), port) }
            case .paused(let watchId):
                guard var w = watches.first(where: { $0.id == watchId }) else { continue }
                w.paused = true
                try? appState?.db.saveCompanionWatch(w)
                watches.removeAll { $0.id == watchId }
                watches.append(w)
                pauseNotice(w, c)
            }
        }
    }

    private func tick(companionId: String) {
        guard var q = queues[companionId], let c = appState?.companions.first(where: { $0.id == companionId }) else { return }
        let actions = q.tick(now: now())
        queues[companionId] = q
        perform(actions, for: c)
    }

    /// What the companion is told: which port, how many events, and each one, cut to a readable size.
    func message(for events: [WakeQueue.Event], port: String, companion: AgentConfig) -> String {
        let title = appState?.portWindows.panels.first { $0.udid == port }?.title ?? "port"
        let lines = events.suffix(Self.maxListed).map { e -> String in
            let p = e.payload.count > Self.maxPayload ? String(e.payload.prefix(Self.maxPayload)) + "…" : e.payload
            return "- \(e.kind) \(p)"
        }
        let dropped = events.count > Self.maxListed ? " (the last \(Self.maxListed) shown)" : ""
        let noun = events.count == 1 ? "event" : "events"
        return "You watch port '\(title)' (id \(port)). \(events.count) \(noun) since your last turn\(dropped):\n"
            + lines.joined(separator: "\n")
            + "\nAct on it if it needs you. Your reply is posted in that port's chat."
    }

    static let maxListed = 20
    static let maxPayload = 300
}

// MARK: - API

/// The companion a watch call is about: `companion` (an id or a name) or else the caller itself.
@MainActor
private func watchSubject(_ p: Principal, _ args: BridgeArgs, _ appState: AppState) throws -> AgentConfig {
    if let ref = args.string("companion") {
        guard let c = appState.companions.first(where: { $0.id == ref || $0.displayName.lowercased() == ref.lowercased() })
        else { throw BridgeError.notFound("companion '\(ref)'") }
        return c
    }
    guard let c = appState.companion(actingAs: p) else {
        throw BridgeError.badArg("you are not a companion; pass `companion` (a name or id) to say whose watch this is")
    }
    return c
}

@MainActor
func registerWatchMethods(into r: inout BridgeRegistry, appState: AppState) {
    r["companions.watch"] = BridgeMethod(permission: nil, paramNames: ["port", "kinds", "every", "companion"],
        description: "Watch a port: an event on it of a kind you name wakes you for a turn, and your reply is posted in that port's chat. Default kinds: [\"port\"], the port's own published events (port.publish). Others: \"console\" (a log line or error), \"state\" (an edit), \"chat\" (every post in its chat), or one exact kind such as \"port.alert\". Events that arrive while you are in a turn are held and given to you together when it ends. Watching again changes the watch and resumes it if it paused (a watch pauses after 60 wakes in an hour, and says so in the port's chat). Call it as the companion that should wake, or pass `companion` to set a watch for another.",
        inputSchema: [
            "type": "object",
            "properties": [
                "port": ["type": "string", "description": "The port to watch (id, udid or title)."],
                "kinds": ["type": "array", "items": ["type": "string"], "description": "Event kinds that wake you (default [\"port\"])."],
                "every": ["type": "integer", "description": "The least time between two wakes, in seconds (default: none)."],
                "companion": ["type": "string", "description": "Whose watch, by name or id (default: you)."],
            ],
            "required": ["port"],
        ]) { p, args in
        let c = try watchSubject(p, args, appState)
        let port = try args.requireString("port")
        guard let udid = appState.resolvePortRef(port)?.udid else { throw BridgeError.notFound("port '\(port)'") }
        let kinds = (args.any("kinds") as? [String]) ?? []
        let w = try appState.companionWatches.watch(companion: c, portUdid: udid, kinds: kinds, every: args.int("every"))
        return .object(["companion": .string(c.displayName), "port": .string(udid),
                        "kinds": .array(w.kinds.map { .string($0) }), "every": w.every.map { .int($0) } ?? .null])
    }

    r["companions.unwatch"] = BridgeMethod(permission: nil, paramNames: ["port", "companion"],
        description: "Stop watching a port. Call it as the watcher, or pass `companion`.",
        inputSchema: [
            "type": "object",
            "properties": [
                "port": ["type": "string", "description": "The watched port (id, udid or title)."],
                "companion": ["type": "string", "description": "Whose watch, by name or id (default: you)."],
            ],
            "required": ["port"],
        ]) { p, args in
        let c = try watchSubject(p, args, appState)
        let port = try args.requireString("port")
        let udid = appState.resolvePortRef(port)?.udid ?? port
        guard try appState.companionWatches.unwatch(companionId: c.id, portUdid: udid) else {
            throw BridgeError.notFound("\(c.displayName) does not watch port '\(port)'")
        }
        return .object(["ok": .bool(true)])
    }

    r["companions.watches"] = BridgeMethod(permission: nil, paramNames: ["companion"],
        description: "List watches: yours, another companion's (`companion`), or every one (`companion`: \"*\"). Each is {companion, port, title, kinds, every, paused}.",
        inputSchema: [
            "type": "object",
            "properties": ["companion": ["type": "string", "description": "A name or id, or \"*\" for all (default: you)."]],
        ]) { p, args in
        let all = args.string("companion") == "*"
        let subject = all ? nil : try watchSubject(p, args, appState)
        let list = appState.companionWatches.watches.filter { subject == nil || $0.companionId == subject!.id }
        return .array(list.map { w in
            let name = appState.companions.first { $0.id == w.companionId }?.displayName ?? w.companionId
            let title = appState.portWindows.panels.first { $0.udid == w.portUdid }?.title
            return .object(["companion": .string(name), "port": .string(w.portUdid), "title": title.map { .string($0) } ?? .null,
                            "kinds": .array(w.kinds.map { .string($0) }), "every": w.every.map { .int($0) } ?? .null,
                            "paused": .bool(w.paused)])
        })
    }
}

@MainActor
func registerCompanionCreate(into r: inout BridgeRegistry, appState: AppState) {
    r["companions.create"] = BridgeMethod(permission: .terminal, paramNames: ["name", "agent", "args", "runs", "port", "kinds", "cwd", "prompt", "command", "space_id"],
        description: "Make a companion, as the new-companion card does: an agent CLI (claude or codex) in a terminal port, or a custom command run headless. runs: \"port\" (default, on the desktop) or \"hidden\" (no place on the desktop; reach it through its chat). It joins the space and hears @mentions there; pass `port` to have it watch that port instead, woken by `kinds` (default [\"port\"], the port's own events) and replying in its chat. Needs the terminal permission, since it starts one.",
        inputSchema: [
            "type": "object",
            "properties": [
                "name": ["type": "string", "description": "Its name; @mention it by this."],
                "agent": ["type": "string", "enum": ["claude", "codex", "custom"], "description": "The CLI (default claude)."],
                "args": ["type": "array", "items": ["type": "string"], "description": "Arguments for the CLI or command."],
                "runs": ["type": "string", "enum": ["port", "hidden"], "description": "Where its terminal runs (default port)."],
                "port": ["type": "string", "description": "A port to watch instead of listening to the space."],
                "kinds": ["type": "array", "items": ["type": "string"], "description": "With `port`: event kinds that wake it."],
                "cwd": ["type": "string", "description": "Working directory (default: the space's)."],
                "prompt": ["type": "string", "description": "Its system prompt."],
                "command": ["type": "string", "description": "agent custom: the command to run."],
                "space_id": ["type": "string", "description": "The space (default: yours, else the current one)."],
            ],
            "required": ["name"],
        ]) { p, args in
        guard let user = appState.currentUser else { throw BridgeError.badArg("no user is signed in") }
        let name = try args.requireString("name").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BridgeError.badArg("name is empty") }
        let agent = args.string("agent") ?? "claude"
        guard ["claude", "codex", "custom"].contains(agent) else { throw BridgeError.badArg("agent must be claude, codex or custom") }
        if agent == "custom", (args.string("command") ?? "").isEmpty { throw BridgeError.badArg("agent custom needs a command") }
        let c = ShellNewCompanionView.makeCompanion(
            owner: user.id, name: name, cli: agent, command: args.string("command") ?? "",
            argsText: ((args.any("args") as? [String]) ?? []).joined(separator: " "),
            workingDir: args.string("cwd") ?? "", prompt: args.string("prompt") ?? "",
            hidden: args.string("runs") == "hidden", secrets: [])
        let sid = args.string("space_id") ?? p.spaceId ?? appState.currentSpace?.id ?? ""
        try appState.createCompanion(c, spaceId: sid, watchPort: args.string("port"),
                                     watchKinds: (args.any("kinds") as? [String]) ?? WatchKinds.defaultKinds)
        return .object(["id": .string(c.id), "name": .string(c.displayName), "agent": .string(agent),
                        "runs": .string(c.runsHidden ? "hidden" : (c.openInTerminal ? "port" : "headless"))])
    }
}
