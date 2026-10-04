import Foundation

/// Bringing terminals up after a launch in order, a few at a time (#223; Gordon, 2026-10-04: the current space
/// first, five at once). See `docs/plan-boot-order.md`.
///
/// Every terminal in every space used to start its CLI at launch, together. On a loaded Mac the current space's
/// sessions took 139 s once and did not finish in 200 s twice (`docs/research/boot-order.md`). Now a restored
/// terminal is **waiting**: its port exists (listed, in the rail, its chat works) and this queue starts it, the
/// current space's first, at most `cap` at a time. Anything that needs a waiting terminal starts it at once
/// (`startNow`), ahead of the queue and the cap.
@MainActor
public final class TerminalStarts: ObservableObject {
    /// How many terminals may be starting at once.
    static var cap = 5
    /// How long a start may take before the next is let in anyway.
    static var settleAfter: TimeInterval = 20

    /// A terminal the queue holds: its port, where it lives, and how to start it.
    struct Entry {
        let id: String
        let spaces: Set<String>
        let everywhere: Bool
        let start: () -> Void
    }

    @Published private(set) var waiting: [Entry] = []
    /// Ports whose start has begun and not yet settled, with when it began.
    private(set) var starting: [String: Date] = [:]
    /// Has this port's CLI reported its session? Replaced in tests.
    var hasStarted: (String) -> Bool = { _ in false }
    private var checking = false

    public func isWaiting(_ id: String) -> Bool { waiting.contains { $0.id == id } }
    var waitingIds: [String] { waiting.map(\.id) }

    /// Hold a restored terminal until its turn.
    func enqueue(_ entry: Entry) {
        guard !isWaiting(entry.id), starting[entry.id] == nil else { return }
        waiting.append(entry)
    }

    /// Put the queue in launch order: what is on the current space first (its own, pinned everywhere, or shown
    /// in it), then the other spaces, most recently visited first. Stable within a space.
    func order(current: String?, visited: [String: Date]) {
        func rank(_ e: Entry) -> (Int, Double) {
            if e.everywhere || (current.map { e.spaces.contains($0) } ?? false) { return (0, 0) }
            let last = e.spaces.compactMap { visited[$0]?.timeIntervalSince1970 }.max() ?? 0
            return (1, -last)
        }
        waiting = waiting.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// The person went to `space`: its waiting terminals go to the front, in the order they had.
    func prefer(space: String?) {
        guard let space else { return }
        let here = waiting.filter { $0.everywhere || $0.spaces.contains(space) }
        guard !here.isEmpty else { return }
        waiting = here + waiting.filter { !($0.everywhere || $0.spaces.contains(space)) }
        pump()
    }

    /// Something needs this terminal now: start it, ahead of the queue and whatever the cap says.
    func startNow(_ id: String) {
        guard let i = waiting.firstIndex(where: { $0.id == id }) else { return }
        begin(waiting.remove(at: i))
    }

    /// Start waiting terminals until `cap` are starting.
    func pump() {
        while starting.count < Self.cap, !waiting.isEmpty { begin(waiting.removeFirst()) }
    }

    /// Let go of the starts that have settled (the CLI reported its session, or `settleAfter` passed), and let
    /// the next ones in.
    func settle(now: Date = Date()) {
        for (id, began) in starting where hasStarted(id) || now.timeIntervalSince(began) >= Self.settleAfter {
            starting[id] = nil
        }
        pump()
        if !starting.isEmpty { check() }
    }

    private func begin(_ entry: Entry) {
        starting[entry.id] = Date()
        entry.start()
        check()
    }

    private func check() {
        guard !checking else { return }
        checking = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.checking = false
            self?.settle()
        }
    }
}

extension AppState {
    /// How long a call waits for a waiting terminal it needs to come up.
    static var waitForWaitingTerminal: TimeInterval = 30

    /// A call that needs a terminal still waiting its turn starts it now and waits for its surface (#223), so it
    /// is delivered instead of refused as having no live surface. Any other port, or a terminal already running,
    /// returns at once. `refs`: the arguments that name the call's target.
    func startWaitingTerminal(named refs: [String?]) async {
        for raw in refs.compactMap({ $0 }) {
            guard let id = resolvePortRef(raw)?.id, terminalStarts.isWaiting(id) else { continue }
            p42log("[Port42] starting waiting terminal %@ now: a call needs it", id)
            terminalStarts.startNow(id)
            let until = Date().addingTimeInterval(Self.waitForWaitingTerminal)
            while Date() < until, terminalControllers[id]?.canDeliver != true {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }
}
