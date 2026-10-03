import Testing
import Foundation
@testable import Port42Lib

// Two instances, an agent on each side, on one shared port: Phase 4, UX (docs/plan-two-agents-one-port.md).

@Suite("two agents: bring a companion, the shared chat", .serialized)
@MainActor
struct TwoAgentsUXTests {
    static let me = "25njqamcweflpvkl73j4szahhihoc4xt3ktcgjnpaingr5yhkena"
    static let host = "aaaqeayeaudaocajbifqydiob4ibceqtcqkrmfyydenbwha5dypq"

    func tileWorld() throws -> (ParityWorld, String) {
        let w = try makeParityWorld()
        w.state.door.receive(#"{"type":"welcome","sender_id":"host","self_peer":"\#(Self.me)"}"#)
        w.state.door.sendOverride = { _ in }
        let made = w.state.createPort(type: "web", title: "board", html: "<title>board</title>", command: nil, cwd: nil,
                                      systemPrompt: nil, spaceId: w.space.id, createdBy: nil, createdByName: nil)
        let tile = try #require(made["id"] as? String)
        var row = DatabaseService.RemotePortRow(peerKey: Self.host, portKey: "P", title: "Shared board", rights: [.see, .use, .edit],
                                                relays: ["wss://relay.test/v1"], hostName: "Gordon")
        row.knownAs = "gordon11"
        try w.state.db.upsertRemotePort(row)
        try w.state.db.setRemotePortTile(peerKey: Self.host, portKey: "P", localPort: tile)
        return (w, tile)
    }

    @Test("bringing a companion onto a tile makes it a member and tells it where it is and to answer in the port's chat")
    func bringOnto() throws {
        let (w, tile) = try tileWorld()
        var bram = AgentConfig.createCommand(ownerId: w.state.currentUser!.id, displayName: "bram", command: "claude",
                                             systemPrompt: nil, trigger: .mentionOnly)
        bram.openInTerminal = true
        try w.state.db.saveAgent(bram)
        w.state.companions.append(bram)
        _ = try #require(w.state.spawnNativeTerminalPort(command: "true", cwd: NSTemporaryDirectory(), spaceId: w.space.id,
                                                         title: "bram", companionName: "bram", companionId: bram.id,
                                                         systemPrompt: nil, postCard: false))
        let key = try #require(w.state.mirrorChatKey(tile))
        #expect(w.state.sharedChatLabel(key)?.contains("Gordon") == true, "the tile's chat does not say it is shared")
        w.state.pendingTerminalInjections = [:]
        w.state.chatReplyTargets = [:]
        w.state.bringOnto(tile: tile, companions: [bram])
        #expect(w.state.isPortMember(bram.id, port: key), "the companion was not brought onto the tile")
        #expect(w.state.chatReplyTargets["bram"] == key, "the companion was not told, or its reply would not reach the port's chat")
        let told = (w.state.pendingTerminalInjections.values.flatMap { $0 }).joined()
        #expect(told.contains("Shared board") && told.contains("reply in that chat") && told.contains("shared from Gordon"),
                "the companion was not told where it is: \(told)")
        #expect(w.state.sharedChatLabel(key)?.contains("bram") == true, "the shared chat does not list the companion")
    }

    @Test("a port this machine shares says so in its chat")
    func hostSideLabel() throws {
        let w = try makeParityWorld()
        let made = w.state.createPort(type: "web", title: "board", html: "<title>board</title>", command: nil, cwd: nil,
                                      systemPrompt: nil, spaceId: w.space.id, createdBy: nil, createdByName: nil)
        let key = try #require(made["id"] as? String)
        #expect(w.state.sharedChatLabel(key) == nil, "an unshared port's chat says it is shared")
        w.state.grantRemoteRights([.see, .use], to: "guestpeer", onPort: key)
        #expect(w.state.sharedChatLabel(key)?.hasPrefix("shared chat with") == true)
    }
}
