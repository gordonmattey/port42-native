import AppKit

/// Puts dictated text into whatever has the keyboard.
///
/// One path for all three surfaces. The chat field, a web port and a terminal all speak
/// `NSTextInputClient`, which is the same seam a keystroke arrives on: a surface cannot tell dictation
/// from typing, so none of them needs code of its own, and a port cannot opt out of being dictated into
/// any more than it can opt out of being typed into.
///
/// Nothing here synthesizes a key event. A synthetic event would need Accessibility, would reach
/// whatever is frontmost rather than what the shell believes is focused, and would let a hidden port
/// type into another app. Going through the responder that already has the keyboard is the narrow path.
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
