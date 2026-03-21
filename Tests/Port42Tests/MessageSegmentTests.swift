import Testing
import Foundation
@testable import Port42Lib

@Suite("MessageSegment parsing")
struct MessageSegmentTests {

    // MARK: - No ports

    @Test("plain text message returns single text segment")
    func plainText() {
        let entry = ChatEntry(id: "1", senderName: "user", content: "hello world")
        let segs = entry.messageSegments
        #expect(segs.count == 1)
        if case .text(let t) = segs[0] { #expect(t == "hello world") } else { Issue.record("expected .text") }
    }

    @Test("containsPort is false for plain text")
    func containsPortFalse() {
        let entry = ChatEntry(id: "1", senderName: "user", content: "hello world")
        #expect(!entry.containsPort)
    }

    // MARK: - Single port

    @Test("single port block produces one port segment")
    func singlePort() {
        let content = "```port\n<div>hello</div>\n```"
        let entry = ChatEntry(id: "1", senderName: "agent", content: content)
        let segs = entry.messageSegments
        #expect(segs.count == 1)
        if case .port(let h) = segs[0] { #expect(h.contains("<div>hello</div>")) } else { Issue.record("expected .port") }
    }

    @Test("containsPort is true for port block")
    func containsPortTrue() {
        let entry = ChatEntry(id: "1", senderName: "agent", content: "```port\n<div/>\n```")
        #expect(entry.containsPort)
    }

    @Test("text before port is preserved as leading text segment")
    func textBeforePort() {
        let content = "here you go\n```port\n<div/>\n```"
        let entry = ChatEntry(id: "1", senderName: "agent", content: content)
        let segs = entry.messageSegments
        #expect(segs.count == 2)
        if case .text(let t) = segs[0] { #expect(t.contains("here you go")) } else { Issue.record("expected .text first") }
        if case .port = segs[1] { } else { Issue.record("expected .port second") }
    }

    @Test("text after port is preserved as trailing text segment")
    func textAfterPort() {
        let content = "```port\n<div/>\n```\nenjoy!"
        let entry = ChatEntry(id: "1", senderName: "agent", content: content)
        let segs = entry.messageSegments
        #expect(segs.count == 2)
        if case .port = segs[0] { } else { Issue.record("expected .port first") }
        if case .text(let t) = segs[1] { #expect(t.contains("enjoy!")) } else { Issue.record("expected .text second") }
    }

    // MARK: - Multiple ports (B-003)

    @Test("two port blocks produce two port segments")
    func twoPorts() {
        let content = "```port\n<div>first</div>\n```\n```port\n<div>second</div>\n```"
        let entry = ChatEntry(id: "1", senderName: "agent", content: content)
        let segs = entry.messageSegments
        let ports = segs.filter { if case .port = $0 { return true }; return false }
        #expect(ports.count == 2)
    }

    @Test("text between two port blocks is preserved")
    func textBetweenPorts() {
        let content = "```port\n<div>A</div>\n```\nmiddle text\n```port\n<div>B</div>\n```"
        let entry = ChatEntry(id: "1", senderName: "agent", content: content)
        let segs = entry.messageSegments
        #expect(segs.count == 3)
        if case .port = segs[0] { } else { Issue.record("expected .port at 0") }
        if case .text(let t) = segs[1] { #expect(t.contains("middle text")) } else { Issue.record("expected .text at 1") }
        if case .port = segs[2] { } else { Issue.record("expected .port at 2") }
    }

    @Test("portIndex is 0 for first port, 1 for second")
    func portIndexes() {
        let content = "```port\n<div>A</div>\n```\n```port\n<div>B</div>\n```"
        let entry = ChatEntry(id: "1", senderName: "agent", content: content)
        let segs = entry.messageSegments
        let portSegIndices = segs.enumerated().compactMap { (i, s) -> Int? in
            if case .port = s { return i } else { return nil }
        }
        #expect(portSegIndices.count == 2)
        #expect(entry.portIndex(atSegment: portSegIndices[0]) == 0)
        #expect(entry.portIndex(atSegment: portSegIndices[1]) == 1)
    }

    // MARK: - Truncated port

    @Test("isPortTruncated is true when last port has unclosed script tag")
    func truncatedScript() {
        let content = "```port\n<script>function foo() {</script>\n```"
        // Actually simulate truncation — unclosed script
        let truncated = "```port\n<script>function foo() {"
        let entry = ChatEntry(id: "1", senderName: "agent", content: truncated)
        #expect(entry.isPortTruncated)
    }

    @Test("isPortTruncated is false for complete port")
    func notTruncated() {
        let content = "```port\n<script>function foo() {}</script>\n```"
        let entry = ChatEntry(id: "1", senderName: "agent", content: content)
        #expect(!entry.isPortTruncated)
    }

    @Test("isPortTruncated is false for plain text message")
    func notTruncatedPlainText() {
        let entry = ChatEntry(id: "1", senderName: "user", content: "just text")
        #expect(!entry.isPortTruncated)
    }
}
