import Foundation

/// Tool definitions for the Anthropic API tool use protocol.
/// Each tool maps to an existing port42 bridge API method.
enum ToolDefinitions {

    /// All available tools grouped by permission requirement.
    static var all: [[String: Any]] {
        infoTools + actionTools + deviceTools
    }

    // MARK: - Info Tools (no permission needed)

    static let infoTools: [[String: Any]] = [
        [
            "name": "user_get",
            "description": "Get the current user's identity (id and display name)",
            "input_schema": ["type": "object", "properties": [String: Any]()]
        ],
        [
            "name": "channel_current",
            "description": "Get the current channel's metadata (id, name, member count)",
            "input_schema": ["type": "object", "properties": [String: Any]()]
        ],
        [
            "name": "channel_list",
            "description": "List all channels the user belongs to",
            "input_schema": ["type": "object", "properties": [String: Any]()]
        ],
        [
            "name": "companions_list",
            "description": "List all companions in this Port42 instance with their names, models, and trigger modes",
            "input_schema": ["type": "object", "properties": [String: Any]()]
        ],
        [
            "name": "companions_get",
            "description": "Get details about a specific companion by ID",
            "input_schema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The companion's ID"]
                ],
                "required": ["id"]
            ] as [String: Any]
        ],
        [
            "name": "messages_recent",
            "description": "Get the most recent messages from the current channel",
            "input_schema": [
                "type": "object",
                "properties": [
                    "count": ["type": "integer", "description": "Number of messages to retrieve (default 20, max 100)"]
                ]
            ] as [String: Any]
        ],
    ]

    // MARK: - Action Tools (no permission needed)

    static let actionTools: [[String: Any]] = [
        [
            "name": "ports_list",
            "description": "List all active ports (popped-out interactive surfaces) with their IDs, titles, and status",
            "input_schema": ["type": "object", "properties": [String: Any]()]
        ],
        [
            "name": "port_manage",
            "description": "Manage a port window. Actions: focus (bring to front), close, minimize/dock (hide but keep running in background), restore/undock (show a docked port as floating window). Check the status field from ports_list — use restore/undock for 'docked' ports, focus for 'floating' ports.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The port's UDID or title"],
                    "action": ["type": "string", "description": "One of: focus, close, minimize, dock, restore, undock"]
                ],
                "required": ["id", "action"]
            ] as [String: Any]
        ],
        [
            "name": "port_update",
            "description": "Update an existing port's HTML content. The port can be identified by its UDID or title. Works whether the port is windowed or minimized.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The port's UDID or title to identify which port to update"],
                    "html": ["type": "string", "description": "The new HTML content for the port (full HTML, not a diff)"]
                ],
                "required": ["id", "html"]
            ] as [String: Any]
        ],
        [
            "name": "messages_send",
            "description": "Send a message to the current channel",
            "input_schema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "The message text to send"]
                ],
                "required": ["text"]
            ] as [String: Any]
        ],
        [
            "name": "storage_get",
            "description": "Get a value from persistent key-value storage",
            "input_schema": [
                "type": "object",
                "properties": [
                    "key": ["type": "string", "description": "The storage key"]
                ],
                "required": ["key"]
            ] as [String: Any]
        ],
        [
            "name": "storage_set",
            "description": "Store a value in persistent key-value storage",
            "input_schema": [
                "type": "object",
                "properties": [
                    "key": ["type": "string", "description": "The storage key"],
                    "value": ["type": "string", "description": "The value to store"]
                ],
                "required": ["key", "value"]
            ] as [String: Any]
        ],
        [
            "name": "storage_delete",
            "description": "Delete a value from persistent storage",
            "input_schema": [
                "type": "object",
                "properties": [
                    "key": ["type": "string", "description": "The storage key to delete"]
                ],
                "required": ["key"]
            ] as [String: Any]
        ],
        [
            "name": "storage_list",
            "description": "List all keys in persistent storage",
            "input_schema": ["type": "object", "properties": [String: Any]()]
        ],
    ]

    // MARK: - Device Tools (need permission)

    static let deviceTools: [[String: Any]] = [
        [
            "name": "clipboard_read",
            "description": "Read the current clipboard contents. Returns text or base64 image data.",
            "input_schema": ["type": "object", "properties": [String: Any]()]
        ],
        [
            "name": "clipboard_write",
            "description": "Write text to the system clipboard",
            "input_schema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "The text to copy to clipboard"]
                ],
                "required": ["text"]
            ] as [String: Any]
        ],
        [
            "name": "screen_capture",
            "description": "Capture a screenshot of the screen. Returns a base64 PNG image.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "scale": ["type": "number", "description": "Image scale factor 0.1-2.0 (default 1.0)"]
                ]
            ] as [String: Any]
        ],
        [
            "name": "screen_windows",
            "description": "List all visible windows with their titles, apps, and positions",
            "input_schema": ["type": "object", "properties": [String: Any]()]
        ],
        [
            "name": "terminal_exec",
            "description": "Execute a shell command and return the output. Runs in /bin/zsh.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "The shell command to execute"],
                    "cwd": ["type": "string", "description": "Working directory (default: home)"],
                    "timeout": ["type": "integer", "description": "Timeout in seconds (default: 30, max: 120)"]
                ],
                "required": ["command"]
            ] as [String: Any]
        ],
        [
            "name": "terminal_send",
            "description": "Send input to a named port's terminal session. Use this to interact with running CLI tools like Claude Code, npm, docker, etc.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "The port title/name containing the terminal"],
                    "data": ["type": "string", "description": "The text to send as stdin (include \\n for enter)"]
                ],
                "required": ["name", "data"]
            ] as [String: Any]
        ],
        [
            "name": "terminal_list",
            "description": "List all ports that have active terminal sessions, showing port name and session status",
            "input_schema": ["type": "object", "properties": [String: Any]()]
        ],
        [
            "name": "terminal_bridge",
            "description": "Start bridging a port terminal's output to the current channel. Output is ANSI-stripped and posted as messages so companions can see what the terminal is doing.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "The port title/name containing the terminal"]
                ],
                "required": ["name"]
            ] as [String: Any]
        ],
        [
            "name": "terminal_unbridge",
            "description": "Stop bridging a port terminal's output to the channel.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "The port title/name to stop bridging"]
                ],
                "required": ["name"]
            ] as [String: Any]
        ],
        [
            "name": "file_read",
            "description": "Read the contents of a file. Path must have been previously approved by the user via file picker.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute file path"],
                    "encoding": ["type": "string", "description": "utf8 (default) or base64"]
                ],
                "required": ["path"]
            ] as [String: Any]
        ],
        [
            "name": "file_write",
            "description": "Write content to a file. Path must have been previously approved by the user via file picker.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute file path"],
                    "data": ["type": "string", "description": "Content to write"],
                    "encoding": ["type": "string", "description": "utf8 (default) or base64"]
                ],
                "required": ["path", "data"]
            ] as [String: Any]
        ],
        [
            "name": "run_applescript",
            "description": "Execute AppleScript code and return the result. Use this to control other applications on macOS.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "source": ["type": "string", "description": "AppleScript source code"],
                    "timeout": ["type": "integer", "description": "Timeout in seconds (default: 30, max: 120)"]
                ],
                "required": ["source"]
            ] as [String: Any]
        ],
        [
            "name": "run_jxa",
            "description": "Execute JavaScript for Automation (JXA) code and return the result. Use this to control other applications on macOS.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "source": ["type": "string", "description": "JXA source code"],
                    "timeout": ["type": "integer", "description": "Timeout in seconds (default: 30, max: 120)"]
                ],
                "required": ["source"]
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
        [
            "name": "notify_send",
            "description": "Send a macOS system notification",
            "input_schema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Notification title"],
                    "body": ["type": "string", "description": "Notification body text"]
                ],
                "required": ["title", "body"]
            ] as [String: Any]
        ],
        [
            "name": "audio_speak",
            "description": "Speak text aloud using text-to-speech",
            "input_schema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "Text to speak"],
                    "rate": ["type": "number", "description": "Speech rate 0.1-1.0 (default 0.5)"]
                ],
                "required": ["text"]
            ] as [String: Any]
        ],
    ]

    /// Permission required for a tool, or nil if no permission needed.
    static func permission(for toolName: String) -> PortPermission? {
        switch toolName {
        case "clipboard_read", "clipboard_write": return .clipboard
        case "screen_capture", "screen_windows": return .screen
        case "terminal_exec", "terminal_send", "terminal_list", "terminal_bridge", "terminal_unbridge": return .terminal
        case "file_read", "file_write": return .filesystem
        case "run_applescript", "run_jxa": return .automation
        case "browser_open", "browser_text", "browser_capture", "browser_close": return .browser
        case "notify_send": return .notification
        case "audio_speak": return nil // TTS doesn't need permission
        default: return nil
        }
    }
}
