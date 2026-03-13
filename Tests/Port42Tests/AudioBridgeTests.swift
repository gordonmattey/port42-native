import Testing
import Foundation
@testable import Port42Lib

@Suite("Audio Bridge")
struct AudioBridgeTests {

    // MARK: - Permission Mapping

    @Test("audio.capture requires .microphone permission")
    func capturePermission() {
        #expect(PortPermission.permissionForMethod("audio.capture") == .microphone)
    }

    @Test("audio.stopCapture requires .microphone permission")
    func stopCapturePermission() {
        #expect(PortPermission.permissionForMethod("audio.stopCapture") == .microphone)
    }

    @Test("audio.speak requires no permission")
    func speakNoPermission() {
        #expect(PortPermission.permissionForMethod("audio.speak") == nil)
    }

    @Test("audio.play requires no permission")
    func playNoPermission() {
        #expect(PortPermission.permissionForMethod("audio.play") == nil)
    }

    @Test("audio.stop requires no permission")
    func stopNoPermission() {
        #expect(PortPermission.permissionForMethod("audio.stop") == nil)
    }

    // MARK: - AudioBridge State

    @Test("new AudioBridge is not capturing")
    @MainActor
    func newBridgeNotCapturing() {
        let bridge = PortBridge(appState: DummyAppState(), channelId: nil)
        let ab = AudioBridge(bridge: bridge)
        #expect(!ab.capturing)
    }

    @Test("stopCapture returns error when not capturing")
    @MainActor
    func stopCaptureWhenNotCapturing() {
        let bridge = PortBridge(appState: DummyAppState(), channelId: nil)
        let ab = AudioBridge(bridge: bridge)
        let result = ab.stopCapture()
        #expect(result["error"] as? String == "no active capture")
    }

    @Test("stop returns ok even when nothing playing")
    @MainActor
    func stopWhenNothingPlaying() {
        let bridge = PortBridge(appState: DummyAppState(), channelId: nil)
        let ab = AudioBridge(bridge: bridge)
        let result = ab.stop()
        #expect(result["ok"] as? Bool == true)
    }

    @Test("play with invalid base64 returns error")
    @MainActor
    func playInvalidBase64() {
        let bridge = PortBridge(appState: DummyAppState(), channelId: nil)
        let ab = AudioBridge(bridge: bridge)
        let result = ab.play(data: "not-valid-base64!!!", opts: nil)
        #expect(result["error"] != nil)
    }

    @Test("play with empty data returns error")
    @MainActor
    func playEmptyData() {
        let bridge = PortBridge(appState: DummyAppState(), channelId: nil)
        let ab = AudioBridge(bridge: bridge)
        let result = ab.play(data: "", opts: nil)
        #expect(result["error"] != nil)
    }

    @Test("cleanup when not active does not crash")
    @MainActor
    func cleanupWhenIdle() {
        let bridge = PortBridge(appState: DummyAppState(), channelId: nil)
        let ab = AudioBridge(bridge: bridge)
        ab.cleanup()
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

// Minimal stand-in for AppState in tests
private class DummyAppState {}
