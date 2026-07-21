import Testing
import Foundation
@testable import Port42Lib

@Suite("Audio Bridge")
struct AudioBridgeTests {

    // MARK: - Permission Mapping

    @Test("audio.capture requires .microphone permission")
    @MainActor func capturePermission() throws {
        #expect(try registryPermission("audio.capture") == .microphone)
    }

    @Test("audio.stopCapture requires .microphone permission")
    @MainActor func stopCapturePermission() throws {
        #expect(try registryPermission("audio.stopCapture") == .microphone)
    }

    @Test("audio.speak requires no permission")
    @MainActor func speakNoPermission() throws {
        #expect(try registryPermission("audio.speak") == nil)
    }

    @Test("audio.play requires no permission")
    @MainActor func playNoPermission() throws {
        #expect(try registryPermission("audio.play") == nil)
    }

    @Test("audio.stop requires no permission")
    @MainActor func stopNoPermission() throws {
        #expect(try registryPermission("audio.stop") == nil)
    }

    // MARK: - AudioBridge State

    @Test("new AudioBridge is not capturing")
    @MainActor
    func newBridgeNotCapturing() {
        let ab = AudioBridge()
        #expect(!ab.capturing)
    }

    @Test("stopCapture returns error when not capturing")
    @MainActor
    func stopCaptureWhenNotCapturing() {
        let ab = AudioBridge()
        let result = ab.stopCapture()
        #expect(result["error"] as? String == "no active capture")
    }

    @Test("stop returns ok even when nothing playing")
    @MainActor
    func stopWhenNothingPlaying() {
        let ab = AudioBridge()
        let result = ab.stop()
        #expect(result["ok"] as? Bool == true)
    }

    @Test("play with invalid base64 returns error")
    @MainActor
    func playInvalidBase64() {
        let ab = AudioBridge()
        let result = ab.play(data: "not-valid-base64!!!", opts: nil)
        #expect(result["error"] != nil)
    }

    @Test("play with empty data returns error")
    @MainActor
    func playEmptyData() {
        let ab = AudioBridge()
        let result = ab.play(data: "", opts: nil)
        #expect(result["error"] != nil)
    }

    @Test("cleanup when not active does not crash")
    @MainActor
    func cleanupWhenIdle() {
        let ab = AudioBridge()
        ab.cleanup()
        #expect(!ab.capturing)
    }

    // MARK: - Ownership guard (backlog 0.5, Step 1) — keyed on the stable port id

    @Test("releaseIfOwned ignores a non-owner port id")
    @MainActor
    func releaseIgnoresNonOwner() {
        let ab = AudioBridge()
        ab.isCapturing = true
        ab.ownerPortId = "A"
        ab.releaseIfOwned(byPortId: "other")
        #expect(ab.capturing, "another port's id must not stop this capture")
    }

    @Test("releaseIfOwned stops the capture for the owning port id")
    @MainActor
    func releaseStopsForOwner() {
        let ab = AudioBridge()
        ab.isCapturing = true
        ab.ownerPortId = "A"
        ab.releaseIfOwned(byPortId: "A")
        #expect(!ab.capturing, "the owning port id must stop the capture")
    }

    @Test("releaseIfOwned is idempotent")
    @MainActor
    func releaseIdempotent() {
        let ab = AudioBridge()
        ab.isCapturing = true
        ab.ownerPortId = "A"
        ab.releaseIfOwned(byPortId: "A")
        ab.releaseIfOwned(byPortId: "A")  // second call is a safe no-op
        #expect(!ab.capturing)
    }

    // MARK: - Permission descriptions

    @Test(".microphone permission has descriptive text")
    func microphonePermissionDescription() {
        let desc = PortPermission.microphone.permissionDescription
        #expect(!desc.title.isEmpty)
        #expect(!desc.message.isEmpty)
    }
}
