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

    /// The tools still hand-written here (not yet in the registry). Kept in sync with `all` below.
    static let hybridToolNames: Set<String> = ["browser_open", "browser_text", "browser_capture", "browser_close", "rest_call"]

    /// The hybrid tools the generated list folds in. Once browser.*/rest.call are extracted, this empties.
    static var hybridTools: [[String: Any]] { all }

    /// All hand-written tools (now only the hybrid set). Production reads `generatedToolDefinitions`.
    static let all: [[String: Any]] = [
        [
            "name": "rest_call",
            "description": "Make an HTTP request to an external API. Use the 'secret' parameter to inject authentication from the secrets store — you never see the raw credential. Supports GET, POST, PUT, PATCH, DELETE. JSON bodies are auto-serialized. Responses with JSON content-type are auto-parsed.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "Full URL to call (https recommended)"],
                    "method": ["type": "string", "description": "HTTP method: GET, POST, PUT, PATCH, DELETE. Default: GET."],
                    "headers": [
                        "type": "object",
                        "description": "Additional HTTP headers as key-value pairs.",
                        "additionalProperties": ["type": "string"]
                    ] as [String: Any],
                    "body": ["type": "string", "description": "Request body. Objects are JSON-serialized automatically."],
                    "secret": ["type": "string", "description": "Named secret from the secrets store. The runtime injects the auth header — you never see the raw key."],
                    "timeout": ["type": "integer", "description": "Timeout in milliseconds. Default: 30000, max: 120000."]
                ],
                "required": ["url"]
            ] as [String: Any]
        ],
        [
            "name": "browser_open",
            "description": "Open a URL in a headless browser and return the page title. Use browser_text to read page content after opening.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "The URL to open (http or https)"]
                ],
                "required": ["url"]
            ] as [String: Any]
        ],
        [
            "name": "browser_text",
            "description": "Extract text content from an open browser session",
            "input_schema": [
                "type": "object",
                "properties": [
                    "sessionId": ["type": "string", "description": "Browser session ID from browser_open"],
                    "selector": ["type": "string", "description": "CSS selector to extract from (default: body)"]
                ],
                "required": ["sessionId"]
            ] as [String: Any]
        ],
        [
            "name": "browser_capture",
            "description": "Take a screenshot of an open browser session. Returns base64 PNG.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "sessionId": ["type": "string", "description": "Browser session ID from browser_open"]
                ],
                "required": ["sessionId"]
            ] as [String: Any]
        ],
        [
            "name": "browser_close",
            "description": "Close a browser session",
            "input_schema": [
                "type": "object",
                "properties": [
                    "sessionId": ["type": "string", "description": "Browser session ID to close"]
                ],
                "required": ["sessionId"]
            ] as [String: Any]
        ],
    ]

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
