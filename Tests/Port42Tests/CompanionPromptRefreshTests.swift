import Testing
import Foundation
@testable import Port42Lib

/// A companion terminal launches with TODAY's instructions, not the ones stored when it was made
/// (2026-09-27): prod's stored prompts still told companions to post with `messages.send`, a method
/// long gone, so a relaunched companion followed them and its posts vanished.
@Suite("A companion's instructions are current at launch")
@MainActor
struct CompanionPromptRefreshTests {
    @Test("a relaunched companion terminal gets the prompt baked now, with its own brief")
    func rebakedAtLaunch() throws {
        let w = try makeParityWorld()
        var b = AgentConfig.createCommand(ownerId: try #require(w.state.currentUser?.id), displayName: "beta",
                                          command: "claude", systemPrompt: "BETA-BRIEF", trigger: .mentionOnly)
        b.openInTerminal = true
        try w.state.db.saveAgent(b)
        w.state.companions = try w.state.db.getAllAgents()
        let panelId = try #require(w.state.spawnNativeTerminalPort(
            command: "true", cwd: NSTemporaryDirectory(), spaceId: w.space.id, title: "beta",
            companionName: "beta", companionId: b.id, systemPrompt: "BETA-BRIEF", postCard: false))
        // What an old build stored with the terminal.
        let idx = try #require(w.state.portWindows.panels.firstIndex { $0.id == panelId })
        var config = try #require(w.state.portWindows.panels[idx].terminalConfig)
        config.companionPrompt = "You are beta. POST with messages.send({text, senderName, space_id})."
        w.state.portWindows.panels[idx].html = String(data: try JSONEncoder().encode(config), encoding: .utf8)!
        let controller = try #require(w.state.makeTerminalController(for: w.state.portWindows.panels[idx]))
        let prompt = controller.config.companionPrompt
        #expect(!prompt.contains("messages.send"), "the stored, stale instructions were used")
        #expect(prompt.contains("BETA-BRIEF"), "the companion's own brief is missing")
        #expect(prompt == w.state.bakeCompanionPrompt(name: "beta", spaceId: w.space.id, systemPrompt: "BETA-BRIEF"))
        controller.teardown()
        withExtendedLifetime(w.state) {}
    }
}
