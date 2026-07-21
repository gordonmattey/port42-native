import Testing
import Foundation
@testable import Port42Lib

@Suite("Camera Bridge")
struct CameraBridgeTests {

    // MARK: - Permission Mapping

    @Test("camera.capture requires .camera permission")
    @MainActor func capturePermission() throws {
        #expect(try registryPermission("camera.capture") == .camera)
    }

    @Test("camera.stream requires .camera permission")
    @MainActor func streamPermission() throws {
        #expect(try registryPermission("camera.stream") == .camera)
    }

    // Stopping an already-permitted stream needs no fresh permission (same as screen.stopStream).
    // capture/stream are the gated entry points; stop is always allowed.
    @Test("camera.stopStream needs no permission")
    @MainActor func stopStreamPermission() throws {
        #expect(try registryPermission("camera.stopStream") == nil)
    }

    // MARK: - Permission Description

    @Test(".camera permission has descriptive text")
    func cameraPermissionDescription() {
        let desc = PortPermission.camera.permissionDescription
        #expect(!desc.title.isEmpty)
        #expect(!desc.message.isEmpty)
    }

    // MARK: - Ownership guard (backlog 0.5, Step 1) — keyed on the stable port id

    @Test("releaseIfOwned ignores a non-owner port id")
    @MainActor
    func releaseIgnoresNonOwner() {
        let cb = CameraBridge()
        cb.isStreaming = true
        cb.ownerPortId = "A"
        cb.releaseIfOwned(byPortId: "other")
        #expect(cb.isStreaming, "another port's id must not stop this stream")
    }

    @Test("releaseIfOwned stops the stream for the owning port id")
    @MainActor
    func releaseStopsForOwner() {
        let cb = CameraBridge()
        cb.isStreaming = true
        cb.ownerPortId = "A"
        cb.releaseIfOwned(byPortId: "A")
        #expect(!cb.isStreaming, "the owning port id must stop the stream")
    }

    @Test("releaseIfOwned is idempotent")
    @MainActor
    func releaseIdempotent() {
        let cb = CameraBridge()
        cb.isStreaming = true
        cb.ownerPortId = "A"
        cb.releaseIfOwned(byPortId: "A")
        cb.releaseIfOwned(byPortId: "A")  // second call is a safe no-op
        #expect(!cb.isStreaming)
    }
}
