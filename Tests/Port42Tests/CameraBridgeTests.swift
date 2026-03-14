import Testing
import Foundation
@testable import Port42Lib

@Suite("Camera Bridge")
struct CameraBridgeTests {

    // MARK: - Permission Mapping

    @Test("camera.capture requires .camera permission")
    func capturePermission() {
        #expect(PortPermission.permissionForMethod("camera.capture") == .camera)
    }

    @Test("camera.stream requires .camera permission")
    func streamPermission() {
        #expect(PortPermission.permissionForMethod("camera.stream") == .camera)
    }

    @Test("camera.stopStream requires .camera permission")
    func stopStreamPermission() {
        #expect(PortPermission.permissionForMethod("camera.stopStream") == .camera)
    }

    // MARK: - Permission Description

    @Test(".camera permission has descriptive text")
    func cameraPermissionDescription() {
        let desc = PortPermission.camera.permissionDescription
        #expect(!desc.title.isEmpty)
        #expect(!desc.message.isEmpty)
    }
}
