import AppKit
import CoreGraphics

/// Types into an app that is not ours, by synthesizing keystrokes.
///
/// Inside Port42 the words go through `NSTextInputClient`, the seam a keystroke arrives on. Another app has
/// no such seam we can reach, so the words are typed. The alternative, setting text through the
/// accessibility API, works in TextEdit and fails in Electron apps and terminals, which is most of where
/// this is wanted.
///
/// This is the ONLY place in the app that synthesizes input, together with the tap that sees the key. It
/// needs Accessibility, and a test pins that nothing else on the voice path does this.
public struct VoiceTyper {

    /// `CGEventKeyboardSetUnicodeString` is not meant for long strings, so the text goes in short runs.
    private static let runLength = 16
    private static let backspaceKey: CGKeyCode = 51

    /// Type `text` into whatever has the keyboard right now.
    public static func type(_ text: String) {
        guard !text.isEmpty else { return }
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let run = Array(units[index..<min(index + runLength, units.count)])
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return }
            down.keyboardSetUnicodeString(stringLength: run.count, unicodeString: run)
            up.keyboardSetUnicodeString(stringLength: run.count, unicodeString: run)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            index += run.count
        }
    }

    /// Delete `count` characters, one backspace each, which is what one backspace removes.
    public static func backspace(_ count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            CGEvent(keyboardEventSource: nil, virtualKey: backspaceKey, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: nil, virtualKey: backspaceKey, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }

    /// Turn what is on screen into what was heard, with the smallest edit: some backspaces, then some
    /// characters. Returns what the app now holds, to pass back as `previous` on the next partial.
    @discardableResult
    public static func stream(_ next: String, previous: String) -> String {
        let (deletes, insert) = VoiceInserter.edit(from: previous, to: next)
        backspace(deletes)
        type(insert)
        return next
    }

    /// The app the words will land in, for the indicator.
    public static var frontmostAppName: String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    /// True when Port42 itself is frontmost, in which case the in-app path owns the hold and the tap must
    /// keep its hands off.
    public static var port42IsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
    }
}
