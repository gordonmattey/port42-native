import Testing
import Foundation
@testable import Port42Lib

/// Hold space to talk, without making space slow to type.
///
/// The property that matters most is the one about NOT firing: a person types thousands of spaces a
/// day and dictates occasionally, so every test here is really asking whether ordinary typing
/// survives the feature.
@Suite("Voice trigger: hold space, insert and retract")
struct VoiceTriggerTests {

    let space = VoiceTrigger.spaceKeyCode
    let threshold = VoiceTrigger.threshold

    // MARK: typing is untouched

    @Test("a tapped space types a space and starts nothing")
    func tapTypes() {
        var t = VoiceTrigger()
        #expect(t.keyDown(keyCode: space, hasModifiers: false, isRepeat: false, now: 0) == .passThrough)
        #expect(t.keyUp(keyCode: space, now: 0.09) == .passThrough)
        #expect(!t.isCapturing)
    }

    @Test("a fast run of spaces all pass through")
    func fastTypingPassesThrough() {
        var t = VoiceTrigger()
        var now = 0.0
        for _ in 0..<20 {
            #expect(t.keyDown(keyCode: space, hasModifiers: false, isRepeat: false, now: now) == .passThrough)
            now += 0.08
            #expect(t.keyUp(keyCode: space, now: now) == .passThrough)
            now += 0.05
        }
        #expect(!t.isCapturing)
    }

    @Test("a space with any modifier is not ours")
    func modifiedSpaceIsUntouched() {
        var t = VoiceTrigger()
        #expect(t.keyDown(keyCode: space, hasModifiers: true, isRepeat: false, now: 0) == .passThrough)
        #expect(!t.isPending, "a modified space must not arm the threshold")
        #expect(t.keyUp(keyCode: space, now: 1.0) == .passThrough)
    }

    @Test("other keys pass through untouched")
    func otherKeysPassThrough() {
        var t = VoiceTrigger()
        #expect(t.keyDown(keyCode: 0, hasModifiers: false, isRepeat: false, now: 0) == .passThrough)
        #expect(t.keyUp(keyCode: 0, now: 0.1) == .passThrough)
    }

    // MARK: the hold

    @Test("holding past the threshold begins capture, and the caller retracts the space")
    func holdBeginsCapture() {
        var t = VoiceTrigger()
        #expect(t.keyDown(keyCode: space, hasModifiers: false, isRepeat: false, now: 0) == .passThrough)
        #expect(t.isPending, "the caller arms its timer from here")
        #expect(t.thresholdElapsed() == .beginCapture)
        #expect(t.isCapturing)
    }

    @Test("releasing after a hold ends capture")
    func releaseEndsCapture() {
        var t = VoiceTrigger()
        _ = t.keyDown(keyCode: space, hasModifiers: false, isRepeat: false, now: 0)
        _ = t.thresholdElapsed()
        #expect(t.keyUp(keyCode: space, now: 3.0) == .endCapture)
        #expect(!t.isCapturing)
    }

    @Test("key repeat during a hold types no extra spaces")
    func repeatsAreSwallowed() {
        var t = VoiceTrigger()
        _ = t.keyDown(keyCode: space, hasModifiers: false, isRepeat: false, now: 0)
        // The system may begin repeating before or after the threshold; both are swallowed.
        #expect(t.keyDown(keyCode: space, hasModifiers: false, isRepeat: true, now: 0.15) == .consume)
        _ = t.thresholdElapsed()
        #expect(t.keyDown(keyCode: space, hasModifiers: false, isRepeat: true, now: 0.30) == .consume)
        #expect(t.keyDown(keyCode: space, hasModifiers: false, isRepeat: true, now: 0.35) == .consume)
    }

    @Test("a repeat with no preceding press is not a hold")
    func orphanRepeatIsNotAHold() {
        var t = VoiceTrigger()
        #expect(t.keyDown(keyCode: space, hasModifiers: false, isRepeat: true, now: 0) == .passThrough)
        #expect(!t.isPending)
    }

    @Test("typing while holding is swallowed, because the hold owns the keyboard")
    func otherKeysDuringCaptureAreSwallowed() {
        var t = VoiceTrigger()
        _ = t.keyDown(keyCode: space, hasModifiers: false, isRepeat: false, now: 0)
        _ = t.thresholdElapsed()
        #expect(t.keyDown(keyCode: 0, hasModifiers: false, isRepeat: false, now: 0.5) == .consume)
    }

    // MARK: the threshold is not armed twice

    @Test("the threshold firing without a pending hold does nothing")
    func strayThresholdIsHarmless() {
        var t = VoiceTrigger()
        #expect(t.thresholdElapsed() == .passThrough)
        #expect(!t.isCapturing)
    }

    @Test("a tap then a late threshold does not start capture")
    func cancelledTimerCannotFireLate() {
        var t = VoiceTrigger()
        _ = t.keyDown(keyCode: space, hasModifiers: false, isRepeat: false, now: 0)
        _ = t.keyUp(keyCode: space, now: 0.09)          // tapped, so the caller cancels its timer
        #expect(t.thresholdElapsed() == .passThrough,   // but if it fires anyway, nothing happens
                "a late timer must not start capture after the key came up")
        #expect(!t.isCapturing)
    }

    // MARK: losing the keyboard

    @Test("losing focus while capturing ends capture")
    func cancelEndsCapture() {
        var t = VoiceTrigger()
        _ = t.keyDown(keyCode: space, hasModifiers: false, isRepeat: false, now: 0)
        _ = t.thresholdElapsed()
        #expect(t.cancel() == .endCapture, "a hold must not outlive the keyboard")
        #expect(!t.isCapturing)
    }

    @Test("losing focus while pending starts nothing")
    func cancelWhilePendingIsQuiet() {
        var t = VoiceTrigger()
        _ = t.keyDown(keyCode: space, hasModifiers: false, isRepeat: false, now: 0)
        #expect(t.cancel() == .passThrough)
        #expect(!t.isPending && !t.isCapturing)
    }

    @Test("a second hold works after the first")
    func holdsRepeat() {
        var t = VoiceTrigger()
        for round in 0..<3 {
            let base = Double(round)
            _ = t.keyDown(keyCode: space, hasModifiers: false, isRepeat: false, now: base)
            #expect(t.thresholdElapsed() == .beginCapture)
            #expect(t.keyUp(keyCode: space, now: base + 0.5) == .endCapture)
        }
    }
}
