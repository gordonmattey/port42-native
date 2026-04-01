import Foundation

/// TerminalOutputProcessor — raw terminal bytes in, cleaned signal out.
///
/// Pure pipeline: no AppState, no channel knowledge. Accumulates raw terminal
/// output, debounces 10s, force-flushes at 8KB, strips ANSI, collapses noise,
/// deduplicates, then calls `onFlush` with the cleaned result.
///
/// Used by `OutputBatcher` (bridge/OpenClaw path) and directly by
/// `AppState.bridgeTerminalPort` (CLI terminal companion path).
final class TerminalOutputProcessor {
    private var buffer = ""
    private var flushTimer: Timer?
    private var lastPosted = ""
    private let onFlush: @MainActor (String) -> Void

    init(onFlush: @escaping @MainActor (String) -> Void) {
        self.onFlush = onFlush
    }

    func receive(_ raw: String) {
        buffer += raw
        // Debounce: flush after 10s of quiet
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.flush()
            }
        }
        // Force flush if buffer gets large
        if buffer.count > 8000 {
            flush()
        }
    }

    func flush() {
        flushTimer?.invalidate()
        guard !buffer.isEmpty else {
            buffer = ""
            return
        }

        let cleaned = TerminalOutputProcessor.stripANSI(buffer)
        buffer = ""

        let trimmed = TerminalOutputProcessor.collapseAndFilter(cleaned)
        guard !trimmed.isEmpty else { return }

        // Skip if identical to last posted (avoids repeated prompts)
        guard trimmed != lastPosted else { return }
        lastPosted = trimmed

        // Truncate long output
        let content = trimmed.count > 2000 ? String(trimmed.prefix(2000)) + "\n… (truncated)" : trimmed

        Task { @MainActor [onFlush] in
            onFlush(content)
        }
    }

    // MARK: - Static processing

    /// Strip ANSI escape sequences for clean text.
    static func stripANSI(_ str: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "\\x1b(?:\\[[0-9;?]*[a-zA-Z]|\\].*?(?:\\x07|\\x1b\\\\)|[()][0-9A-Za-z]|[>=<]|\\[\\?[0-9;]*[hl])",
            options: []
        ) else { return str }
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
        let spinnerChars = CharacterSet(charactersIn: "✻✶✳✽✢·⟡◐◑◒◓⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
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
