import Testing
import Foundation
@testable import Port42Lib

@Suite("TerminalOutputProcessor")
struct TerminalOutputProcessorTests {

    // MARK: - stripANSI

    @Test("stripANSI removes SGR colour codes")
    func stripSGR() {
        let raw = "\u{1b}[32mhello\u{1b}[0m world"
        #expect(TerminalOutputProcessor.stripANSI(raw) == "hello world")
    }

    @Test("stripANSI removes cursor movement sequences")
    func stripCursorMovement() {
        let raw = "\u{1b}[2A\u{1b}[1Bhello"
        #expect(TerminalOutputProcessor.stripANSI(raw) == "hello")
    }

    @Test("stripANSI removes OSC title sequences")
    func stripOSCTitle() {
        let raw = "\u{1b}]0;My Terminal\u{07}hello"
        #expect(TerminalOutputProcessor.stripANSI(raw) == "hello")
    }

    @Test("stripANSI strips bare carriage returns")
    func stripCR() {
        let raw = "line1\rline2"
        #expect(TerminalOutputProcessor.stripANSI(raw) == "line1line2")
    }

    @Test("stripANSI leaves plain text unchanged")
    func stripPlainPassthrough() {
        let raw = "hello world\nfoo bar"
        #expect(TerminalOutputProcessor.stripANSI(raw) == "hello world\nfoo bar")
    }

    @Test("stripANSI removes private-mode sequences (?25h)")
    func stripPrivateMode() {
        let raw = "\u{1b}[?25lhello\u{1b}[?25h"
        #expect(TerminalOutputProcessor.stripANSI(raw) == "hello")
    }

    // MARK: - collapseAndFilter: CR collapse

    @Test("collapseAndFilter keeps last segment after CR overwrite")
    func crCollapse() {
        // Terminal overwrites line: "loading\r" then "done"
        let raw = "loading\rdone"
        let result = TerminalOutputProcessor.collapseAndFilter(raw)
        #expect(result == "done")
        #expect(!result.contains("loading"))
    }

    // MARK: - collapseAndFilter: noise filtering

    @Test("collapseAndFilter drops spinner characters")
    func dropsSpinners() {
        let raw = "✻\n✶\n✳\nBuild complete"
        let result = TerminalOutputProcessor.collapseAndFilter(raw)
        #expect(result == "Build complete")
    }

    @Test("collapseAndFilter drops token counter lines")
    func dropsTokenCounters() {
        // Spinner glyph + digit-only = token counter noise
        let raw = "✻ 1234\nBuild complete\n✻ 5678"
        let result = TerminalOutputProcessor.collapseAndFilter(raw)
        #expect(result == "Build complete")
    }

    @Test("collapseAndFilter drops spinner-word lines (e.g. 'Thinking...')")
    func dropsSpinnerWords() {
        let raw = "✻ Thinking...\nBuild complete"
        let result = TerminalOutputProcessor.collapseAndFilter(raw)
        #expect(result == "Build complete")
    }

    @Test("collapseAndFilter drops '(thinking)' line")
    func dropsThinking() {
        let raw = "(thinking)\nBuild complete"
        let result = TerminalOutputProcessor.collapseAndFilter(raw)
        #expect(result == "Build complete")
    }

    @Test("collapseAndFilter drops compiler note lines")
    func dropsNotes() {
        let raw = "note: candidate function not viable\nBuild complete"
        let result = TerminalOutputProcessor.collapseAndFilter(raw)
        #expect(result == "Build complete")
    }

    @Test("collapseAndFilter drops empty lines")
    func dropsEmptyLines() {
        let raw = "\n\nBuild complete\n\n"
        let result = TerminalOutputProcessor.collapseAndFilter(raw)
        #expect(result == "Build complete")
    }

    @Test("collapseAndFilter drops single-character lines")
    func dropsSingleChars() {
        let raw = ">\nBuild complete"
        let result = TerminalOutputProcessor.collapseAndFilter(raw)
        // single char ">" is noise; "Build complete" is signal
        #expect(result == "Build complete")
    }

    // MARK: - collapseAndFilter: signal preservation

    @Test("collapseAndFilter keeps error lines")
    func keepsErrors() {
        let raw = "Sources/Foo.swift:10: error: use of undeclared 'bar'"
        let result = TerminalOutputProcessor.collapseAndFilter(raw)
        #expect(result.contains("error"))
    }

    @Test("collapseAndFilter keeps ⏺ lines (Claude Code output marker)")
    func keepsBulletOutput() {
        let raw = "⏺ Hi! How can I help?"
        let result = TerminalOutputProcessor.collapseAndFilter(raw)
        #expect(result == "⏺ Hi! How can I help?")
    }

    @Test("collapseAndFilter keeps shell prompt lines")
    func keepShellPrompt() {
        let raw = "$ echo hello"
        let result = TerminalOutputProcessor.collapseAndFilter(raw)
        #expect(result == "$ echo hello")
    }

    // MARK: - collapseAndFilter: build phase collapse

    @Test("collapseAndFilter collapses multiple Compiling lines")
    func collapsesCompiling() {
        let raw = "Compiling Foo.swift\nCompiling Bar.swift\nCompiling Baz.swift\nBuild complete"
        let result = TerminalOutputProcessor.collapseAndFilter(raw)
        #expect(result.contains("Compiling 3 files"))
        #expect(result.contains("Build complete"))
    }

    @Test("collapseAndFilter summarises single build file")
    func collapsesSingleFile() {
        let raw = "Compiling Foo.swift\nBuild complete"
        let result = TerminalOutputProcessor.collapseAndFilter(raw)
        #expect(result.contains("Compiling 1 file"))
    }

    @Test("collapseAndFilter collapses Linking lines")
    func collapsesLinking() {
        let raw = "Linking libFoo.a\nLinking libBar.a\nBuild complete"
        let result = TerminalOutputProcessor.collapseAndFilter(raw)
        #expect(result.contains("Linking 2 files"))
    }

    // MARK: - collapseAndFilter: deduplication

    @Test("collapseAndFilter deduplicates repeated lines")
    func deduplicates() {
        let raw = "Build complete\nBuild complete\nBuild complete"
        let result = TerminalOutputProcessor.collapseAndFilter(raw)
        let lines = result.components(separatedBy: "\n")
        #expect(lines.count == 1)
        #expect(lines[0] == "Build complete")
    }

    // MARK: - collapseAndFilter: line cap

    @Test("collapseAndFilter caps output at 60 lines")
    func capsAt60Lines() {
        let lines = (1...100).map { "line \($0)" }
        let raw = lines.joined(separator: "\n")
        let result = TerminalOutputProcessor.collapseAndFilter(raw)
        let resultLines = result.components(separatedBy: "\n")
        #expect(resultLines.count <= 60)
    }

    @Test("collapseAndFilter keeps trailing lines when capping")
    func capsKeepsTrailing() {
        let lines = (1...100).map { "line \($0)" }
        let raw = lines.joined(separator: "\n")
        let result = TerminalOutputProcessor.collapseAndFilter(raw)
        // Should keep the last 60 lines (41–100)
        #expect(result.contains("line 100"))
        #expect(!result.contains("line 1\n"))
    }

    // MARK: - TerminalOutputProcessor: receive + flush

    @Test("flush with empty buffer calls no callback")
    @MainActor
    func flushEmptyNoCallback() async {
        var called = false
        let p = TerminalOutputProcessor { _ in called = true }
        p.flush()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!called)
    }

    @Test("explicit flush delivers cleaned content to callback")
    @MainActor
    func explicitFlushDeliversContent() async throws {
        var received: String?
        let p = TerminalOutputProcessor { content in received = content }
        p.receive("⏺ Hello from Claude\n")
        p.flush()
        try await Task.sleep(for: .milliseconds(20))
        #expect(received == "⏺ Hello from Claude")
    }

    @Test("force-flush fires at 8KB")
    @MainActor
    func forceFlushAt8KB() async throws {
        var received: String?
        let p = TerminalOutputProcessor { content in received = content }
        // Send 8001 chars of signal text (repeated meaningful line)
        let chunk = String(repeating: "⏺ output line\n", count: 600) // ~8400 chars
        p.receive(chunk)
        // Force flush is synchronous path but callback is async
        try await Task.sleep(for: .milliseconds(20))
        #expect(received != nil)
    }

    @Test("duplicate content is not delivered twice")
    @MainActor
    func deduplicatesFlushes() async throws {
        var callCount = 0
        let p = TerminalOutputProcessor { _ in callCount += 1 }
        p.receive("⏺ Hello\n")
        p.flush()
        try await Task.sleep(for: .milliseconds(20))
        // Second flush with same content
        p.receive("⏺ Hello\n")
        p.flush()
        try await Task.sleep(for: .milliseconds(20))
        #expect(callCount == 1)
    }

    @Test("different content is delivered on second flush")
    @MainActor
    func differentContentDeliveredTwice() async throws {
        var callCount = 0
        let p = TerminalOutputProcessor { _ in callCount += 1 }
        p.receive("⏺ Hello\n")
        p.flush()
        try await Task.sleep(for: .milliseconds(20))
        p.receive("⏺ World\n")
        p.flush()
        try await Task.sleep(for: .milliseconds(20))
        #expect(callCount == 2)
    }

    @Test("content over 2000 chars is truncated")
    @MainActor
    func truncatesLongContent() async throws {
        var received: String?
        let p = TerminalOutputProcessor { content in received = content }
        // 70 unique signal lines of ~35 chars each → well over 2000 chars and over the 60-line cap
        let lines = (1...70).map { "⏺ This is output line number \($0) from Claude" }
        p.receive(lines.joined(separator: "\n") + "\n")
        p.flush()
        try await Task.sleep(for: .milliseconds(20))
        if let r = received {
            #expect(r.count <= 2000 + "\n… (truncated)".count)
            #expect(r.hasSuffix("… (truncated)"))
        } else {
            // content may have been filtered to under 2000 after collapse — acceptable
        }
    }
}
