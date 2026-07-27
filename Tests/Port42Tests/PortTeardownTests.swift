import Testing
import Foundation
@testable import Port42Lib

// Backlog 0.5, the exhaustive port teardown. These gates cover the central seam: the registered
// list of device bridges and the single releaseAcquisitions funnel that a closing port fans out
// through. Live capture is TCC-gated and verified in Port42Dev (Step 7); here the logic is proven
// headless with spies.

/// Records every port id it was asked to release, so a test can assert the fan-out and that only the
/// target id reaches each registered bridge.
@MainActor
final class SpyOwnedResource: PortOwnedResource {
    var released: [String] = []
    func releaseIfOwned(byPortId id: String) { released.append(id) }
}

@Suite("Port teardown")
struct PortTeardownTests {

    @MainActor
    func makeState() throws -> AppState {
        let db = try DatabaseService(inMemory: true)
        return AppState(db: db)
    }

    // MARK: - Step 3: the registered list and the central entry point

    @Test("releaseAcquisitions fans the target port id out to every registered bridge")
    @MainActor
    func fanOutToEveryBridge() throws {
        let state = try makeState()
        let a = SpyOwnedResource()
        let b = SpyOwnedResource()
        state.deviceBridges = [a, b]

        state.releaseAcquisitions(portId: "target-port")

        #expect(a.released == ["target-port"], "every registered bridge is asked to release the target id")
        #expect(b.released == ["target-port"])
    }

    @Test("releaseAcquisitions passes only the target id, nothing else")
    @MainActor
    func passesOnlyTheTargetId() throws {
        let state = try makeState()
        let spy = SpyOwnedResource()
        state.deviceBridges = [spy]

        state.releaseAcquisitions(portId: "A")
        state.releaseAcquisitions(portId: "B")

        #expect(spy.released == ["A", "B"], "each call passes exactly its own port id")
    }

    // MARK: - Step 4: the funnel from close/deinit + the AI loop

    @Test("PortBridge.releaseAcquisitions fans out its own id and cancels its AI loop")
    @MainActor
    func bridgeReleaseFansOutAndCancelsAI() throws {
        let state = try makeState()
        let spy = SpyOwnedResource()
        state.deviceBridges = [spy]

        let bridge = PortBridge(appState: state, spaceId: nil, messageId: "P")
        bridge.streamTasks[1] = Task { while !Task.isCancelled { await Task.yield() } }

        bridge.releaseAcquisitions()

        #expect(spy.released == ["P"], "the bridge releases its own stable id across the device list")
        #expect(bridge.streamTasks.isEmpty, "the in-flight generation is cancelled")
    }

    @Test("PortWindowManager.close triggers releaseAcquisitions for that port and cancels its AI loop")
    @MainActor
    func closeTriggersRelease() throws {
        let state = try makeState()
        let spy = SpyOwnedResource()
        state.deviceBridges = [spy]

        let bridge = PortBridge(appState: state, spaceId: nil, messageId: "P")
        bridge.streamTasks[1] = Task { while !Task.isCancelled { await Task.yield() } }
        let panel = PortPanel(
            id: "P", udid: "P", html: "", bridge: bridge,
            spaceId: nil, createdBy: nil, messageId: "P",
            userTitle: nil, size: CGSize(width: 100, height: 100), position: nil)
        state.portWindows.panels.append(panel)

        state.portWindows.close("P")

        #expect(spy.released == ["P"], "closing the port releases the resources it acquired")
        #expect(bridge.streamTasks.isEmpty, "closing the port cancels its in-flight generation")
        #expect(!state.portWindows.panels.contains { $0.id == "P" }, "the panel is gone after close")
    }

    // MARK: - Step 5: the WKScriptMessageHandler retain cycle is broken

    @Test("closing a port deallocates its PortBridge (the retain cycle is broken)")
    @MainActor
    func closeDeallocatesBridge() async throws {
        let state = try makeState()
        weak var weakBridge: PortBridge?
        let portId = "inline-teardown-1"

        // Confine the strong bridge ref to this call, so after it returns the only strong holders
        // are the panel and the "port42" UCC handler — exactly what close() must drop.
        func register() {
            let bridge = state.portWindows.registerInlinePort(
                id: portId, html: "<html><body>hi</body></html>",
                spaceId: nil, createdBy: nil, title: "t", anchorMessageId: nil)
            weakBridge = bridge
        }
        register()
        #expect(weakBridge != nil, "the bridge is alive while the port is registered")

        state.portWindows.close(portId)
        for _ in 0..<100 {
            if weakBridge == nil { break }
            await Task.yield()
        }
        #expect(weakBridge == nil, "the bridge deallocated after close: the WKScriptMessageHandler retain is broken")
    }

    // MARK: - Step 6: enforcement — a new capability cannot skip teardown

    @Test("every start-with-owner device bridge is registered for teardown")
    @MainActor
    func teardownInventoryIsComplete() throws {
        let state = try makeState()
        let bridges = state.deviceBridges

        // Fixed inventory. Swift has no runtime reflection over stored properties, so this guards
        // drift by count + type: the four device families that accept an owning port today are
        // audio (capture / speak / play), camera (stream), screen (stream), and browser (sessions).
        //
        // ADDING A NEW start-with-owner capability (a bridge that records owner?.messageId at start)?
        // Conform it to PortOwnedResource, add it to AppState.deviceBridges, AND add it here. If you
        // add the bridge to the list but not here (or vice versa), this test fails on purpose — that
        // is the point: it turns "someone forgot teardown" from a silent leak into a red test.
        #expect(bridges.count == 4, "deviceBridges drifted from the four owner-taking device families")
        #expect(bridges.contains { $0 is AudioBridge }, "AudioBridge must be registered for teardown")
        #expect(bridges.contains { $0 is CameraBridge }, "CameraBridge must be registered for teardown")
        #expect(bridges.contains { $0 is ScreenBridge }, "ScreenBridge must be registered for teardown")
        #expect(bridges.contains { $0 is BrowserBridge }, "BrowserBridge must be registered for teardown")
    }

    // MARK: - Step 7 field regression: owner resolution for a createdBy-set port

    // The live mic-down (Step 7) found teardown no-opping for a port whose createdBy differs from its
    // own id (every gateway/companion-created port): portPrincipal.id is the CREATOR, so owner
    // resolution matched nothing and the capture recorded a nil owner. The port's own id now rides on
    // Principal.portId; owner resolution keys on it. This proves the resolution, headlessly.
    @Test("owner resolution finds a createdBy-set port by its own id")
    @MainActor
    func ownerResolvesForCreatedByPort() throws {
        let state = try makeState()
        let bridge = try #require(state.portWindows.registerInlinePort(
            id: "port-own-id", html: "<html><body>x</body></html>",
            spaceId: nil, createdBy: "companion-x", title: "t", anchorMessageId: nil))

        let p = bridge.portPrincipal
        #expect(p.id == "companion-x", "authz identity stays the creator (P-260)")
        #expect(p.portId == "port-own-id", "the port's own id rides alongside for owner resolution")
        #expect(state.streamPortBridge(for: p) === bridge,
                "resolution finds the specific port by its own id, not the shared creator id")
    }

    @Test("Principal.portId is excluded from identity (grants do not split)")
    @MainActor
    func portIdNotPartOfIdentity() {
        let a = Principal.port(id: "companion-x", displayName: "x", spaceId: "s", portId: "port-1")
        let b = Principal.port(id: "companion-x", displayName: "x", spaceId: "s", portId: "port-2")
        #expect(a == b, "two ports of the same creator stay one authz identity for coalescing")
    }
}
