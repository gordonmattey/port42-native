import Testing
import Foundation
@testable import Port42Lib

/// C3 · every agent-facing example that calls the gateway carries a credential.
///
/// **The defect this exists to stop is not a typo, it is a teaching surface that was wrong.** The
/// first thing every companion and every CLI tool reads told it to `curl` the gateway with no
/// `Authorization` header. Step 5b had already made that call refused, and the refusal's remedy is
/// "add a client in Settings → Access", which a process cannot do. So a session that needed to call
/// went looking for a credential it could read, found the CLI's token file at a predictable path,
/// and used it. Measured 2026-07-31.
///
/// A hand-checked list of documents would rot, so this scans every generated surface: a `curl` line
/// aimed at `/call` must carry a header, wherever it appears.
@Suite("Agent-facing docs teach an authenticated call (C)")
struct AgentFacingAuthDocsTests {

    /// Every line that curls the gateway, paired with the document it came from.
    private func gatewayCurlLines(_ text: String, source: String) -> [(String, String)] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.contains("curl") && $0.contains("/call") }
            .map { ($0, source) }
    }

    /// A `curl` may put the header on a continuation line, so a line ending in `\` is judged
    /// together with what follows rather than on its own.
    private func unauthenticatedCurls(_ text: String, source: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var offenders: [String] = []
        for (i, line) in lines.enumerated() where line.contains("curl") && line.contains("/call") {
            // The whole command: this line plus any continuations.
            var command = line
            var j = i
            while command.hasSuffix("\\"), j + 1 < lines.count {
                j += 1
                command += "\n" + lines[j]
            }
            if !command.contains("Authorization") {
                offenders.append("\(source): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        return offenders
    }

    @Test("the generated instruction block never shows an unauthenticated call")
    @MainActor
    func instructionBlockCarriesTheHeader() throws {
        let markdown = InstructionService.shared.buildMarkdown(toolName: "Claude Code")
        let offenders = unauthenticatedCurls(markdown, source: "instruction block")
        #expect(offenders.isEmpty, "\(offenders)")
        #expect(!gatewayCurlLines(markdown, source: "x").isEmpty,
                "no curl examples at all — the scan would pass vacuously")

        // And it must say where the caller's OWN credential lives, or the header is unusable.
        #expect(markdown.contains("PORT42_TOKEN_FILE"))
        #expect(markdown.contains("Settings → Access"), "a caller with no token needs the route")
    }

    @Test("the published preamble never shows an unauthenticated call")
    func preambleCarriesTheHeader() throws {
        let url = try #require(Bundle.module.url(forResource: "llms-preamble", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let offenders = unauthenticatedCurls(text, source: "llms-preamble.txt")
        #expect(offenders.isEmpty, "\(offenders)")
        #expect(text.contains("PORT42_TOKEN_FILE"))
    }

    @Test("the companion prompt tells a companion it has its own credential")
    func companionPromptCarriesTheHeader() {
        // Every Port42-spawned companion reads this before anything else, and after B it always has
        // a token file, so the instruction is honest rather than aspirational.
        let prompt = AppState.companionPromptText(name: "Maker", spaceId: "SPACE-1",
                                                  spaceName: "space-2", gatewayPort: 4245,
                                                  systemPrompt: nil)

        let offenders = unauthenticatedCurls(prompt, source: "companion prompt")
        #expect(offenders.isEmpty, "\(offenders)")
        #expect(prompt.contains("PORT42_TOKEN_FILE"))
        #expect(prompt.lowercased().contains("never read another tool"),
                "the borrow has to be named, because it is the thing that actually happened")
    }
}
