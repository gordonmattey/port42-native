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

    /// Tool (snake) name → canonical dotted name, or nil if unknown. Built as the exact reverse of
    /// `tool(fromCanonical:)` over the inventory, so the two can never silently disagree.
    public static func canonical(fromTool tool: String) -> String? {
        reverseMap[tool]
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

    private static let reverseMap: [String: String] = {
        var m: [String: String] = [:]
        for c in canonicalMethods {
            m[tool(fromCanonical: c)] = c
        }
        return m
    }()

    // MARK: The canonical inventory
    //
    // The union of the port-JS surface (`PortBridge.handleMethod`) and the tool-use surface
    // (`ToolExecutor.executeImpl` / `ToolDefinitions`) as of Phase 0. Phase 1 populates the registry
    // from exactly this list; the coverage test asserts every `ToolDefinitions` tool name maps back
    // into it. Streaming (`ai.complete` / `ai.cancel`) stays a documented exception on its own path
    // but is listed here for completeness of the surface.

    public static let canonicalMethods: [String] = [
        // identity / spaces / companions / messages / bus
        "user.get",
        "space.current", "space.list", "space.switchTo",
        "companions.list", "companions.get", "companions.invoke",
        "messages.recent", "messages.send", "messages.sendAsCreator",
        "bus.read", "bus.publish",

        // ports
        "ports.list",
        "port.create", "port.getHtml", "port.update", "port.patch", "port.push",
        "port.exec", "port.history", "port.restore", "port.manage", "port.move",
        "port.rename", "port.position", "port.info", "port.close", "port.resize",
        "port.setTitle", "port.setCapabilities",

        // storage
        "storage.get", "storage.set", "storage.delete", "storage.list",

        // relationship memory
        "crease.read", "crease.write", "crease.touch", "crease.forget",
        "engrave.read", "engrave.write", "engrave.touch", "engrave.forget",
        "fold.read", "fold.update",
        "position.read", "position.set",

        // ai
        "ai.models", "ai.status", "ai.complete", "ai.cancel",

        // devices
        "clipboard.read", "clipboard.write",
        "screen.capture", "screen.windows", "screen.displays", "screen.stream", "screen.stopStream",
        "camera.capture", "camera.stream", "camera.stopStream",
        "audio.speak", "audio.play", "audio.stop", "audio.capture", "audio.stopCapture",
        "notify.send",
        "fs.read", "fs.write", "fs.pick", "fs.list", "fs.mkdir",
        "browser.open", "browser.navigate", "browser.capture", "browser.text",
        "browser.html", "browser.execute", "browser.close",
        "automation.runAppleScript", "automation.runJXA",
        "rest.call",
        "terminal.exec",
    ]

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
