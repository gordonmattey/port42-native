import Foundation

// MARK: - ToolNaming
//
// The single seam between the canonical method name (dotted, e.g. `port.getHtml` — what the docs
// publish and what a port's JS calls) and the tool name the model emits (snake, e.g. `port_get_html`
// — Anthropic tool names disallow dots). Before this, the gateway munged `.`→`_` and nothing more, so
// `port.getHtml` → `port_getHtml` ≠ `port_get_html` = "Unknown tool". A string munge cannot recover
// `get_html` from `getHtml`; an explicit map can. This kills the whole class.
//
// Most names are algorithmic (dots + camelCase → snake). Only genuine RENAMES need an override —
// where the tool surface chose a different word than the JS surface for the same method. The audit
// found these: the automation runners, the display query, and the file ops (`fs.*` in JS, `file_*`
// as tools).

public enum ToolNaming {

    /// Canonical (dotted) → tool (snake), only where the tool name is not a pure snakeification of
    /// the canonical name. Everything else falls through to `snakeify`.
    public static let toolOverrides: [String: String] = [
        "automation.runAppleScript": "run_applescript",
        "automation.runJXA": "run_jxa",
        "screen.displays": "screen_info",
        "fs.read": "file_read",
        "fs.write": "file_write",
        "fs.list": "file_list",
        "fs.mkdir": "file_mkdir",
    ]

    /// Canonical dotted name → tool (snake) name.
    public static func tool(fromCanonical canonical: String) -> String {
        if let o = toolOverrides[canonical] { return o }
        return snakeify(canonical)
    }

    /// dots → underscores, camelCase → snake_case, lowercased.
    /// `port.getHtml` → `port_get_html`; `ports.list` → `ports_list`.
    public static func snakeify(_ dotted: String) -> String {
        var out = ""
        for ch in dotted {
            if ch == "." {
                out.append("_")
            } else if ch.isUppercase {
                out.append("_")
                out.append(contentsOf: ch.lowercased())
            } else {
                out.append(ch)
            }
        }
        return out
    }

    // The canonical inventory is NOT declared here (close-out step 4a): the registry's keys are the
    // inventory, and `AppState.toolNameMap` derives tool → canonical from them. This file owns only
    // the spelling rules above.

    /// The `files.*` aliases (`files.read` / `files.write` / `files.pick`) resolve to their `fs.*`
    /// canonical. Kept separate from the inventory so the canonical set stays a clean union; the
    /// adapters resolve an alias to its canonical before lookup.
    public static let aliases: [String: String] = [
        "files.read": "fs.read",
        "files.write": "fs.write",
        "files.pick": "fs.pick",
        "-h": "help",
    ]

    /// Resolve any incoming dotted name (canonical or alias) to its canonical form.
    public static func resolveAlias(_ dotted: String) -> String {
        aliases[dotted] ?? dotted
    }
}
