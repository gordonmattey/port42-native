import Testing
import Foundation
@testable import Port42Lib

// Root fix for "background port vanishes on restart": fetchPortHtml falls back to the latest version
// when there is no port_panels row (the case that made SHADER's background unresolvable — panel row
// gone, versions intact).

@Suite("fetchPortHtml — version fallback")
struct FetchPortHtmlFallbackTests {

    @Test("returns the latest version when there is no panel row")
    func fallsBackToVersion() throws {
        let db = try DatabaseService(inMemory: true)
        // No panel row — only versions (as a backgrounded/generative port ends up).
        try db.savePortVersion(portUdid: "bg-1", html: "<div>v1</div>", createdBy: nil)
        try db.savePortVersion(portUdid: "bg-1", html: "<div>v2-latest</div>", createdBy: nil)
        #expect(try db.fetchPortHtml(udid: "bg-1") == "<div>v2-latest</div>")
    }

    @Test("returns nil when neither a panel row nor any version exists")
    func nilWhenNothing() throws {
        let db = try DatabaseService(inMemory: true)
        #expect(try db.fetchPortHtml(udid: "ghost") == nil)
    }
}
