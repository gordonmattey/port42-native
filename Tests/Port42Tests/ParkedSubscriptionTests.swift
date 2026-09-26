import Testing
import Foundation
import WebKit
@testable import Port42Lib

// Parking a port stops its AI generations (they cost money while they run). It used to stop every
// stream on the port, subscriptions included, and the page was never told: a port parked once never
// received another event, even back on screen (measured on Dev4, 2026-09-26, Phase 3 step 3.0).
@Suite("A parked port keeps its subscriptions")
struct ParkedSubscriptionTests {

    @MainActor
    func js(_ wv: WKWebView, _ src: String) async -> Any? {
        try? await wv.callAsyncJavaScript(src, arguments: [:], in: nil, contentWorld: .page)
    }

    @Test("a subscriber parked and unparked still receives the producer's events")
    @MainActor
    func survivesPark() async throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        let pw = state.portWindows
        defer { withExtendedLifetime(state) {} }
        pw.registerTiledPort(id: "prod", html: "<title>prod</title>", spaceId: "s", createdBy: nil,
                             title: "prod", position: CGPoint(x: 40, y: 40))
        let prodUdid = try #require(pw.panels.first { $0.id == "prod" }?.udid)
        pw.registerTiledPort(id: "cons", html: """
            <title>cons</title><script>
            window.got = 0;
            port42.port.subscribe('\(prodUdid)', ev => { if (ev.kind === 'port.tick') window.got++ });
            window.ready = true;
            </script>
            """, spaceId: "s", createdBy: nil, title: "cons", position: CGPoint(x: 500, y: 40))
        let wv = try #require(pw.webViews["cons"])
        for _ in 0..<100 where await js(wv, "return window.ready ?? null") as? Bool != true {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let topic = PortNotify.topic(forPortKey: state.resolvePortRef(prodUdid)?.key ?? prodUdid)
        func publish() { state.notifyBus.publish(topic: topic, kind: "port.tick", payload: .int(1)) }
        func got() async -> Int { (await js(wv, "return window.got") as? Int) ?? -1 }
        func settle() async throws { try await Task.sleep(nanoseconds: 300_000_000) }

        for _ in 0..<50 where !state.notifyBus.hasSubscribers(topic) { try await settle() }
        publish(); try await settle()
        #expect(await got() == 1, "the subscription never delivered")

        pw.park(id: "cons"); try await settle()
        pw.unpark(id: "cons"); try await settle()
        #expect(state.notifyBus.hasSubscribers(topic), "parking cancelled the subscription")
        publish(); try await settle()
        #expect(await got() == 2, "a parked-then-unparked port stopped receiving")
    }
}
