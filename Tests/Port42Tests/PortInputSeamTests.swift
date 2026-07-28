import Testing
import Foundation
@testable import Port42Lib

/// I2 · C1 — the input seam's door (plan-port42-protocol-local-bus.md §C).
///
/// Nothing calls the seam yet; C2 moves the translators onto it. These are pure tests of the POLICY,
/// which is the part worth settling before any caller depends on it: the seam decides what counts,
/// and everything above it inherits that decision.
@Suite("Port input seam (I2 C1)")
struct PortInputSeamTests {

    let alice = ActorRef(principal: "alice")
    let bob = ActorRef(principal: "bob")
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func input(_ kind: PortInput.Kind, actor: ActorRef?, name: String? = nil,
               trust: PortInput.Trust = .native, port: String = "p1") -> PortInput {
        PortInput(port: port, kind: kind, actor: actor, actorName: name, trust: trust)
    }

    // MARK: - rule 1: the token always moves

    @Test("EVERY kind moves the token, which is the entire point of the seam")
    func everyKindCounts() {
        var seam = PortInputSeam()
        let kinds: [PortInput.Kind] = [
            .text("a"), .gesture, .navigation(URL(string: "https://example.com")!), .programmatic,
        ]
        var seen: [String] = [seam.token(for: "p1")]
        for k in kinds {
            seen.append(seam.received(input(k, actor: alice), now: t0).token)
        }
        // Five distinct tokens: the start plus one per kind. A kind that did not count would repeat
        // its predecessor, and the port would have changed while its token stood still. That is the
        // exact failure Spike C measured for dictation, the emoji picker, right-click paste and a
        // cross-app drag.
        #expect(Set(seen).count == 5, "a kind failed to move the token: \(seen)")
    }

    @Test("a gesture counts, because a canvas click can change everything and emits no beforeinput")
    func gestureCounts() {
        var seam = PortInputSeam()
        let before = seam.token(for: "p1")
        let after = seam.received(input(.gesture, actor: alice), now: t0).token
        #expect(before != after)
    }

    @Test("the token moves even with NO actor, because the port changed either way")
    func unattributedStillCounts() {
        var seam = PortInputSeam()
        let out = seam.received(input(.text("x"), actor: nil), now: t0)
        #expect(out.token != PortInputSeam().token(for: "p1"))
        // …and names nobody. I1.1 measured this path: native input before setup completes, and the
        // app writing a startup command into a pty on behalf of no one.
        #expect(out.driverChanged == nil)
        #expect(seam.driver(of: "p1", now: t0) == nil)
    }

    @Test("two writes at the SAME instant still produce two tokens")
    func tokenIsNotThrottled() {
        var seam = PortInputSeam()
        // Same actor, same instant, twice. Presence says "no change" here (step 3); the token must
        // still move, because the port changed twice.
        let a = seam.received(input(.text("a"), actor: alice), now: t0).token
        let b = seam.received(input(.text("b"), actor: alice), now: t0).token
        #expect(a != b, """
            A throttled token is a correctness hole, not a tuning choice: a companion's write \
            composed seconds ago would pass CAS against a line you are halfway through typing.
            """)
    }

    // MARK: - rule 2: presence follows the actor, and nothing else

    @Test("an actor records presence; its absence records nothing")
    func presenceFollowsTheActor() {
        var seam = PortInputSeam()
        #expect(seam.received(input(.text("x"), actor: alice, name: "Alice"), now: t0).driverChanged?.name == "Alice")

        var other = PortInputSeam()
        #expect(other.received(input(.programmatic, actor: nil), now: t0).driverChanged == nil)
    }

    @Test("a driver name is never blank: no name falls back to the principal id")
    func driverNameNeverBlank() {
        var seam = PortInputSeam()
        let out = seam.received(input(.text("x"), actor: alice, name: nil), now: t0)
        #expect(out.driverChanged?.name == "alice")
    }

    @Test("a TAKEOVER is announced immediately, or the human could never win the chip back")
    func takeoverIsAnnouncedAtOnce() {
        var seam = PortInputSeam()
        _ = seam.received(input(.programmatic, actor: bob, name: "echo"), now: t0)
        // A human types one second later. Under the old 5s presence throttle this event was dropped.
        let out = seam.received(input(.text("h"), actor: alice, name: "Alice"),
                                now: t0.addingTimeInterval(1))
        #expect(out.driverChanged?.ref == alice, """
            GM caught this live before R1b: a companion writing every 2s against a 5s throttle \
            meant the human could never take the chip back. Step 3 deleted the throttle rather than \
            tuning it — a change is announced, a repeat is not, and neither needs a rate limit.
            """)
    }

    @Test("a REPEAT is silent, so the port's topic is not drowned per keystroke")
    func repeatIsSilent() {
        var seam = PortInputSeam()
        #expect(seam.received(input(.text("a"), actor: alice), now: t0).driverChanged != nil)
        // Same actor again, immediately: still driving, nothing new to say. This is what replaced
        // the throttle — the broadcast keys off the driver CHANGING, not off a rate limit, so a
        // burst of typing publishes once for the reason rather than by suppression.
        #expect(seam.received(input(.text("b"), actor: alice), now: t0).driverChanged == nil)
        // …and it is still the driver. Silence is about the broadcast, not the fact.
        #expect(seam.driver(of: "p1", now: t0)?.ref == alice)
    }

    // MARK: - close: the two tables have OPPOSITE lifecycles

    @Test("closing a port forgets presence but NEVER the token (Spike A, correction 4)")
    func closeForgetsPresenceNotTheToken() {
        var seam = PortInputSeam()
        _ = seam.received(input(.text("x"), actor: alice), now: t0)
        let tokenBeforeClose = seam.token(for: "p1")

        seam.portClosed("p1")

        #expect(seam.driver(of: "p1", now: t0) == nil, "presence must lapse: it is a claim about now")
        #expect(seam.token(for: "p1") == tokenBeforeClose, """
            The token must NOT reset. A counter that rewinds lets a token minted against a dead \
            port pass CAS against a live one that reused the id. The epoch covers a restart; this \
            covers a reused id within one run.
            """)
    }

    @Test("after a close, the next write announces its driver even if it is the same actor")
    func closeAnnouncesTheNextDriver() {
        var seam = PortInputSeam()
        _ = seam.received(input(.text("a"), actor: alice), now: t0)
        seam.portClosed("p1")
        // A new port reusing the id, driven by the same actor, well inside the display window.
        let out = seam.received(input(.text("b"), actor: alice), now: t0.addingTimeInterval(1))
        #expect(out.driverChanged != nil, "a leftover attribution would hide the new driver")
    }

    // MARK: - scoping

    @Test("ports do not share a token or a driver")
    func portsAreIndependent() {
        var seam = PortInputSeam()
        _ = seam.received(input(.text("a"), actor: alice, port: "p1"), now: t0)
        #expect(seam.token(for: "p1") != seam.token(for: "p2"))
        #expect(seam.driver(of: "p2", now: t0) == nil)
    }

    // MARK: - C2.0 · one owner

    @Test("the table has ONE owner: nothing outside the seam holds its own")
    func seamIsTheOnlyOwner() throws {
        // C2.0. While `AppState` held `portActivity`/`portDrivers`/`presenceThrottle` and the seam
        // held its own, moving a single translator would have bumped one counter while every reader
        // read the other, splitting a port's token in two for the length of the migration. That is
        // the exact lie the seam exists to prevent, introduced by the work meant to prevent it.
        //
        // Tree-wide, because a gate scoped to named files is not a gate: `bothHostsWireIt` named two
        // files and a third site walked past it (C0), and the old `Principal` scan was per-file
        // while both live holes hid behind it (I1).
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let walker = try #require(FileManager.default.enumerator(at: root,
                                                                 includingPropertiesForKeys: nil))
        var owners: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            // The seam is the owner; ShellState's `portDrivers` is an unrelated @Published dict of
            // display badges for the chrome, not the registry.
            let file = url.lastPathComponent
            guard file != "PortInput.swift", file != "ShellState.swift" else { continue }
            let src = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for line in src.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("//"), !t.hasPrefix("///") else { continue }
                if t.contains("= PortActivity(") {
                    owners.append("\(file): \(t.prefix(60))")
                }
            }
        }
        #expect(owners.isEmpty, """
            These declare their own copy of a table the seam owns: \(owners).
            A second owner splits a port's token across two counters, which is the failure C2.0 \
            exists to make impossible.
            """)
    }

    // MARK: - C4 · the mutating surface is exactly two doors (three until step 3)

    @Test("the seam has exactly TWO mutating entry points, and the table is private")
    func twoDoorsAndNoOther() throws {
        // C4 was planned as "flip the fields private, and the compiler names every path missed". It
        // landed early and incrementally instead: C1 declared the tables private from the start, and
        // each passthrough deleted in C2 made the compiler produce that phase's caller list. There
        // was never a big-bang flip.
        //
        // What is left is keeping it true. A fourth mutating method is how this erodes: it would not
        // fail any behaviour test, and it would quietly become a second door.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Port42Lib/Services/PortInput.swift")
        let src = try String(contentsOf: url, encoding: .utf8)

        let doors = src.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("mutating func") && !$0.hasPrefix("//") && !$0.hasPrefix("///") }
            .compactMap { line -> String? in
                guard let r = line.range(of: "mutating func ") else { return nil }
                return String(line[r.upperBound...]).components(separatedBy: "(").first
            }
        #expect(Set(doors) == ["received", "portClosed"], """
            The seam's mutating surface changed: \(doors.sorted()).
            received = input (the token always moves, and presence falls out of it). portClosed = \
            the attribution lapses, the token does not. A third door is a second way in, which is \
            what this seam exists to remove — and it is exactly what `presenceClaimed` was before \
            step 3 derived presence from the token (§F).
            """)

        // And the table stays private, or the doors are decoration.
        #expect(src.contains("private var activity"),
                "the activity table must be private to the seam, or any path can mutate it directly")
    }

    @Test("nothing can claim presence without moving the token (step 3)")
    func presenceCannotBeClaimedWithoutAWrite() throws {
        // `presenceClaimed` was the second door, and focus was its only caller: it named a driver
        // while proving nothing about the port. Under a derived driver that is incoherent, and GM
        // decided focus stops conferring presence rather than keeping a claim a peer could not
        // verify (§F). The seam offers no way to name a driver except by changing the port.
        var seam = PortInputSeam()
        let before = seam.token(for: "p1")
        #expect(seam.driver(of: "p1", now: t0) == nil)

        let out = seam.received(input(.text("h"), actor: alice, name: "Alice"), now: t0)
        #expect(out.driverChanged?.ref == alice)
        #expect(seam.token(for: "p1") != before, "presence and the token move together, or not at all")

        // And the shell's focus path no longer records anything. Tree-wide: a gate scoped to named
        // files is not a gate.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var claims: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let src = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for line in src.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("//"), !t.hasPrefix("///") else { continue }
                if t.contains("recordHumanFocus") || t.contains("recordDriving") {
                    claims.append("\(url.lastPathComponent): \(t.prefix(60))")
                }
            }
        }
        #expect(claims.isEmpty, "focus is naming a driver again without proving anything: \(claims)")
    }

    // MARK: - the recorded risk

    @Test("PortInput has exactly four fields plus a display label")
    func fourFieldsNotABag() throws {
        // The plan records the failure condition explicitly: PortInput has four fields because four
        // things need it TODAY, and if a fifth is added for a CONSUMER rather than a SOURCE it has
        // become a bag and the design failed. This asserts the shape so that addition is a
        // deliberate act with a test to change, not a drift.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Port42Lib/Services/PortInput.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        let head = try #require(src.range(of: "public struct PortInput"))
        // Everything from the struct's declaration up to where the seam begins.
        let body = String(src[head.lowerBound...]).components(separatedBy: "// MARK: - The seam")[0]
        let stored = body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("public let ") }
        #expect(stored.count == 5, """
            PortInput's stored properties changed: \(stored).
            Four are the design (port, kind, actor, trust) plus actorName as display. A fifth added \
            for a consumer rather than a source means this became a bag; see plan §C.
            """)
    }
}
