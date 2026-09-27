import Testing
import Foundation
import AVFoundation
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
