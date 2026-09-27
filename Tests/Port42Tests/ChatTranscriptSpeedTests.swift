import Testing
import AppKit
@testable import Port42Lib

/// A long chat opens without stalling (GM, 2026-09-27: opening the port chats in #port42-app, whose
/// biggest chat has 257 messages and ~280 KB, lagged and slowed the machine on the old one-SwiftUI-Text
/// transcript). Sized above that chat; the bound is loose, to catch a return to seconds, not to race.
@Suite("Chat transcript speed")
@MainActor
struct ChatTranscriptSpeedTests {
    @Test("300 messages of ~1,000 characters build and lay out in well under a second")
    func longChat() throws {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let body = String(repeating: "the shader reacts to the mic now, and the colors follow the beat. ", count: 15)
        let entries = (1...300).map { i in
            PortChatEntry(seq: i, at: t0.addingTimeInterval(Double(i * 40)), text: "\(i) \(body)",
                          fromId: i % 3 == 0 ? "me" : "a\(i % 4)", fromName: "agent-\(i % 4)", fromKind: "human")
        }
        let start = Date()
        let built = ChatTranscript.build(entries, me: "me", accent: .green)
        let scroll = ChatTranscriptView.makeScroll()
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 360)
        let text = try #require(scroll.documentView as? NSTextView)
        text.frame.size.width = 420
        text.textStorage?.setAttributedString(built.text)
        ChatTranscriptView.scrollToEnd(scroll)              // lays out the whole transcript
        let elapsed = Date().timeIntervalSince(start)
        print("[speed] 300 messages, \(built.text.length) chars: \(String(format: "%.3f", elapsed)) s")
        #expect(elapsed < 1.0)
    }

    @Test("a new message in a full chat (200 kept) is appended, not a rebuild of all of it")
    func newMessageInFullChat() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let body = String(repeating: "the colors follow the beat. ", count: 36)
        func entry(_ i: Int) -> PortChatEntry {
            PortChatEntry(seq: i, at: t0.addingTimeInterval(Double(i * 400)), text: "\(i) \(body)",
                          fromId: "a\(i % 3)", fromName: "agent-\(i % 3)", fromKind: "human")
        }
        let storage = NSMutableAttributedString()
        var layout = ChatTranscript.Layout()
        ChatTranscript.update(storage, &layout, to: (1...200).map(entry), me: nil, accent: .green)
        let start = Date()
        let inPlace = ChatTranscript.update(storage, &layout, to: (2...201).map(entry), me: nil, accent: .green)
        let elapsed = Date().timeIntervalSince(start)
        print("[speed] new message in a 200-message chat: \(String(format: "%.4f", elapsed)) s")
        #expect(inPlace)
        #expect(elapsed < 0.05)
    }
}
