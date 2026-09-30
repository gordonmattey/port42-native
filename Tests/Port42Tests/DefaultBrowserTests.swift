import Testing
import Foundation
@testable import Port42Lib

/// Port42 as the default web browser (docs/plan-default-browser.md): a link from another app opens as a
/// browser port on the space the person is in.
@Suite("Default browser: a link from another app opens as a browser port")
@MainActor
struct DefaultBrowserTests {

    @Test("http and https links are web pages; port42 links and addresses with no host are not")
    func recognizes() {
        #expect(WebLink.isWebLink(URL(string: "https://news.ycombinator.com/item?id=1")!))
        #expect(WebLink.isWebLink(URL(string: "HTTP://example.com")!))
        #expect(!WebLink.isWebLink(URL(string: "port42://imagine?line=hi")!))
        #expect(!WebLink.isWebLink(URL(string: "mailto:a@b.com")!))
        #expect(!WebLink.isWebLink(URL(string: "https:")!))
    }

    @Test("a link opens as a browser port on the current space, with its address")
    func opensOnCurrentSpace() throws {
        let w = try makeParityWorld()
        w.state.currentSpace = w.space
        w.state.isSetupComplete = true
        let before = w.state.portWindows.panels.count
        w.state.openWebLink(URL(string: "https://example.com/page")!)
        #expect(w.state.portWindows.panels.count == before + 1)
        let p = try #require(w.state.portWindows.panels.last)
        #expect(p.portType == "browser")
        #expect(p.spaceId == w.space.id, "the link opened somewhere other than the space the person is in")
        #expect(p.html == "https://example.com/page")
    }

    @Test("a link that arrives before setup is done waits, and opens once it is")
    func heldUntilSetup() throws {
        let w = try makeParityWorld()
        w.state.currentSpace = w.space
        w.state.isSetupComplete = false
        let before = w.state.portWindows.panels.count
        w.state.openWebLink(URL(string: "https://example.com/early")!)
        #expect(w.state.portWindows.panels.count == before, "a port opened before setup was done")
        w.state.isSetupComplete = true
        w.state.openHeldWebLinks()
        #expect(w.state.portWindows.panels.last?.html == "https://example.com/early")
    }

    @Test("the release app offers to be the default browser; the plist claims http and https")
    func plistClaimsWeb() throws {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Info.plist")
        let d = try #require(NSDictionary(contentsOf: plist))
        let schemes = (d["CFBundleURLTypes"] as? [[String: Any]] ?? []).flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes.contains("http") && schemes.contains("https") && schemes.contains("port42"))
    }
}
