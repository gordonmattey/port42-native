import Foundation

/// Minimal, surgical TOML editing for ONE job: adding Port42's hooks to the user's own codex config
/// without throwing the rest of it away.
///
/// **Why this exists** (2026-07-31, GM reported it live). `CODEX_HOME` points codex at a directory of
/// our making, and we owned `config.toml` outright — so codex stopped loading the user's real one as
/// its USER config. Because a Port42 terminal's cwd is often the home directory, codex then found
/// `$HOME/.codex/config.toml` as a PROJECT-LOCAL config, where only a subset of keys is legal, and
/// said so:
///
///     Ignored unsupported project-local config keys in /Users/gordon/.codex/config.toml: notify.
///
/// The warning names one key; the loss is the whole file. GM's is 62 lines and 14 tables — `notify`,
/// marketplaces, six plugins, `[features]`, an MCP server and its env, `[desktop]`, a project trust
/// entry, TUI state. None of it reached codex. The producer's mirror symlinks every entry in
/// `~/.codex` EXCEPT `config.toml`, which is the one file the settings live in.
///
/// **Why not just concatenate.** TOML forbids redefining a table. The user already defines
/// `[features]` and `[projects."<home>"]`, and so do we, so appending our block to theirs produces a
/// config codex REJECTS — worse than the warning it was meant to fix. So the two colliding keys are
/// merged INTO the user's existing tables, and only genuinely new material is appended.
///
/// **Why not a TOML library.** This needs to add two keys and append array-of-tables entries while
/// preserving the user's file byte-for-byte otherwise. A parse/re-emit round trip would reformat and
/// drop their comments, which is a bigger change to someone's config than the thing being fixed.
enum CodexConfigMerge {

    /// Set `key = value` inside `[table]`, wherever that leaves the rest of the document untouched.
    ///
    /// Three cases, and the third is the one that makes appending unsafe without this:
    ///   - the table exists and already has the key → replace that line in place
    ///   - the table exists without the key        → insert the line just under the header
    ///   - the table does not exist                 → append the table at the end
    ///
    /// `value` is written verbatim, so callers pass TOML syntax (`true`, `"trusted"`).
    static func setKey(_ key: String, to value: String, inTable table: String,
                       of toml: String) -> String {
        var lines = toml.components(separatedBy: "\n")
        let header = "[\(table)]"

        guard let headerIdx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == header
        }) else {
            // Absent: append. A trailing newline keeps successive appends from running together.
            var out = toml
            if !out.hasSuffix("\n") { out += "\n" }
            return out + "\n\(header)\n\(key) = \(value)\n"
        }

        // The table runs to the next header line, or to the end of the document.
        var end = lines.count
        for i in (headerIdx + 1)..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end = i; break }
        }

        // Already set? Replace the assignment rather than adding a duplicate key, which TOML also
        // forbids. Matches `key` at the start of a line, ignoring leading whitespace.
        for i in (headerIdx + 1)..<end {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key) else { continue }
            let after = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            if after.hasPrefix("=") {
                lines[i] = "\(key) = \(value)"
                return lines.joined(separator: "\n")
            }
        }

        lines.insert("\(key) = \(value)", at: headerIdx + 1)
        return lines.joined(separator: "\n")
    }

    /// Does this document already declare `[table]`? Used to keep the caller honest about which
    /// additions are safe to append.
    static func hasTable(_ table: String, in toml: String) -> Bool {
        toml.components(separatedBy: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces) == "[\(table)]"
        }
    }

    // MARK: - Hook state (codex's own trust record)

    /// Codex records hook trust as `[hooks.state."<defining config path>:<event>:0:0"]` with a
    /// `trusted_hash`, WRITTEN BACK INTO the config that defined the hook.
    ///
    /// Two consequences, and both are bugs if ignored:
    ///
    /// 1. **It must not be copied from the user's config into ours.** The key names the file that
    ///    defined the hook, so a state entry carried into a different file is meaningless at best.
    ///    Observed live: an entry for `/<session-flags>/config.toml` (left in `~/.codex/config.toml`
    ///    by a `-c` experiment) rode the merge into a generated config where it referred to nothing.
    ///
    /// 2. **It must be carried forward between generations of OUR config**, or every regeneration
    ///    presents codex with an unrecognised hook, which it marks for review and SKIPS. That is the
    ///    whole reason codex companions never registered: the config path moved every time.
    static func isHookStateHeader(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t == "[hooks.state]" || t.hasPrefix("[hooks.state.")
    }

    /// Split a document into (everything else, the `[hooks.state…]` tables verbatim).
    static func partitionHookState(_ toml: String) -> (rest: String, state: String) {
        var rest: [String] = [], state: [String] = []
        var inState = false
        for line in toml.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { inState = isHookStateHeader(line) }
            (inState ? { state.append(line) } : { rest.append(line) })()
        }
        return (rest.joined(separator: "\n"), state.joined(separator: "\n"))
    }
}
