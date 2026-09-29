import Testing
import Foundation
@testable import Port42Lib

/// A port renders by its size: at card size (a peek) Port42 draws its state card, from what it declared
/// and what Port42 knows (docs/plan-port-state-v1.md, Phase A).
@Suite("A port's card and size tier")
struct PortCardTests {

    @Test("a peek and a tile resized small are cards; orientation follows the shape")
    func tiers() {
        #expect(PortPresentation.tier(ShellPlacement.peekSize) == .card)
        // A tile resized small becomes its card too: nothing about peeks is special (GM).
        #expect(PortPresentation.tier(ShellState.minTileSize) == .card)
        #expect(PortPresentation.tier(CGSize(width: 220, height: 160)) == .compact)
        #expect(PortPresentation.tier(CGSize(width: 620, height: 440)) == .full)
        #expect(PortPresentation.tier(CGSize(width: 900, height: 300)) == .compact, "short counts, not just narrow")
        #expect(PortPresentation.orientation(CGSize(width: 800, height: 300)) == .wide)
        #expect(PortPresentation.orientation(CGSize(width: 300, height: 600)) == .tall)
        #expect(PortPresentation.orientation(CGSize(width: 620, height: 440)) == .square)
    }

    @Test("the presentation event carries tier and orientation when visible, and neither when not")
    func event() {
        let shown = PortPresentation(state: .peek, visible: true, size: ShellPlacement.peekSize).jsonObject
        #expect(shown["tier"] as? String == "card" && shown["orientation"] as? String == "square")
        let hidden = PortPresentation(state: .hidden, visible: false).jsonObject
        #expect(hidden["tier"] == nil && hidden["orientation"] == nil)
    }

    @Test("a terminal's card: what it runs, a failed command stands out, the directory short, a recent bell")
    func terminal() {
        let now = Date(timeIntervalSince1970: 10_000)
        var t = TerminalFacts()
        t.apply(.pwd("/Users/me/port42-native"), at: now)
        t.apply(.title("✳ fixing the rail"), at: now)
        t.apply(.commandFinished(exit: 1, seconds: 1.2), at: now.addingTimeInterval(-120))
        t.apply(.bell, at: now.addingTimeInterval(-30))
        t.apply(.progress(.init(percent: 40, failed: false, paused: false)), at: now)
        let card = PortCard.build(title: "rail", terminal: t, home: "/Users/me", now: now)
        #expect(card.lines.map(\.label) == ["running", "failed", "in", "bell"])
        #expect(card.lines[1].value == "exit 1 · 1.2s · 2m ago" && card.lines[1].tone == .alert)
        #expect(card.lines[2].value == "~/port42-native")
        #expect(card.progress == 0.4)
        #expect(card.summary == "running ✳ fixing the rail")
        // A title that is only the directory says nothing new, so it is not shown as "running".
        var plain = TerminalFacts()
        plain.apply(.pwd("/Users/me"), at: now)
        plain.apply(.title("/Users/me"), at: now)
        #expect(PortCard.build(title: "sh", terminal: plain, home: "/Users/me", now: now).lines.map(\.label) == ["in"])
    }

    @Test("a companion working or waiting leads its terminal's card; declared lines come first of all")
    func companionAndDeclared() {
        let now = Date(timeIntervalSince1970: 10_000)
        var working = ChatPresence(name: "echo", state: .working, since: now.addingTimeInterval(-90))
        working.doing = .init(summary: "editing a file", detail: "editing ShellDesktop.swift")
        let card = PortCard.build(title: "echo", declared: [StateLine(label: "task", value: "the rail")],
                                  companion: .init(presence: working, waitingMessages: true), now: now)
        #expect(card.lines.map(\.label) == ["task", "working", "doing", "queued"])
        #expect(card.lines[0].known == false && card.lines[1].known == true)
        #expect(card.lines[1].value == "1m" && card.lines[2].value == "editing ShellDesktop.swift")
        let waiting = ChatPresence(name: "echo", state: .waiting("needs approval"), since: now)
        let w = PortCard.build(title: "echo", companion: .init(presence: waiting, waitingMessages: false), now: now)
        #expect(w.lines.first?.value == "needs approval" && w.lines.first?.tone == .alert)
    }

    @Test("a browser's card: its page, its site and a bar while it loads; a web port's errors; five lines at most")
    func browserAndCaps() {
        let b = BrowserFacts(title: "Port42", url: URL(string: "https://port42.ai/docs"), progress: 0.5)
        let card = PortCard.build(title: "browser", browser: b, errors: 2)
        #expect(card.lines.map(\.label) == ["page", "site", "errors"])
        #expect(card.lines[1].value == "port42.ai" && card.progress == 0.5)
        let many = (1...8).map { StateLine(label: "l\($0)", value: "v") }
        #expect(PortCard.build(title: "x", declared: many).lines.count == PortCard.maxLines)
    }
}

/// `state.set` and `state.get` through the registry: who may say what a port is doing, and what reads back.
@Suite("A port's declared state")
@MainActor
struct PortStateMethodTests {

    func port(_ w: ParityWorld, _ id: String, space: String? = nil) -> PortPanel {
        w.state.portWindows.registerTiledPort(id: id, html: "<title>\(id)</title>", spaceId: space ?? w.space.id,
                                              createdBy: nil, title: id, position: CGPoint(x: 40, y: 40))
        return w.state.portWindows.panels.first { $0.id == id }!
    }

    func call(_ w: ParityWorld, _ who: Principal, _ method: String, _ args: [String: Any]) async throws -> [String: Any] {
        let v = try await w.state.runBridgeMethod(method, principal: who, args: BridgeArgs(args))
        return v.toJSONObject() as? [String: Any] ?? [:]
    }

    @Test("a port sets its own state, trimmed to the caps, and reads it back before what Port42 knows")
    func ownState() async throws {
        let w = try makeParityWorld()
        let panel = port(w, "p1")
        let me = Principal.port(id: panel.udid, displayName: "p1", spaceId: w.space.id)
        let lines = (1...7).map { ["label": "l\($0)", "value": String(repeating: "x", count: 100)] }
        _ = try await call(w, me, "state.set", ["lines": lines])
        let got = try await call(w, me, "state.get", [:])
        let read = try #require(got["lines"] as? [[String: Any]])
        #expect(read.count == 5 && (read[0]["value"] as? String)?.count == 80 && read[0]["known"] as? Bool == false)
        #expect(w.state.portSummary(panel) == "l1 " + String(repeating: "x", count: 80))
        _ = try await call(w, me, "state.set", ["lines": []])
        #expect(w.state.portStates.declared[panel.id] == nil, "an empty list clears it")
    }

    @Test("a companion in the port's space may set its state; a companion from another space may not")
    func whoMaySet() async throws {
        let w = try makeParityWorld()
        let panel = port(w, "p2")
        let here = Principal.companion(id: w.companion.id, displayName: w.companion.displayName, spaceId: w.space.id)
        _ = try await call(w, here, "state.set", ["port": panel.udid, "lines": [["label": "doing", "value": "x"]]])
        #expect(w.state.portStates.declared[panel.id]?.first?.value == "x")

        let other = Space.create(name: "elsewhere")
        try w.state.db.saveSpace(other)
        w.state.spaces.append(other)
        let far = port(w, "p3", space: other.id)
        let outsider = Principal.port(id: far.udid, displayName: "p3", spaceId: other.id)
        await #expect(throws: BridgeError.self) {
            _ = try await call(w, outsider, "state.set", ["port": panel.udid, "lines": [["label": "a", "value": "b"]]])
        }
        #expect(w.state.portStates.declared[panel.id]?.first?.value == "x", "a refused set changed nothing")

        // Another port's page in the same space can see it, but it did not make it and is no companion.
        let neighbour = port(w, "p5")
        let page = Principal.port(id: neighbour.udid, displayName: "p5", spaceId: w.space.id)
        await #expect(throws: BridgeError.self) {
            _ = try await call(w, page, "state.set", ["port": panel.udid, "lines": [["label": "a", "value": "b"]]])
        }
        #expect(w.state.portStates.declared[panel.id]?.first?.value == "x")
    }

    @Test("closing a port forgets its state")
    func forgetsOnClose() async throws {
        let w = try makeParityWorld()
        let panel = port(w, "p4")
        w.state.portStates.declare([StateLine(label: "a", value: "b")], port: panel.id)
        w.state.portWindows.close(panel.id)
        #expect(w.state.portStates.declared[panel.id] == nil)
    }
}
