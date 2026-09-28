import Foundation

/// Hold space to talk, without making space slow to type.
///
/// Space is a printing character, so the trigger cannot simply claim it. The distinction is
/// DURATION: at typing speed the key is down for roughly 80 to 120 ms, and held past `threshold` it
/// is intent rather than a character.
///
/// Three ways to handle the window before the threshold resolves, and this is the third:
/// withholding the space until it resolves would put the threshold's worth of lag on every space
/// typed; waiting for the system's key repeat is free but its delay is a user preference and can
/// exceed a second, by which point several spaces have been typed. So the space is **inserted
/// normally** and **retracted** if the hold completes. One character appears and vanishes, and
/// typing is untouched.
///
/// Pure and synchronous: the caller owns the clock and the timer, so the whole behavior is testable
/// without a window, a key or a run loop.
public struct VoiceTrigger {

    /// What the caller should do with the event it just reported.
    public enum Action: Equatable {
        /// Let the key through. Typing must not be affected by a feature that is not firing.
        case passThrough
        /// Swallow the key. Used for the repeats that arrive while a hold is in progress: the user
        /// is holding to talk, and the system would otherwise type a run of spaces.
        case consume
        /// The hold completed. Retract the character already inserted, then begin capturing.
        case beginCapture
        /// The key came up while capturing. Stop, and transcribe what was captured.
        case endCapture
    }

    /// How long the key must be held before it stops being a character. Above a typing keystroke
    /// (80 to 120 ms) and below a deliberate press feeling sluggish.
    public static let threshold: TimeInterval = 0.2

    /// A hold longer than this is a stuck state, not a sentence. While capturing, the trigger swallows every
    /// key (the hold owns the keyboard), so a release that is never seen would leave the keyboard dead until the
    /// app is quit: it happened, and it looked like the app had hung. Both paths cancel on this.
    public static let maximumHold: TimeInterval = 45

    /// The space bar. `kVK_Space`.
    public static let spaceKeyCode: UInt16 = 49

    private enum State: Equatable {
        case idle
        /// Space is down and the threshold has not yet elapsed. The character is already inserted.
        case pending(since: TimeInterval)
        /// The hold completed and audio is being captured.
        case capturing
    }

    private var state: State = .idle

    public init() {}

    public var isCapturing: Bool { state == .capturing }

    /// True while a hold is undecided, so a caller can arm a timer for `threshold` from `now`.
    public var isPending: Bool { if case .pending = state { return true }; return false }

    /// A key went down. `isRepeat` is the system's auto-repeat, which is itself evidence of a hold.
    ///
    /// Any modifier disqualifies the key: a space with Command or Option belongs to whatever binding
    /// owns it, and a feature that swallowed those would break more than it added.
    public mutating func keyDown(keyCode: UInt16, hasModifiers: Bool, isRepeat: Bool,
                                 now: TimeInterval) -> Action {
        guard keyCode == Self.spaceKeyCode, !hasModifiers else {
            // A different key during a hold is not a character the user wants; the hold owns the
            // keyboard until it ends.
            return state == .capturing ? .consume : .passThrough
        }
        switch state {
        case .idle:
            guard !isRepeat else { return .passThrough }   // a repeat with no down is not ours
            state = .pending(since: now)
            return .passThrough                            // the space types, as it always did
        case .pending:
            // The system started repeating before the threshold elapsed, which means the key is
            // held. Swallow the repeat; the timer still decides when capture begins.
            return .consume
        case .capturing:
            return .consume
        }
    }

    /// The threshold elapsed with the key still down. The caller arms this after a `.pending`
    /// `keyDown` and cancels it on key-up.
    public mutating func thresholdElapsed() -> Action {
        guard case .pending = state else { return .passThrough }
        state = .capturing
        return .beginCapture
    }

    /// A key came up.
    public mutating func keyUp(keyCode: UInt16, now: TimeInterval) -> Action {
        guard keyCode == Self.spaceKeyCode else { return .passThrough }
        switch state {
        case .idle:
            return .passThrough
        case .pending:
            // A tap. The space is already where it should be and nothing else happens.
            state = .idle
            return .passThrough
        case .capturing:
            state = .idle
            return .endCapture
        }
    }

    /// Abandon whatever is in progress, for a window losing focus or the app resigning active. A
    /// hold that survives losing the keyboard would capture audio nobody asked for.
    public mutating func cancel() -> Action {
        let wasCapturing = state == .capturing
        state = .idle
        return wasCapturing ? .endCapture : .passThrough
    }
}
