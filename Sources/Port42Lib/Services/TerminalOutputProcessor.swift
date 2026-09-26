import Foundation

/// TerminalOutputProcessor — raw terminal bytes in, cleaned signal out.
///
/// Pure pipeline: no AppState, no space knowledge. Accumulates raw terminal
/// output, debounces 10s, force-flushes at 8KB, strips ANSI, collapses noise,
/// deduplicates, then calls `onFlush` with the cleaned result.
///
/// Used by `GhosttyTerminalController` to extract `<p42>` tags from a native terminal's PTY tee.
/// (Its `onFlush` cleaned-output stream is currently unused — reserved for a future native
/// output-streaming bridge; see `summer2026-todo.md`.)
@MainActor
final class TerminalOutputProcessor {
    private var buffer = ""
    private var flushTimer: Timer?
    private var lastPosted = ""
    private var warmingUp = true  // discard startup dump until first prompt
    private let onFlush: @MainActor (String) -> Void

    /// Fires with every `<p42>…</p42>` payload found in the raw stream. Independent
    /// of `onFlush` and of the `lastPosted` dedup — each emitted tag is delivered.
    /// Runs even during warmup (gap #9), so tags emitted before the first prompt
    /// are not lost to the startup discard.
    var onP42Output: (([String]) -> Void)?

    /// Whether anyone uses the cleaned output. A hooks-capable terminal (claude, codex) posts its
    /// replies from its Stop hook and discards `onFlush`, so cleaning its output (ANSI strip, noise
    /// collapse, several regexes per line) was main-thread work for nothing, on the terminals that
    /// print the most. Without it a flush only extracts `<p42>` tags.
    private let wantsCleanedOutput: Bool

    init(wantsCleanedOutput: Bool = true, onFlush: @escaping @MainActor (String) -> Void) {
        self.wantsCleanedOutput = wantsCleanedOutput
        self.onFlush = onFlush
    }

    /// How much of the buffer's end the prompt check reads. The prompt is the LAST line, so the
    /// check never needs more; it used to strip and split the whole buffer (up to 8,000 characters)
    /// on every chunk, and with several agents' TUIs redrawing at once that re-scan took the main
    /// thread (sampled on Dev4, 2026-09-26: gateway calls waited 30 s behind it).
    static let promptTail = 512

    /// What the prompt check reads: the end of the buffer, never more than `promptTail`.
    static func promptWindow(of buffer: String) -> String { String(buffer.suffix(promptTail)) }

    func receive(_ raw: String) {
        buffer += raw
        // Prompt detection: flush immediately when CLI tool returns to its ready state
        if TerminalOutputProcessor.endsWithPrompt(Self.promptWindow(of: buffer)) {
            if warmingUp {
                // First prompt = startup complete. Extract any <p42> tags emitted
                // during startup BEFORE discarding (gap #9), then discard the dump.
                emitP42Tags(in: buffer)
                warmingUp = false
                buffer = ""
                flushTimer?.invalidate()
                flushTimer = nil
                return
            }
            flush()
            return
        }
        // Fallback debounce: flush after 3s of quiet. ONE timer that checks when output last came,
        // not a timer torn down and rebuilt on every chunk (that churn was most of the remaining
        // per-chunk cost once the prompt check read only the tail).
        lastReceive = Date()
        if flushTimer == nil { armQuietFlush(after: Self.quietFlush) }
        // Force flush if buffer gets large
        if buffer.utf8.count > 8000 {
            flush()
        }
    }

    private var lastReceive = Date.distantPast
    static let quietFlush: TimeInterval = 3

    private func armQuietFlush(after wait: TimeInterval) {
        flushTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.flushTimer = nil
                let quiet = Date().timeIntervalSince(self.lastReceive)
                if quiet >= Self.quietFlush { self.flush() } else { self.armQuietFlush(after: Self.quietFlush - quiet) }
            }
        }
    }

    func flush() {
        flushTimer?.invalidate()
        flushTimer = nil
        guard !buffer.isEmpty else {
            buffer = ""
            return
        }

        // Extract <p42> tags from the raw buffer BEFORE collapse/dedup — both would
        // shred or drop tags. Independent of the onFlush signal path below.
        emitP42Tags(in: buffer)
        guard wantsCleanedOutput else { buffer = ""; return }

        let cleaned = TerminalOutputProcessor.stripANSI(buffer)
        buffer = ""

        let trimmed = TerminalOutputProcessor.collapseAndFilter(cleaned)
        guard !trimmed.isEmpty else { return }

        // Skip if identical to last posted (avoids repeated prompts)
        guard trimmed != lastPosted else { return }
        lastPosted = trimmed

        // Truncate long output
        let content = trimmed.count > 2000 ? String(trimmed.prefix(2000)) + "\n… (truncated)" : trimmed

        onFlush(content)
    }

    private func emitP42Tags(in raw: String) {
        let tags = TerminalOutputProcessor.extractP42Tags(from: raw)
        if !tags.isEmpty { onP42Output?(tags) }
    }

    // MARK: - Static processing

    /// Extract the inner text of every `<p42>…</p42>` block in the stream.
    /// ANSI-stripped first so color codes / CR around the tag don't break the match.
    /// `[\s\S]*?` spans newlines (terminal-wrapped payloads). Tolerates a stray `\`
    /// before the closing slash, matching the legacy xterm extractor.
    private static let p42Regex = try? NSRegularExpression(
        pattern: "<p42>([\\s\\S]*?)<\\\\?/p42>", options: .caseInsensitive)

    static func extractP42Tags(from text: String) -> [String] {
        let stripped = stripANSI(text)
        guard let regex = p42Regex else { return [] }
        let range = NSRange(stripped.startIndex..., in: stripped)
        return regex.matches(in: stripped, range: range).compactMap { m in
            guard let r = Range(m.range(at: 1), in: stripped) else { return nil }
            let inner = String(stripped[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            return inner.isEmpty ? nil : inner
        }
    }

    /// Returns true if the buffer ends with a CLI ready prompt, meaning the tool
    /// has finished processing and is waiting for input. Triggers an immediate flush.
    /// Covers: Claude Code (> ), Gemini CLI (❯ ), bash/zsh ($ , % ), generic (> ).
    static func endsWithPrompt(_ raw: String) -> Bool {
        let stripped = stripANSI(raw)
        // Get the last non-empty line after CR collapse
        let lastLine = stripped
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "\r").last ?? $0 }
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        let trimmed = lastLine.trimmingCharacters(in: .whitespaces)
        // Match common interactive CLI prompts (check both raw and trimmed to catch trailing spaces)
        return trimmed == ">" || trimmed == "❯" || trimmed == "$" || trimmed == "%" ||
               lastLine.hasPrefix("> ") || lastLine.hasPrefix("❯ ") ||
               lastLine.hasPrefix("$ ") || lastLine.hasPrefix("% ")
    }

    /// Strip ANSI escape sequences for clean text.
    /// Compiled once. It was compiled on every call, and this runs on every chunk of every
    /// terminal's output, on the main thread.
    private static let ansiRegex = try? NSRegularExpression(
        pattern: "\\x1b(?:\\][^\\x07\\x1b]*(?:\\x07|\\x1b\\\\)|\\[[0-?]*[ -/]*[@-~]|[@-Z\\\\-_])",
        options: [])

    static func stripANSI(_ str: String) -> String {
        // ECMA-48 comprehensive strip: CSI sequences, OSC sequences, 2-byte Fe sequences
        guard let regex = ansiRegex else { return str }
        let range = NSRange(str.startIndex..., in: str)
        var result = regex.stringByReplacingMatches(in: str, range: range, withTemplate: "")
        result = result.replacingOccurrences(of: "\r", with: "")
        return result
    }

    /// Full bridge filter: collapses \r overwrites, drops noise, collapses build phases,
    /// deduplicates, and caps output so 800 lines of noise becomes ~5 lines of signal.
    static func collapseAndFilter(_ str: String) -> String {
        // 1. CR collapse — keep only the last \r segment per visual line
        let rows = str.components(separatedBy: "\n").map { row -> String in
            (row.components(separatedBy: "\r").last ?? row)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2. Drop noise lines, collapse build phases, dedup
        let spinnerChars = CharacterSet(charactersIn: "✻✶✳✽✢·⟡◐◑◒◓⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏▗▖▘▝")
        let signalPatterns: [NSRegularExpression] = [
            "error[: ]", "warning[: ]", "fatal[: ]",
            "^build complete", "^build failed", "^failed", "^passed",
            "^error\\[", "undefined symbol", "exited with code",
            "wrote ", "saved ", "created ", "deleted ", "updated ",
            "^\\$\\s", "^>\\s", "^⏺", "file written", "\\.(swift|go|ts|js|py|rs):.*error"
        ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

        func isSignal(_ t: String) -> Bool {
            let range = NSRange(t.startIndex..., in: t)
            return signalPatterns.contains { $0.firstMatch(in: t, range: range) != nil }
        }

        func isNoise(_ t: String) -> Bool {
            guard !t.isEmpty else { return true }
            if t.count == 1 { return true }
            let nonSpaceScalars = t.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }
            if nonSpaceScalars.allSatisfy({ spinnerChars.contains($0)
                || $0.properties.generalCategory == .otherSymbol
                || $0.properties.generalCategory == .mathSymbol }) { return true }
            let stripped = t.unicodeScalars.filter { !spinnerChars.contains($0) && !CharacterSet.whitespaces.contains($0) }
            if stripped.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) { return true }
            if let r = try? NSRegularExpression(pattern: "^[✻✶✳✽✢·⟡◐◑◒◓⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏\\s]*\\w+ing[…\\.]+\\s*$"),
               r.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil { return true }
            if t == "(thinking)" { return true }
            if t.hasPrefix("note: ") { return true }
            // Claude Code status/slash-command lines
            if t.hasPrefix("/") && !t.contains(" ") { return true }  // bare /mcp /login /effort
            if t.hasPrefix("⎿") { return true }  // tool result lines
            if t.hasPrefix("?for") || t == "0q" { return true }  // ANSI remnants
            if let r = try? NSRegularExpression(pattern: "^[◐◑◒◓✽✻✶]\\s+(low|medium|high|auto)"),
               r.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil { return true }
            // Echo lines: [name]: message
            if let r = try? NSRegularExpression(pattern: "^\\[\\w+\\]:"),
               r.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil { return true }
            return false
        }

        let buildPhasePattern = try? NSRegularExpression(
            pattern: "^(?:\\[\\d+/\\d+\\]\\s+)?(?:Compiling|Linking|Build input file|Merging module|Emitting module)",
            options: .caseInsensitive)

        func buildPhasePrefix(_ t: String) -> String? {
            guard let r = buildPhasePattern,
                  let m = r.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                  let range = Range(m.range, in: t) else { return nil }
            let raw = String(t[range]).trimmingCharacters(in: .whitespaces)
            if raw.lowercased().contains("compil") { return "Compiling" }
            if raw.lowercased().contains("link") { return "Linking" }
            if raw.lowercased().contains("emit") { return "Emitting" }
            if raw.lowercased().contains("merg") { return "Merging" }
            return "Building"
        }

        var output: [String] = []
        var seen: Set<String> = []
        var currentPhase: String? = nil
        var phaseCount = 0

        func flushPhase() {
            guard let phase = currentPhase, phaseCount > 0 else { return }
            let summary = phaseCount == 1 ? "\(phase) 1 file…" : "\(phase) \(phaseCount) files…"
            if !seen.contains(summary) {
                output.append(summary)
                seen.insert(summary)
            }
            currentPhase = nil
            phaseCount = 0
        }

        for t in rows {
            guard !isNoise(t) else { continue }

            if let phase = buildPhasePrefix(t) {
                if phase == currentPhase {
                    phaseCount += 1
                } else {
                    flushPhase()
                    currentPhase = phase
                    phaseCount = 1
                }
                continue
            }

            flushPhase()

            if seen.contains(t) { continue }
            seen.insert(t)
            output.append(t)
        }
        flushPhase()

        let capped = output.count > 60 ? Array(output.suffix(60)) : output
        return capped.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
