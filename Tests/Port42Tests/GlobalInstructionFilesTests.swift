import Testing
import Foundation

/// Port42 does not write global agent instruction files (GM, 2026-09-28). It used to rewrite a Port42
/// block in ~/.claude/CLAUDE.md, ~/.codex/AGENTS.md and ~/.gemini/GEMINI.md at every launch, which
/// every session on the Mac then read, Port42's or not.
@Suite("No global instruction files")
struct GlobalInstructionFilesTests {

    @Test("nothing in the app installs or refreshes an instruction block in the person's home")
    func noWriters() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        var callers: [String] = []
        for case let url as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        where url.pathExtension == "swift" && url.lastPathComponent != "InstructionService.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                if code.contains("refreshInstalled(") || code.contains("installInstructions(") {
                    callers.append("\(url.lastPathComponent):\(i + 1)")
                }
            }
        }
        #expect(callers.isEmpty, "something writes the person's global agent instructions again: \(callers)")
    }
}
