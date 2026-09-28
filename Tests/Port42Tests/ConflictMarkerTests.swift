import Testing
import Foundation

/// No merge conflict markers in anything that ships or is built from. A resolved merge left
/// `<<<<<<< HEAD` and a second script tag in the invite page, served live at tele.port42.ai (GM,
/// 2026-09-27); nothing checked. The build gate runs this, so a marker stops the build.
@Suite("No conflict markers")
struct ConflictMarkerTests {

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let dirs = ["Sources", "Tests", "guest", "gateway", "docs", "scripts"]
    static let skip: Set<String> = ["node_modules", "dist", ".build", "GhosttyKit.xcframework"]
    static let kinds: Set<String> = ["swift", "go", "js", "mjs", "html", "css", "json", "md", "txt", "sh", "py", "toml", "yml", "yaml"]

    static func offenders(in text: String) -> [Int] {
        text.components(separatedBy: "\n").enumerated().compactMap { i, line in
            line.hasPrefix("<<<<<<< ") || line.hasPrefix(">>>>>>> ") || line == "<<<<<<<" || line == ">>>>>>>" ? i + 1 : nil
        }
    }

    @Test("the marker check sees a marker")
    func sees() {
        #expect(Self.offenders(in: "a\n<<<<<<< HEAD\nb\n=======\nc\n>>>>>>> branch\n") == [2, 6])
        #expect(Self.offenders(in: "a heading\n=======\nnot a conflict\n").isEmpty)
    }

    @Test("no source, test, guest, gateway, doc or script file holds a conflict marker")
    func none() throws {
        var found: [String] = []
        for dir in Self.dirs {
            let base = Self.root.appendingPathComponent(dir)
            guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for case let url as URL in walk {
                if Self.skip.contains(url.lastPathComponent) { walk.skipDescendants(); continue }
                guard Self.kinds.contains(url.pathExtension), url.lastPathComponent != "ConflictMarkerTests.swift",
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for line in Self.offenders(in: text) {
                    found.append("\(url.path.replacingOccurrences(of: Self.root.path + "/", with: "")):\(line)")
                }
            }
        }
        #expect(found.isEmpty, "merge conflict markers: \(found)")
    }
}
