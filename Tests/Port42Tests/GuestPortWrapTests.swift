import Testing
import Foundation
@testable import Port42Lib

/// The browser guest wraps a shared port with a COPY of the app's base style (guest/src/shim.js
/// BASE_CSS), since the guest is JavaScript and the app is Swift. This keeps the copy identical to
/// `<style data-port42>` in PortWebViewFactory.wrapHTML, so a shared port looks the same in both.
@Suite("Shared port looks the same in the browser")
struct GuestPortWrapTests {
    func norm(_ s: String) -> String {
        s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    @Test("the guest's base style is the app's")
    func sameStyle() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let swift = try String(contentsOf: root.appendingPathComponent("Sources/Port42Lib/Views/PortWindowManager.swift"), encoding: .utf8)
        let js = try String(contentsOf: root.appendingPathComponent("guest/src/shim.js"), encoding: .utf8)
        let open = try #require(swift.range(of: "<style data-port42>"))
        let close = try #require(swift.range(of: "</style>", range: open.upperBound..<swift.endIndex))
        let app = String(swift[open.upperBound..<close.lowerBound]).replacingOccurrences(of: "\\(overflow)", with: "auto")
        let start = try #require(js.range(of: "export const BASE_CSS = `"))
        let end = try #require(js.range(of: "`;", range: start.upperBound..<js.endIndex))
        let guest = String(js[start.upperBound..<end.lowerBound])
        #expect(norm(app) == norm(guest), "the guest's copy of the base style has drifted from the app's")
    }

    /// The port manual teaches `var(--color-accent)`, and nothing defined it, so every port that
    /// followed the manual lost its accent, in the app and in the browser (2026-09-27, found by a
    /// companion diagnosing a shared port).
    @Test("the base style defines the accent variable the port manual teaches")
    @MainActor
    func accentVariable() {
        #expect(PortWebViewFactory.wrapHTML("<p>x</p>").contains("--color-accent: #00ff41"))
    }
}
