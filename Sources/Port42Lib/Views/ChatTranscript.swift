import AppKit
import SwiftUI

/// A chat's transcript, laid out as every chat app does (GM, 2026-09-27): the person's own messages on
/// the right, everyone else's on the left under their name, consecutive messages from one sender
/// grouped. It stays ONE text, so a drag still selects and copies any number of messages (GM,
/// 2026-09-25); an AppKit text view, because SwiftUI's text can neither align paragraphs one by one
/// nor select across views. Each message carries its time as a tooltip, and the panel shows the time
/// of the top message in view while it scrolls.
enum ChatTranscript {
    struct Built {
        let text: NSAttributedString
        /// Each message's range in `text`, in order.
        let ranges: [NSRange]
        /// Each message's text alone (no name line), for copying.
        let bodyRanges: [NSRange]
        let senders: [String]
        let dates: [Date]
    }

    static let bodySize: CGFloat = 11.5
    /// Messages from one sender this close together are one group: no second name, less space.
    static let groupGap: TimeInterval = 300

    static func isMine(_ e: PortChatEntry, me: String?) -> Bool { me != nil && e.fromId == me }

    /// Port42's own notices (a turn that failed, a budget spent) read as "system", not as a sender
    /// named Port42 (GM, 2026-09-27). Stored notices keep their sender id, so older ones read the same.
    static func isSystem(_ e: PortChatEntry) -> Bool { e.fromId == ChatRouting.port42SenderId }

    static func senderName(_ e: PortChatEntry) -> String {
        isSystem(e) ? "system" : (e.fromName.isEmpty ? e.fromId : e.fromName)
    }

    /// Grouped under the message before it: the same sender, soon after.
    static func continues(_ e: PortChatEntry, after prev: PortChatEntry?) -> Bool {
        guard let prev else { return false }
        return prev.fromId == e.fromId && e.at.timeIntervalSince(prev.at) < groupGap
    }

    /// `after`: the message already shown before these, when appending to a transcript: it decides
    /// whether the first of these groups with it, and a line break is put first.
    /// The widest line `text` makes in `font` when wrapped at `max`.
    static func textWidth(_ text: String, font: NSFont, max: CGFloat) -> CGFloat {
        let r = (text as NSString).boundingRect(with: NSSize(width: max, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin], attributes: [.font: font])
        return ceil(r.width)
    }

    /// `width`: the line width the transcript is laid out at. With it, the person's own messages sit on
    /// the right as a block whose text reads left-aligned (GM, 2026-09-27: right-aligned lines left a
    /// wrapped message ragged on the left), each indented by the room its widest line leaves.
    static func build(_ entries: [PortChatEntry], me: String?, accent: NSColor, after prev: PortChatEntry? = nil,
                      width: CGFloat? = nil, now: Date = Date()) -> Built {
        let out = NSMutableAttributedString()
        var ranges: [NSRange] = []
        var bodyRanges: [NSRange] = []
        let body = NSFont.monospacedSystemFont(ofSize: bodySize, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        let theirs = NSColor(Port42Theme.textPrimary).withAlphaComponent(0.85)
        let mine = accent.blended(withFraction: 0.55, of: .white) ?? accent

        if prev != nil && !entries.isEmpty {
            out.append(NSAttributedString(string: "\n", attributes: [.font: body]))
        }
        for (i, e) in entries.enumerated() {
            let own = isMine(e, me: me)
            let before = i > 0 ? entries[i - 1] : prev
            let grouped = continues(e, after: before)
            let start = out.length
            let tip = tooltip(e.at)
            // Own messages: a right-hand block of left-aligned text when the width is known; right-aligned
            // lines before the first layout, when it is not.
            var ownIndent: CGFloat? = nil
            if own, let width, width > 96 {
                let widest = textWidth(ChatRouting.displayText(e.text), font: body, max: width - 48)
                ownIndent = Swift.max(48, width - widest)
            }
            func para(before: CGFloat) -> NSParagraphStyle {
                let p = NSMutableParagraphStyle()
                p.alignment = own && ownIndent == nil ? .right : .left
                p.paragraphSpacingBefore = before
                // Keep the two sides apart: a long message never reaches the other edge.
                if own { let i = ownIndent ?? 48; p.firstLineHeadIndent = i; p.headIndent = i } else { p.tailIndent = -48 }
                p.lineBreakMode = .byWordWrapping
                return p
            }
            let gap: CGFloat = before == nil ? 0 : (grouped ? 3 : 12)
            var bodyGap = gap
            if !own && !grouped {
                let system = isSystem(e)
                out.append(NSAttributedString(string: senderName(e) + "\n", attributes: [
                    .font: bold, .foregroundColor: system ? NSColor(Port42Theme.textSecondary) : NSColor(ShellDock.avatarColor(e.fromId)),
                    .paragraphStyle: para(before: gap), .toolTip: tip,
                ]))
                bodyGap = 2
            }
            let bodyStart = out.length
            let lines = ChatRouting.displayText(e.text).components(separatedBy: "\n")
            for (j, line) in lines.enumerated() {
                let last = i == entries.count - 1 && j == lines.count - 1
                out.append(NSAttributedString(string: line + (last ? "" : "\n"), attributes: [
                    .font: body, .foregroundColor: own ? mine : (isSystem(e) ? NSColor(Port42Theme.textSecondary) : theirs),
                    .paragraphStyle: para(before: j == 0 ? bodyGap : 0), .toolTip: tip,
                ]))
            }
            ranges.append(NSRange(location: start, length: out.length - start))
            bodyRanges.append(NSRange(location: bodyStart, length: out.length - bodyStart))
        }
        return Built(text: out, ranges: ranges, bodyRanges: bodyRanges,
                     senders: entries.map(senderName), dates: entries.map(\.at))
    }

    /// What a copy puts on the pasteboard when the selection spans messages (GM, 2026-09-27): each
    /// message as "[time] name: text", the first and last cut where the selection starts and ends,
    /// so the times and every sender (yours included, which the view does not show) come through.
    /// nil within one message: that copies as plain text.
    static func copyText(_ b: Built, selection: NSRange) -> String? {
        guard selection.length > 0 else { return nil }
        let s = b.text.string as NSString
        var lines: [String] = []
        for i in b.ranges.indices where NSIntersectionRange(b.ranges[i], selection).length > 0 {
            let part = NSIntersectionRange(b.bodyRanges[i], selection)
            let text = part.length > 0 ? s.substring(with: part).trimmingCharacters(in: .newlines) : ""
            lines.append("[\(tooltip(b.dates[i]))] \(b.senders[i]): \(text)")
        }
        return lines.count > 1 ? lines.joined(separator: "\n") : nil
    }

    /// The transcript on screen and what it was built from, updated in place as messages come and go.
    struct Layout {
        var entries: [PortChatEntry] = []
        /// The width it was laid out at; a different width lays it out again.
        var width: CGFloat? = nil
        var ranges: [NSRange] = []
        var bodyRanges: [NSRange] = []

        func built(_ text: NSAttributedString) -> Built {
            Built(text: text, ranges: ranges, bodyRanges: bodyRanges,
                  senders: entries.map(senderName), dates: entries.map(\.at))
        }
    }

    /// Bring `storage` from `layout.entries` to `entries`. A chat grows at the end and, past what it
    /// keeps, loses messages at the start, so that is done in place: the oldest cut off, the newest
    /// appended. Rebuilding a 200-message transcript for every message cost a visible stall (GM,
    /// 2026-09-27). Anything else is rebuilt whole. Returns whether it was done in place.
    @discardableResult
    static func update(_ storage: NSMutableAttributedString, _ layout: inout Layout, to entries: [PortChatEntry],
                       me: String?, accent: NSColor, width: CGFloat? = nil) -> Bool {
        let old = layout.width == width ? layout.entries : []
        func rebuild() -> Bool {
            let b = build(entries, me: me, accent: accent, width: width)
            storage.setAttributedString(b.text)
            layout = Layout(entries: entries, width: width, ranges: b.ranges, bodyRanges: b.bodyRanges)
            return false
        }
        guard !old.isEmpty, let first = entries.first else { return rebuild() }
        let drop = old.firstIndex { $0.seq == first.seq } ?? -1
        guard drop >= 0 else { return rebuild() }
        let kept = old[drop...]
        guard entries.count >= kept.count,
              zip(kept, entries).allSatisfy({ $0.seq == $1.seq }) else { return rebuild() }
        // A cut inside a run from one sender would leave the new first message without its name.
        if drop > 0 && continues(first, after: old[drop - 1]) { return rebuild() }
        storage.beginEditing()
        defer { storage.endEditing() }
        if drop > 0 {
            let cut = layout.ranges[drop].location
            storage.deleteCharacters(in: NSRange(location: 0, length: cut))
            layout.entries.removeFirst(drop)
            layout.ranges = layout.ranges.dropFirst(drop).map { NSRange(location: $0.location - cut, length: $0.length) }
            layout.bodyRanges = layout.bodyRanges.dropFirst(drop).map { NSRange(location: $0.location - cut, length: $0.length) }
        }
        let added = Array(entries.dropFirst(kept.count))
        if !added.isEmpty {
            let b = build(added, me: me, accent: accent, after: layout.entries.last, width: width)
            let base = storage.length
            storage.append(b.text)
            // The appended text opens with the line break that ends the message before it.
            let lead = layout.entries.isEmpty ? 0 : 1
            if lead == 1, let last = layout.ranges.indices.last {
                layout.ranges[last].length += 1
                layout.bodyRanges[last].length += 1
            }
            layout.entries += added
            layout.ranges += b.ranges.map { NSRange(location: $0.location + base, length: $0.length) }
            layout.bodyRanges += b.bodyRanges.map { NSRange(location: $0.location + base, length: $0.length) }
        }
        return true
    }

    /// The message whose range holds character `index` (the last one past the end).
    static func message(at index: Int, in ranges: [NSRange]) -> Int? {
        guard !ranges.isEmpty else { return nil }
        var lo = 0, hi = ranges.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if ranges[mid].location <= index { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The scroll pill: the day in words when it is near, then the time.
    static func label(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = d.formatted(.dateTime.hour().minute())
        if calendar.isDate(d, inSameDayAs: now) { return "today \(time)" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) {
            return "yesterday \(time)"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: d), to: calendar.startOfDay(for: now)).day ?? 99
        if days < 7 { return "\(d.formatted(.dateTime.weekday(.abbreviated))) \(time)" }
        if calendar.component(.year, from: d) == calendar.component(.year, from: now) {
            return "\(d.formatted(.dateTime.month(.abbreviated).day())), \(time)"
        }
        return "\(d.formatted(.dateTime.month(.abbreviated).day().year())), \(time)"
    }

    static func tooltip(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }
}

/// The transcript's AppKit text view, scrolled to the newest message as messages arrive (unless the
/// person has scrolled up to read), reporting the time of the top message in view as it scrolls.
struct ChatTranscriptView: NSViewRepresentable {
    let entries: [PortChatEntry]
    let me: String?
    let accent: Color
    let onScroll: (Date) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = Self.makeScroll()
        let text = scroll.documentView as! TranscriptTextView
        let coordinator = context.coordinator
        text.copyText = { [weak coordinator] range in coordinator?.built.flatMap { ChatTranscript.copyText($0, selection: range) } }
        context.coordinator.onScroll = onScroll
        Self.wire(context.coordinator, to: scroll)
        return scroll
    }

    /// The scroll view and its text view. TextKit 1, explicitly: a TextKit 2 text view asked to scroll
    /// before its first layout raises "attempt to create NSTextRange from nil location", which ended
    /// the app when a chat opened (Dev5, 2026-09-27), and the scroll-time lookup uses the layout manager.
    static func makeScroll() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let text = TranscriptTextView(usingTextLayoutManager: false)
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 6, height: 8)
        text.textContainer?.widthTracksTextView = true
        text.isAutomaticLinkDetectionEnabled = false
        return scroll
    }

    /// The coordinator hears the chat scroll and resize. Split out so a test wires it as the app does.
    static func wire(_ coordinator: Coordinator, to scroll: NSScrollView) {
        let text = scroll.documentView as! NSTextView
        coordinator.text = text
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        text.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.resized),
                                               name: NSView.frameDidChangeNotification, object: text)
    }

    /// To the newest message, by moving the clip view: no text-range lookup, so it is safe before the
    /// first layout and outside a window.
    static func scrollToEnd(_ scroll: NSScrollView) {
        guard let doc = scroll.documentView else { return }
        (doc as? NSTextView)?.layoutManager?.ensureLayout(for: (doc as! NSTextView).textContainer!)
        doc.scroll(NSPoint(x: 0, y: max(0, doc.bounds.maxY - scroll.contentView.bounds.height)))
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onScroll = onScroll
        let signature = "\(entries.count):\(entries.last?.seq ?? -1):\(me ?? "")"
        guard signature != c.signature, let text = c.text else { return }
        let first = c.signature.isEmpty
        let atBottom = first || c.isAtBottom(scroll)
        let ownLast = entries.last.map { ChatTranscript.isMine($0, me: me) } ?? false
        c.signature = signature
        if c.me != me { c.layout = .init(); c.me = me }      // a different person: rebuild whole
        c.entries = entries
        c.accent = NSColor(accent)
        c.apply()
        if atBottom || ownLast {
            DispatchQueue.main.async { Self.scrollToEnd(scroll) }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject {
        weak var text: NSTextView?
        var layout = ChatTranscript.Layout()
        var me: String?
        var entries: [PortChatEntry] = []
        var accent: NSColor = .systemGreen

        /// The line width text is laid out at: the container less its padding on both sides.
        var lineWidth: CGFloat? {
            guard let text, let tc = text.textContainer else { return nil }
            let w = tc.containerSize.width - 2 * tc.lineFragmentPadding
            return w > 0 && w < 100_000 ? (w).rounded() : nil
        }

        /// Bring the text to `entries` at the current width (in place when only messages changed).
        func apply() {
            guard !applying, let storage = text?.textStorage else { return }
            // Editing the storage resizes the text view, and its frame change calls `resized` right here,
            // inside this update. So the update works on a copy (updating `layout` in place while
            // `resized` read it was a fatal access conflict: the app quit when a chat opened, GM
            // 2026-09-27) and does not re-enter; a width that moved meanwhile is laid out once after.
            applying = true
            var next = layout
            ChatTranscript.update(storage, &next, to: entries, me: me, accent: accent, width: lineWidth)
            layout = next
            applying = false
            if !entries.isEmpty, lineWidth != layout.width {
                applying = true
                var again = layout
                ChatTranscript.update(storage, &again, to: entries, me: me, accent: accent, width: lineWidth)
                layout = again
                applying = false
            }
        }
        private var applying = false

        /// The chat was resized: own messages are placed by width, so lay out again at the new one.
        @objc func resized() {
            guard !applying, !entries.isEmpty, lineWidth != layout.width else { return }
            apply()
        }
        var built: ChatTranscript.Built? { text?.textStorage.map { layout.built($0) } }
        var signature = ""
        var onScroll: ((Date) -> Void)?

        func isAtBottom(_ scroll: NSScrollView) -> Bool {
            guard let doc = scroll.documentView else { return true }
            return scroll.contentView.bounds.maxY >= doc.bounds.maxY - 24
        }

        @objc func scrolled() {
            guard let text, let lm = text.layoutManager, let tc = text.textContainer else { return }
            let top = CGPoint(x: 8, y: text.visibleRect.minY + 4 - text.textContainerInset.height)
            let glyph = lm.glyphIndex(for: top, in: tc)
            let char = lm.characterIndexForGlyph(at: glyph)
            if let i = ChatTranscript.message(at: char, in: layout.ranges), i < layout.entries.count {
                onScroll?(layout.entries[i].at)
            }
        }
    }
}

/// The transcript's text view: a copy across messages carries each one's time and sender.
final class TranscriptTextView: NSTextView {
    var copyText: ((NSRange) -> String?)?

    override func copy(_ sender: Any?) {
        guard let text = copyText?(selectedRange()) else { return super.copy(sender) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
