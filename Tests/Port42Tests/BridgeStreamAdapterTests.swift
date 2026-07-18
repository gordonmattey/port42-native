import Testing
import Foundation
@testable import Port42Lib

// Item 8, C4: the request/response adapters (gateway RPC + in-app tool-use) route ai.complete through
// runBridgeStream as collect-into-final. Uses the hermetic StubStreamBackend (defined in
// BridgeStreamTests) via the streamBackendOverride seam. On success both return the structured {text};
// a failed call renders {error} (gateway body) / an error tool block — correct for request/response,
// not the never-reject shim (that is the port-JS promise surface).

@Suite("Bridge — streaming adapters (gateway + tool-use)")
struct BridgeStreamAdapterTests {

    @Test("gateway RemoteToolExecutor routes ai.complete through runBridgeStream, returns {text}")
    @MainActor
    func gatewayAiComplete() async throws {
        let w = try makeParityWorld()
        w.state.streamBackendOverride = { _ in StubStreamBackend(tokens: ["Hel", "lo"], finalText: "Hello") }
        w.state.saveCompanionPermissions([.ai], createdBy: "peer-1", spaceId: nil)   // pre-grant .ai
        let exec = RemoteToolExecutor(appState: w.state, senderId: "peer-1", senderName: "curl")
        let result = await exec.execute(method: "ai.complete", input: ["prompt": "hi"])
        #expect((result as? [String: Any])?["text"] as? String == "Hello")
    }

    @Test("gateway: a failed ai.complete returns {error} in the body (request/response, not a shim)")
    @MainActor
    func gatewayAiCompleteError() async throws {
        let w = try makeParityWorld()
        w.state.saveCompanionPermissions([.ai], createdBy: "peer-1", spaceId: nil)
        let exec = RemoteToolExecutor(appState: w.state, senderId: "peer-1", senderName: "curl")
        let result = await exec.execute(method: "ai.complete", input: ["prompt": ""])   // empty -> BridgeError
        #expect((result as? [String: Any])?["error"] as? String == "ai.complete requires a prompt")
    }

    @Test("in-app ToolExecutor routes ai.complete through runBridgeStream, renders a text tool block")
    @MainActor
    func toolUseAiComplete() async throws {
        let w = try makeParityWorld()
        w.state.streamBackendOverride = { _ in StubStreamBackend(tokens: ["a", "b"], finalText: "ab") }
        let exec = ToolExecutor(appState: w.state, spaceId: w.space.id,
                                createdBy: w.companion.id, createdByName: "Echo")
        exec.pregrant(.ai)
        let blocks = await exec.execute(name: "ai.complete", input: ["prompt": "hi"])
        let text = blocks.compactMap { $0["text"] as? String }.joined()
        #expect(text.contains("ab"))
    }
}
