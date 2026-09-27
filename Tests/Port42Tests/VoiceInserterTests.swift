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

    func insertText(_ string: Any, replacementRange: NSRange) {
        inserted.append((string as? String) ?? (string as? NSAttributedString)?.string ?? "")
        ranges.append(replacementRange)
    }
    override func doCommand(by selector: Selector) {}
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    func unmarkText() {}
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
