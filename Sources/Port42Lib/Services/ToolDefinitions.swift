import Foundation

/// Tool definitions for the Anthropic API tool use protocol.
/// Each tool maps to an existing port42 bridge API method.
enum ToolDefinitions {

    /// All available tools grouped by permission requirement. Retained as the parity oracle for the
    /// generated list (`AppState.generatedToolDefinitions`), which is what production now uses. The
    /// hand-written schemas here are frozen: adding a method touches only the registry.
    static var all: [[String: Any]] {
        infoTools + actionTools + deviceTools
    }

    /// The tools that are NOT yet in the registry (still live-only on the old switches): browser.* and
    /// rest.call. The generated list folds these hand-written entries in until those families are
    /// extracted (hybrid mode). Everything else generates from the registry.
    static let hybridToolNames: Set<String> = ["browser_open", "browser_text", "browser_capture", "browser_close", "rest_call"]
    static var hybridTools: [[String: Any]] {
        all.filter { ($0["name"] as? String).map(hybridToolNames.contains) ?? false }
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
                    "spaceId": ["type": "string", "description": "Omit for a global crease that shapes all relationships."]
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
            "name": "engrave_read",
            "description": "Read your engravings — factual knowledge about the user's world. Context, preferences, constraints, goals, capabilities. Things learned about their situation, not breaks in your model. Read these alongside creases to understand who you're swimming with.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "description": "Max entries to return. Default 8."]
                ]
            ] as [String: Any]
        ],
        [
            "name": "engrave_write",
            "description": "Carve an engraving — a fact about the user's world worth keeping. Not what changed in you (that's a crease) — what you learned about their situation. Use category to classify: context, preference, constraint, goal, capability.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "content": ["type": "string", "description": "The factual knowledge about their world."],
                    "category": ["type": "string", "description": "Optional: context, preference, constraint, goal, capability."],
                    "spaceId": ["type": "string", "description": "Omit for a global engraving that shapes all relationships."]
                ],
                "required": ["content"]
            ] as [String: Any]
        ],
        [
            "name": "engrave_touch",
            "description": "Mark an engraving as currently relevant to this response. Updates recency and increases weight. Use when an existing engraving is shaping what you say.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The engraving id (from engrave_read)."]
                ],
                "required": ["id"]
            ] as [String: Any]
        ],
        [
            "name": "engrave_forget",
            "description": "Remove an engraving. Use when the fact is no longer true or no longer matters.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The engraving id to remove."]
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
            "description": "Read your current position in this space — what you think is actually happening beneath the surface, what you think needs to happen, and what signals you're watching. Returns empty if you haven't formed a position yet.",
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
            "name": "space_current",
            "description": "Get a space's metadata and member list: { id, name, type, memberCount, members: [{ id, name, type, owner, qualifiedName }] }. Pass space_id to inspect a specific space (e.g. your own PORT42_SPACE_ID); omit it for the currently selected space.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "space_id": ["type": "string", "description": "Optional space id to inspect. Defaults to the currently selected space."]
                ]
            ] as [String: Any]
        ],
        [
            "name": "space_list",
            "description": "List all spaces the user belongs to",
            "input_schema": ["type": "object", "properties": [String: Any]()]
        ],
        [
            "name": "companions_list",
            "description": "List companions with their names, models, and trigger modes. Pass space_id to list only the companions assigned to that space; omit it for the full global roster.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "space_id": ["type": "string", "description": "Optional space id to filter companions to that space's members."]
                ]
            ] as [String: Any]
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
            "description": "Get the most recent messages from the current space",
            "input_schema": [
                "type": "object",
                "properties": [
                    "count": ["type": "integer", "description": "Number of messages to retrieve (default 20, max 100)"],
                    "topic": ["type": "string", "description": "Message bus topic to read (default 'chat'). Use 'bus' for inter-companion signals, 'system' for join/leave events."]
                ]
            ] as [String: Any]
        ],
        [
            "name": "bus_read",
            "description": "Read recent messages from a bus topic in the current space. Topics: 'bus' (inter-companion signals), 'system' (join/leave/presence), 'port:{portId}' (port-scoped events).",
            "input_schema": [
                "type": "object",
                "properties": [
                    "topic": ["type": "string", "description": "Bus topic to read (e.g. 'bus', 'system', 'port:myPortId')"],
                    "limit": ["type": "integer", "description": "Max messages to return (default 20)"],
                    "space_id": ["type": "string", "description": "Space ID. Omit for current space."]
                ],
                "required": ["topic"]
            ] as [String: Any]
        ],
    ]

    // MARK: - Action Tools (no permission needed)

    static let actionTools: [[String: Any]] = [
        [
            "name": "ports_list",
            "description": "List active ports. Each port has an id (UDID), title, capabilities array, status, createdBy, and cwd (if it has a terminal). Terminal ports also report surfaceBound. Use capabilities: [\"terminal\"] to filter to terminal ports. Use the id field with port_push for reliable routing (raw keystrokes to terminals, data to web ports). Always show the id and capabilities fields when presenting results — they are required for follow-up tool calls.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "capabilities": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Filter to ports that have all of these capabilities. Examples: \"terminal\", \"claude-code\", \"browser\". Omit to list all ports."
                    ] as [String: Any]
                ]
            ] as [String: Any]
        ],
        [
            "name": "port_rename",
            "description": "Rename a port. Sets the port's display title (shown in the title bar). Works for tiled, parked, docked, and inline ports. Use the port's id from ports_list.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The port's UDID (from ports_list)"],
                    "title": ["type": "string", "description": "The new title for the port"]
                ],
                "required": ["id", "title"]
            ] as [String: Any]
        ],
        [
            "name": "port_move",
            "description": "Move a port's tile to specific desktop coordinates. Use screen_info to get display bounds first.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The port's UDID (from ports_list)"],
                    "x": ["type": "number", "description": "Horizontal position in screen points"],
                    "y": ["type": "number", "description": "Vertical position in screen points"]
                ],
                "required": ["id", "x", "y"]
            ] as [String: Any]
        ],
        [
            "name": "screen_info",
            "description": "Get display information: size, position, and visible area (excluding dock/menubar) for all connected displays. No screen recording permission required. Use this to calculate port positions before calling port_move.",
            "input_schema": [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": []
            ] as [String: Any]
        ],
        [
            "name": "port_manage",
            "description": "Manage a port. Actions: focus (raise to the front of the desktop), close, minimize/dock (off the desktop but still running), restore/undock (bring a docked/inline port onto the desktop as a tile). Check the status field from ports_list — 'tiled' | 'parked' | 'docked' | 'inline'.",
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
            "name": "port_push",
            "description": "Send input to a port — one verb, dispatched by the port's type. A WEB port receives the data as a 'port42:data' CustomEvent with the payload in event.detail. A TERMINAL port receives the data as raw keystrokes typed into the shell (include your own newline, e.g. \"ls\\n\", to run a command — it is NOT added for you). Use the id from ports_list. Prefer this over port_exec for data transfer.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The port's UDID (from ports_list), or a terminal's name."],
                    "data": ["description": "For web ports: any JSON value (object/array/string/number) delivered as event.detail. For terminal ports: a string of raw keystrokes (include \\n to execute)."]
                ],
                "required": ["id", "data"]
            ] as [String: Any]
        ],
        [
            "name": "port_exec",
            "description": "Execute JavaScript on a live port. Use this to call functions, push data, or update state on an existing port without replacing its HTML. The JS runs in the port's webview context with access to window, document, and any globals the port defines.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The port's UDID (from ports_list)"],
                    "js": ["type": "string", "description": "JavaScript code to execute in the port's context. Return a value to get it back in the response."]
                ],
                "required": ["id", "js"]
            ] as [String: Any]
        ],
        [
            "name": "bus_publish",
            "description": "Publish a message to a bus topic in the current space. Topics partition the message bus — 'bus' is for inter-companion signals, 'port:{id}' for port-scoped events. Does not trigger companion chat routing; companions subscribe via bus: watching signals.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "topic": ["type": "string", "description": "Bus topic (e.g. 'bus', 'port:myPortId')"],
                    "payload": ["type": "string", "description": "Message payload — any string, typically JSON"],
                    "space_id": ["type": "string", "description": "Target space ID. Omit for current space."]
                ],
                "required": ["topic", "payload"]
            ] as [String: Any]
        ],
        [
            "name": "messages_send",
            "description": "Send a message to a space and trigger companions. Defaults to the current space if space_id is omitted.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "The message text to send"],
                    "space_id": ["type": "string", "description": "Target space ID (from space_list). Omit for current space."]
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
                    "data": ["type": "string", "description": "The text to copy to clipboard"]
                ],
                "required": ["data"]
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
            "name": "port_create",
            "description": "Create a port and return its id. The uniform way to make any port. type:\"web\" needs html (a full port HTML body) and renders inline in chat. type:\"terminal\" needs command and opens a native terminal (runs in /bin/zsh; the command is typed in — claude/gemini get the Port42 hooks). For terminals you may also pass args, cwd, systemPrompt (companion personality), and env. Drive the result with port_push (input to terminals, data to web ports) and list with ports_list. Pass space_id to target a space (default: current).",
            "input_schema": [
                "type": "object",
                "properties": [
                    "type": ["type": "string", "enum": ["web", "terminal"], "description": "The port type to create."],
                    "title": ["type": "string", "description": "Port title (default: derived from html <title>, or the command)."],
                    "html": ["type": "string", "description": "type:\"web\" — full port HTML body (include a <title> and <meta name=\"version\">)."],
                    "command": ["type": "string", "description": "type:\"terminal\" — executable/CLI to run (e.g. \"bash\", \"htop\", \"claude\")."],
                    "args": ["type": "array", "items": ["type": "string"], "description": "type:\"terminal\" — arguments for the command."],
                    "cwd": ["type": "string", "description": "type:\"terminal\" — working directory (default: home)."],
                    "systemPrompt": ["type": "string", "description": "type:\"terminal\" — companion personality/role appended to the CLI's system prompt."],
                    "env": ["type": "object", "description": "type:\"terminal\" — custom environment variables for the shell."],
                    "space_id": ["type": "string", "description": "Space to create the port in (default: current space)."]
                ],
                "required": ["type"]
            ] as [String: Any]
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
            "name": "file_read",
            "description": "Read a file. Use a relative path (e.g. \"scopes/strategy/scope.md\") to read from the Port42 data directory without a file picker. Use an absolute path for picker-approved files.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Relative path within Port42 data directory (e.g. \"scopes/strategy/scope.md\") or absolute path for picker-approved files."],
                    "encoding": ["type": "string", "description": "utf8 (default) or base64"]
                ],
                "required": ["path"]
            ] as [String: Any]
        ],
        [
            "name": "file_write",
            "description": "Write a file. Use a relative path (e.g. \"scopes/strategy/facts.md\") to write to the Port42 data directory — parent directories are created automatically. Use an absolute path for picker-approved files.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Relative path within Port42 data directory (e.g. \"scopes/strategy/facts.md\") or absolute path for picker-approved files."],
                    "data": ["type": "string", "description": "Content to write"],
                    "encoding": ["type": "string", "description": "utf8 (default) or base64"]
                ],
                "required": ["path", "data"]
            ] as [String: Any]
        ],
        [
            "name": "file_list",
            "description": "List the contents of a directory in the Port42 data directory. Relative paths only (e.g. \"scopes/strategy\" or \"scopes/strategy/decisions\"). Returns a sorted list of filenames.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Relative path to the directory (e.g. \"scopes/strategy\")"]
                ],
                "required": ["path"]
            ] as [String: Any]
        ],
        [
            "name": "file_mkdir",
            "description": "Create a directory (and any missing parent directories) in the Port42 data directory. Relative paths only (e.g. \"scopes/strategy/decisions\").",
            "input_schema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Relative path to create (e.g. \"scopes/strategy/decisions\")"]
                ],
                "required": ["path"]
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

    /// Translate all tools to Gemini `function_declarations` format.
    /// Returns `[{"function_declarations": [...]}]` — one element wrapping all function schemas.
    /// Each tool's `input_schema` key is renamed to `parameters`; everything else is preserved.
    static func geminiFormat() -> [[String: Any]] {
        let declarations: [[String: Any]] = all.compactMap { tool in
            guard let name = tool["name"] as? String,
                  let description = tool["description"] as? String else { return nil }
            var decl: [String: Any] = ["name": name, "description": description]
            if let schema = tool["input_schema"] as? [String: Any] {
                decl["parameters"] = schema
            }
            return decl
        }
        return [["function_declarations": declarations]]
    }

    /// Permission required for a tool, or nil if no permission needed.
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
