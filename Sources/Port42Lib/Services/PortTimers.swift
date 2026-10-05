import Foundation

/// A clock for ports (#259; Gordon, 2026-10-04). A page asks `port42.timer.every(seconds, fn)` or
/// `after(seconds, fn)`, and Port42 calls it back, instead of the page running its own `setInterval`.
///
/// Port42 can then pace the timer by where the port is, which a page's own timer cannot be: full rate on
/// screen, or when the port is set to run in the background; slowed to `slowEvery` in another space, paused,
/// or behind the galaxy; and due at once when it comes back into view, so it catches up. A page polling on its
/// own timer kept the shared web process awake from a space nobody was in (#257, the CPU chart).
@MainActor
public final class PortTimers {
    struct Entry {
        let id: String
        let port: String
        let every: TimeInterval
        let once: Bool
        var last: Date
    }

    /// The pace of a port that is not on screen.
    static var slowEvery: TimeInterval = 60
    static let minEvery: TimeInterval = 0.25
    static let maxPerPort = 20

    private(set) var entries: [String: Entry] = [:]
    /// Full rate for this port: on screen, or set to run in the background. Replaced in tests.
    var fullRate: (String) -> Bool = { _ in true }
    /// Hand a tick to the port's page; false when the port is gone. Replaced in tests.
    var deliver: (_ port: String, _ id: String) -> Bool = { _, _ in false }
    private var clock: Timer?

    /// Add a timer for `port` firing every `seconds` (or once, after them). Returns its id: `id` when the page
    /// chose one (it records it first, so the first tick can never beat it), else a new one.
    func add(port: String, seconds: Double, once: Bool, id chosen: String? = nil, now: Date = Date()) throws -> String {
        guard seconds.isFinite, seconds > 0 else { throw BridgeError.badArg("seconds must be a positive number") }
        guard entries.values.filter({ $0.port == port }).count < Self.maxPerPort else {
            throw BridgeError.badArg("a port has at most \(Self.maxPerPort) timers; cancel one first")
        }
        let id = chosen.map { String($0.prefix(64)) } ?? ("t" + UUID().uuidString.prefix(8).lowercased())
        entries[Self.key(port, id)] = Entry(id: id, port: port, every: max(seconds, Self.minEvery), once: once, last: now)
        startClock()
        return id
    }

    /// Cancel one of `port`'s timers. Another port's timer is never touched.
    func cancel(_ id: String, port: String) {
        entries[Self.key(port, id)] = nil
    }

    /// Timers are kept by port and id, so two ports' ids never meet.
    static func key(_ port: String, _ id: String) -> String { port + "|" + id }

    func cancelAll(port: String) {
        entries = entries.filter { $0.value.port != port }
    }

    /// Fire every timer that is due at its port's pace.
    func tick(now: Date = Date()) {
        for (key, e) in entries {
            let pace = fullRate(e.port) ? e.every : max(e.every, Self.slowEvery)
            guard now.timeIntervalSince(e.last) >= pace else { continue }
            guard deliver(e.port, e.id) else { cancelAll(port: e.port); continue }   // its port is gone
            if e.once { entries[key] = nil } else { entries[key]?.last = now }
        }
        if entries.isEmpty { clock?.invalidate(); clock = nil }
    }

    /// One clock for every port, ticking as often as the fastest timer needs (at most four times a second),
    /// and only while there is a timer.
    private func startClock() {
        let fastest = entries.values.map(\.every).min() ?? 1
        let step = min(max(fastest / 2, Self.minEvery), 1)
        if let clock, abs(clock.timeInterval - step) < 0.01 { return }
        clock?.invalidate()
        guard !AppState.isTestProcess else { return }
        clock = Timer.scheduledTimer(withTimeInterval: step, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }
}

@MainActor
func registerTimerMethods(into r: inout BridgeRegistry, appState: AppState) {
    /// The calling page's port, or a refusal: a timer is a page's, and fires into that page.
    func ownPort(_ p: Principal) throws -> String {
        guard p.kind == .port, let ref = appState.resolvePortRef(p.portId ?? p.id), let key = ref.key else {
            throw BridgeError.badArg("timers are for a port's own page: call port42.timer.every from inside a port")
        }
        return key
    }
    let seconds: [String: Any] = ["type": "number", "description": "Seconds between ticks (at least 0.25)."]
    let chosenId: [String: Any] = ["type": "string", "description": "The timer's id, chosen by the page (the port42 library does this); else Port42 makes one."]

    r["timer.every"] = BridgeMethod(permission: nil, paramNames: ["seconds", "id"], toolExposed: false,
        description: "From a port's page: call back every `seconds`, as port42.timer.every(seconds, fn), which returns the timer's id. Use it instead of setInterval: Port42 owns the clock, runs it at full rate while the port is on screen or set to run in the background, slows it to once a minute while the port is in another space, paused or hidden, and fires it at once when the port is shown again. Returns { id }.",
        inputSchema: ["type": "object", "properties": ["seconds": seconds, "id": chosenId], "required": ["seconds"]]) { p, args in
        guard let s = args.double("seconds") else { throw BridgeError.missingArg("seconds") }
        return .object(["id": .string(try appState.portTimers.add(port: try ownPort(p), seconds: s, once: false, id: args.string("id")))])
    }
    r["timer.after"] = BridgeMethod(permission: nil, paramNames: ["seconds", "id"], toolExposed: false,
        description: "From a port's page: call back once, after `seconds`, as port42.timer.after(seconds, fn). Paced as timer.every: while the port is not on screen it may fire later, and fires when the port is shown again. Returns { id }.",
        inputSchema: ["type": "object", "properties": ["seconds": seconds, "id": chosenId], "required": ["seconds"]]) { p, args in
        guard let s = args.double("seconds") else { throw BridgeError.missingArg("seconds") }
        return .object(["id": .string(try appState.portTimers.add(port: try ownPort(p), seconds: s, once: true, id: args.string("id")))])
    }
    r["timer.cancel"] = BridgeMethod(permission: nil, paramNames: ["id"], toolExposed: false,
        description: "From a port's page: stop a timer, by the id timer.every or timer.after returned (port42.timer.cancel(id)). A port's timers also stop when it closes or its page reloads.",
        inputSchema: ["type": "object", "properties": ["id": ["type": "string", "description": "The timer's id."]], "required": ["id"]]) { p, args in
        appState.portTimers.cancel(try args.requireString("id"), port: try ownPort(p))
        return .object(["ok": .bool(true)])
    }
}
