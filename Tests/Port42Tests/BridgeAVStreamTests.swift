import Testing
import Foundation
import AVFoundation
import Speech
@testable import Port42Lib

// Tail item 6: audio.capture + the camera/screen streams extracted to the registry. ONE shared
// stateful instance per device family lives on AppState (audioDevice / cameraDevice / screenDevice);
// a capture or stream remembers the PortBridge that started it (owner) for event routing, and a
// dying owner stops any session it still holds (the mic-leak teardown). The Tier-A gates assert the
// stop methods RELEASE the engine / session / delegate — deallocated, not merely stopped. The
// hardware-loop half of the gate (real mic / camera / screen start-stop with TCC prompts) runs live
// in Port42Dev; these are the headless state-machine and release gates.

/// Holds a weak reference so a test can assert an object was actually deallocated after teardown.
private final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ v: T) { value = v }
}

@Suite("Bridge — AV streams")
struct BridgeAVStreamTests {

    @MainActor
    func call(_ w: ParityWorld, _ canonical: String, _ input: [String: Any] = [:]) async throws -> BridgeValue {
        let method = try #require(w.registry[canonical], "missing \(canonical)")
        return try await method.run(w.principal, BridgeArgs(input))
    }

    // MARK: - Priming (inject an active-looking session without touching hardware)

    /// Simulate an active audio capture on the shared instance: a real (never-started) engine and
    /// recognition request, exactly the references stopCapture must release.
    @MainActor
    private func primeAudio(_ audio: AudioBridge, ownerPortId: String? = nil) -> WeakBox<AVAudioEngine> {
        let engine = AVAudioEngine()
        audio.audioEngine = engine
        audio.recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        audio.isCapturing = true
        audio.ownerPortId = ownerPortId
        return WeakBox(engine)
    }

    /// Simulate an active camera stream: a real (never-started) AVCaptureSession.
    @MainActor
    private func primeCamera(_ camera: CameraBridge) -> WeakBox<AVCaptureSession> {
        let session = AVCaptureSession()
        camera.captureSession = session
        camera.isStreaming = true
        return WeakBox(session)
    }

    /// Simulate an active screen stream: the delegate is real, the SCStream itself cannot be built
    /// headless (its filter needs TCC), so the release gate is on the delegate + state.
    @MainActor
    private func primeScreen(_ screen: ScreenBridge) -> WeakBox<ScreenStreamDelegate> {
        let delegate = ScreenStreamDelegate(bridge: nil, scale: 1.0)
        screen.streamDelegate = delegate
        screen.isStreaming = true
        return WeakBox(delegate)
    }

    // MARK: - Registration

    @Test("all six AV stream methods are registered, gated, and not tool-exposed")
    @MainActor
    func registration() throws {
        let w = try makeParityWorld()
        let expected: [(String, PortPermission?)] = [
            ("audio.capture", .microphone),
            ("audio.stopCapture", .microphone),
            ("camera.stream", .camera),
            ("camera.stopStream", nil),
            ("screen.stream", .screen),
            ("screen.stopStream", nil),
        ]
        for (name, perm) in expected {
            let m = try #require(w.registry[name], "missing \(name)")
            #expect(m.permission == perm, "\(name) permission should be \(String(describing: perm))")
            #expect(!m.toolExposed, "\(name) is port-event-driven, not an LLM tool")
        }
    }

    // MARK: - Stop with nothing active throws (clean break from the {error} dicts)

    @Test("stopping with nothing active throws")
    @MainActor
    func stopWithNothingActive() async throws {
        let w = try makeParityWorld()
        await #expect(throws: BridgeError.self) { _ = try await call(w, "audio.stopCapture") }
        await #expect(throws: BridgeError.self) { _ = try await call(w, "camera.stopStream") }
        await #expect(throws: BridgeError.self) { _ = try await call(w, "screen.stopStream") }
    }

    // MARK: - Tier-A teardown (release, not merely stop)

    @Test("audio.stopCapture releases the engine and recognition chain")
    @MainActor
    func audioTeardownReleases() async throws {
        let w = try makeParityWorld()
        let audio = w.state.audioDevice
        let engineBox = primeAudio(audio)
        _ = try await call(w, "audio.stopCapture")
        #expect(!audio.capturing)
        #expect(audio.audioEngine == nil)
        #expect(audio.recognitionRequest == nil)
        #expect(audio.recognitionTask == nil)
        #expect(engineBox.value == nil, "the AVAudioEngine must be deallocated, not merely stopped")
    }

    @Test("camera.stopStream releases the capture session")
    @MainActor
    func cameraTeardownReleases() async throws {
        let w = try makeParityWorld()
        let camera = w.state.cameraDevice
        let sessionBox = primeCamera(camera)
        _ = try await call(w, "camera.stopStream")
        #expect(!camera.isStreaming)
        #expect(camera.captureSession == nil, "the AVCaptureSession must be released on stop")
        #expect(sessionBox.value == nil, "the AVCaptureSession must be deallocated, not merely stopped")
    }

    @Test("screen.stopStream releases the stream and delegate")
    @MainActor
    func screenTeardownReleases() async throws {
        let w = try makeParityWorld()
        let screen = w.state.screenDevice
        let delegateBox = primeScreen(screen)
        _ = try await call(w, "screen.stopStream")
        #expect(!screen.isStreaming)
        #expect(screen.stream == nil)
        #expect(screen.streamDelegate == nil)
        #expect(delegateBox.value == nil, "the stream delegate must be deallocated on stop")
    }

    // MARK: - The mic-leak teardown (a dying owner stops its own capture)

    @Test("a dying owner port stops the capture it started")
    @MainActor
    func ownerDeathStopsCapture() async throws {
        let w = try makeParityWorld()
        let audio = w.state.audioDevice
        // A capture-capable port always has a non-nil messageId (the teardown key). The dying
        // owner's deinit releases by that id.
        var bridge: PortBridge? = PortBridge(appState: w.state, spaceId: nil, messageId: "owner-port")
        let engineBox = primeAudio(audio, ownerPortId: "owner-port")
        bridge = nil  // deinit fires; its teardown hops to the main actor
        for _ in 0..<50 {
            await Task.yield()
            if !audio.capturing { break }
        }
        #expect(!audio.capturing, "the shared capture must stop when its owning port dies")
        #expect(audio.audioEngine == nil)
        #expect(engineBox.value == nil)
    }

    @Test("a dying non-owner port leaves someone else's capture running")
    @MainActor
    func nonOwnerDeathLeavesCapture() async throws {
        let w = try makeParityWorld()
        let audio = w.state.audioDevice
        let owner = PortBridge(appState: w.state, spaceId: nil, messageId: "owner-port")
        var other: PortBridge? = PortBridge(appState: w.state, spaceId: nil, messageId: "other-port")
        _ = primeAudio(audio, ownerPortId: owner.messageId)
        other = nil
        for _ in 0..<20 { await Task.yield() }
        #expect(audio.capturing, "another port dying must not stop the owner's capture")
        _ = audio.stopCapture()
        _ = other  // silence the unused-write warning; the point is the dealloc
    }
}
