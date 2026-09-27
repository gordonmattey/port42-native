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

    @Test("a copy across messages carries each one's time and sender, mine included; within one message it is plain")
    func copy() {
        let b = ChatTranscript.build([e(1, "me", "gordon", "make it warmer"), e(2, "a", "alpha", "done, v3 is up", at: 60)],
                                     me: "me", accent: .green)
        let all = NSRange(location: 0, length: b.text.length)
        #expect(ChatTranscript.copyText(b, selection: all) ==
                "[\(ChatTranscript.tooltip(t0))] gordon: make it warmer\n[\(ChatTranscript.tooltip(t0.addingTimeInterval(60)))] alpha: done, v3 is up")
        // Starting mid-way through the first message cuts it there.
        let s = b.text.string as NSString
        let from = s.range(of: "warmer").location
        let partial = ChatTranscript.copyText(b, selection: NSRange(location: from, length: b.text.length - from))
        #expect(partial?.hasPrefix("[\(ChatTranscript.tooltip(t0))] gordon: warmer\n") == true)
        #expect(ChatTranscript.copyText(b, selection: s.range(of: "v3 is")) == nil)
    }

    @Test("opening a chat scrolls to its end without raising (the crash on opening a port's chat, Dev5 2026-09-27)")
    @MainActor
    func scrollBeforeLayout() throws {
        let scroll = ChatTranscriptView.makeScroll()
        let text = try #require(scroll.documentView as? NSTextView)
        #expect(text.textLayoutManager == nil, "TextKit 2 raised when scrolled before its first layout")
        let b = ChatTranscript.build((1...40).map { e($0, "a", "alpha", "line \($0)", at: Double($0)) }, me: nil, accent: .green)
        text.textStorage?.setAttributedString(b.text)
        ChatTranscriptView.scrollToEnd(scroll)          // no window, no layout yet: must not throw
        scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
        ChatTranscriptView.scrollToEnd(scroll)
        #expect(scroll.contentView.bounds.maxY >= text.bounds.maxY - 1, "not at the newest message")
    }

    /// Updating in place must give exactly what a whole rebuild gives: the same text, the same ranges.
    func check(_ steps: [[PortChatEntry]], inPlace expected: [Bool]) {
        let storage = NSMutableAttributedString()
        var layout = ChatTranscript.Layout()
        var done: [Bool] = []
        for list in steps {
            done.append(ChatTranscript.update(storage, &layout, to: list, me: "me", accent: .green))
            let whole = ChatTranscript.build(list, me: "me", accent: .green)
            #expect(storage.string == whole.text.string)
            #expect(layout.ranges == whole.ranges)
            #expect(layout.bodyRanges == whole.bodyRanges)
        }
        #expect(done == expected)
    }

    @Test("new messages are appended in place, and the result is what a rebuild gives")
    func appendInPlace() {
        let a = [e(1, "a", "alpha", "one"), e(2, "a", "alpha", "two", at: 10)]
        let b = a + [e(3, "a", "alpha", "three", at: 20)]           // groups with the last
        let c = b + [e(4, "me", "gordon", "mine", at: 30), e(5, "b", "beta", "x\ny", at: 40)]
        check([a, b, c], inPlace: [false, true, true])
    }

    @Test("past what a chat keeps, the oldest are cut in place; a cut inside a sender's run rebuilds")
    func trimInPlace() {
        let a = [e(1, "a", "alpha", "one"), e(2, "b", "beta", "two", at: 400), e(3, "b", "beta", "three", at: 410)]
        let dropFirst = Array(a.dropFirst()) + [e(4, "me", "gordon", "four", at: 420)]   // cut at a sender change
        let cutRun = Array(dropFirst.dropFirst()) + [e(5, "a", "alpha", "five", at: 430)] // cuts inside beta's run
        check([a, dropFirst, cutRun], inPlace: [false, true, false])
    }

    @Test("Port42's notices read as system, dimmed, and are not a participant")
    @MainActor
    func systemNotices() throws {
        let notice = PortChatEntry(seq: 1, at: t0, text: "echo could not reply", fromId: ChatRouting.port42SenderId,
                                   fromName: "port42", fromKind: "peer")
        let b = ChatTranscript.build([notice, e(2, "a", "alpha", "hi", at: 5)], me: nil, accent: .green)
        #expect(b.text.string.hasPrefix("system\necho could not reply"))
        #expect(b.senders.first == "system")
        let store = PortChatStore()
        store.load("c", from: try DatabaseService(inMemory: true))
        store.received("c", notice)
        store.received("c", e(2, "a", "alpha", "hi", at: 5))
        #expect(store.participants("c").map(\.name) == ["alpha"])
    }
}
