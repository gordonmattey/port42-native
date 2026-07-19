import Testing
import Foundation
@testable import Port42Lib

// MARK: - Bridge JS Completeness
//
// The injected `window.port42` is a generic Proxy (big-bang step 2): any `port42.a.b(...args)` posts
// `call('a.b', args)`, so EVERY method is exposed by construction. The old completeness bug ("a Swift
// handler exists but port42.* never exposes it") is designed away — there is no per-method JS binding to
// forget. So these tests assert the shape that guarantees it, plus that the non-generic carve-outs stay
// explicit, and that the docs still describe the port methods.

@Suite("Bridge JS Completeness")
struct BridgeJSTests {

    @Test("bridgeJS exposes every method via a generic Proxy (completeness by construction)")
    func genericProxyExposesEverything() {
        let js = PortBridge.bridgeJS
        // The Proxy + the per-namespace helper are what make any a.b reachable without a hand binding.
        #expect(js.contains("new Proxy"))
        #expect(js.contains("function __ns"))
        #expect(js.contains("Array.prototype.slice.call(arguments)"))
    }

    @Test("bridgeJS keeps the non-generic members explicit (machinery, streaming, client-only, events)")
    func carveOutsStayExplicit() {
        let js = PortBridge.bridgeJS
        // Bridge machinery the host calls into.
        #expect(js.contains("_resolve") && js.contains("_reject") && js.contains("_tokenCallback"))
        // Streaming shims (token callback wiring) — not request/response, so not generic.
        #expect(js.contains("ai.complete") && js.contains("companions.invoke"))
        // Client-only DOM method.
        #expect(js.contains("messageHandlers.portHeight.postMessage"))
        // Event-listener registration.
        #expect(js.contains("port42:filedrop"))
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
