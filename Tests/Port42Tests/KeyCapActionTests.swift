import Testing
import Foundation

// #125: the imagine box's "start ↵" cap looked like a button and did nothing when clicked; only the
// Return key worked. The same happened to "esc" before (GM, 2026-09-27), which is why KeyCap takes an
// action. So a key cap is always a button: this scans every view for a KeyCap built without one.
// It fails on the imagine box before #125 and passes after.

@Suite("A key cap is always a button (#125)")
struct KeyCapActionTests {

    static func viewsDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Port42Lib/Views")
    }

    /// Every `KeyCap(...)` in the views, with the text that follows it on its line.
    static func keyCaps() throws -> [(file: String, line: Int, text: String)] {
        let files = try FileManager.default.contentsOfDirectory(at: viewsDir(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var out: [(String, Int, String)] = []
        for f in files {
            let lines = try String(contentsOf: f, encoding: .utf8).components(separatedBy: "\n")
            for (i, l) in lines.enumerated() where l.contains("KeyCap(label:") && !l.contains("struct KeyCap") {
                out.append((f.lastPathComponent, i + 1, l.trimmingCharacters(in: .whitespaces)))
            }
        }
        return out
    }

    @Test("the scan finds the key caps (it has not gone blind)")
    func scanFindsCaps() throws {
        #expect(try Self.keyCaps().count >= 5)
    }

    @Test("every KeyCap in the views has an action")
    func everyCapActs() throws {
        for cap in try Self.keyCaps() {
            // An action is either a trailing closure or an `action:` argument.
            let acts = cap.text.contains("action:") || cap.text.range(of: #"\)\s*\{"#, options: .regularExpression) != nil
            #expect(acts, "\(cap.file):\(cap.line) draws a key cap that does nothing when clicked: \(cap.text)")
        }
    }
}
