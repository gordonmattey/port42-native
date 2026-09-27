import Testing
import Foundation
import AVFoundation
import FluidAudio
@testable import Port42Lib

// Phase 2 of voice input: the microphone and the model. The trigger is covered by VoiceTriggerTests.
//
// Nothing here opens a microphone or loads Parakeet. The conversion is a type of its own so it can be
// fed a synthetic buffer, and the session takes its audio source and its transcriber, so the contract
// that matters (the source is ALWAYS stopped) is testable without hardware.

@Suite("Voice resampler: whatever the mic gives us, 16 kHz mono out")
struct VoiceResamplerTests {

    /// A tone in `format`, `seconds` long, so the conversion has real samples to work on.
    private func tone(_ format: AVAudioFormat, seconds: Double) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let data = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) {
                data[i] = sin(2 * .pi * 440 * Double(i) / format.sampleRate).magnitude > 0 ?
                    Float(sin(2 * .pi * 440 * Double(i) / format.sampleRate)) : 0
            }
        }
        return buffer
    }

    @Test("44.1 kHz stereo becomes one second of 16 kHz mono")
    func downsamples() throws {
        let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                  channels: 2, interleaved: false)!
        let resampler = try #require(VoiceResampler(from: input))
        let out = resampler.samples(from: tone(input, seconds: 1))

        // The converter is allowed a small ramp, but a second in must be about a second out.
        #expect(abs(out.count - 16_000) < 400, "got \(out.count) samples for one second")
        #expect(out.contains { $0 != 0 }, "the conversion returned silence")
    }

    @Test("audio already at 16 kHz mono passes through at the same length")
    func passesThrough() throws {
        let input = VoiceResampler.targetFormat
        let resampler = try #require(VoiceResampler(from: input))
        let out = resampler.samples(from: tone(input, seconds: 0.5))
        #expect(out.count == 8_000)
    }

    @Test("an empty buffer converts to nothing rather than failing")
    func emptyBuffer() throws {
        let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                  channels: 1, interleaved: false)!
        let resampler = try #require(VoiceResampler(from: input))
        let empty = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 512)!
        empty.frameLength = 0
        #expect(resampler.samples(from: empty).isEmpty)
    }

    @Test("the target is what Parakeet takes: 16 kHz, mono, Float32")
    func targetFormat() {
        #expect(VoiceResampler.targetFormat.sampleRate == 16_000)
        #expect(VoiceResampler.targetFormat.channelCount == 1)
        #expect(VoiceResampler.targetFormat.commonFormat == .pcmFormatFloat32)
    }
}

// MARK: - The session

private final class FakeSource: VoiceAudioSource {
    var starts = 0, stops = 0
    var isRunning = false
    var failOnStart = false
    var samples: [Float] = [0.1, -0.2, 0.3]

    func start() throws {
        if failOnStart { throw VoiceCapture.Failure.noInputFormat }
        starts += 1; isRunning = true
    }
    func stop() -> [Float] { stops += 1; isRunning = false; return samples }
    func snapshot() -> [Float] { samples }
}

private struct FakeTranscriber: VoiceTranscriber {
    let text: String
    let fails: Bool
    init(text: String = "hello there", fails: Bool = false) { self.text = text; self.fails = fails }
    struct Boom: Error {}
    func transcribe(_ samples: [Float]) async throws -> String {
        if fails { throw Boom() }
        return text
    }
}

@Suite("Voice session: a hold becomes text, and the mic always stops")
@MainActor
struct VoiceSessionTests {

    private func session(_ transcriber: FakeTranscriber = FakeTranscriber(),
                         model: VoiceModelState = .ready) -> (VoiceSession, FakeSource) {
        let source = FakeSource()
        return (VoiceSession(source: source, transcriber: transcriber,
                             modelIsReady: { true }, model: model), source)
    }

    @Test("a hold starts the mic and a release reports the text once")
    func oneHoldOneText() async {
        let (s, source) = session()
        var texts: [String] = []
        s.onText = { texts.append($0) }

        s.begin()
        #expect(source.starts == 1)
        #expect(s.isCapturing)
        s.end()
        #expect(source.stops == 1)
        #expect(!s.isCapturing)

        await s.transcription?.value
        #expect(texts == ["hello there"])
    }

    @Test("two holds in a row both produce text")
    func twoHolds() async {
        let (s, source) = session()
        var texts: [String] = []
        s.onText = { texts.append($0) }
        s.begin(); s.end()
        await s.transcription?.value
        s.begin(); s.end()
        await s.transcription?.value
        #expect(source.starts == 2 && source.stops == 2)
        #expect(texts.count == 2)
    }

    /// The gate that matters. An engine left running is a live microphone, so the source is stopped
    /// before transcription is even attempted, and a failing transcription cannot keep it open.
    @Test("a transcription that throws still stops the microphone")
    func failedTranscriptionStopsTheMic() async {
        let (s, source) = session(FakeTranscriber(fails: true))
        var texts: [String] = []
        s.onText = { texts.append($0) }
        s.begin(); s.end()
        #expect(source.stops == 1)
        #expect(!source.isRunning)
        await s.transcription?.value
        #expect(texts.isEmpty, "a failed transcription reported text")
    }

    @Test("silence is not reported as text")
    func silenceIsNotText() async {
        let (s, source) = session(FakeTranscriber(text: ""))
        source.samples = []
        var texts: [String] = []
        s.onText = { texts.append($0) }
        s.begin(); s.end()
        await s.transcription?.value
        #expect(texts.isEmpty)
    }

    @Test("with no model the hold starts no microphone and types nothing")
    func noModelNoMic() async {
        let (s, source) = session(model: .absent)
        var texts: [String] = []
        s.onText = { texts.append($0) }
        s.begin()
        #expect(source.starts == 0, "the microphone opened with no model loaded")
        #expect(!s.isCapturing)
        s.end()
        await s.transcription?.value
        #expect(texts.isEmpty)
    }

    @Test("a release with no hold does nothing")
    func releaseWithoutHold() {
        let (s, source) = session()
        s.end()
        #expect(source.stops == 0)
    }

    @Test("a microphone that will not start is reported, and capture does not begin")
    func micFailure() {
        let (s, source) = session()
        source.failOnStart = true
        var states: [VoiceModelState] = []
        s.onModelState = { states.append($0) }
        s.begin()
        #expect(!s.isCapturing)
        #expect(states.contains { if case .failed = $0 { return true }; return false })
    }

    /// Partials are feedback while the hold is open. They are re-reads of the whole buffer so far, which
    /// is why they need no second model and no sliding window.
    @Test("the words so far arrive while the hold is still open")
    func partialsWhileHolding() async {
        let (s, source) = session()
        source.samples = Array(repeating: 0.05, count: 20_000)     // over the half-second floor
        var partials: [String] = []
        s.onPartial = { partials.append($0) }

        s.begin()
        await s.runPartialOnce()
        #expect(partials == ["hello there"], "no partial arrived while holding")

        // And they stop at the release: a tick that lands after the hold reports nothing.
        s.end()
        await s.runPartialOnce()
        #expect(partials.count == 1, "a partial arrived after the release")
    }

    @Test("a hold shorter than half a second of audio reports no partial")
    func partialsNeedAudio() async {
        let (s, source) = session()
        source.samples = [0.1, 0.2]
        var partials: [String] = []
        s.onPartial = { partials.append($0) }
        s.begin()
        await s.runPartialOnce()
        #expect(partials.isEmpty)
    }

    @Test("the 480 MB download is off by default, so a hold cannot start one")
    func downloadIsOptIn() {
        #expect(UserDefaults.standard.bool(forKey: VoiceSession.downloadAllowedKey) == false,
                "the model download defaults to allowed")
    }
}

@Suite("Microphone teardown is in the source, not just in the tests")
struct MicrophoneTeardownGate {

    /// Every file that opens a tap must also remove one. This is a source gate rather than a runtime
    /// test because the failure (a tap left installed) is a live microphone, and the runtime test for
    /// it would need a microphone to be open in CI.
    @Test("every file that installs an audio tap also removes it")
    func tapsAreRemoved() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var offenders: [String] = []
        for case let url as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("installTap(") && !text.contains("removeTap(") {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty, "installs a tap and never removes it: \(offenders)")
    }
}

@Suite("What the model state says, and where the weights come from")
struct VoiceModelStateTests {

    /// GM, Dev7, 2026-09-26: the capsule read "speech model 50%" while nothing was downloading (the
    /// weights were already complete on disk). FluidAudio reports listing, downloading and compiling on
    /// one progress stream, so the three must not all read as a download.
    @Test("compiling is loading, not downloading")
    func phasesAreNotAllDownloads() {
        #expect(VoiceModelState.from(.init(fractionCompleted: 0.5, phase: .compiling(modelName: "Encoder")))
                == .loading(0.5))
        #expect(VoiceModelState.from(.init(fractionCompleted: 0.5, phase: .downloading(completedFiles: 2, totalFiles: 4)))
                == .downloading(0.5))
        #expect(VoiceModelState.from(.init(fractionCompleted: 0, phase: .listing)) == .downloading(0))
    }

    @Test("only a real download says downloading")
    func labels() {
        #expect(VoiceModelState.ready.label == "listening")
        #expect(VoiceModelState.downloading(0.42).label == "downloading speech model 42%")
        #expect(VoiceModelState.loading(0.42).label == "loading speech model 42%")
        #expect(VoiceModelState.loading(0).label == "loading speech model")
        #expect(VoiceModelState.absent.label == "speech model not installed")
        #expect(VoiceModelState.failed("no mic").label == "voice: no mic")
        for state in [VoiceModelState.loading(0.5), .ready, .absent, .failed("x")] {
            #expect(!state.label.contains("downloading"), "\(state) calls itself a download")
        }
    }

    /// Bundled weights win, so a shipped app never reaches for the network, and the shared cache wins
    /// over a second download of the same 461 MB.
    @Test("where the weights come from, in order")
    func sourceOrder() {
        #expect(VoiceModelSource.resolve(bundled: true, cached: true, downloadAllowed: true) == .bundled)
        #expect(VoiceModelSource.resolve(bundled: true, cached: false, downloadAllowed: false) == .bundled)
        #expect(VoiceModelSource.resolve(bundled: false, cached: true, downloadAllowed: false) == .cache)
        #expect(VoiceModelSource.resolve(bundled: false, cached: false, downloadAllowed: true) == .download)
        #expect(VoiceModelSource.resolve(bundled: false, cached: false, downloadAllowed: false) == .unavailable)
    }
}
