import Testing
import Foundation
@testable import Port42Lib

/// Step 8: the `[port:id:title]` reference card — inline presence of a registered web port,
/// symmetric with the `[terminal:id:title]` card. Pure parsing + formatting.
@Suite("Web port card parsing")
struct WebPortCardTests {

    @Test("parses a well-formed card into id + title")
    func parses() {
        let entry = ChatEntry(id: "1", senderName: "agent", content: "[port:abc-123:My Port]")
        let info = entry.webPortInfo
        #expect(info?.id == "abc-123")
        #expect(info?.title == "My Port")
    }

    @Test("title may contain colons")
    func titleWithColons() {
        let entry = ChatEntry(id: "1", senderName: "agent", content: "[port:abc:weather: NYC 3:00]")
        #expect(entry.webPortInfo?.id == "abc")
        #expect(entry.webPortInfo?.title == "weather: NYC 3:00")
    }

    @Test("surrounding whitespace is tolerated")
    func whitespace() {
        let entry = ChatEntry(id: "1", senderName: "agent", content: "  \n[port:xyz:T]\n ")
        #expect(entry.webPortInfo?.id == "xyz")
        #expect(entry.webPortInfo?.title == "T")
    }

    @Test("plain text is not a card")
    func plainText() {
        let entry = ChatEntry(id: "1", senderName: "user", content: "talk about [port:foo] sometime")
        #expect(entry.webPortInfo == nil)
    }

    @Test("empty id is rejected")
    func emptyId() {
        let entry = ChatEntry(id: "1", senderName: "agent", content: "[port::title]")
        #expect(entry.webPortInfo == nil)
    }

    @Test("a terminal card is not a web-port card and vice versa")
    func noCrossTalk() {
        let term = ChatEntry(id: "1", senderName: "agent", content: "[terminal:t1:shell]")
        #expect(term.webPortInfo == nil)
        #expect(term.terminalPortInfo?.id == "t1")

        let web = ChatEntry(id: "2", senderName: "agent", content: "[port:w1:page]")
        #expect(web.terminalPortInfo == nil)
        #expect(web.webPortInfo?.id == "w1")
    }

    @Test("a port fence message is not a card")
    func fenceIsNotCard() {
        let entry = ChatEntry(id: "1", senderName: "agent", content: "```port\n<div/>\n```")
        #expect(entry.webPortInfo == nil)
    }

    @Test("portCard formats and round-trips through the parser")
    func roundTrip() {
        let card = ChatEntry.portCard(id: "id-9", title: "Some: Title")
        #expect(card == "[port:id-9:Some: Title]")
        let entry = ChatEntry(id: "1", senderName: "agent", content: card)
        #expect(entry.webPortInfo?.id == "id-9")
        #expect(entry.webPortInfo?.title == "Some: Title")
    }
}
