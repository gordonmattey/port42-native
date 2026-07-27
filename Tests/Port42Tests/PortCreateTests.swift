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
    @MainActor
    func portCreateRegistered() throws {
        let names = try generatedToolList().compactMap { $0["name"] as? String }
        #expect(names.contains("port_create"))
    }

    @Test("port_create needs no permission (ungated)")
    @MainActor
    func portCreateUngated() throws {
        let w = try makeParityWorld()
        #expect(try #require(w.registry["port.create"]).permission == nil)
    }

    @Test("port.create bridge method needs no permission (ungated)")
    @MainActor func portCreateBridgeUngated() throws {
        #expect(try registryPermission("port.create") == nil)
    }

    // MARK: - Web ports render inline + auto-play (any caller)

    @Test("web port.create renders inline (a fence) and auto-activates — regardless of the inline flag")
    @MainActor
    func webRendersInlineAndAutoPlays() throws {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let space = Space.create(name: "general")
        try db.saveSpace(space)
        let spaceId = space.id

        // Default presentation ("inline") → a web port renders inline in chat and auto-plays.
        let result = state.createPort(type: "web", title: "Hi", html: "<title>Hi</title><div/>",
                                      command: nil, args: [], cwd: nil, systemPrompt: nil, env: [:],
                                      spaceId: spaceId, createdBy: nil, createdByName: "echo",
                                      presentation: "inline")
        let id = try #require(result["id"] as? String)
        #expect(result["error"] == nil)

        let msg = try #require(try db.getMessages(spaceId: spaceId).first(where: { $0.id == id }))
        // A fence (renders inline + syncs), NOT a window-only [port:id] card.
        #expect(msg.content.contains("```port"))
        #expect(ChatEntry(id: msg.id, senderName: msg.senderName, content: msg.content).webPortInfo == nil)
        // Marked to auto-activate so it plays immediately instead of as a collapsed card.
        #expect(state.pendingPortActivationId == id)
    }
    // MARK: - browser (GM 2026-07-27: every port type through one door)

    @Test("type:\"browser\" is accepted and needs a url")
    func browserValidates() {
        #expect(PortCreateValidation.validate(type: "browser", html: nil, command: nil,
                                              url: "https://example.com")
                == .ok(.browser(url: "https://example.com")))

        // `browser` was rejected outright until 2026-07-27, while being a first-class port type with
        // its own portType, webview config, navigation delegate and tile chrome, creatable ONLY from
        // the dock. That contradicted the unified API's claim that a human and an agent reach the
        // same surfaces through one bridge.
        guard case .error(let msg) = PortCreateValidation.validate(type: "browser", html: nil,
                                                                   command: nil, url: "  ") else {
            Issue.record("a blank url must be rejected"); return
        }
        #expect(msg.contains("requires non-empty 'url'"))
    }

    @Test("a browser url may arrive as `html`, the field the panel stores it in")
    func browserAcceptsHtmlAsFallback() {
        // A caller reading the stored panel shape would reasonably reach for `html`; rejecting that
        // would be a papercut with no upside.
        #expect(PortCreateValidation.validate(type: "browser", html: "https://example.com",
                                              command: nil, url: nil)
                == .ok(.browser(url: "https://example.com")))
    }

    @Test("type:\"chat\" is accepted and needs no payload")
    func chatValidates() {
        #expect(PortCreateValidation.validate(type: "chat", html: nil, command: nil, url: nil)
                == .ok(.chat))
        // A space has exactly one chat and `space_id` says which, so stray fields are tolerated
        // rather than rejected: pedantry with no upside.
        #expect(PortCreateValidation.validate(type: "chat", html: "ignored", command: nil, url: nil)
                == .ok(.chat))
    }

    @Test("revealing a chat brings it back from DOCKED, not just from parked")
    @MainActor
    func revealChatUndocksIt() throws {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let space = Space.create(name: "s")
        try db.saveSpace(space)
        state.spaces = [space]
        state.portWindows.switchToSpace(space.id, spaceName: space.name)

        let chat = try #require(state.portWindows.panels.first(where: { $0.isChatPort }))
        state.portWindows.minimize(chat.id)
        #expect(state.portWindows.panels.first(where: { $0.isChatPort })?.isBackground == true)

        state.portWindows.revealChat(spaceId: space.id, spaceName: space.name)

        // `isBackground` is a SEPARATE flag from `presentation`, and revealChat cleared only the
        // latter until 2026-07-27. A docked chat stayed docked, including for the dock's own chat
        // button, whose sole purpose is reopening it. Found by exposing chat through port.create.
        let after = try #require(state.portWindows.panels.first(where: { $0.isChatPort }))
        #expect(after.isBackground == false, "a docked chat must come back")
        #expect(after.presentation == "tiled")
    }

    @Test("the rejection message names every type it accepts")
    func unknownTypeNamesAllThree() {
        guard case .error(let msg) = PortCreateValidation.validate(type: "hologram", html: nil,
                                                                   command: nil, url: nil) else {
            Issue.record("unknown type must be rejected"); return
        }
        // A caller told "expected web or terminal" would conclude browser ports are not creatable,
        // which is exactly the wrong belief this change exists to remove.
        for t in ["web", "terminal", "browser", "chat"] { #expect(msg.contains(t), "message omits \(t)") }
    }
}
