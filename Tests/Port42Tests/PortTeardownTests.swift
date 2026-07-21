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
}
