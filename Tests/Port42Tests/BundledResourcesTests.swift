import Testing
import Foundation
@testable import Port42Lib

// Every file shipped inside the app must be read by something. `ports-core.txt` shipped for weeks
// after the code that read it went: it looked current, it was edited, and nothing ever saw the edits
// (found 2026-09-26). The same sweep found two more: a doc for a separate Python CLI and a stale MCP
// server. A resource counts as read when the Swift sources or build.sh name it.
@Suite("Every bundled resource is read by something")
struct BundledResourcesTests {

    /// Shipped without being read, on purpose. Each needs its reason.
    static let shippedUnread: [String: String] = [
        "THIRD-PARTY-LICENSES.txt": "license notices must ship with the app whether or not code reads them",
    ]

    @Test("no resource ships unread")
    func noDeadResources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        var sources = try String(contentsOf: root.appendingPathComponent("build.sh"), encoding: .utf8)
        for case let url as URL in FileManager.default.enumerator(at: root.appendingPathComponent("Sources"),
                                                                     includingPropertiesForKeys: nil)!
        where url.pathExtension == "swift" {
            sources += try String(contentsOf: url, encoding: .utf8)
        }
        var dead: [String] = []
        for dir in ["Sources/Port42Lib/Resources", "Sources/Port42/Resources"] {
            for name in try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(dir).path)
            where !name.hasPrefix(".") {
                let stem = (name as NSString).deletingPathExtension
                let read = sources.contains(name) || sources.contains("\"\(stem)\"")
                if !read && Self.shippedUnread[name] == nil { dead.append("\(dir)/\(name)") }
            }
        }
        #expect(dead.isEmpty, "shipped but read by nothing: \(dead). Remove it, or add it to shippedUnread with the reason")
    }
}
