import Foundation

/// Tool definitions for the Anthropic API tool use protocol.
///
/// Big-bang step 1 (done): the tool schemas are GENERATED from the registry
/// (`AppState.generatedToolDefinitions`) via each method's self-describing metadata. The 52 hand-written
/// schemas that used to live here are gone; their frozen snapshot is `Tests/Fixtures/tool-definitions-golden.json`,
/// which `BridgeSchemaParityTests` checks the generator against so generation can never silently drift.
///
/// Only the not-yet-extracted live-only tools remain hand-written here — `browser.*` and `rest.call`,
/// which still run on the old switches. `generatedToolDefinitions` folds these in as hybrid entries
/// until those families move into the registry (the tail), at which point this list empties entirely.
enum ToolDefinitions {

    /// EMPTY since tail items 4+5: every tool is generated from the registry. These stay only until
    /// the close-out deletes this type entirely (with the old switches).
    static let hybridToolNames: Set<String> = []

    /// The hybrid tools the generated list folds in. Empty — the tail extracted the last holdouts.
    static var hybridTools: [[String: Any]] { all }

    /// All hand-written tools: none remain. Production reads `generatedToolDefinitions`.
    static let all: [[String: Any]] = []

    /// Permission required for a tool, or nil if no permission needed. Still used by the old
    /// `ToolExecutor` path for the not-yet-extracted families; registry methods gate via
    /// `BridgeMethod.permission`.
    static func permission(for toolName: String) -> PortPermission? {
        switch toolName {
        case "clipboard_read", "clipboard_write": return .clipboard
        case "screen_capture", "screen_windows", "camera_capture": return .screen
        case "terminal_exec": return .terminal // headless run-and-capture; the only gated terminal tool
        case "file_read", "file_write": return .filesystem
        case "file_list", "file_mkdir": return nil  // relative paths only, Port42 data dir
        case "run_applescript", "run_jxa": return .automation
        case "browser_open", "browser_text", "browser_capture", "browser_close": return .browser
        case "notify_send": return .notification
        case "audio_speak": return nil // TTS doesn't need permission
        case "rest_call": return .rest
        default: return nil
        }
    }
}
