import Testing
import Foundation
@testable import Port42Lib

// APP-10: a zero-grant caller enumerated every port in every space and read its source, history,
// live DOM and console. The read verbs now answer only for ports in the space the caller acts in.
// Each test fails on the unscoped code (the other space's port is listed and readable) and passes
// with the scope.

@Suite("Port read scope (APP-10)")
struct PortReadScopeTests {

    @MainActor
    func call(_ w: ParityWorld, _ canonical: String, as principal: Principal,
              _ input: [String: Any]) async throws -> BridgeValue {
        let method = try #require(w.registry[canonical])
        return try await method.run(principal, BridgeArgs(input))
    }

    @MainActor
    func makePort(_ w: ParityWorld, title: String, spaceId: String) throws -> String {
        let created = w.state.createPort(
            type: "web", title: title, html: "<title>\(title)</title><div>secret</div>", command: nil,
            cwd: nil, systemPrompt: nil, spaceId: spaceId, createdBy: w.companion.id,
            createdByName: w.companion.displayName, presentation: "tiled")
        return try #require(created["id"] as? String)
    }

    func ids(_ listed: BridgeValue) -> [String] {
        guard case let .array(entries) = listed else { return [] }
        return entries.compactMap { e in
            guard case let .object(o) = e, case let .string(id)? = o["id"] else { return nil }
            return id
        }
    }

    func isNotFound(_ error: Error) -> Bool {
        (error as? BridgeError)?.code == BridgeErrorCode.notFound.wire
    }

    @Test("a companion lists only its own space's ports, even when it names another space")
    @MainActor
    func listScopedForCompanion() async throws {
        let w = try makeParityWorld()
        let here = try makePort(w, title: "here", spaceId: w.space.id)
        let away = try makePort(w, title: "away", spaceId: "another-space")

        let all = ids(try await call(w, "ports.list", as: w.principal, [:]))
        #expect(all.contains(here))
        #expect(!all.contains(away), "another space's port must not be enumerable")

        let named = ids(try await call(w, "ports.list", as: w.principal, ["space_id": "another-space"]))
        #expect(named.isEmpty, "space_id must not widen what the caller can see")
    }

    @Test("a port's JS cannot list another space's ports")
    @MainActor
    func listScopedForPort() async throws {
        let w = try makeParityWorld()
        let caller = try makePort(w, title: "caller", spaceId: w.space.id)
        let away = try makePort(w, title: "away", spaceId: "another-space")
        let asPort = Principal.port(id: caller, displayName: "caller", spaceId: w.space.id)

        let all = ids(try await call(w, "ports.list", as: asPort, [:]))
        #expect(all.contains(caller))
        #expect(!all.contains(away))
    }

    @Test("getHtml, history and console refuse another space's port as not_found")
    @MainActor
    func byIdReadsRefused() async throws {
        let w = try makeParityWorld()
        let away = try makePort(w, title: "away", spaceId: "another-space")

        for method in ["port.getHtml", "port.history", "port.console"] {
            do {
                _ = try await call(w, method, as: w.principal, ["id": away])
                Issue.record("\(method) read a port in another space")
            } catch {
                #expect(isNotFound(error), "\(method) must answer not_found, not confirm the port exists")
            }
        }
        // Addressing it by title is the same port, so the same answer.
        await #expect(throws: BridgeError.self) {
            _ = try await call(w, "port.getHtml", as: w.principal, ["id": "away"])
        }
    }

    @Test("getDom refuses another space's port before touching its webview")
    @MainActor
    func getDomRefused() async throws {
        let w = try makeParityWorld()
        let away = try makePort(w, title: "away", spaceId: "another-space")
        do {
            _ = try await call(w, "port.getDom", as: w.principal, ["id": away])
            Issue.record("port.getDom read a port in another space")
        } catch {
            #expect(isNotFound(error))
        }
    }

    @Test("the same reads still work inside the caller's own space")
    @MainActor
    func ownSpaceReadable() async throws {
        let w = try makeParityWorld()
        let here = try makePort(w, title: "here", spaceId: w.space.id)
        let html = try await call(w, "port.getHtml", as: w.principal, ["id": here])
        #expect(html == .string("<title>here</title><div>secret</div>"))
        guard case .array = try await call(w, "port.history", as: w.principal, ["id": here]) else {
            Issue.record("expected history array"); return
        }
        guard case .object = try await call(w, "port.console", as: w.principal, ["id": here]) else {
            Issue.record("expected console object"); return
        }
    }

    @Test("a caller with no space of its own sees no spaced port, not everywhere")
    @MainActor
    func spacelessPortRefused() async throws {
        let w = try makeParityWorld()
        let away = try makePort(w, title: "away", spaceId: "another-space")
        let spaceless = Principal.port(id: "p-nowhere", displayName: "nowhere", spaceId: nil)
        #expect(!ids(try await call(w, "ports.list", as: spaceless, [:])).contains(away))
        await #expect(throws: BridgeError.self) {
            _ = try await call(w, "port.getHtml", as: spaceless, ["id": away])
        }
    }

    @Test("a gateway caller and the human keep machine-wide reads (not scoped by APP-10)")
    @MainActor
    func peerAndHumanUnscoped() async throws {
        let w = try makeParityWorld()
        let away = try makePort(w, title: "away", spaceId: "another-space")
        let peer = Principal.peer(id: "client-1", displayName: "CLI")
        let human = Principal.human(id: "alice", displayName: "Alice", spaceId: w.space.id)
        #expect(ids(try await call(w, "ports.list", as: peer, [:])).contains(away))
        #expect(try await call(w, "port.getHtml", as: human, ["id": away])
                == .string("<title>away</title><div>secret</div>"))
    }
}
