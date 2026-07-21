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

    // MARK: - Speak / play ownership (backlog 0.5, Step 2)

    @Test("releaseIfOwned stops speech for the owning port id, leaves a non-owner")
    @MainActor
    func speakReleasedByOwner() {
        let ab = AudioBridge()
        ab.speakPortId = "A"
        ab.releaseIfOwned(byPortId: "other")
        #expect(ab.speakPortId == "A", "another port's id must not stop this port's speech")
        ab.releaseIfOwned(byPortId: "A")
        #expect(ab.speakPortId == nil, "the owning port id must stop the speech")
    }

    @Test("releaseIfOwned stops playback for the owning port id, leaves a non-owner")
    @MainActor
    func playReleasedByOwner() {
        let ab = AudioBridge()
        ab.playPortId = "A"
        ab.releaseIfOwned(byPortId: "other")
        #expect(ab.playPortId == "A", "another port's id must not stop this port's playback")
        ab.releaseIfOwned(byPortId: "A")
        #expect(ab.playPortId == nil, "the owning port id must stop the playback")
    }

    @Test("play records the owning port id at start")
    @MainActor
    func playRecordsOwner() {
        let ab = AudioBridge()
        let owner = PortBridge(appState: NSObject(), spaceId: nil, messageId: "portA")
        let result = ab.play(data: Self.silentWAV(), opts: nil, owner: owner)
        #expect(result["ok"] as? Bool == true, "a valid WAV must play")
        #expect(ab.playPortId == "portA", "play must record the owning port id")
        _ = ab.stop()
    }

    /// A tiny valid PCM WAV (0.1s of silence) so play() can create a real AVAudioPlayer without any
    /// asset file — just enough for the ownership-recording assertion.
    @MainActor
    static func silentWAV(seconds: Double = 0.1, sampleRate: Int = 8000) -> String {
        let numSamples = Int(Double(sampleRate) * seconds)
        let channels = 1, bitsPerSample = 16
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * blockAlign
        let dataSize = numSamples * blockAlign
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + dataSize)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(byteRate)); u16(UInt16(blockAlign)); u16(UInt16(bitsPerSample))
        d.append("data".data(using: .ascii)!); u32(UInt32(dataSize)); d.append(Data(count: dataSize))
        return d.base64EncodedString()
    }

    // MARK: - Permission descriptions

    @Test(".microphone permission has descriptive text")
    func microphonePermissionDescription() {
        let desc = PortPermission.microphone.permissionDescription
        #expect(!desc.title.isEmpty)
        #expect(!desc.message.isEmpty)
    }
}
