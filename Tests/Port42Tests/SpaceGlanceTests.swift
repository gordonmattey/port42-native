import Testing
import Foundation
@testable import Port42Lib

// #137: the galaxy tile said only a space's name and its port count. It now shows the space at a
// glance: who is waiting on the person, what failed, who is working on what, ports running and paused,
// and unread chat. Built headlessly from the same stores the rail and the port cards read.

@Suite("A space at a glance in the galaxy (#137)")
@MainActor
struct SpaceGlanceTests {

    func presence(_ name: String, _ state: ChatPresence.State, doing: String? = nil) -> ChatPresence {
        var p = ChatPresence(name: name, state: state, since: Date())
        if let doing { p.doing = .init(summary: doing, detail: doing) }
        return p
    }

    func failedTerminal(exit: Int) -> TerminalFacts {
        var t = TerminalFacts()
        t.apply(.commandFinished(exit: exit, seconds: 2), at: Date())
        return t
    }

    @Test("waiting, working and what, counted once per companion, waiting first")
    func presenceSummary() {
        let g = SpaceGlance.build(presence: [
            presence("lead", .working, doing: "editing index.html"),
            presence("eng-1", .waiting("needs permission to use Bash")),
            presence("eng-1", .working),                 // the same companion in another chat
            presence("eng-2", .received),
        ], ports: [], unread: 0)
        #expect(g.waiting == ["eng-1: needs permission to use Bash"])
        #expect(g.working == ["lead: editing index.html", "eng-2"])
        #expect(g.needsYou)
    }

    @Test("ports: running and paused, and a failed terminal needs you; a clean exit does not")
    func portsSummary() {
        let g = SpaceGlance.build(presence: [], ports: [
            .init(title: "board", paused: false),
            .init(title: "build", paused: false, terminal: failedTerminal(exit: 1)),
            .init(title: "notes", paused: true, terminal: failedTerminal(exit: 0)),
        ], unread: 4)
        #expect(g.running == 2 && g.paused == 1)
        #expect(g.failed == ["build"])
        #expect(g.unread == 4)
        #expect(g.needsYou)
        #expect(!SpaceGlance.build(presence: [], ports: [.init(title: "ok", paused: false,
                                                             terminal: failedTerminal(exit: 0))], unread: 0).needsYou)
    }

    @Test("the real glance reads the space's own chat and its ports' chats, and nothing from other spaces")
    func fromAppState() throws {
        let w = try makeParityWorld()
        let made = w.state.createPort(type: "web", title: "board", html: "<title>board</title>", command: nil, cwd: nil,
                                      systemPrompt: nil, spaceId: w.space.id, createdBy: w.companion.id,
                                      createdByName: w.companion.displayName, presentation: "tiled")
        let id = try #require(made["id"] as? String)
        let udid = try #require(w.state.portWindows.findPort(by: id)).udid
        _ = w.state.createPort(type: "web", title: "parked", html: "<title>parked</title>", command: nil, cwd: nil,
                               systemPrompt: nil, spaceId: w.space.id, createdBy: w.companion.id,
                               createdByName: w.companion.displayName, presentation: "parked")
        _ = w.state.createPort(type: "web", title: "elsewhere", html: "<title>x</title>", command: nil, cwd: nil,
                               systemPrompt: nil, spaceId: "other", createdBy: w.companion.id,
                               createdByName: w.companion.displayName, presentation: "tiled")
        w.state.presence.received("lead", in: w.space.id)
        w.state.presence.update("lead", to: .working)
        w.state.presence.doing("lead", .init(summary: "editing", detail: "editing board.js"))
        w.state.presence.received("eng-1", in: udid)
        w.state.presence.update("eng-1", to: .waiting("needs you"))
        w.state.presence.received("stranger", in: "other-chat")

        let g = w.state.spaceGlance(w.space)
        #expect(g.working == ["lead: editing board.js"])
        #expect(g.waiting == ["eng-1: needs you"])
        #expect(g.running == 1 && g.paused == 1, "running \(g.running), paused \(g.paused)")
    }

    @Test("the tile's lines")
    func lines() {
        var g = SpaceGlance()
        #expect(SpaceGlanceView.portsLine(g) == "no ports")
        g.running = 3; g.paused = 1
        #expect(SpaceGlanceView.portsLine(g) == "3 running · 1 paused")
        g.waiting = ["eng-1: needs permission"]
        #expect(SpaceGlanceView.attentionLine(g) == "eng-1: needs permission")
        g.failed = ["build"]
        #expect(SpaceGlanceView.attentionLine(g) == "2 need you: eng-1: needs permission, build failed")
    }
}
