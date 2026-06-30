import Testing
import Foundation
@testable import Port42Lib

@Suite("Port Create")
struct PortCreateTests {

    // MARK: - Validation (pure)

    @Test("web with html resolves to .web")
    func webWithHtml() {
        #expect(PortCreateValidation.validate(type: "web", html: "<h1>hi</h1>", command: nil)
                == .ok(.web(html: "<h1>hi</h1>")))
    }

    @Test("terminal with command resolves to .terminal")
    func terminalWithCommand() {
        #expect(PortCreateValidation.validate(type: "terminal", html: nil, command: "bash")
                == .ok(.terminal(command: "bash")))
    }

    @Test("unknown type errors")
    func unknownType() {
        guard case .error = PortCreateValidation.validate(type: "bogus", html: "<h1/>", command: "bash") else {
            Issue.record("expected .error for unknown type"); return
        }
    }

    @Test("missing type errors")
    func missingType() {
        guard case .error = PortCreateValidation.validate(type: nil, html: "<h1/>", command: "bash") else {
            Issue.record("expected .error for missing type"); return
        }
    }

    @Test("web without html errors")
    func webWithoutHtml() {
        guard case .error = PortCreateValidation.validate(type: "web", html: nil, command: nil) else {
            Issue.record("expected .error for web without html"); return
        }
    }

    @Test("web with whitespace-only html errors")
    func webWithBlankHtml() {
        guard case .error = PortCreateValidation.validate(type: "web", html: "   \n ", command: nil) else {
            Issue.record("expected .error for blank html"); return
        }
    }

    @Test("terminal without command errors")
    func terminalWithoutCommand() {
        guard case .error = PortCreateValidation.validate(type: "terminal", html: nil, command: nil) else {
            Issue.record("expected .error for terminal without command"); return
        }
    }

    @Test("inputs are trimmed before resolving")
    func trimsInputs() {
        #expect(PortCreateValidation.validate(type: "terminal", html: nil, command: "  htop  ")
                == .ok(.terminal(command: "htop")))
    }

    // MARK: - Tool surface

    @Test("port_create is registered as a tool")
    func portCreateRegistered() {
        let names = ToolDefinitions.all.compactMap { $0["name"] as? String }
        #expect(names.contains("port_create"))
    }

    @Test("port_create needs no permission (ungated)")
    func portCreateUngated() {
        #expect(ToolDefinitions.permission(for: "port_create") == nil)
    }

    @Test("port.create bridge method needs no permission (ungated)")
    func portCreateBridgeUngated() {
        #expect(PortPermission.permissionForMethod("port.create") == nil)
    }

    // MARK: - Step 8: external floating web port leaves a [port:id] chat card

    @Test("external web port.create posts a [port:id] card bound to the returned id")
    @MainActor
    func externalWebPostsCard() throws {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let space = Space.create(name: "general")
        try db.saveSpace(space)
        let spaceId = space.id

        let result = state.createPort(type: "web", title: "Hi", html: "<title>Hi</title><div/>",
                                      command: nil, args: [], cwd: nil, systemPrompt: nil, env: [:],
                                      spaceId: spaceId, createdBy: nil, createdByName: "echo",
                                      inline: false)
        let portId = try #require(result["id"] as? String)
        #expect(result["error"] == nil)

        // A local-only [port:id] card referencing the floating port's id was saved.
        let msgs = try db.getMessages(spaceId: spaceId)
        let card = try #require(msgs.first(where: { ChatEntry(id: $0.id, senderName: $0.senderName, content: $0.content).webPortInfo != nil }))
        let info = ChatEntry(id: card.id, senderName: card.senderName, content: card.content).webPortInfo
        #expect(info?.id == portId)
        #expect(info?.title == "Hi")
        #expect(card.syncStatus == "local")   // not synced — floating port is local to this machine
    }

    @Test("inline web port.create posts a fence, not a [port:id] card")
    @MainActor
    func inlineWebPostsFence() throws {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let space = Space.create(name: "general")
        try db.saveSpace(space)
        let spaceId = space.id

        let result = state.createPort(type: "web", title: "Hi", html: "<div>x</div>",
                                      command: nil, args: [], cwd: nil, systemPrompt: nil, env: [:],
                                      spaceId: spaceId, createdBy: nil, createdByName: "echo",
                                      inline: true)
        let id = try #require(result["id"] as? String)
        let msgs = try db.getMessages(spaceId: spaceId)
        let msg = try #require(msgs.first(where: { $0.id == id }))
        // Inline web ports stay fence-carried (syncable, restart-safe), not a card.
        #expect(msg.content.contains("```port"))
        #expect(ChatEntry(id: msg.id, senderName: msg.senderName, content: msg.content).webPortInfo == nil)
    }
}
