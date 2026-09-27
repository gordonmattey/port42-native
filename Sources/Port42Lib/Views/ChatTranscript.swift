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
        let dates: [Date]
    }

    static let bodySize: CGFloat = 11.5
    /// Messages from one sender this close together are one group: no second name, less space.
    static let groupGap: TimeInterval = 300

    static func isMine(_ e: PortChatEntry, me: String?) -> Bool { me != nil && e.fromId == me }

    /// Grouped under the message before it: the same sender, soon after.
    static func continues(_ e: PortChatEntry, after prev: PortChatEntry?) -> Bool {
        guard let prev else { return false }
        return prev.fromId == e.fromId && e.at.timeIntervalSince(prev.at) < groupGap
    }

    static func build(_ entries: [PortChatEntry], me: String?, accent: NSColor, now: Date = Date()) -> Built {
        let out = NSMutableAttributedString()
        var ranges: [NSRange] = []
        let body = NSFont.monospacedSystemFont(ofSize: bodySize, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        let theirs = NSColor(Port42Theme.textPrimary).withAlphaComponent(0.85)
        let mine = accent.blended(withFraction: 0.55, of: .white) ?? accent

        for (i, e) in entries.enumerated() {
            let own = isMine(e, me: me)
            let grouped = continues(e, after: i > 0 ? entries[i - 1] : nil)
            let start = out.length
            let tip = tooltip(e.at)
            func para(before: CGFloat) -> NSParagraphStyle {
                let p = NSMutableParagraphStyle()
                p.alignment = own ? .right : .left
                p.paragraphSpacingBefore = before
                // Keep the two sides apart: a long message never reaches the other edge.
                if own { p.firstLineHeadIndent = 48; p.headIndent = 48 } else { p.tailIndent = -48 }
                p.lineBreakMode = .byWordWrapping
                return p
            }
            let gap: CGFloat = i == 0 ? 0 : (grouped ? 3 : 12)
            var bodyGap = gap
            if !own && !grouped {
                let name = (e.fromName.isEmpty ? e.fromId : e.fromName)
                out.append(NSAttributedString(string: name + "\n", attributes: [
                    .font: bold, .foregroundColor: NSColor(ShellDock.avatarColor(e.fromId)),
                    .paragraphStyle: para(before: gap), .toolTip: tip,
                ]))
                bodyGap = 2
            }
            let lines = ChatRouting.displayText(e.text).components(separatedBy: "\n")
            for (j, line) in lines.enumerated() {
                let last = i == entries.count - 1 && j == lines.count - 1
                out.append(NSAttributedString(string: line + (last ? "" : "\n"), attributes: [
                    .font: body, .foregroundColor: own ? mine : theirs,
                    .paragraphStyle: para(before: j == 0 ? bodyGap : 0), .toolTip: tip,
                ]))
            }
            ranges.append(NSRange(location: start, length: out.length - start))
        }
        return Built(text: out, ranges: ranges, dates: entries.map(\.at))
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
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 6, height: 8)
        text.textContainer?.widthTracksTextView = true
        text.isAutomaticLinkDetectionEnabled = false
        context.coordinator.text = text
        context.coordinator.onScroll = onScroll
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return scroll
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
        let built = ChatTranscript.build(entries, me: me, accent: NSColor(accent))
        c.ranges = built.ranges
        c.dates = built.dates
        text.textStorage?.setAttributedString(built.text)
        if atBottom || ownLast {
            DispatchQueue.main.async { text.scrollToEndOfDocument(nil) }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject {
        weak var text: NSTextView?
        var ranges: [NSRange] = []
        var dates: [Date] = []
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
            if let i = ChatTranscript.message(at: char, in: ranges), i < dates.count { onScroll?(dates[i]) }
        }
    }
}
