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
}
