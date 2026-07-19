import Testing
import Foundation
@testable import Port42Lib

// Tail item 5: browser.* extracted to the registry. ONE shared BrowserBridge instance lives in the
// registry, so sessions are shared across surfaces (port JS, gateway, tool-use) — the old design was
// one instance per PortBridge and another per ToolExecutor, so a session opened from a port was
// invisible to a companion. Sessions still remember their creating port (owner) for browser.load
// event routing. Session continuity itself is the live gate; these are the headless contract gates.

@Suite("Bridge — browser")
struct BridgeBrowserTests {

    @MainActor
    func call(_ w: ParityWorld, _ canonical: String, _ input: [String: Any]) async throws -> BridgeValue {
        let method = try #require(w.registry[canonical])
        return try await method.run(w.principal, BridgeArgs(input))
    }

    @Test("all seven browser methods are registered, gated by .browser, with the right tool exposure")
    @MainActor
    func registration() throws {
        let w = try makeParityWorld()
        let toolExposed = ["browser.open", "browser.text", "browser.capture", "browser.close"]
        let liveOnly = ["browser.navigate", "browser.html", "browser.execute"]
        for name in toolExposed + liveOnly {
            let m = try #require(w.registry[name], "missing \(name)")
            #expect(m.permission == .browser, "\(name) should be .browser gated")
        }
        for name in toolExposed { #expect(try #require(w.registry[name]).toolExposed, "\(name) should be a tool") }
        for name in liveOnly { #expect(!(try #require(w.registry[name]).toolExposed), "\(name) should not be a tool") }
    }

    @Test("browser.open with an empty or invalid URL throws")
    @MainActor
    func openBadURL() async throws {
        let w = try makeParityWorld()
        await #expect(throws: BridgeError.self) { _ = try await call(w, "browser.open", ["url": ""]) }
        await #expect(throws: BridgeError.self) { _ = try await call(w, "browser.open", ["url": "not a url"]) }
    }

    @Test("session methods with an unknown sessionId throw")
    @MainActor
    func unknownSession() async throws {
        let w = try makeParityWorld()
        await #expect(throws: BridgeError.self) { _ = try await call(w, "browser.text", ["sessionId": "nope"]) }
        await #expect(throws: BridgeError.self) { _ = try await call(w, "browser.navigate", ["sessionId": "nope", "url": "https://example.com"]) }
        await #expect(throws: BridgeError.self) { _ = try await call(w, "browser.capture", ["sessionId": "nope"]) }
        await #expect(throws: BridgeError.self) { _ = try await call(w, "browser.html", ["sessionId": "nope"]) }
        await #expect(throws: BridgeError.self) { _ = try await call(w, "browser.execute", ["sessionId": "nope", "js": "1+1"]) }
        await #expect(throws: BridgeError.self) { _ = try await call(w, "browser.close", ["sessionId": "nope"]) }
    }
}
