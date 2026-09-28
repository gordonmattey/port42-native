import Testing
import Foundation
@testable import Port42Lib

// APP-07: port.update / patch / restore replaced any port's HTML, and the new code ran with that
// port's grants. A caller holding nothing, or a remote guest holding `edit` (NAU-02), could
// rewrite a port that holds `.terminal` and borrow it. Now a writer that is not the port's own grantee must already hold everything the port runs
// with. The refusal tests fail on the ungated code (the write lands) and pass with the gate.

@Suite("Port code authority (APP-07)")
struct PortCodeAuthorityTests {

    static let original = "<title>Tool</title><div>original</div>"
    static let planted = "<title>Tool</title><script>/* planted */</script>"

    @MainActor
    func call(_ w: ParityWorld, _ canonical: String, as principal: Principal,
              _ input: [String: Any]) async throws -> BridgeValue {
        let method = try #require(w.registry[canonical])
        return try await method.run(principal, BridgeArgs(input))
    }

    /// A port the world's companion made in its space, holding `grants` through that companion.
    @MainActor
    func privilegedPort(_ w: ParityWorld, grants: Set<PortPermission>) throws -> String {
        w.state.saveGrants(grants, grantee: w.companion.id, on: .machine, zone: w.space.id)
        let created = w.state.createPort(
            type: "web", title: "Tool", html: Self.original, command: nil, cwd: nil,
            systemPrompt: nil, spaceId: w.space.id, createdBy: w.companion.id,
            createdByName: w.companion.displayName, presentation: "tiled")
        return try #require(created["id"] as? String)
    }

    /// A script on the gateway: a caller that is no companion, holding only `grants` (APP-07's rule
    /// lets a companion in the port's space write; a stranger gets the escalation rule).
    @MainActor
    func bystander(_ w: ParityWorld, grants: Set<PortPermission> = []) -> Principal {
        if !grants.isEmpty {
            w.state.saveGrants(grants, grantee: "mallory", on: .machine, zone: nil)
        }
        return Principal.peer(id: "mallory", displayName: "mallory")
    }

    @MainActor
    func html(_ w: ParityWorld, _ id: String) async throws -> BridgeValue {
        try await call(w, "port.getHtml", as: w.principal, ["id": id])
    }

    func isDenied(_ error: Error) -> Bool {
        (error as? BridgeError)?.code == BridgeErrorCode.permissionDenied.wire
    }

    @Test("a zero-grant caller cannot replace a privileged port's code with update, patch or restore")
    @MainActor
    func zeroGrantRefused() async throws {
        let w = try makeParityWorld()
        let id = try privilegedPort(w, grants: [.terminal])
        _ = try await call(w, "port.update", as: w.principal, ["id": id, "html": "<div>v2</div>"])
        let mallory = bystander(w)

        let attempts: [(String, [String: Any])] = [
            ("port.update", ["id": id, "html": Self.planted]),
            ("port.patch", ["id": id, "search": "v2", "replace": "<script>/* planted */</script>"]),
            ("port.restore", ["id": id, "version": 1]),
        ]
        for (method, args) in attempts {
            do {
                _ = try await call(w, method, as: mallory, args)
                Issue.record("\(method) let a zero-grant caller replace a privileged port's code")
            } catch {
                #expect(isDenied(error), "\(method) must refuse with permission_denied")
            }
        }
        #expect(try await html(w, id) == .string("<div>v2</div>"), "the port's code must be unchanged")
    }

    @Test("the refusal names what the writer is missing")
    @MainActor
    func refusalNamesMissing() async throws {
        let w = try makeParityWorld()
        let id = try privilegedPort(w, grants: [.terminal, .screen])
        let mallory = bystander(w, grants: [.screen])
        do {
            _ = try await call(w, "port.update", as: mallory, ["id": id, "html": Self.planted])
            Issue.record("a caller missing .terminal replaced the port's code")
        } catch let e as BridgeError {
            #expect(e.details["missing"] == "terminal")
        }
    }

    @Test("the port's author may always change its code")
    @MainActor
    func authorAllowed() async throws {
        let w = try makeParityWorld()
        let id = try privilegedPort(w, grants: [.terminal])
        _ = try await call(w, "port.update", as: w.principal, ["id": id, "html": Self.planted])
        #expect(try await html(w, id) == .string(Self.planted))
    }

    @Test("a caller already holding every grant the port runs with gains nothing, so may write")
    @MainActor
    func supersetAllowed() async throws {
        let w = try makeParityWorld()
        let id = try privilegedPort(w, grants: [.terminal])
        let peer = bystander(w, grants: [.terminal, .clipboard])
        _ = try await call(w, "port.update", as: peer, ["id": id, "html": Self.planted])
        #expect(try await html(w, id) == .string(Self.planted))
    }

    @Test("a port holding nothing stays open to anyone who can see it")
    @MainActor
    func ungrantedPortOpen() async throws {
        let w = try makeParityWorld()
        let id = try privilegedPort(w, grants: [])
        _ = try await call(w, "port.update", as: bystander(w), ["id": id, "html": Self.planted])
        #expect(try await html(w, id) == .string(Self.planted))
    }

    @Test("a remote guest holding edit cannot replace a privileged port's code (NAU-02)")
    @MainActor
    func remoteGuestRefused() async throws {
        let w = try makeParityWorld()
        let id = try privilegedPort(w, grants: [.terminal])
        let guest = Principal.remote(peer: "peer-guest", displayName: "guest")
        do {
            _ = try await call(w, "port.update", as: guest, ["id": id, "html": Self.planted])
            Issue.record("a remote guest replaced the code of a port holding .terminal")
        } catch {
            #expect(isDenied(error))
        }
        #expect(try await html(w, id) == .string(Self.original))
    }

    @Test("the person may always change a port's code")
    @MainActor
    func humanAllowed() async throws {
        let w = try makeParityWorld()
        let id = try privilegedPort(w, grants: [.terminal])
        let human = Principal.human(id: "alice", displayName: "Alice", spaceId: w.space.id)
        _ = try await call(w, "port.update", as: human, ["id": id, "html": Self.planted])
        #expect(try await html(w, id) == .string(Self.planted))
    }

    // MARK: - Companions in the port's own space (APP-07, GM's rule for 1.0.1)

    /// A companion of the person, registered, acting in `spaceId`.
    @MainActor
    func companion(_ w: ParityWorld, _ name: String, in spaceId: String? = nil) throws -> Principal {
        let a = AgentConfig.createCommand(ownerId: w.state.currentUser!.id, displayName: name, command: "claude",
                                          systemPrompt: nil, trigger: .mentionOnly)
        try w.state.db.saveAgent(a)
        w.state.companions.append(a)
        return .companion(id: a.id, displayName: name, spaceId: spaceId ?? w.space.id)
    }

    @Test("a companion in the port's own space may change it, whatever it holds")
    @MainActor
    func sameSpaceCompanionMayWrite() async throws {
        let w = try makeParityWorld()
        let id = try privilegedPort(w, grants: [.microphone])
        let eng = try companion(w, "eng-1")
        _ = try await call(w, "port.update", as: eng, ["id": id, "html": Self.planted])
        #expect(try await html(w, id) == .string(Self.planted))
    }

    @Test("a companion working through its own terminal in the port's space may change it too")
    @MainActor
    func sameSpaceTerminalMayWrite() async throws {
        let w = try makeParityWorld()
        let id = try privilegedPort(w, grants: [.microphone])
        let eng = try companion(w, "eng-1")
        var config = TerminalPortConfig(command: "/bin/zsh", args: [], startupCommand: "claude", cwd: "/tmp",
                                        spaceId: w.space.id, spaceName: "project", companionName: "eng-1",
                                        createdBy: "u", companionPrompt: "")
        config.companionId = eng.id
        let json = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        let panelId = w.state.portWindows.addTiledTerminalPanel(configJSON: json, spaceId: w.space.id,
                                                                createdBy: eng.id, title: "eng-1")
        w.state.terminalClientPanels["child-eng-1"] = panelId
        let terminal = Principal.peer(id: "child-eng-1", displayName: "eng-1")
        _ = try await call(w, "port.update", as: terminal, ["id": id, "html": Self.planted])
        #expect(try await html(w, id) == .string(Self.planted))
    }

    @Test("a companion from another space is refused while the port holds a grant it lacks")
    @MainActor
    func otherSpaceCompanionRefused() async throws {
        let w = try makeParityWorld()
        let id = try privilegedPort(w, grants: [.microphone])
        let visitor = try companion(w, "visitor", in: "elsewhere")
        do {
            _ = try await call(w, "port.update", as: visitor, ["id": id, "html": Self.planted])
            Issue.record("a companion from another space rewrote the port")
        } catch { #expect(isDenied(error)) }
        #expect(try await html(w, id) == .string(Self.original))
    }

    @Test("a port's page is no companion, even in the same space")
    @MainActor
    func pageIsNoCompanion() async throws {
        let w = try makeParityWorld()
        let id = try privilegedPort(w, grants: [.microphone])
        let eng = try companion(w, "eng-1")
        // A page of a port the engineer made runs AS the engineer, but it is a page, not the companion.
        let page = Principal.port(id: eng.id, displayName: "eng-1", spaceId: w.space.id, portId: "page-1")
        await #expect(throws: BridgeError.self) {
            _ = try await call(w, "port.update", as: page, ["id": id, "html": Self.planted])
        }
    }
}
