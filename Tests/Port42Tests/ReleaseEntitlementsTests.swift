import Testing
import Foundation

/// A notarized build runs with the hardened runtime, which lets the app ask for the microphone or the
/// camera only when it declares the matching entitlement. The release entitlements lacked both, so in
/// every release voice showed a live mic and typed nothing, and macOS never asked (GM, 2026-09-27).
/// Development builds do not run hardened, which is why no dev instance showed it.
@Suite("Release entitlements")
struct ReleaseEntitlementsTests {
    @Test("the release build may use the microphone and the camera")
    func devices() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Port42.release.entitlements").standardized
        let plist = try #require(NSDictionary(contentsOf: url) as? [String: Any], "cannot read \(url.path)")
        #expect(plist["com.apple.security.device.audio-input"] as? Bool == true, "no microphone: voice and audio capture get silence")
        #expect(plist["com.apple.security.device.camera"] as? Bool == true, "no camera for a port's camera capture")
        #expect(plist["com.apple.security.get-task-allow"] == nil, "get-task-allow fails notarization")
    }
}
