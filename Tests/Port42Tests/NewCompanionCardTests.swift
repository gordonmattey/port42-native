import Testing
import Foundation
@testable import Port42Lib

// The new-companion card after GM's review (nautilus Phase 3.7): no pre-canned types, every field
// shown, ARGS for every CLI, RUNS in a tile or hidden, LISTENS TO this space or a port. TRIGGER went:
// it was stored and never read.
@Suite("New-companion card")
struct NewCompanionCardTests {

    @Test("a CLI companion takes its args and can run hidden; a custom command is headless, never 'hidden'")
    func fieldsBecomeTheCompanion() {
        let c = ShellNewCompanionView.makeCompanion(owner: "u", name: "scout", cli: "claude", command: "",
                                                    argsText: "--model sonnet", workingDir: " ", prompt: "",
                                                    hidden: true, secrets: ["b", "a"])
        #expect(c.command == "claude" && c.args == ["--model", "sonnet"] && c.openInTerminal)
        #expect(c.runsHidden)
        #expect(c.workingDir == nil && c.systemPrompt == nil, "blank fields must not be stored as blanks")
        #expect(c.secretNames == ["a", "b"])
        let custom = ShellNewCompanionView.makeCompanion(owner: "u", name: "bot", cli: "custom", command: " my-agent ",
                                                         argsText: "", workingDir: "", prompt: "be brief",
                                                         hidden: true, secrets: [])
        #expect(custom.command == "my-agent" && !custom.openInTerminal && !custom.runsHidden && custom.args == nil)
        #expect(custom.systemPrompt == "be brief")
    }

    @Test("runsHidden is stored, so a reopened terminal comes back hidden")
    @MainActor
    func runsHiddenStored() throws {
        let db = try DatabaseService(inMemory: true)
        let user = AppUser.createForTesting(displayName: "Alice")
        try db.saveUser(user)
        var c = AgentConfig.createCommand(ownerId: user.id, displayName: "scout", command: "claude",
                                          openInTerminal: true, trigger: .mentionOnly)
        c.runsHidden = true
        try db.saveAgent(c)
        #expect(try db.getAllAgents().first { $0.id == c.id }?.runsHidden == true)
    }

    @Test("switching RUNS in settings hides and shows the companion's live terminal")
    @MainActor
    func settingsToggleHides() throws {
        let w = try makeParityWorld(companionName: "scout")
        let config = TerminalPortConfig(command: "/bin/zsh", args: [], startupCommand: "claude", cwd: "/tmp",
                                        spaceId: w.space.id, spaceName: w.space.name, companionName: "scout",
                                        companionId: w.companion.id, createdBy: "", companionPrompt: "", env: [:], initialInput: "")
        let json = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        var panel = PortPanel(id: "t1", udid: "t1", html: json, bridge: PortBridge(appState: w.state, spaceId: w.space.id, messageId: "t1"),
                              spaceId: w.space.id, createdBy: nil, messageId: "t1", size: CGSize(width: 400, height: 300))
        panel.portType = "terminal"
        w.state.portWindows.panels.append(panel)
        w.state.setCompanionHidden(w.companion, hidden: true)
        #expect(w.state.portWindows.hiddenPanels.map(\.id) == ["t1"])
        w.state.setCompanionHidden(w.companion, hidden: false)
        #expect(w.state.portWindows.hiddenPanels.isEmpty)
    }

    @Test("no pre-canned types and no TRIGGER remain in the shell")
    func nothingDeadLeft() throws {
        let views = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Port42Lib/Views")
        for file in ["ShellView.swift", "ShellShared.swift"] {
            let src = try String(contentsOf: views.appendingPathComponent(file), encoding: .utf8)
            #expect(!src.contains("CompanionTypePreset"), "\(file) still offers pre-canned types")
            #expect(!src.contains("fieldLabel(\"TRIGGER\")") && !src.contains("label(\"TRIGGER\")"),
                    "\(file) still shows TRIGGER, which nothing reads")
        }
    }

    @Test("companions.create is the card's path: a custom companion joins the space and watches the port it was made for")
    @MainActor
    func createPath() async throws {
        let w = try makeParityWorld(companionName: "scout")
        w.state.portWindows.registerTiledPort(id: "p", html: "<title>feed</title>", spaceId: w.space.id, createdBy: nil,
                                              title: "feed", position: CGPoint(x: 40, y: 40))
        let udid = w.state.portWindows.panels.first { $0.id == "p" }!.udid
        let person = Principal.peer(id: "cli", displayName: "cli", spaceId: w.space.id)
        let run = { (args: [String: Any]) async throws -> BridgeValue in
            try await w.state.runBridgeMethod("companions.create", principal: person, args: BridgeArgs(args),
                                              pregrant: [.terminal])
        }
        _ = try await run(["name": "watcher", "agent": "custom", "command": "my-agent", "port": udid, "kinds": ["console"]])
        let c = try #require(w.state.companions.first { $0.displayName == "watcher" })
        #expect(try w.state.db.getAgentsForSpace(spaceId: w.space.id).contains { $0.id == c.id }, "it did not join the space")
        #expect(w.state.companionWatches.watches.map(\.kinds) == [["console"]])
        await #expect(throws: BridgeError.self) { _ = try await run(["name": "Watcher", "agent": "custom", "command": "x"]) }
        await #expect(throws: BridgeError.self) { _ = try await run(["name": "other", "agent": "custom", "command": "x", "port": "nope"]) }
        #expect(!w.state.companions.contains { $0.displayName == "other" }, "a refused create left a companion behind")
    }

    @Test("waking a hidden companion whose terminal is still starting does not put it on the desktop")
    @MainActor
    func hiddenStaysHidden() throws {
        let w = try makeParityWorld(companionName: "scout")
        let config = TerminalPortConfig(command: "/bin/zsh", args: [], startupCommand: "claude", cwd: "/tmp",
                                        spaceId: w.space.id, spaceName: w.space.name, companionName: "scout",
                                        companionId: w.companion.id, createdBy: "", companionPrompt: "", env: [:], initialInput: "")
        let json = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        var panel = PortPanel(id: "t1", udid: "t1", html: json, bridge: PortBridge(appState: w.state, spaceId: w.space.id, messageId: "t1"),
                              spaceId: w.space.id, createdBy: nil, messageId: "t1", size: CGSize(width: 400, height: 300))
        panel.portType = "terminal"
        w.state.portWindows.panels.append(panel)
        w.state.portWindows.minimize("t1")
        w.state.ensureTerminalLive(companion: w.companion, spaceId: w.space.id)
        #expect(w.state.portWindows.hiddenPanels.map(\.id) == ["t1"], "waking it un-hid it")
    }
}
