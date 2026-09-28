import Testing
import Foundation
@testable import Port42Lib

/// A turn a restart cut off is picked up again (hit list 38, GM 2026-09-28: after an update or a crash,
/// companions sat idle until told to carry on). Presence is written down as turns start and end, so a
/// crash leaves it accurate; a quit does not wipe it; the next launch hands each turn back.
@Suite("Restart pickup")
@MainActor
struct RestartPickupTests {

    func terminalCompanion(_ w: ParityWorld, _ name: String, existing: AgentConfig? = nil) throws -> (AgentConfig, String) {
        var a = existing ?? AgentConfig.createCommand(ownerId: w.state.currentUser!.id, displayName: name, command: "claude",
                                                      systemPrompt: nil, trigger: .mentionOnly)
        a.openInTerminal = true
        if existing == nil { try w.state.db.saveAgent(a) }
        w.state.companions = [a]
        let panelId = try #require(w.state.spawnNativeTerminalPort(command: "true", cwd: NSTemporaryDirectory(), spaceId: w.space.id,
                                                                  title: name, companionName: name, companionId: a.id,
                                                                  systemPrompt: nil, postCard: false))
        return (a, panelId)
    }

    @Test("a turn is written down while it runs and gone when it ends; another machine's companions are not")
    func recordFollowsPresence() throws {
        let w = try makeParityWorld()
        w.state.presence.received("alpha", in: "chat-1")
        w.state.presence.update("alpha", to: .working)
        #expect(try w.state.db.turnsInFlight().map { "\($0.companion) \($0.chat)" } == ["alpha chat-1"])
        w.state.presence.setRemote("tile-chat", [ChatPresence(name: "host-echo", state: .working, since: Date())])
        #expect(try w.state.db.turnsInFlight().map(\.companion) == ["alpha"], "a host's companion was recorded as ours")
        w.state.presence.done("alpha")
        #expect(try w.state.db.turnsInFlight().isEmpty, "a finished turn stayed on the record")
    }

    @Test("quitting does not wipe what was in flight, though the sessions end as it quits")
    func quitKeepsTheRecord() throws {
        let w = try makeParityWorld()
        w.state.presence.received("alpha", in: "chat-1")
        w.state.quitting = true
        w.state.presence.done("alpha")                     // the session ends because the app is quitting
        #expect(try w.state.db.turnsInFlight().map(\.companion) == ["alpha"])
    }

    @Test("the next launch hands the turn back: Port42's own line, the reply bound for the chat that asked")
    func launchResumes() throws {
        let w = try makeParityWorld()
        let (alpha, _) = try terminalCompanion(w, "alpha")
        w.state.presence.received("alpha", in: "chat-1")   // then a crash: nothing clears it

        let next = AppState(db: w.state.db)                  // the next launch, on the same data
        next.currentUser = w.state.currentUser
        next.spaces = [w.space]
        _ = try terminalCompanion(ParityWorld(state: next, companion: w.companion, space: w.space), "alpha", existing: alpha)
        #expect(next.turnsCutOff.map(\.companion) == ["alpha"], "the launch did not read what was cut off")
        next.pendingTerminalInjections = [:]
        next.resumeTurnsCutOff()

        let queued = next.pendingTerminalInjections["alpha"] ?? []
        let injected = queued.first ?? ""
        #expect(queued.count == 1, "the turn was not handed back once: \(queued)")
        #expect(ChatRouting.isInjectedLine(injected) && injected.contains("Port42 restarted"),
                "the resume line is not Port42's own: \(injected)")
        #expect(next.chatReplyTargets["alpha"] == "chat-1", "the reply is not bound for the chat that asked")
        #expect(next.presence.entries("chat-1").map(\.name) == ["alpha"], "presence does not show it back on the message")
        #expect(next.turnsCutOff.isEmpty)
        withExtendedLifetime(w.state) {}
    }

    @Test("with nothing in flight, a launch hands nothing back")
    func quietLaunch() throws {
        let w = try makeParityWorld()
        let next = AppState(db: w.state.db)
        next.resumeTurnsCutOff()
        #expect(next.pendingTerminalInjections.isEmpty && next.chatReplyTargets.isEmpty)
    }
}
