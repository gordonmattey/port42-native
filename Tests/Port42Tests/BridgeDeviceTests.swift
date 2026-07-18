import Testing
import Foundation
import AppKit
@testable import Port42Lib

// Phase 1, batch 7: the headless-safe device methods. Clipboard round-trips via NSPasteboard;
// screen.displays is the canonical structured array (was the screen_info text blob). The rest of the
// device families are extracted during Phase-2 wiring, where hardware/UI can be exercised live.

@Suite("Bridge — devices (headless)", .serialized)
struct BridgeDeviceTests {

    @MainActor
    func call(_ w: ParityWorld, _ canonical: String, _ input: [String: Any]) async throws -> BridgeValue {
        let method = try #require(w.registry[canonical])
        return try await method.run(w.principal, BridgeArgs(input))
    }

    @Test("clipboard.write then clipboard.read round-trips text")
    @MainActor
    func clipboardRoundTrip() async throws {
        let w = try makeParityWorld()
        let marker = "port42-\(UUID().uuidString)"
        let wrote = try await call(w, "clipboard.write", ["data": marker])
        #expect(wrote == .object(["ok": .bool(true)]))
        let read = try await call(w, "clipboard.read", [:])
        #expect(read == .object(["type": .string("text"), "data": .string(marker)]))
    }

    @Test("clipboard.write requires data")
    @MainActor
    func clipboardRequiresData() async throws {
        let w = try makeParityWorld()
        await #expect(throws: BridgeError.self) { _ = try await call(w, "clipboard.write", [:]) }
    }

    @Test("clipboard methods carry the .clipboard permission")
    @MainActor
    func clipboardPermission() throws {
        let w = try makeParityWorld()
        #expect(w.registry["clipboard.read"]?.permission == .clipboard)
        #expect(w.registry["clipboard.write"]?.permission == .clipboard)
    }

    @Test("screen.displays returns a structured array of displays, no permission")
    @MainActor
    func screenDisplays() async throws {
        let w = try makeParityWorld()
        #expect(w.registry["screen.displays"]?.permission == nil)
        let displays = try await call(w, "screen.displays", [:])
        guard case let .array(items) = displays else { Issue.record("expected array"); return }
        #expect(items.count == NSScreen.screens.count)
        if let first = items.first {
            guard case let .object(o) = first else { Issue.record("expected object"); return }
            // the fields the docs advertise, structured (not a text blob)
            for key in ["width", "height", "x", "y", "visibleWidth", "isMain"] {
                #expect(o[key] != nil, "missing \(key)")
            }
        }
    }
}
