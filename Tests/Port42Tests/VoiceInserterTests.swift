import Testing
import AppKit
@testable import Port42Lib

// Phase 3 of voice input: the text reaches the surface that has the keyboard.
//
// The responder is passed in, so this runs without a window: what is under test is which seam is used
// and what is sent, not AppKit's own delivery.

/// A surface that speaks the modern seam, the one the chat field, a web port and a terminal all use.
private final class FakeInputClient: NSResponder, NSTextInputClient {
    var inserted: [String] = []
    var ranges: [NSRange] = []
    var marked: [String] = []
    var markCarets: [Int] = []
    var unmarks = 0

    func insertText(_ string: Any, replacementRange: NSRange) {
        inserted.append((string as? String) ?? (string as? NSAttributedString)?.string ?? "")
        ranges.append(replacementRange)
    }
    override func doCommand(by selector: Selector) {}
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked.append((string as? String) ?? (string as? NSAttributedString)?.string ?? "")
        markCarets.append(selectedRange.location)
    }
    func unmarkText() { unmarks += 1 }
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { false }
    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}

/// A surface that types nothing: a button, a list, the desktop itself.
private final class DeafResponder: NSResponder {}

@Suite("Voice insertion: one path for the field, the web port and the terminal")
struct VoiceInserterTests {

    @Test("text goes to the surface that has the keyboard, at the insertion point")
    func insertsAtInsertionPoint() {
        let client = FakeInputClient()
        #expect(VoiceInserter.insert("hello there", into: client))
        #expect(client.inserted == ["hello there "])
        // NSNotFound is what a typed character uses: at the insertion point, replacing the selection.
        #expect(client.ranges.first?.location == NSNotFound)
    }

    @Test("dictation ends with one space, and a space is never doubled")
    func oneTrailingSpace() {
        #expect(VoiceInserter.payload(for: "hello") == "hello ")
        #expect(VoiceInserter.payload(for: "hello ") == "hello ")
        #expect(VoiceInserter.payload(for: "hello\n") == "hello\n")
        #expect(VoiceInserter.payload(for: "") == "")
    }

    /// Conformance is the test, not `responds(to:)`. NSResponder declares `insertText:`, so every
    /// responder answers yes to it: a button, a list, the desktop. This test is why the selector check
    /// is not in the code.
    @Test("a surface that is not a text client is refused, although AppKit says it answers insertText:")
    func selectorCheckWouldBeWrong() {
        let deaf = DeafResponder()
        #expect(deaf.responds(to: Selector(("insertText:"))), "AppKit changed: NSResponder no longer declares insertText:")
        #expect(VoiceInserter.insert("hi", into: deaf) == false)
    }

    /// Partials stream in the way an input method composes: each mark replaces the last, the caret sits
    /// at the end of the words so far, and nothing is in the document until the commit.
    @Test("the words so far are marked, not inserted, and each mark replaces the last")
    func marksWhileHolding() {
        let client = FakeInputClient()
        #expect(VoiceInserter.mark("hello", into: client))
        #expect(VoiceInserter.mark("hello there", into: client))
        #expect(client.marked == ["hello", "hello there"])
        #expect(client.markCarets == [5, 11], "the caret is not at the end of the marked text")
        #expect(client.inserted.isEmpty, "a partial was committed to the document")
    }

    @Test("the release commits over the marked text")
    func commitReplacesTheMark() {
        let client = FakeInputClient()
        VoiceInserter.mark("hello ther", into: client)
        #expect(VoiceInserter.insert("hello there", into: client))
        // NSNotFound means the marked range or the selection, which is what an input method commits over.
        #expect(client.ranges.last?.location == NSNotFound)
        #expect(client.inserted == ["hello there "])
    }

    @Test("a hold that produced nothing leaves no uncommitted text")
    func unmarkOnSilence() {
        let client = FakeInputClient()
        VoiceInserter.mark("hel", into: client)
        #expect(VoiceInserter.unmark(client))
        #expect(client.unmarks == 1)
        #expect(client.inserted.isEmpty)
    }

    @Test("an empty partial marks nothing")
    func emptyPartial() {
        let client = FakeInputClient()
        #expect(VoiceInserter.mark("", into: client) == false)
        #expect(client.marked.isEmpty)
    }

    @Test("nowhere to type is reported, not swallowed")
    func nowhereToType() {
        #expect(VoiceInserter.insert("hi", into: DeafResponder()) == false)
        #expect(VoiceInserter.insert("hi", into: nil) == false)
    }

    @Test("empty text inserts nothing")
    func emptyText() {
        let client = FakeInputClient()
        #expect(VoiceInserter.insert("", into: client) == false)
        #expect(client.inserted.isEmpty)
    }

    /// The reason this type exists. A synthesized key event would need Accessibility, would land in
    /// whatever is frontmost rather than the focused port, and would let a hidden port type into another
    /// app. Phase 5 is where Accessibility is asked for explicitly, for other apps.
    @Test("no code on the voice path synthesizes key events")
    func noSyntheticEvents() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var offenders: [String] = []
        for case let url as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        where url.pathExtension == "swift" && url.lastPathComponent.hasPrefix("Voice") {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                if code.contains("CGEvent") || code.contains("postToPid") || code.contains("keyboardEventSource") {
                    offenders.append("\(url.lastPathComponent):\(i + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "the voice path synthesizes key events at \(offenders)")
    }
}

@Suite("Streaming into a terminal: real characters, smallest edit")
struct VoiceStreamEditTests {

    /// GM, 2026-09-27, Claude Code in a terminal tile: a spoken sentence longer than the window ran off
    /// the end of the first line instead of wrapping, because a terminal draws marked text on one line at
    /// the cursor. A TUI's line editor wraps real characters, so a terminal is streamed as edits.
    @Test("extending the sentence sends only the new words")
    func appendOnly() {
        let e = VoiceInserter.edit(from: "hello", to: "hello there")
        #expect(e.deletes == 0)
        #expect(e.insert == " there")
    }

    @Test("a revised word costs only the characters that changed")
    func revision() {
        let e = VoiceInserter.edit(from: "hello there", to: "hello their")
        #expect(e.deletes == 2)          // "re"
        #expect(e.insert == "ir")
    }

    @Test("clearing sends one backspace per character")
    func clearing() {
        let e = VoiceInserter.edit(from: "hello", to: "")
        #expect(e.deletes == 5)
        #expect(e.insert.isEmpty)
    }

    @Test("the first partial is all insert")
    func firstPartial() {
        let e = VoiceInserter.edit(from: "", to: "hi")
        #expect(e.deletes == 0)
        #expect(e.insert == "hi")
    }

    /// Counted in characters, not bytes: one backspace removes one character, however many bytes it is.
    @Test("an emoji is one backspace, not four")
    func graphemes() {
        let e = VoiceInserter.edit(from: "ok 👍", to: "ok")
        #expect(e.deletes == 2)          // the space and the emoji
        #expect(e.insert.isEmpty)
    }

    @Test("no change sends nothing")
    func noChange() {
        let e = VoiceInserter.edit(from: "same", to: "same")
        #expect(e.deletes == 0 && e.insert.isEmpty)
    }
}
