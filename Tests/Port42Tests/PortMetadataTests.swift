import Testing
import Foundation
@testable import Port42Lib

@Suite("Port Metadata")
struct PortMetadataTests {

    // MARK: - PortPanel title resolution

    @Test("userTitle nil falls back to HTML title")
    @MainActor
    func titleFallsBackToHtml() {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let panel = PortPanel(
            id: "x", udid: "x", html: "<title>html-title</title>",
            bridge: bridge, channelId: nil, createdBy: nil, messageId: nil,
            userTitle: nil, size: CGSize(width: 400, height: 300)
        )
        #expect(panel.title == "html-title")
    }

    @Test("userTitle overrides HTML title")
    @MainActor
    func userTitleOverridesHtml() {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let panel = PortPanel(
            id: "x", udid: "x", html: "<title>html-title</title>",
            bridge: bridge, channelId: nil, createdBy: nil, messageId: nil,
            userTitle: "my title", size: CGSize(width: 400, height: 300)
        )
        #expect(panel.title == "my title")
    }

    @Test("empty userTitle falls back to HTML title")
    @MainActor
    func emptyUserTitleFallsBackToHtml() {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let panel = PortPanel(
            id: "x", udid: "x", html: "<title>html-title</title>",
            bridge: bridge, channelId: nil, createdBy: nil, messageId: nil,
            userTitle: "", size: CGSize(width: 400, height: 300)
        )
        #expect(panel.title == "html-title")
    }

    @Test("no HTML title falls back to 'port'")
    @MainActor
    func titleFallsBackToPort() {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let panel = PortPanel(
            id: "x", udid: "x", html: "<div>no title</div>",
            bridge: bridge, channelId: nil, createdBy: nil, messageId: nil,
            userTitle: nil, size: CGSize(width: 400, height: 300)
        )
        #expect(panel.title == "port")
    }

    // MARK: - DB round-trip

    @Test("userTitle persists and restores from DB")
    @MainActor
    func userTitleRoundTrips() throws {
        let db = try DatabaseService(inMemory: true)
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let panel = PortPanel(
            id: "p1", udid: "p1", html: "<title>html</title>",
            bridge: bridge, channelId: nil, createdBy: nil, messageId: nil,
            userTitle: "custom name", size: CGSize(width: 400, height: 300)
        )
        try db.savePortPanel(PersistedPortPanel(from: panel))

        let fetched = try db.fetchPortPanels()
        #expect(fetched.count == 1)
        #expect(fetched[0].userTitle == "custom name")
    }

    @Test("nil userTitle stored as nil in DB")
    @MainActor
    func nilUserTitleStoredAsNil() throws {
        let db = try DatabaseService(inMemory: true)
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let panel = PortPanel(
            id: "p2", udid: "p2", html: "<title>html</title>",
            bridge: bridge, channelId: nil, createdBy: nil, messageId: nil,
            userTitle: nil, size: CGSize(width: 400, height: 300)
        )
        try db.savePortPanel(PersistedPortPanel(from: panel))

        let fetched = try db.fetchPortPanels()
        #expect(fetched[0].userTitle == nil)
    }

    @Test("storedCapabilities persist and restore from DB")
    @MainActor
    func capabilitiesRoundTrip() throws {
        let db = try DatabaseService(inMemory: true)
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let panel = PortPanel(
            id: "p3", udid: "p3", html: "<title>t</title>",
            bridge: bridge, channelId: nil, createdBy: nil, messageId: nil,
            userTitle: nil, storedCapabilities: ["claude-code", "browser"],
            size: CGSize(width: 400, height: 300)
        )
        try db.savePortPanel(PersistedPortPanel(from: panel))

        let fetched = try db.fetchPortPanels()
        #expect(fetched.count == 1)
        let capStr = try #require(fetched[0].capabilities)
        let caps = try JSONSerialization.jsonObject(with: capStr.data(using: .utf8)!) as! [String]
        #expect(caps == ["claude-code", "browser"])
    }

    @Test("empty storedCapabilities stored as nil in DB")
    @MainActor
    func emptyCapabilitiesStoredAsNil() throws {
        let db = try DatabaseService(inMemory: true)
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let panel = PortPanel(
            id: "p4", udid: "p4", html: "<title>t</title>",
            bridge: bridge, channelId: nil, createdBy: nil, messageId: nil,
            userTitle: nil, storedCapabilities: [],
            size: CGSize(width: 400, height: 300)
        )
        try db.savePortPanel(PersistedPortPanel(from: panel))

        let fetched = try db.fetchPortPanels()
        #expect(fetched[0].capabilities == nil)
    }

    // MARK: - port_rename tool definition

    @Test("port_rename tool is defined")
    func portRenameToolExists() {
        #expect(ToolDefinitions.all.contains(where: { $0["name"] as? String == "port_rename" }))
    }

    @Test("port_rename requires id and title")
    func portRenameRequiredParams() {
        guard let tool = ToolDefinitions.all.first(where: { $0["name"] as? String == "port_rename" }),
              let schema = tool["input_schema"] as? [String: Any],
              let required = schema["required"] as? [String] else {
            Issue.record("port_rename tool not found")
            return
        }
        #expect(required.contains("id"))
        #expect(required.contains("title"))
    }

    // MARK: - ports-context.txt docs

    @Test("ports-context.txt documents new port metadata APIs")
    func portsContextDocumentsMetadataApis() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Port42Lib/Resources/ports-context.txt")
        let content = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(content.contains("port42.terminal.cwd"))
        #expect(content.contains("terminal.on('cwd'"))
        #expect(content.contains("port42.port.setCapabilities"))
        #expect(content.contains("port42.port.rename"))
    }
}
