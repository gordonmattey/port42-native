import Testing
import Foundation
@testable import Port42Lib

/// Phase 0 of "the desktop rearranges itself" (docs/summer2026-todo.md): a re-grid must be
/// attributable. Two things move tiles — `applyArrange`, and the `arrangeBump` counter that
/// triggers it from a distance — and the second is the one that hides. A dozen callers bump it,
/// the desktop sees only a changed Int, and every re-grid that results reads as "the user pressed
/// ⌘L". That is exactly the mis-attribution Phase 0 exists to remove, so it is pinned here rather
/// than left to whoever adds the thirteenth caller.
@Suite("Arrange attribution (Phase 0)")
struct ArrangeAttributionTests {

    func sourceFiles() throws -> [(path: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/Port42Tests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources")
        var out: [(String, String)] = []
        let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in en where url.pathExtension == "swift" {
            out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return out
    }

    /// Code lines (comments dropped) containing a needle.
    func hits(_ needle: String, in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && $0.contains(needle) }
    }

    @Test("the arrange counter is only ever bumped through bumpArrange(_:), which names the caller")
    func everyBumpIsNamed() throws {
        var increments: [String] = []
        for file in try sourceFiles() {
            increments += hits("arrangeBump += 1", in: file.text).map { "\(file.path): \($0)" }
        }
        // Exactly one increment exists in the whole tree, and it is the one inside `bumpArrange`,
        // which records the name first. An unnamed bump re-grids the desktop and reports as ⌘L.
        #expect(increments.count == 1, "unnamed arrangeBump increments:\n\(increments.joined(separator: "\n"))")
        #expect(increments.first?.hasPrefix("ShellState.swift:") == true)

        // …and it sits inside bumpArrange, after the reason is recorded: the two lines are adjacent.
        let shellState = try #require(try sourceFiles().first { $0.path == "ShellState.swift" }?.text)
        let lines = shellState.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let bumpLine = try #require(lines.firstIndex(of: "arrangeBump += 1"))
        #expect(lines[bumpLine - 1] == "lastArrangeBumpReason = reason",
                "the increment must be preceded by the reason it records")
    }

    @Test("every applyArrange call site states a reason")
    func everyArrangeStatesAReason() throws {
        var unnamed: [String] = []
        for file in try sourceFiles() {
            for line in hits("applyArrange(", in: file.text) where !line.contains("func applyArrange") {
                if !line.contains("reason:") { unnamed.append("\(file.path): \(line)") }
            }
        }
        #expect(unnamed.isEmpty, "applyArrange call sites without a reason:\n\(unnamed.joined(separator: "\n"))")
    }

    @Test("bumpArrange records who asked, and the reason survives to the re-grid")
    @MainActor
    func bumpRecordsReason() throws {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let shell = ShellState(appState: state)

        #expect(shell.lastArrangeBumpReason == "none")
        shell.bumpArrange("cmd-L")
        #expect(shell.arrangeBump == 1)
        #expect(shell.lastArrangeBumpReason == "cmd-L")
        shell.bumpArrange("closeDM")
        #expect(shell.arrangeBump == 2)
        #expect(shell.lastArrangeBumpReason == "closeDM")
    }
}
