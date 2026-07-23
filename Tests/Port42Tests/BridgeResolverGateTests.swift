import Testing
import Foundation
@testable import Port42Lib

// Phase L0 invariant gate (docs/plan-port42-protocol-local-bus.md): every by-id port method resolves
// its target through the ONE resolver (AppState.resolvePortRef → PortResolution), so a new method
// cannot re-introduce the old scattered terminal-vs-web dispatch. Source-scan, same technique as
// BridgeCloseOutTests.
@Suite("Bridge — L0 resolver invariant")
struct BridgeResolverGateTests {

    static func source(_ file: String) throws -> String {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/Port42Tests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/Port42Lib/Services/\(file)")
        return try String(contentsOf: dir, encoding: .utf8)
    }

    @Test("BridgeMethods does not re-introduce the old scattered port dispatch")
    func noScatteredDispatch() throws {
        let src = try Self.source("BridgeMethods.swift")
        // The PortPushRoute triad is deleted; terminal-vs-web precedence lives in PortResolution.
        #expect(!src.contains("PortPushRoute"), "PortPushRoute is gone; resolve via resolvePortRef")
        #expect(!src.contains("resolveTerminalController("),
                "terminal-vs-web dispatch lives in PortResolution now; call resolvePortRef")
    }

    @Test("the by-id port methods route through resolvePortRef")
    func byIdMethodsUseResolver() throws {
        let src = try Self.source("BridgeMethods.swift")
        // Floor: one resolvePortRef reference per rewired by-id method (push/exec/getHtml/history/
        // manage/update/patch/restore/move/rename = 10). A new by-id method that skips the resolver
        // drops this below the floor.
        let count = src.components(separatedBy: "resolvePortRef").count - 1
        #expect(count >= 9, "expected the by-id methods to route through resolvePortRef, found \(count)")
    }
}
