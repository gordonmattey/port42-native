import Testing
import Foundation
@testable import Port42Lib

// Terminal output is processed on the main thread, chunk by chunk. The prompt check re-scanned the
// whole buffer on every chunk, so its cost grew with the buffer; with several agents redrawing at
// once it held the main thread and gateway calls timed out (Dev4, 2026-09-26). It reads the tail.
@Suite("Terminal output processing stays cheap")
@MainActor
struct TerminalOutputCostTests {
    @Test("a TUI redrawing thousands of times costs time in proportion to its output")
    func linearInOutput() {
        let p = TerminalOutputProcessor(wantsCleanedOutput: false, onFlush: { _ in })
        let frame = "\u{1b}[2K\u{1b}[1G\u{1b}[38;5;245m⠋ Thinking… (esc to interrupt)\u{1b}[0m " + String(repeating: "·", count: 60)
        let start = Date()
        for _ in 0..<8_000 { p.receive(frame) }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 3, "8,000 redraw chunks took \(String(format: "%.1f", elapsed)) s on the main thread")
    }

    @Test("the prompt is still found at the end of a long buffer")
    func promptStillFound() {
        var flushed: [String] = []
        let p = TerminalOutputProcessor(onFlush: { flushed.append($0) })
        p.receive("$ \n")                                            // warm-up ends at the first prompt
        p.receive(String(repeating: "output line\n", count: 300) + "> ")
        #expect(!flushed.isEmpty, "a prompt at the end of 3,600 characters of output was missed")
    }

    @Test("the prompt check reads the end of the buffer, never the whole of it")
    func readsOnlyTheTail() {
        let big = String(repeating: "x", count: 20_000) + "\n> "
        let window = TerminalOutputProcessor.promptWindow(of: big)
        #expect(window.count <= TerminalOutputProcessor.promptTail)
        #expect(TerminalOutputProcessor.endsWithPrompt(window))
    }

    @Test("a terminal nobody reads cleaned output from never cleans it, and still finds <p42> tags")
    func noCleaningForHookedTerminals() {
        var flushed = 0
        var tags: [String] = []
        let p = TerminalOutputProcessor(wantsCleanedOutput: false, onFlush: { _ in flushed += 1 })
        p.onP42Output = { tags += $0 }
        p.receive("$ \n")
        p.receive("working\n<p42>hello</p42>\n> ")
        #expect(flushed == 0, "cleaned output was produced for a terminal that discards it")
        #expect(tags == ["hello"])
    }
}
