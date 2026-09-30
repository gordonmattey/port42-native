import Testing
import Foundation
@testable import Port42Lib

/// A long dictation (GM, 2026-09-29, on 1.0.4): a hold that ran long lost its words at the old 45 second
/// limit, and the whole-buffer re-reads it had queued kept the model busy after it ended. The limit is now
/// two minutes and keeps the words; re-reads space out as the hold grows; a late re-read never lands in the
/// next hold.
@Suite("Voice: a long hold keeps its words and does not jam the next one")
struct VoiceLongHoldTriggerTests {

    let space = VoiceTrigger.spaceKeyCode

    private func capturing() -> VoiceTrigger {
        var t = VoiceTrigger()
        _ = t.keyDown(keyCode: space, hasModifiers: false, isRepeat: false, now: 0)
        _ = t.thresholdElapsed()
        return t
    }

    @Test("the limit is two minutes")
    func limitIsTwoMinutes() {
        #expect(VoiceTrigger.maximumHold == 120)
    }

    @Test("reaching the limit ends the hold as a release does")
    func limitEndsCapture() {
        var t = capturing()
        #expect(t.reachedLimit() == .endCapture)
        #expect(!t.isCapturing)
    }

    @Test("a space still held after the limit types nothing, and its release starts nothing")
    func heldSpaceAfterLimitIsQuiet() {
        var t = capturing()
        _ = t.reachedLimit()
        for i in 0..<10 {
            #expect(t.keyDown(keyCode: space, hasModifiers: false, isRepeat: true, now: 120 + Double(i) * 0.03) == .consume)
        }
        #expect(!t.isPending, "a repeat after the limit armed a new hold")
        #expect(t.keyUp(keyCode: space, now: 121) == .passThrough)
        // And the next press is an ordinary one again.
        #expect(t.keyDown(keyCode: space, hasModifiers: false, isRepeat: false, now: 122) == .passThrough)
        #expect(t.isPending)
    }

    @Test("other keys work again once the limit is reached")
    func keyboardFreedAtLimit() {
        var t = capturing()
        #expect(t.keyDown(keyCode: 0, hasModifiers: false, isRepeat: false, now: 1) == .consume)
        _ = t.reachedLimit()
        #expect(t.keyDown(keyCode: 0, hasModifiers: false, isRepeat: false, now: 121) == .passThrough)
    }

    @Test("a fresh press after the limit, with the release never seen, starts over")
    func freshPressAfterLimit() {
        var t = capturing()
        _ = t.reachedLimit()
        #expect(t.keyDown(keyCode: space, hasModifiers: false, isRepeat: false, now: 130) == .passThrough)
        #expect(t.isPending)
    }

    @Test("the limit does nothing when no hold is open")
    func limitWithoutHold() {
        var t = VoiceTrigger()
        #expect(t.reachedLimit() == .passThrough)
    }

    @Test("re-reads space out as they get slower, never below the floor")
    func partialGapGrows() {
        #expect(VoiceSession.partialGap(interval: 0.5, lastRead: 0) == 0.5)
        #expect(VoiceSession.partialGap(interval: 0.5, lastRead: 0.1) == 0.5)
        #expect(VoiceSession.partialGap(interval: 0.5, lastRead: 0.6) == 1.2)
        #expect(VoiceSession.partialGap(interval: 0.5, lastRead: 2) == 4)
    }
}

private final class LongSource: VoiceAudioSource {
    var starts = 0
    var isRunning = false
    var samples: [Float] = Array(repeating: 0.05, count: 16_000 * 110)   // 110 seconds
    func start() throws { starts += 1; isRunning = true }
    func stop() -> [Float] { isRunning = false; return samples }
    func snapshot() -> [Float] { samples }
}

/// Holds each call until the test lets it go, so a re-read can be caught in flight.
private actor GatedTranscriber: VoiceTranscriber {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var answers: [String]
    init(_ answers: [String]) { self.answers = answers }
    func transcribe(_ samples: [Float]) async throws -> String {
        await withCheckedContinuation { waiting.append($0) }
        return answers.isEmpty ? "" : answers.removeFirst()
    }
    var inFlight: Int { waiting.count }
    func release() { if !waiting.isEmpty { waiting.removeFirst().resume() } }
}

private struct Instant: VoiceTranscriber {
    func transcribe(_ samples: [Float]) async throws -> String { "the whole two minutes" }
}

@Suite("Voice session: the end of a long hold")
@MainActor
struct VoiceLongHoldSessionTests {

    private func session(_ t: VoiceTranscriber) -> (VoiceSession, LongSource) {
        let source = LongSource()
        let s = VoiceSession(source: source, transcriber: t, modelIsReady: { true }, model: .ready,
                             micGranted: { true }, askForPermissions: {})
        s.partialInterval = 0            // partials are driven by hand here
        return (s, source)
    }

    @Test("a hold ended at the limit reports its words, marked as cut off")
    func limitKeepsWords() async {
        let (s, _) = session(Instant())
        var texts: [String] = []
        s.onText = { texts.append($0) }
        s.begin()
        s.end(atLimit: true)
        await s.transcription?.value
        #expect(texts == ["the whole two minutes"])
        #expect(s.endedAtLimit)
    }

    @Test("the next hold starts clean after one cut off at the limit")
    func nextHoldAfterLimit() async {
        let (s, source) = session(Instant())
        var texts: [String] = []
        s.onText = { texts.append($0) }
        s.begin(); s.end(atLimit: true)
        await s.transcription?.value
        s.begin()
        #expect(s.isCapturing)
        #expect(source.starts == 2)
        #expect(!s.endedAtLimit, "a new hold still read as cut off, so its release would not send")
        s.end()
        await s.transcription?.value
        #expect(texts.count == 2)
    }

    @Test("a re-read that finishes after its hold is replaced says nothing in the new one")
    func lateReadStaysInItsHold() async {
        let gate = GatedTranscriber(["from the first hold", "second hold final"])
        let (s, _) = session(gate)
        var partials: [String] = []
        s.onPartial = { partials.append($0) }

        s.begin()
        let late = Task { await s.runPartialOnce() }
        while await gate.inFlight == 0 { await Task.yield() }
        s.end()                                  // its final read queues behind the re-read
        s.begin()                                // and the next hold opens straight away
        #expect(s.isCapturing)
        await gate.release()                     // the first hold's re-read lands now
        await late.value
        #expect(partials.isEmpty, "the first hold's words appeared in the second: \(partials)")
        while await gate.inFlight == 0 { await Task.yield() }
        await gate.release()
        await s.transcription?.value
        s.abandon()
    }
}

/// The real model on a full two-minute buffer: that it reads one at all, and how long a read takes, which
/// is what `partialGap` spaces re-reads by. Opt in (`PORT42_VOICE_BENCH=1`): it needs the weights in this
/// machine's cache and the Neural Engine.
@Suite("Voice: the real model on two minutes of audio")
struct VoiceLongHoldBench {
    @Test("a two-minute buffer is read, and the time is reported",
          .enabled(if: ProcessInfo.processInfo.environment["PORT42_VOICE_BENCH"] == "1"))
    func twoMinutes() async throws {
        let t = FluidVoiceTranscriber()
        try await t.prepare(downloadAllowed: false) { _ in }
        #expect(await t.isReady())
        for seconds in [10, 45, 120] {
            let samples = (0..<(16_000 * seconds)).map { i in Float(sin(Double(i) * 0.05) * 0.02) }
            let started = Date()
            _ = try await t.transcribe(samples)
            print("[bench] \(seconds)s of audio read in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        }
    }
}
