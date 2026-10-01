import Foundation

// MARK: - A space at a glance (#137)
//
// Zoomed out to the galaxy, each space said only its name and how many ports it had. The person could
// not see where they were needed or what was going on without diving into every space. This is the
// port state card (1.0.4) one level up: what the galaxy tile shows about a space, built from the same
// facts the rail and the port cards use, so the two never disagree.
//
// - Waiting on you: a companion whose presence in any of the space's chats is `waiting` (it asked for
//   a permission, or stopped at its prompt).
// - Failed: a terminal port whose last command exited non-zero, or whose progress reported an error.
// - Working: a companion at work in the space's chats, with what it is doing when the CLI says.
// - Ports: running (on the desktop or hidden, still running) and paused (parked in the rail), the
//   rail's own two sections.
// - Unread: the space chat's unread count, as the resting shelf already shows it.

public struct SpaceGlance: Equatable {
    /// Companions waiting on the person: "name: why", or the name when it gave no reason.
    public var waiting: [String] = []
    /// Terminal ports whose last command failed, by title.
    public var failed: [String] = []
    /// Companions at work: "name: what it is doing", or the name between tools.
    public var working: [String] = []
    public var running = 0
    public var paused = 0
    public var unread = 0

    /// Something here needs the person: the red dot.
    public var needsYou: Bool { !waiting.isEmpty || !failed.isEmpty }

    /// One port of the space, as the glance needs it.
    public struct Port: Equatable {
        public var title: String
        public var paused: Bool
        public var terminal: TerminalFacts?
        public init(title: String, paused: Bool, terminal: TerminalFacts? = nil) {
            self.title = title; self.paused = paused; self.terminal = terminal
        }
    }

    /// Pure, so the galaxy and the tests build the same thing. `presence` is every entry in the
    /// space's chats (its own and its ports'); a companion listed in more than one is counted once,
    /// and waiting outranks working.
    public static func build(presence: [ChatPresence], ports: [Port], unread: Int) -> SpaceGlance {
        var g = SpaceGlance(unread: unread)
        var seen = Set<String>()
        for p in presence {
            guard case .waiting(let why) = p.state, seen.insert(p.name.lowercased()).inserted else { continue }
            g.waiting.append(why.isEmpty ? p.name : "\(p.name): \(why)")
        }
        for p in presence where p.state == .working || p.state == .received {
            guard seen.insert(p.name.lowercased()).inserted else { continue }
            g.working.append(p.doing.map { "\(p.name): \($0.detail)" } ?? p.name)
        }
        for port in ports {
            if port.paused { g.paused += 1 } else { g.running += 1 }
            if let t = port.terminal,
               (t.lastCommand?.exit).map({ $0 != 0 }) == true || t.progress?.failed == true {
                g.failed.append(port.title)
            }
        }
        return g
    }
}

@MainActor
extension AppState {
    /// The glance for one space: its own chat and its home ports' chats, its ports, its unread count.
    public func spaceGlance(_ space: Space) -> SpaceGlance {
        let home = portWindows.panels.filter { $0.spaceId == space.id }
        let parked = Set(portWindows.railIds(in: space.id))
        let chats = [space.id] + home.map(\.udid)
        let entries = chats.flatMap { self.presence.entries($0) }
        let ports = home.map { p in
            SpaceGlance.Port(title: p.title, paused: parked.contains(p.id), terminal: portStates.terminals[p.id])
        }
        return SpaceGlance.build(presence: entries, ports: ports,
                                 unread: chats.first.map { self.chats.unread($0, me: currentUser?.id) } ?? 0)
    }
}
