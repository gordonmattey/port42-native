import Testing
import Foundation
@testable import Port42Lib

@Suite("Bridge JS Completeness")
struct BridgeJSTests {

    /// Every method handled in PortBridge.handleCall must be exposed in the JS bridge.
    /// This test prevents the bug where a Swift handler exists but port42.* never exposes it.

    // All methods that must appear as callable functions in bridgeJS.
    // Grouped by namespace for readability.
    static let requiredJSMethods: [(namespace: String, method: String)] = [
        // port42.user
        ("user", "get"),
        // port42.companions
        ("companions", "list"),
        ("companions", "get"),
        ("companions", "invoke"),
        // port42.messages
        ("messages", "recent"),
        ("messages", "send"),
        // port42.channel
        ("channel", "current"),
        ("channel", "list"),
        ("channel", "switchTo"),
        // port42.port
        ("port", "info"),
        ("port", "close"),
        ("port", "setTitle"),
        ("port", "setCapabilities"),
        ("port", "rename"),
        ("port", "resize"),
        ("port", "update"),
        ("port", "getHtml"),
        ("port", "patch"),
        ("port", "history"),
        ("port", "manage"),
        ("port", "restore"),
        ("port", "move"),
        ("port", "position"),
        // port42.ports
        ("ports", "list"),
        // port42.storage
        ("storage", "set"),
        ("storage", "get"),
        ("storage", "delete"),
        ("storage", "list"),
        // port42.ai
        ("ai", "status"),
        ("ai", "models"),
        ("ai", "complete"),
        ("ai", "cancel"),
        // port42.terminal
        ("terminal", "spawn"),
        ("terminal", "send"),
        ("terminal", "resize"),
        ("terminal", "kill"),
        ("terminal", "loadXterm"),
        // port42.clipboard
        ("clipboard", "read"),
        ("clipboard", "write"),
        // port42.fs
        ("fs", "pick"),
        ("fs", "read"),
        ("fs", "write"),
        // port42.notify
        ("notify", "send"),
        // port42.audio
        ("audio", "capture"),
        ("audio", "stopCapture"),
        ("audio", "speak"),
        ("audio", "play"),
        ("audio", "stop"),
        // port42.screen
        ("screen", "displays"),
        ("screen", "windows"),
        ("screen", "capture"),
        ("screen", "stream"),
        ("screen", "stopStream"),
        // port42.camera
        ("camera", "capture"),
        ("camera", "stream"),
        ("camera", "stopStream"),
        // port42.browser
        ("browser", "open"),
        ("browser", "navigate"),
        ("browser", "capture"),
        ("browser", "text"),
        ("browser", "html"),
        ("browser", "execute"),
        ("browser", "close"),
        // port42.automation
        ("automation", "runAppleScript"),
        ("automation", "runJXA"),
        // port42.creases
        ("creases", "read"),
        // port42.fold
        ("fold", "read"),
        // port42.position
        ("position", "read"),
    ]

    @Test("bridgeJS contains all required method definitions")
    func bridgeJSExposesAllMethods() {
        let js = PortBridge.bridgeJS

        var missing: [String] = []
        for (namespace, method) in Self.requiredJSMethods {
            // Check the JS defines this method in the namespace.
            // Methods appear as either `method:` or `method =` in the JS object literal.
            let patterns = [
                "\(method):",        // object literal style: setTitle: (title) =>
                "\(method) =",       // assignment style
                "\(method)()",       // function call in definition
            ]
            let found = patterns.contains { js.contains($0) }
            if !found {
                missing.append("port42.\(namespace).\(method)")
            }
        }

        if !missing.isEmpty {
            Issue.record("Missing from bridgeJS: \(missing.joined(separator: ", "))")
        }
        #expect(missing.isEmpty, "All documented methods must be exposed in bridgeJS")
    }

    @Test("bridgeJS exposes port.setTitle")
    func setTitleExposed() {
        let js = PortBridge.bridgeJS
        #expect(js.contains("setTitle:") || js.contains("setTitle ="))
    }

    @Test("bridgeJS exposes port.setCapabilities")
    func setCapabilitiesExposed() {
        let js = PortBridge.bridgeJS
        #expect(js.contains("setCapabilities:") || js.contains("setCapabilities ="))
    }

    @Test("bridgeJS exposes port.rename")
    func renameExposed() {
        let js = PortBridge.bridgeJS
        #expect(js.contains("rename:") || js.contains("rename ="))
    }

    @Test("ports-context.txt documents setTitle")
    func portsContextDocumentsSetTitle() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Port42Lib/Resources/ports-context.txt")
        let content = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(content.contains("port42.port.setTitle"))
    }

    @Test("ports-context.txt documents setCapabilities")
    func portsContextDocumentsSetCapabilities() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Port42Lib/Resources/ports-context.txt")
        let content = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(content.contains("port42.port.setCapabilities"))
    }
}
