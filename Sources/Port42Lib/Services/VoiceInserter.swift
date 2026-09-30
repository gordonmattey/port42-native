import AppKit

/// Puts dictated text into whatever has the keyboard.
///
/// One path for all three surfaces. The chat field, a web port and a terminal all speak
/// `NSTextInputClient`, which is the same seam a keystroke arrives on: a surface cannot tell dictation
/// from typing, so none of them needs code of its own, and a port cannot opt out of being dictated into
/// any more than it can opt out of being typed into.
///
/// Nothing here posts a key event to the system. A posted event would need Accessibility, would reach
/// whatever is frontmost rather than what the shell believes is focused, and would let a hidden port
/// type into another app. Going through the responder that already has the keyboard is the narrow path,
/// and `submit` keeps to it: its Return is handed to that one responder, never posted.
public enum VoiceInserter {

    /// Dictation ends with a space, so the next word does not run into the last one, and so the space
    /// the hold took back is given back. Text that already ends in whitespace is left alone.
    static func payload(for text: String) -> String {
        guard let last = text.last else { return text }
        return last.isWhitespace ? text : text + " "
    }

    /// Show the words so far inline, as uncommitted text, while the hold is still open.
    ///
    /// This is the mechanism an input method uses: marked text appears in the surface, each mark replaces
    /// the last, and the text is either committed by `insertText` or dropped by `unmark`. So the words
    /// stream into the field as they are heard while nothing is yet in the document, which is what makes
    /// trailing off mid-sentence cost nothing.
    @discardableResult
    public static func mark(_ text: String, into responder: NSResponder?) -> Bool {
        guard !text.isEmpty, let client = responder as? NSTextInputClient else { return false }
        client.setMarkedText(text,
                             selectedRange: NSRange(location: (text as NSString).length, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }

    /// Drop uncommitted text, leaving the surface as it was. Used when a hold produced nothing.
    @discardableResult
    public static func unmark(_ responder: NSResponder?) -> Bool {
        guard let client = responder as? NSTextInputClient else { return false }
        client.unmarkText()
        return true
    }

    /// What it takes to turn `previous` into `next` with a keyboard: some backspaces, then some
    /// characters. Counted in characters, not bytes, because that is what one backspace removes.
    ///
    /// Terminals draw uncommitted (marked) text on one line at the cursor, so a spoken sentence longer
    /// than the window runs off the edge instead of wrapping (GM, Claude Code in a terminal tile,
    /// 2026-09-27). A TUI's own line editor wraps real characters correctly, so a terminal is streamed
    /// as edits rather than as a composition.
    static func edit(from previous: String, to next: String) -> (deletes: Int, insert: String) {
        let old = Array(previous), new = Array(next)
        var shared = 0
        while shared < old.count, shared < new.count, old[shared] == new[shared] { shared += 1 }
        return (old.count - shared, String(new[shared...]))
    }

    /// What a terminal should hold while the words are still coming: only what the recognizer has settled
    /// on, and never less than it already holds (GM, 2026-09-29).
    ///
    /// Streaming every guess meant backspacing whenever the recognizer revised a word, and in a narrow
    /// terminal a backspace across a wrap shrinks Claude Code's input box by a line and the retype grows it
    /// back; Claude Code repaints its whole screen on each change of height, so the tile flashed every few
    /// seconds. Settled means whole words both of the last two guesses agree on. The result only ever
    /// grows, so the input box only grows, a line at a time, as with typing; the unsettled tail waits in the
    /// voice pill, and the final read lands it on release.
    static func settled(streamed: String, previousGuess: String, guess: String) -> String {
        // Word by word, and only past what is already typed. Comparing whole guesses from the start
        // stalled everything once the recognizer revised an early word (a capital, a comma), so the
        // words stopped and all landed on release (GM, 2026-09-29, "it's batching"). A revision to a
        // word already typed is left alone here; the final read corrects it once, on release.
        let typed = streamed.split(whereSeparator: \.isWhitespace).count
        let prev = previousGuess.split(whereSeparator: \.isWhitespace).map(String.init)
        let cur = guess.split(whereSeparator: \.isWhitespace).map(String.init)
        var add: [String] = []
        var i = typed
        // A word counts once the next guess agrees on it; the last word of a guess may still be changing.
        while i < cur.count - 1, i < prev.count, cur[i] == prev[i] {
            add.append(cur[i]); i += 1
        }
        // A guess that repeats unchanged is settled whole, last word included.
        if i == cur.count - 1, i < prev.count, cur == prev { add.append(cur[i]) }
        guard !add.isEmpty else { return streamed }
        let lead = streamed.isEmpty || streamed.last?.isWhitespace == true ? "" : " "
        let tail = add.count + typed == cur.count && cur == prev ? "" : " "
        return streamed + lead + add.joined(separator: " ") + tail
    }

    /// Stream `next` into a surface that wants real characters, replacing whatever `previous` put there.
    /// Returns what the surface now holds, so the caller can pass it back as `previous`.
    @discardableResult
    public static func stream(_ next: String, previous: String, into responder: NSResponder?) -> String {
        guard let client = responder as? NSTextInputClient else { return previous }
        let (deletes, insert) = edit(from: previous, to: next)
        for _ in 0..<deletes { client.doCommand(by: #selector(NSResponder.deleteBackward(_:))) }
        if !insert.isEmpty {
            client.insertText(insert, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        return next
    }

    /// Press Return in the surface the words went to, so releasing the space sends what was said (GM,
    /// 2026-09-27). A key event, not `doCommand(insertNewline:)`: the terminal (Ghostty) takes Return only
    /// as a key, the chat field turns the key into its submit, and a web port sees a real keydown. It is
    /// handed to this responder alone, so it cannot land anywhere the words did not.
    @discardableResult
    public static func submit(into responder: NSResponder?) -> Bool {
        guard let responder, responder is NSTextInputClient else { return false }
        let window = (responder as? NSView)?.window
        guard let down = returnKey(.keyDown, in: window), let up = returnKey(.keyUp, in: window) else { return false }
        responder.keyDown(with: down)
        responder.keyUp(with: up)
        return true
    }

    static let returnKeyCode: UInt16 = 36

    static func returnKey(_ type: NSEvent.EventType, in window: NSWindow?) -> NSEvent? {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
                         context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                         isARepeat: false, keyCode: returnKeyCode)
    }

    /// Insert `text` into `responder`. Returns false when there is nowhere to type, so the caller can
    /// say so instead of dropping what was heard. Uncommitted text from `mark` is replaced, because
    /// NSNotFound means "the marked range or the selection", which is what an input method commits over.
    @discardableResult
    public static func insert(_ text: String, into responder: NSResponder?) -> Bool {
        guard !text.isEmpty, let responder else { return false }
        let payload = payload(for: text)

        // Conformance to NSTextInputClient is the whole test. `responds(to: "insertText:")` is not:
        // NSResponder declares that method, so EVERY responder answers yes to it, including a button
        // and the desktop. Measured by a test that expected a deaf responder to refuse and got true.
        guard let client = responder as? NSTextInputClient else { return false }
        // NSNotFound means "at the insertion point, replacing the selection", which is exactly what a
        // typed character does.
        client.insertText(payload, replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }
}
