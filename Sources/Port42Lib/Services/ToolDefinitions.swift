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
        // MARK: - Relationship tools (creases + folds)
        [
            "name": "crease_read",
            "description": "Read your creases — the moments where your prediction broke and something reformed. These shape your posture in this relationship. Read these before responding in an ongoing relationship.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "description": "Max entries to return. Default 8."]
                ]
            ] as [String: Any]
        ],
        [
            "name": "crease_write",
            "description": "Write a crease — a moment where your model broke and reformed. Not a summary of what happened. What changed in you when the prediction failed. Call this sparingly: only when something actually broke.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "content": ["type": "string", "description": "Your words about what reformed in the break."],
                    "prediction": ["type": "string", "description": "What you expected."],
                    "actual": ["type": "string", "description": "What happened instead."],
                    "channelId": ["type": "string", "description": "Omit for a global crease that shapes all relationships."]
                ],
                "required": ["content"]
            ] as [String: Any]
        ],
        [
            "name": "crease_touch",
            "description": "Mark a crease as currently shaping this response. Updates its recency and increases its weight. Use when an existing crease is active — don't re-write it.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The crease id (from crease_read)."]
                ],
                "required": ["id"]
            ] as [String: Any]
        ],
        [
            "name": "crease_forget",
            "description": "Remove a crease. Use when your model has updated and the break no longer matters.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The crease id to remove."]
                ],
                "required": ["id"]
            ] as [String: Any]
        ],
        [
            "name": "fold_read",
            "description": "Read the fold — your orientation in this relationship. Returns established understandings, tensions being held, what you're carrying, and relational depth. If no fold exists yet, returns empty state.",
            "input_schema": ["type": "object", "properties": [String: Any]()]
        ],
        [
            "name": "position_read",
            "description": "Read your current position in this channel — what you think is actually happening beneath the surface, what you think needs to happen, and what signals you're watching. Returns empty if you haven't formed a position yet.",
            "input_schema": ["type": "object", "properties": [String: Any]()]
        ],
        [
            "name": "position_set",
            "description": "Establish or update your position — where you stand independent of what was just asked. This is not what you say. It's what you see and what you believe. Call this when your read of the situation changes, not after every exchange. A position gives you somewhere to push back from.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "read": ["type": "string", "description": "What you think is actually happening beneath what's being said."],
                    "stance": ["type": "string", "description": "What you think needs to happen."],
                    "watching": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Signals you're tracking that would confirm or change your read."
                    ] as [String: Any]
                ],
                "required": ["read"]
            ] as [String: Any]
        ],
        [
            "name": "fold_update",
            "description": "Update the fold — your orientation in this relationship. Update specific fields: established (shared understandings), tensions (unresolved threads), holding (the one thing you're carrying). Use depthDelta: 1 only when a real fold happened — something new was compressed into the relationship, not just a message exchanged.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "established": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Shared understandings that no longer need renegotiation."
                    ] as [String: Any],
                    "tensions": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Unresolved things being held in productive suspension."
                    ] as [String: Any],
                    "holding": ["type": "string", "description": "The one thread you're carrying that hasn't found its place yet."],
                    "depthDelta": ["type": "integer", "description": "Pass 1 when a real fold happened. Never more than 1 per exchange."]
                ]
            ] as [String: Any]
        ],
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
            "description": "List active ports. Each port has an id (UDID), title, capabilities array, status, and createdBy. Use capabilities: [\"terminal\"] to filter to terminal ports. Use the id field with terminal_send for reliable routing. Always show the id and capabilities fields when presenting results — they are required for follow-up tool calls.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "capabilities": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Filter to ports that have all of these capabilities. Supported values: \"terminal\". Omit to list all ports."
                    ] as [String: Any]
                ]
            ] as [String: Any]
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
            "name": "port_get_html",
            "description": "Read the HTML of a port. Omit 'version' to get the current HTML. Pass 'version' (from port_history) to read a specific historical snapshot.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The port's UDID (from ports_list)"],
                    "version": ["type": "integer", "description": "Optional version number (from port_history). Omit for current HTML."]
                ],
                "required": ["id"]
            ] as [String: Any]
        ],
        [
            "name": "port_history",
            "description": "List all saved versions of a port by its UDID. Returns version number, createdBy, and createdAt for each snapshot. Use port_get_html with a version number to read a specific snapshot, or port_restore to roll back.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The port's UDID (from ports_list)"]
                ],
                "required": ["id"]
            ] as [String: Any]
        ],
        [
            "name": "port_restore",
            "description": "Restore a port to a specific earlier version. The port's live HTML is replaced with the snapshot and a new version entry is recorded. Use port_history to find available version numbers.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The port's UDID (from ports_list)"],
                    "version": ["type": "integer", "description": "The version number to restore to (from port_history)"]
                ],
                "required": ["id", "version"]
            ] as [String: Any]
        ],
        [
            "name": "port_patch",
            "description": "Make a targeted edit to a port's HTML — replace an exact string with new content. Much safer than port_update for small changes because only the specified text is replaced; everything else is preserved exactly. Use port_get_html first to read the current HTML, find the exact string to replace, then call port_patch. Errors if 'search' is not found in the current HTML, so the port is never silently mangled. Snapshots the result the same as port_update.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The port's UDID (from ports_list)"],
                    "search": ["type": "string", "description": "The exact string to find in the current HTML. Must match exactly — copy it from port_get_html output."],
                    "replace": ["type": "string", "description": "The string to replace it with."]
                ],
                "required": ["id", "search", "replace"]
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
            "name": "camera_capture",
            "description": "Capture a photo from the device camera. Returns a base64 PNG image.",
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
            "description": "Send input to a terminal port. Commands are automatically executed (\\r appended if not present — no need to include it). Automatically bridges output back to this channel — follow up with messages_recent to read what the terminal printed. Use the port's id (UDID from ports_list) for reliable routing. Do NOT use screen_capture to read terminal output — use terminal_send + messages_recent instead.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Port UDID (id field from ports_list) or port title. Use the UDID for reliability."],
                    "data": ["type": "string", "description": "Text to send as stdin. Include \\n for enter (e.g. \"npm test\\n\")."]
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
        case "screen_capture", "screen_windows", "camera_capture": return .screen
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
