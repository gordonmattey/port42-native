import Testing
import Foundation
@testable import Port42Lib

// The never-rejecting-bridge fix, pinned (arc 2). Since 1635d93 a failed port-JS call REJECTS the
// promise (the caller's catch runs) instead of resolving {error} the caller must inspect. The
// triage lives in one function so the seam cannot silently regress back to resolve-with-error.
@Suite("Port call disposition (the reject seam)")
struct PortCallDispositionTests {

    @Test("a streaming handler's deferred marker means no push at all")
    func deferred() {
        let d = PortBridge.disposition(for: ["__deferred__": true])
        guard case .deferred = d else { Issue.record("expected .deferred, got \(d)"); return }
    }

    @Test("an {error} result becomes a real rejection with the message")
    func errorRejects() {
        let d = PortBridge.disposition(for: ["error": "access_denied: nope"])
        guard case let .reject(msg) = d else { Issue.record("expected .reject, got \(d)"); return }
        #expect(msg == "access_denied: nope")
    }

    @Test("success shapes resolve untouched: object, array, and bare fragment")
    func successResolves() {
        for result in [["ok": true] as Any, [1, 2, 3] as Any, "bare string" as Any] {
            let d = PortBridge.disposition(for: result)
            guard case .resolve = d else { Issue.record("expected .resolve for \(result), got \(d)"); return }
        }
    }

    @Test("an object with a non-string error key is a success payload, not a rejection")
    func nonStringErrorIsData() {
        // Only the adapter's own {error: String} envelope rejects; data that happens to carry an
        // "error" field (e.g. {error: {count: 3}}) must reach the caller as a resolved value.
        let d = PortBridge.disposition(for: ["error": ["count": 3]])
        guard case .resolve = d else { Issue.record("expected .resolve, got \(d)"); return }
    }

    @Test("the message handler routes through the one disposition function")
    func handlerUsesDisposition() throws {
        let src = try #require(BridgePrincipalTests.libSources()
            .first { $0.file == "PortBridge.swift" }).source
        #expect(src.contains("disposition(for:"),
                "userContentController must triage results via disposition(for:), not inline checks")
    }
}
