import Testing
import AppKit
@testable import Port42Lib

/// The chat laid out as every chat app is (GM, 2026-09-27): the person's messages right, others left
/// under their name, runs from one sender grouped, the time of the top message shown while scrolling.
@Suite("Chat transcript layout")
struct ChatTranscriptTests {

    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    func e(_ seq: Int, _ id: String, _ name: String, _ text: String, at: TimeInterval = 0) -> PortChatEntry {
        PortChatEntry(seq: seq, at: t0.addingTimeInterval(at), text: text, fromId: id, fromName: name, fromKind: "human")
    }

    func alignment(_ b: ChatTranscript.Built, of message: Int) -> NSTextAlignment? {
        let r = b.ranges[message]
        let p = b.text.attribute(.paragraphStyle, at: r.location + r.length - 1, effectiveRange: nil) as? NSParagraphStyle
        return p?.alignment
    }

    @Test("my messages are on the right with no name; others on the left under their name")
    func sides() {
        let b = ChatTranscript.build([e(1, "me", "gordon", "hi"), e(2, "a", "alpha", "hello")], me: "me", accent: .green)
        #expect(alignment(b, of: 0) == .right)
        #expect(alignment(b, of: 1) == .left)
        #expect(b.text.string == "hi\nalpha\nhello", "my own name is not shown; theirs is")
    }

    @Test("with no person known, every message is someone else's")
    func noMe() {
        let b = ChatTranscript.build([e(1, "me", "gordon", "hi")], me: nil, accent: .green)
        #expect(alignment(b, of: 0) == .left)
    }

    @Test("a run from one sender shows its name once; a pause or another sender starts a new group")
    func grouping() {
        let b = ChatTranscript.build([
            e(1, "a", "alpha", "one"), e(2, "a", "alpha", "two", at: 30),
            e(3, "b", "beta", "three", at: 60), e(4, "a", "alpha", "four", at: 90),
            e(5, "a", "alpha", "five", at: 90 + 600),
        ], me: nil, accent: .green)
        #expect(b.text.string == "alpha\none\ntwo\nbeta\nthree\nalpha\nfour\nalpha\nfive")
    }

    @Test("each message's range covers its name and every line, so the scroll time finds it")
    func ranges() {
        let b = ChatTranscript.build([e(1, "a", "alpha", "line 1\nline 2"), e(2, "b", "beta", "x", at: 5)], me: nil, accent: .green)
        let s = b.text.string as NSString
        #expect(s.substring(with: b.ranges[0]) == "alpha\nline 1\nline 2\n")
        #expect(s.substring(with: b.ranges[1]) == "beta\nx")
        #expect(ChatTranscript.message(at: 0, in: b.ranges) == 0)
        #expect(ChatTranscript.message(at: b.ranges[1].location, in: b.ranges) == 1)
        #expect(ChatTranscript.message(at: b.text.length + 5, in: b.ranges) == 1)
        #expect(ChatTranscript.message(at: 3, in: []) == nil)
    }

    @Test("each message carries its time for hover")
    func tooltip() {
        let b = ChatTranscript.build([e(1, "a", "alpha", "hi")], me: nil, accent: .green)
        #expect(b.text.attribute(.toolTip, at: 0, effectiveRange: nil) as? String == ChatTranscript.tooltip(t0))
    }

    @Test("the scroll pill names the day when it is near, then the time")
    func label() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 15))!
        func at(_ d: Int, _ h: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 9, day: d, hour: h))! }
        #expect(ChatTranscript.label(at(27, 9), now: now, calendar: cal).hasPrefix("today "))
        #expect(ChatTranscript.label(at(26, 9), now: now, calendar: cal).hasPrefix("yesterday "))
        #expect(!ChatTranscript.label(at(23, 9), now: now, calendar: cal).contains("Sep"), "within the week: a weekday")
        #expect(ChatTranscript.label(at(2, 9), now: now, calendar: cal).contains("Sep"))
    }
}
