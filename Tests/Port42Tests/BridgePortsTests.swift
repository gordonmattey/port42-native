import Testing
import Foundation
@testable import Port42Lib

// Phase 1, batch 3: the port read/write core (ports.list, getHtml, history, update, patch, restore,
// rename, move). GM: no backward compat, so ports.list is one array everywhere and the mutators
// return {ok}/throw. Tested directly against the intended contract. The webview/terminal-touching
// port methods (create/push/exec/manage) are a Phase-2 live-only follow-up.

@Suite("Bridge — ports (read/write core)")
struct BridgePortsTests {

    @MainActor
    func call(_ w: ParityWorld, _ canonical: String, _ input: [String: Any]) async throws -> BridgeValue {
        let method = try #require(w.registry[canonical])
        return try await method.run(w.principal, BridgeArgs(input))
    }

    @MainActor
    func makePort(_ w: ParityWorld, title: String = "Clock", html: String = "<title>Clock</title><div>hello</div>") throws -> String {
        let created = w.state.createPort(
            type: "web", title: title, html: html, command: nil, cwd: nil, systemPrompt: nil,
            spaceId: w.space.id, createdBy: w.companion.id, createdByName: w.companion.displayName,
            presentation: "tiled"
        )
        return try #require(created["id"] as? String)
    }

    @Test("ports.list returns an array of port objects (one shape everywhere)")
    @MainActor
    func portsList() async throws {
        let w = try makeParityWorld()
        let id = try makePort(w, title: "Alpha")
        let listed = try await call(w, "ports.list", [:])
        guard case let .array(items) = listed else { Issue.record("expected array"); return }
        #expect(items.count == 1)
        guard case let .object(o) = items[0] else { Issue.record("expected object entry"); return }
        #expect(o["id"] == .string(id))
        #expect(o["title"] == .string("Alpha"))
        // capabilities is always an array, never a text blob
        if case .array = o["capabilities"] {} else { Issue.record("capabilities should be an array") }
        #expect(o["status"] != nil)
    }

    @Test("ports.list capability filter excludes non-matching ports")
    @MainActor
    func portsListFilter() async throws {
        let w = try makeParityWorld()
        _ = try makePort(w)
        // a web port has no "terminal" capability, so filtering by it yields empty
        let listed = try await call(w, "ports.list", ["capabilities": ["terminal"]])
        #expect(listed == .array([]))
    }

    @Test("port.getHtml returns the current HTML; missing id throws not_found")
    @MainActor
    func getHtml() async throws {
        let w = try makeParityWorld()
        let id = try makePort(w)
        _ = try await call(w, "port.update", ["id": id, "html": "<div>v2</div>"])
        #expect(try await call(w, "port.getHtml", ["id": id]) == .string("<div>v2</div>"))
        await #expect(throws: BridgeError.self) { _ = try await call(w, "port.getHtml", ["id": "nope"]) }
    }

    @Test("port.update writes new HTML and returns {ok}")
    @MainActor
    func update() async throws {
        let w = try makeParityWorld()
        let id = try makePort(w)
        #expect(try await call(w, "port.update", ["id": id, "html": "<div>changed</div>"]) == .object(["ok": .bool(true)]))
        #expect(try await call(w, "port.getHtml", ["id": id]) == .string("<div>changed</div>"))
        await #expect(throws: BridgeError.self) { _ = try await call(w, "port.update", ["id": "nope", "html": "x"]) }
    }

    @Test("port.patch replaces the matched string; a miss throws")
    @MainActor
    func patch() async throws {
        let w = try makeParityWorld()
        let id = try makePort(w)
        _ = try await call(w, "port.update", ["id": id, "html": "<div>hello world</div>"])
        #expect(try await call(w, "port.patch", ["id": id, "search": "world", "replace": "port42"]) == .object(["ok": .bool(true)]))
        #expect(try await call(w, "port.getHtml", ["id": id]) == .string("<div>hello port42</div>"))
        await #expect(throws: BridgeError.self) {
            _ = try await call(w, "port.patch", ["id": id, "search": "absent", "replace": "x"])
        }
    }

    @Test("port.history lists versions; port.restore rolls back")
    @MainActor
    func historyAndRestore() async throws {
        let w = try makeParityWorld()
        let id = try makePort(w)
        _ = try await call(w, "port.update", ["id": id, "html": "<div>one</div>"])
        _ = try await call(w, "port.update", ["id": id, "html": "<div>two</div>"])
        let hist = try await call(w, "port.history", ["id": id])
        guard case let .array(versions) = hist else { Issue.record("expected array"); return }
        #expect(versions.count >= 2)
        // restore to the earliest version and confirm the HTML rolled back
        guard case let .object(first) = versions.last, case let .int(v) = first["version"] else {
            Issue.record("expected version objects"); return
        }
        let vHtml = try await call(w, "port.getHtml", ["id": id, "version": v])
        _ = try await call(w, "port.restore", ["id": id, "version": v])
        #expect(try await call(w, "port.getHtml", ["id": id]) == vHtml)
    }

    @Test("port.rename updates the title (visible in ports.list)")
    @MainActor
    func rename() async throws {
        let w = try makeParityWorld()
        let id = try makePort(w, title: "Old")
        #expect(try await call(w, "port.rename", ["id": id, "title": "New"]) == .object(["ok": .bool(true)]))
        let listed = try await call(w, "ports.list", [:])
        guard case let .array(items) = listed, case let .object(o) = items.first else {
            Issue.record("expected one port"); return
        }
        #expect(o["title"] == .string("New"))
    }

    @Test("port.move returns {ok} for a valid id")
    @MainActor
    func move() async throws {
        let w = try makeParityWorld()
        let id = try makePort(w)
        #expect(try await call(w, "port.move", ["id": id, "x": 100, "y": 200]) == .object(["ok": .bool(true)]))
        await #expect(throws: BridgeError.self) { _ = try await call(w, "port.move", ["id": id]) }  // missing coords
    }

    @Test("positional args map through paramNames for a port method")
    @MainActor
    func positional() async throws {
        let w = try makeParityWorld()
        let id = try makePort(w)
        let update = try #require(w.registry["port.update"])
        _ = try await update.run(w.principal, BridgeArgs(positional: [id, "<div>pos</div>"], names: update.paramNames))
        #expect(try await call(w, "port.getHtml", ["id": id]) == .string("<div>pos</div>"))
    }
}
