import Testing
import Foundation
@testable import Port42Lib

// JSONSerialization raises an uncatchable exception on NaN, infinity and non-JSON values; on the main
// queue AppKit swallows it and the main queue never runs again (Dev4, 2026-09-26). SafeJSON cannot.
@Suite("Safe JSON")
struct SafeJSONTests {

    @Test("non-finite numbers become null; bools, ints and strings survive; nesting is cleaned")
    func cleans() throws {
        let v: [String: Any] = ["nan": Double.nan, "inf": -Double.infinity, "b": true, "i": 3, "s": "x",
                                "deep": ["a": [1.5, Double.nan]], "date": Date(timeIntervalSince1970: 0),
                                "opt": Optional<Int>.none as Any]
        let s = try #require(SafeJSON.string(v, options: [.sortedKeys]))
        let o = try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
        #expect(o["nan"] is NSNull && o["inf"] is NSNull && o["opt"] is NSNull)
        #expect(o["b"] as? Bool == true && o["i"] as? Int == 3 && o["s"] as? String == "x")
        #expect((o["deep"] as? [String: Any])?["a"] as? [Any] != nil)
        #expect(s.contains("\"b\":true"), "a bool became a number: \(s)")
        #expect(o["date"] is String)
    }

    @Test("a bare fragment is written; a bare NaN is null")
    func fragments() {
        #expect(SafeJSON.string(42) == "42")
        #expect(SafeJSON.string(Double.nan) == "null")
        #expect(SafeJSON.string("hi") == "\"hi\"")
    }

    @Test("the door's result encoding cannot raise on NaN")
    @MainActor
    func door() {
        #expect(GatewayDoor.jsonContent(from: ["v": Double.nan]) == "{\"v\":null}")
    }

    @Test("gate: nothing else in the package writes JSON with JSONSerialization")
    func gate() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        var offenders: [String] = []
        for case let url as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        where url.pathExtension == "swift" && url.lastPathComponent != "SafeJSON.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.components(separatedBy: "\n").enumerated()
            where (line.components(separatedBy: "//").first ?? "").contains("JSONSerialization.data(")
                || line.contains("JSONSerialization.writeJSONObject") {
                offenders.append("\(url.lastPathComponent):\(i + 1)")
            }
        }
        #expect(offenders.isEmpty, "use SafeJSON: \(offenders)")
    }
}
