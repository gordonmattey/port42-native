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
        // The microphone is granted in these tests: what is under test here is the hold, not the permission.
        // VoicePermissionTests covers the ungranted case, and a test process has no TCC grant of its own.
        return (VoiceSession(source: source, transcriber: transcriber,
                             modelIsReady: { true }, model: model,
                             micGranted: { true }, askForPermissions: {}), source)
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

    /// The app does not ship the weights, so holding space is the consent to fetch them and the indicator
    /// shows the download as it runs. A machine that must not fetch anything sets the key to false.
    @Test("the weights are fetched by default, and refusing is a setting")
    func downloadDefaultsOn() {
        let allowed = UserDefaults(suiteName: "voice.test.allowed")!
        allowed.removePersistentDomain(forName: "voice.test.allowed")
        #expect(VoiceSession.downloadAllowed(allowed), "a shipped app could never fetch the model")
        allowed.set(false, forKey: VoiceSession.downloadAllowedKey)
        #expect(!VoiceSession.downloadAllowed(allowed), "the refusal is ignored")
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

@Suite("System permissions are asked for once, on the first hold")
@MainActor
struct VoicePermissionTests {

    private func session(micGranted: Bool, model: VoiceModelState = .ready)
        -> (VoiceSession, FakeSource, () -> Int) {
        let source = FakeSource()
        final class Counter { var n = 0 }
        let asks = Counter()
        let s = VoiceSession(source: source, transcriber: FakeTranscriber(),
                             modelIsReady: { true }, model: model,
                             micGranted: { micGranted },
                             askForPermissions: { asks.n += 1 })
        return (s, source, { asks.n })
    }

    /// GM, 2026-09-27: system permissions "just stream in". Nothing touches the microphone until a hold, so
    /// nothing prompts until then, and then both are asked for at once.
    @Test("with no microphone permission a hold asks for it and starts nothing")
    func firstHoldAsks() {
        let (s, source, asks) = session(micGranted: false)
        var needed: [VoicePermission?] = []
        s.onPermissionNeeded = { needed.append($0) }

        s.begin()
        #expect(source.starts == 0, "the microphone was opened before it was granted")
        #expect(!s.isCapturing)
        #expect(asks() == 1)
        #expect(needed == [.microphone])
    }

    @Test("holding again does not ask again")
    func asksOnlyOnce() {
        let (s, _, asks) = session(micGranted: false)
        s.begin(); s.end()
        s.begin(); s.end()
        s.begin()
        #expect(asks() == 1, "the system was asked \(asks()) times")
    }

    @Test("with the microphone granted, nothing is outstanding")
    func grantedIsSilent() {
        let (s, source, asks) = session(micGranted: true)
        var needed: [VoicePermission?] = []
        s.onPermissionNeeded = { needed.append($0) }
        s.begin()
        #expect(source.starts == 1)
        #expect(asks() == 0)
        #expect(needed == [nil])
    }

    /// The first hold after a launch is the one a person judges the feature by, so it records even though the
    /// model is still loading, and the words arrive when the model lands.
    @Test("a hold while the model loads is kept, not dropped")
    func heldAudioSurvivesLoading() async {
        let (s, source, _) = session(micGranted: true, model: .loading(0.5))
        source.samples = Array(repeating: 0.05, count: 20_000)
        var texts: [String] = []
        s.onText = { texts.append($0) }

        s.begin()
        #expect(source.starts == 1, "a hold during loading opened no microphone")
        s.end()
        await s.transcription?.value          // whatever the release started, let it finish
        #expect(texts.isEmpty, "it was transcribed before the model was ready")

        s.noteModelState(.ready)
        await s.transcription?.value
        #expect(texts == ["hello there"], "the held audio was dropped")
    }

    @Test("a model that is absent still stops a hold")
    func absentModelStopsAHold() {
        let (s, source, _) = session(micGranted: true, model: .absent)
        s.begin()
        #expect(source.starts == 0)
    }

    @Test("what has to be asked for, microphone first")
    func missingOrder() {
        #expect(VoicePermissions.missing(microphone: false, accessibility: false) == [.microphone, .accessibility])
        #expect(VoicePermissions.missing(microphone: true, accessibility: false) == [.accessibility])
        #expect(VoicePermissions.missing(microphone: true, accessibility: true).isEmpty)
        #expect(VoicePermission.microphone.label == "allow the microphone")
    }
}

@Suite("Fetching 461 MB is something a hold asks for, not something a launch does")
struct VoiceDownloadDecisionTests {

    /// The app does not ship the weights. Launching it must not pull them: nobody has asked for dictation yet,
    /// and a download for a feature not everyone uses is exactly what shipping them was rejected for.
    @Test("a launch never downloads")
    func launchDoesNotDownload() {
        #expect(!VoiceSession.shouldDownload(askedByPerson: false, weightsOnDisk: false, allowed: true))
    }

    @Test("a hold downloads when there is nothing on disk")
    func holdDownloads() {
        #expect(VoiceSession.shouldDownload(askedByPerson: true, weightsOnDisk: false, allowed: true))
    }

    @Test("weights already on disk are loaded, never re-fetched")
    func onDiskIsNeverRefetched() {
        #expect(!VoiceSession.shouldDownload(askedByPerson: true, weightsOnDisk: true, allowed: true))
        #expect(!VoiceSession.shouldDownload(askedByPerson: false, weightsOnDisk: true, allowed: false))
    }

    @Test("a refusal holds even against a hold")
    func refusalWins() {
        #expect(!VoiceSession.shouldDownload(askedByPerson: true, weightsOnDisk: false, allowed: false))
    }
}

@Suite("One decision about what the voice indicator shows")
@MainActor
struct VoiceIndicatorStateTests {

    private func shell() throws -> ShellState {
        let db = try DatabaseService(inMemory: true)
        return ShellState(appState: AppState(db: db))
    }

    @Test("nothing to say when the model is ready and no hold is open")
    func silentWhenIdle() throws {
        let s = try shell()
        s.voiceModel = .ready
        #expect(s.voiceIndicatorForSpace == nil)
    }

    /// The app does not ship the weights, so the fetch is the app acting on the person's behalf and has to be
    /// visible without anyone holding space (GM, 2026-09-27: "we need to show the user too it's downloading").
    @Test("a download shows with no hold in progress")
    func downloadIsVisible() throws {
        let s = try shell()
        s.voiceModel = .downloading(0.25)
        let shown = try #require(s.voiceIndicatorForSpace)
        #expect(shown.label == "downloading speech model 25%")
        #expect(!shown.live, "the mic is not open")
    }

    @Test("loading shows too, and does not call itself a download")
    func loadingIsVisible() throws {
        let s = try shell()
        s.voiceModel = .loading(0)
        let shown = try #require(s.voiceIndicatorForSpace)
        #expect(shown.label == "loading speech model")
    }

    @Test("an open hold wins, and shows the words so far")
    func holdWins() throws {
        let s = try shell()
        s.voiceModel = .ready
        s.voiceCapturing = true
        s.voicePartial = "hello there"
        let shown = try #require(s.voiceIndicatorForSpace)
        #expect(shown.live)
        #expect(shown.label == "hello there")
    }

    @Test("a notice outranks the model's own state")
    func noticeOutranksModel() throws {
        let s = try shell()
        s.voiceModel = .absent
        s.voiceNotice = "nowhere to type: hello"
        #expect(s.voiceIndicatorForSpace?.label == "nowhere to type: hello")
    }

    @Test("an absent model says nothing until something asks for it")
    func absentIsQuiet() throws {
        let s = try shell()
        s.voiceModel = .absent
        #expect(s.voiceIndicatorForSpace == nil)
    }

    /// GM, 2026-09-27: the download showed in the port and not on the space. The anchor is a property of a hold,
    /// and a download is not part of one.
    @Test("a download shows on the space, never on the tile being dictated into")
    func downloadIsNotPinnedToATile() throws {
        let s = try shell()
        s.voiceModel = .downloading(0.4)
        s.voiceAnchorPortId = "p"

        #expect(s.voiceIndicator(forPort: "p") == nil, "the download was pinned to a tile")
        #expect(s.voiceIndicatorForSpace?.label == "downloading speech model 40%")
    }

    @Test("a hold shows on its own tile while the space shows the model")
    func holdAndDownloadAtOnce() throws {
        let s = try shell()
        s.voiceModel = .loading(0)
        s.voiceCapturing = true
        s.voiceAnchorPortId = "p"
        s.voicePartial = "hello"

        #expect(s.voiceIndicator(forPort: "p")?.label == "hello")
        #expect(s.voiceIndicator(forPort: "other") == nil)
        #expect(s.voiceIndicatorForSpace?.label == "loading speech model")
    }
}
