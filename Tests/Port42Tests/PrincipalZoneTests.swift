import Testing
import Foundation
@testable import Port42Lib

/// **One companion, one grantee, one zone, on every surface** (APP-15).
///
/// A companion reached Port42 three ways: its in-app tool use (companion id, its space), the ports
/// it created (companion id, the port's space), and the terminal Port42 spawned for it, which called
/// through the gateway as `child-<companion>-<space>` in the GLOBAL zone. Same actor, two grant
/// buckets, so the user was asked twice for one capability.
@Suite("Principal zone rule")
struct PrincipalZoneTests {

    let companion = "agent-echo"
    let space = "space-1"

    @Test("a companion's terminal, tool use and port authorize as one grantee in one zone")
    func oneGranteeAcrossSurfaces() {
        let childId = ClientRegistry.childId(companionId: companion, spaceId: space)
        let child = Principal.forGatewayClient(
            clientId: childId, displayName: "echo",
            spawn: .init(companionId: companion, spaceId: space))
        let tool = Principal.forCompanionTool(createdBy: companion, createdByName: "echo", spaceId: space)
        let port = Principal.forPortBridge(createdBy: companion, messageId: "msg-1",
                                           instanceFallback: "fallback", title: "a port", spaceId: space)

        #expect(child.id == companion)
        #expect(Set([child.id, tool.id, port.id]).count == 1)
        #expect(Set([child.zone, tool.zone, port.zone]).count == 1)
        #expect(child.zone == space)
    }

    @Test("a spawned terminal acts in its spawn space, and its grants live there")
    func childKeepsGatewayDefaults() {
        let child = Principal.forGatewayClient(
            clientId: "child-x", displayName: "echo",
            spawn: .init(companionId: companion, spaceId: space))
        #expect(child.kind == .peer)
        #expect(child.spaceId == space, "it acts in the space it was spawned into, like its companion")
        #expect(child.zone == space)
        #expect(child.scopeDescription.contains("while working in this space"))
    }

    @Test("an ad-hoc terminal stays itself, zoned to its space; a paired client stays global")
    func noCompanionNoMerge() {
        let adHoc = Principal.forGatewayClient(
            clientId: "term-panel-1", displayName: "Terminal in Home",
            spawn: .init(companionId: nil, spaceId: space))
        #expect(adHoc.id == "term-panel-1")
        #expect(adHoc.zone == space)

        let emptyCompanion = Principal.forGatewayClient(
            clientId: "term-panel-2", displayName: "t", spawn: .init(companionId: "", spaceId: space))
        #expect(emptyCompanion.id == "term-panel-2")

        let paired = Principal.forGatewayClient(clientId: "claude-code", displayName: "Claude Code",
                                                spawn: nil)
        #expect(paired.id == "claude-code")
        #expect(paired.zone == nil)
    }

    @Test("a grant given to the companion in its space is found by its terminal, with no second ask")
    @MainActor
    func grantIsShared() throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        let tool = Principal.forCompanionTool(createdBy: companion, createdByName: "echo", spaceId: space)
        appState.saveGrants([.clipboard], grantee: tool.id, on: .machine, zone: tool.zone)

        let child = Principal.forGatewayClient(
            clientId: ClientRegistry.childId(companionId: companion, spaceId: space),
            displayName: "echo", spawn: .init(companionId: companion, spaceId: space))
        #expect(appState.grants(grantee: child.id, on: .machine, zone: child.zone).contains(.clipboard))

        // And not leaked to the same companion's terminal in ANOTHER space.
        let elsewhere = Principal.forGatewayClient(
            clientId: ClientRegistry.childId(companionId: companion, spaceId: "space-2"),
            displayName: "echo", spawn: .init(companionId: companion, spaceId: "space-2"))
        #expect(appState.grants(grantee: elsewhere.id, on: .machine, zone: elsewhere.zone).isEmpty)
    }

    @Test("a spawned terminal reads only its spawn space; an unbound child reads no space; a paired client reads all")
    @MainActor
    func readScopeFollowsTheZone() throws {
        let w = try makeParityWorld()
        let other = try #require(w.state.createSpace(name: "elsewhere", select: false))

        let child = Principal.forGatewayClient(
            clientId: ClientRegistry.childId(companionId: w.companion.id, spaceId: w.space.id),
            displayName: "echo", spawn: .init(companionId: w.companion.id, spaceId: w.space.id))
        #expect(w.state.canRead(portInSpace: w.space.id, by: child))
        #expect(!w.state.canRead(portInSpace: other.id, by: child))

        // A child client whose terminal is gone: its row says .child, and it has no binding.
        try w.state.db.upsertClient(id: "child-orphan", name: "orphan", kind: Port42Client.Kind.child.rawValue)
        let orphan = Principal.forGatewayClient(clientId: "child-orphan", displayName: "orphan", spawn: nil)
        #expect(!w.state.canRead(portInSpace: w.space.id, by: orphan), "never everywhere")

        let paired = Principal.forGatewayClient(clientId: "claude-code", displayName: "Claude Code", spawn: nil)
        #expect(w.state.canRead(portInSpace: other.id, by: paired))
    }

    @Test("a companion's terminal stores shared data in its own space; a companion elsewhere cannot read it")
    @MainActor
    func sharedStorageLandsInTheSpawnSpace() async throws {
        let w = try makeParityWorld()
        let other = try #require(w.state.createSpace(name: "elsewhere", select: false))
        let terminal = Principal.forGatewayClient(
            clientId: ClientRegistry.childId(companionId: w.companion.id, spaceId: w.space.id),
            displayName: w.companion.displayName,
            spawn: .init(companionId: w.companion.id, spaceId: w.space.id))

        // Found live: this was refused with "storage requires space context".
        var refused: String?
        do {
            _ = try await w.state.runBridgeMethod("storage.set", principal: terminal,
                                                  args: BridgeArgs(["key": "x", "value": "y", "shared": true]))
        } catch let e as BridgeError { refused = e.message }
        #expect(refused == nil, "a companion's terminal must be able to store in its space")
        #expect(try w.state.db.getPortStorage(key: "x", scope: w.space.id, creatorId: "__shared__") == "y",
                "it must land in its own space's shared bucket")

        func read(as p: Principal) async throws -> BridgeValue? {
            guard case let .object(o) = try await w.state.runBridgeMethod(
                "storage.get", principal: p, args: BridgeArgs(["key": "x", "shared": true])) else { return nil }
            return o["value"]
        }
        let sameSpace = Principal.companion(id: "sage", displayName: "sage", spaceId: w.space.id)
        let elsewhere = Principal.companion(id: "sage", displayName: "sage", spaceId: other.id)
        #expect(try await read(as: sameSpace) == .string("y"))
        #expect(try await read(as: elsewhere) == .null, "another space's companion read it")
    }

    @Test("a companion's terminal is still recognized as its companion: chat author, watches, code authority")
    @MainActor
    func terminalIsItsCompanion() async throws {
        let w = try makeParityWorld()
        let terminal = Principal.forGatewayClient(
            clientId: ClientRegistry.childId(companionId: w.companion.id, spaceId: w.space.id),
            displayName: w.companion.displayName,
            spawn: .init(companionId: w.companion.id, spaceId: w.space.id))

        // Its id is the companion's now, so the lookup by terminal client must not be the only way.
        #expect(w.state.companion(actingAs: terminal)?.id == w.companion.id)
        #expect(w.state.companionInSpace(terminal) == w.space.id, "APP-07 must see a companion in its space")

        _ = try await w.state.runBridgeMethod("chat.post", principal: terminal,
                                              args: BridgeArgs(["port": w.space.id, "text": "hi"]))
        let last = try #require(try w.state.db.chatEntries(chat: w.space.id, after: 0, limit: 10).last)
        #expect(last.fromKind == Principal.Kind.companion.rawValue, "its post reads as a different sender")

        // A paired client with the same id shape is not taken for a companion: only a bound terminal is.
        let paired = Principal.forGatewayClient(clientId: w.companion.id, displayName: "x", spawn: nil)
        #expect(w.state.companion(actingAs: paired) == nil)
    }

    @Test("whoami from a companion's terminal names its terminal and chat, and agrees with the principal's space")
    @MainActor
    func whoamiAgreesWithThePrincipal() async throws {
        let w = try makeParityWorld()
        var b = AgentConfig.createCommand(ownerId: try #require(w.state.currentUser?.id), displayName: "beta",
                                          command: "claude", systemPrompt: nil, trigger: .mentionOnly)
        b.openInTerminal = true
        try w.state.db.saveAgent(b)
        w.state.companions = [w.companion, b]
        let panelId = try #require(w.state.spawnNativeTerminalPort(
            command: "true", cwd: NSTemporaryDirectory(), spaceId: w.space.id, title: "beta",
            companionName: "beta", companionId: b.id, systemPrompt: nil, postCard: false))
        let udid = try #require(w.state.portWindows.panels.first { $0.id == panelId }?.udid)
        let clientId = try #require(w.state.terminalClientPanels.first { $0.value == panelId }?.key)
        // The caller the gateway builds for this terminal.
        let terminal = Principal.forGatewayClient(clientId: clientId, displayName: "beta",
                                                  spawn: w.state.spawnBindings[clientId])
        #expect(terminal.id == b.id)

        guard case let .object(o) = try await w.state.runBridgeMethod("whoami", principal: terminal, args: BridgeArgs([:])) else {
            Issue.record("whoami should return an object"); return
        }
        #expect(o["terminal_port"] == .string(udid), "whoami lost the terminal it speaks for")
        #expect(o["chat"] == .string(udid))
        #expect(o["space_id"] == .string(w.space.id))
        #expect(terminal.spaceId == w.space.id, "whoami and the principal disagree on the space")
        withExtendedLifetime(w.state) {}
    }
}
