import Testing
import Foundation
import WebKit
@testable import Port42Lib

// Hidden ports (nautilus Phase 3.2): a port that runs, keeps its chat, storage and subscriptions,
// and has no tile. Stored as `isBackground` (the old "docked", which no view listed, so a docked port
// ran where nobody could find it). A person finds hidden ports in ⌘K and the chrome's count.
@Suite("Hidden ports")
struct HiddenPortTests {

    @MainActor
    func world() throws -> ParityWorld { try makeParityWorld() }

    @MainActor
    func call(_ w: ParityWorld, _ method: String, _ args: [String: Any]) async throws -> BridgeValue {
        try await w.state.runBridgeMethod(method, principal: .peer(id: "cli", displayName: "cli"), args: BridgeArgs(args))
    }

    @MainActor
    func status(_ w: ParityWorld, _ id: String) async throws -> String? {
        guard case .array(let ports) = try await call(w, "ports.list", [:]) else { return nil }
        for case .object(let o) in ports where o["id"] == .string(id) {
            if case .string(let s) = o["status"] { return s }
        }
        return nil
    }

    @MainActor
    func token(_ w: ParityWorld, _ id: String) -> String { w.state.portInput.token(for: id) }

    @Test("created hidden: on no desktop and in no rail, listed hidden, running")
    @MainActor
    func createdHidden() async throws {
        let w = try world()
        let r = w.state.createPort(type: "web", title: "stage", html: "<title>stage</title>", command: nil,
                                   cwd: nil, systemPrompt: nil, spaceId: w.space.id, createdBy: nil,
                                   createdByName: nil, presentation: "hidden")
        let id = try #require(r["id"] as? String)
        let pw = w.state.portWindows
        let panel = try #require(pw.panels.first { $0.id == id || $0.udid == id })
        #expect(pw.hiddenPanels(in: w.space.id).map(\.id) == [panel.id])
        #expect(!pw.panels(in: w.space.id).contains { $0.id == panel.id }, "a hidden port is on a desktop")
        #expect(!pw.railIds(in: w.space.id).contains(panel.id), "a hidden port is in the rail")
        #expect(pw.webViews[panel.id] != nil, "a hidden port must still run")
        #expect(try await status(w, panel.udid) == "hidden")
    }

    @Test("hide then show round-trips through port.manage and keeps the spot")
    @MainActor
    func hideShow() async throws {
        let w = try world()
        let pw = w.state.portWindows
        pw.registerTiledPort(id: "p", html: "<title>p</title>", spaceId: w.space.id, createdBy: nil,
                             title: "p", position: CGPoint(x: 300, y: 200))
        let udid = try #require(pw.panels.first { $0.id == "p" }?.udid)
        let before = pw.panels.first { $0.id == "p" }?.position(on: w.space.id)
        _ = try await call(w, "port.manage", ["id": udid, "action": "hide", "token": token(w, udid)])
        #expect(try await status(w, udid) == "hidden")
        _ = try await call(w, "port.manage", ["id": udid, "action": "show", "token": token(w, udid)])
        #expect(try await status(w, udid) == "tiled")
        #expect(pw.panels.first { $0.id == "p" }?.position(on: w.space.id) == before)
    }

    @Test("hidden is persisted, so it survives a restart")
    @MainActor
    func persisted() throws {
        let w = try world()
        let pw = w.state.portWindows
        pw.registerTiledPort(id: "p", html: "<title>p</title>", spaceId: w.space.id, createdBy: nil,
                             title: "p", position: CGPoint(x: 40, y: 40))
        pw.minimize("p")
        let row = try #require(try w.state.db.fetchPortPanels().first { $0.id == "p" })
        #expect(row.isBackground)
    }

    /// Every place that shows ports as tiles must leave hidden ones out. One predicate is the goal;
    /// until every surface reads it, this scan fails any filter on `presentation == "tiled"` that does
    /// not also exclude `isBackground`, so a new view cannot quietly show a hidden port.
    @Test("no tile filter in the sources lets a hidden port through")
    func noTileFilterLeaks() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Port42Lib")
        var leaks: [String] = []
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains("presentation == \"tiled\"") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") || t.hasPrefix("///") || line.contains("if presentation ==") { continue }
                let window = lines[max(0, i - 1)...min(lines.count - 1, i + 1)].joined(separator: " ")
                if !window.contains("isBackground") { leaks.append("\(url.lastPathComponent):\(i + 1)") }
            }
        }
        #expect(leaks.isEmpty, "tile filters that would show a hidden port: \(leaks)")
    }
}
