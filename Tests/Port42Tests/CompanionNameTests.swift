import Testing
import Foundation
@testable import Port42Lib

// A companion's name is kept exactly as typed; a mention escapes what it cannot carry, as a URL does
// (GM, 2026-09-26: no hyphen folding). Before: `app dev` was stored as typed, its terminal was named
// `app-dev`, and neither `@app dev` nor `@app-dev` reached it. A rename left the live terminal under
// the old name, and the next mention spawned a second one.
@Suite("Companion names and mentions")
@MainActor
struct CompanionNameTests {

    @Test("a mention escapes what it cannot carry; a plain name is unchanged")
    func encode() {
        #expect(CompanionName.mention("scout") == "@scout")
        #expect(CompanionName.mention("claude-code") == "@claude-code")
        #expect(CompanionName.mention("app dev") == "@app%20dev")
        #expect(CompanionName.mention("teleport: main") == "@teleport%3A%20main")
        #expect(CompanionName.mention("146") == "@%3146", "a mention must start with a letter or an escape")
        #expect(CompanionName.mention("café") == "@caf%C3%A9")
    }

    @Test("the parser decodes an escaped mention back to the name, and still ignores emails")
    func decode() {
        for name in ["scout", "app dev", "teleport: main", "146", "café", "a-b c"] {
            #expect(MentionParser.extractMentions(from: "hi \(CompanionName.mention(name)) there") == ["@\(name)"], "\(name)")
        }
        #expect(MentionParser.extractMentions(from: "@app dev") == ["@app"], "an unescaped space still ends the mention")
        #expect(MentionParser.extractMentions(from: "mail gordon@x.com") == [])
        #expect(MentionParser.extractMentions(from: "100%20off @scout") == ["@scout"])
    }

    @Test("autocomplete completes to the escaped mention and matches an escaped query")
    func autocomplete() {
        #expect(ChatRouting.complete("ask @ap", with: "app dev") == "ask @app%20dev ")
        let c = AgentConfig.createCommand(ownerId: "o", displayName: "app dev", command: "claude", systemPrompt: nil, trigger: .mentionOnly)
        #expect(MentionParser.autocomplete(query: "@app%20d", agents: [c]).count == 1)
        #expect(ChatRouting.mentionQuery(in: "ask @app%20d") == "app%20d")
    }

    func person(_ w: ParityWorld) -> Principal { .human(id: w.state.currentUser!.id, displayName: "Alice", spaceId: w.space.id) }

    func create(_ w: ParityWorld, _ name: String) async throws -> AgentConfig {
        _ = try await w.state.runBridgeMethod("companions.create", principal: person(w),
                                              args: BridgeArgs(["name": name, "agent": "claude", "runs": "hidden", "space_id": w.space.id]),
                                              pregrant: [.terminal])
        return try #require(w.state.companions.first { $0.displayName == name })
    }

    func terminals(_ w: ParityWorld, _ c: AgentConfig) -> [PortPanel] {
        w.state.portWindows.panels.filter { $0.terminalConfig?.companionId == c.id }
    }

    @Test("a name with a space is kept as typed, its terminal carries it, and the escaped mention reaches it")
    func spaceName() async throws {
        let w = try makeParityWorld()
        let c = try await create(w, "app dev")
        #expect(terminals(w, c).map { $0.terminalConfig!.companionName } == ["app dev"], "the terminal must carry the name as typed")
        _ = try w.state.postToChat(key: w.space.id, text: "\(CompanionName.mention("app dev")) hello", from: person(w))
        #expect(w.state.chatReplyTargets["app dev"] == w.space.id, "the escaped mention did not reach 'app dev'")
        #expect(terminals(w, c).count == 1)
    }

    @Test("a rename reaches the live terminal: the new name routes to it, no second terminal, and the old name is free")
    func rename() async throws {
        let w = try makeParityWorld()
        var c = try await create(w, "scout")
        let before = terminals(w, c).map(\.id)
        #expect(before.count == 1)
        c.displayName = "ranger"
        w.state.updateCompanion(c)
        _ = try w.state.postToChat(key: w.space.id, text: "@ranger hello", from: person(w))
        #expect(terminals(w, c).map(\.id) == before, "a mention after a rename spawned a second terminal")
        #expect(w.state.chatReplyTargets["ranger"] == w.space.id)
        let panel = try #require(terminals(w, c).first)
        #expect(w.state.currentName(of: panel.terminalConfig!) == "ranger")
        #expect(panel.title == "ranger", "the tile keeps the old name")
    }

    @Test("a rename onto another companion's name is refused")
    func renameClash() async throws {
        let w = try makeParityWorld()
        _ = try await create(w, "scout")
        var r = try await create(w, "ranger")
        r.displayName = "Scout"
        w.state.updateCompanion(r)
        #expect(w.state.companions.first { $0.id == r.id }?.displayName == "ranger")
    }
}
