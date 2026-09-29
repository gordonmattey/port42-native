import AppKit

/// The sound of hold-to-talk (GM, 2026-09-29, picked by ear): Bottle when listening starts and Glass when
/// the key comes up, so a hold is heard as well as seen. Never Tink: it is macOS's default alert sound,
/// and a start cue that sounds like an error is worse than none (the first choice did exactly that). Before this there was no sound of our own; the
/// beep people heard was macOS refusing a delete the terminal did not take (fixed the same day).
///
/// System sounds, quiet, and never the alert sound. Off with
/// `defaults write <bundle id> voiceCueSounds -bool false`.
enum VoiceCue {
    enum Moment { case start, end }

    static let enabledKey = "voiceCueSounds"

    static func sound(for moment: Moment) -> (name: String, volume: Float) {
        switch moment {
        case .start: return ("Bottle", 0.5)
        case .end:   return ("Glass", 0.4)
        }
    }

    static func play(_ moment: Moment) {
        guard UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true else { return }
        let (name, volume) = sound(for: moment)
        // A copy, so a quick start and end do not cut each other off.
        guard let s = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        s.volume = volume
        s.play()
    }
}
