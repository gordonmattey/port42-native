import Testing
import Foundation
@testable import Port42Lib

// Phase 2 step 1: the shared dispatcher + gateway (RemoteToolExecutor) wired registry-first. Proves
// the new path serves extracted methods, both spellings reach the same method (killing the
// port.getHtml Unknown-tool bug), permission gates via pregrant, and unextracted methods still route
// to the old path.

@Suite("Bridge — dispatch + gateway", .serialized)
struct BridgeDispatchTests {

    @MainActor
    func makePortWithHtml(_ w: ParityWorld, _ html: String) throws -> String {
        let created = w.state.createPort(type: "web", title: "T", html: html, command: nil, cwd: nil,
                                         systemPrompt: nil, spaceId: w.space.id, createdBy: w.companion.id,
                                         createdByName: w.companion.displayName, presentation: "tiled")
        return try #require(created["id"] as? String)
    }

    // MARK: dispatcher

    @Test("runBridgeMethod runs a no-permission method")
    @MainActor
    func dispatchNoPerm() async throws {
        let w = try makeParityWorld()
        let p = Principal.peer(id: "peer-1", displayName: "Claude Code")
        let v = try await w.state.runBridgeMethod("ports.list", principal: p, args: BridgeArgs([:]))
        #expect(v == .array([]))
    }

    @Test("runBridgeMethod throws unknown_method for an unregistered name")
    @MainActor
    func dispatchUnknown() async throws {
        let w = try makeParityWorld()
        let p = Principal.peer(id: "peer-1", displayName: "x")
        await #expect(throws: BridgeError.self) {
            _ = try await w.state.runBridgeMethod("bogus.method", principal: p, args: BridgeArgs([:]))
        }
    }

    @Test("a pregranted permission satisfies the gate without prompting")
    @MainActor
    func dispatchPregrant() async throws {
        let original = BridgeFilePaths.dataDir
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("p42-disp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        BridgeFilePaths.dataDir = tmp
        defer { BridgeFilePaths.dataDir = original; try? FileManager.default.removeItem(atPath: tmp) }

        let w = try makeParityWorld()
        let p = Principal.peer(id: "peer-1", displayName: "Claude Code")
        _ = try await w.state.runBridgeMethod("fs.write", principal: p,
                                              args: BridgeArgs(["path": "a.txt", "data": "hi"]),
                                              pregrant: [.filesystem])
        let read = try await w.state.runBridgeMethod("fs.read", principal: p,
                                                     args: BridgeArgs(["path": "a.txt"]),
                                                     pregrant: [.filesystem])
        #expect(read == .object(["data": .string("hi")]))
    }

    // MARK: gateway routing (RemoteToolExecutor)

    @Test("gateway serves ports.list via the registry (JSON array)")
    @MainActor
    func gatewayPortsList() async throws {
        let w = try makeParityWorld()
        _ = try makePortWithHtml(w, "<div>a</div>")
        let exec = RemoteToolExecutor(appState: w.state, senderId: "peer-1", senderName: "Claude Code")
        let result = await exec.execute(method: "ports.list", input: [:])
        let arr = try #require(result as? [Any])
        #expect(arr.count == 1)
    }

    @Test("gateway port.getHtml works — the dotted/camelCase name that used to 404")
    @MainActor
    func gatewayGetHtmlNoLonger404() async throws {
        let w = try makeParityWorld()
        let id = try makePortWithHtml(w, "<div>seed</div>")
        let exec = RemoteToolExecutor(appState: w.state, senderId: "peer-1", senderName: "Claude Code")
        _ = await exec.execute(method: "port.update", input: ["id": id, "html": "<div>current</div>"])
        let html = await exec.execute(method: "port.getHtml", input: ["id": id])
        #expect(html as? String == "<div>current</div>")
    }

    @Test("gateway accepts the snake spelling too (ports_list)")
    @MainActor
    func gatewaySnakeSpelling() async throws {
        let w = try makeParityWorld()
        _ = try makePortWithHtml(w, "<div>a</div>")
        let exec = RemoteToolExecutor(appState: w.state, senderId: "peer-1", senderName: "Claude Code")
        let result = await exec.execute(method: "ports_list", input: [:])
        #expect(result is [Any])
    }

    // MARK: in-app companion routing (ToolExecutor)

    @Test("in-app companion ports_list routes through the registry (JSON array, not a text blob)")
    @MainActor
    func inAppPortsListIsJSON() async throws {
        let w = try makeParityWorld()
        _ = try makePortWithHtml(w, "<div>a</div>")
        let exec = ToolExecutor(appState: w.state, spaceId: w.space.id, createdBy: w.companion.id, createdByName: w.companion.displayName)
        let blocks = await exec.execute(name: "ports_list", input: [:])
        let text = try #require(blocks.first?["text"] as? String)
        // the clean contract: it parses as a JSON array, not the old "N ports:\n..." blob
        let parsed = try JSONSerialization.jsonObject(with: try #require(text.data(using: .utf8)))
        #expect(parsed is [Any])
    }

    @Test("in-app companion crease_read routes through the registry (prose preserved)")
    @MainActor
    func inAppCreaseReadProse() async throws {
        let w = try makeParityWorld()
        let exec = ToolExecutor(appState: w.state, spaceId: w.space.id, createdBy: w.companion.id, createdByName: w.companion.displayName)
        let blocks = await exec.execute(name: "crease_read", input: [:])
        #expect(blocks.first?["text"] as? String == "No creases yet. Creases form when a prediction breaks.")
    }
}
