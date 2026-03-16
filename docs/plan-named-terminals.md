# Implementation Plan: Named Terminals & Terminal Output Bridge

**Features:** P-512 (Named Terminals), P-513 (Terminal Output Bridge), F-412, F-413

**Last updated:** 2026-03-15

---

## Current State

Terminal sessions are per-port. Each PortBridge has its own TerminalBridge instance with its own `sessions` dict. A session spawned in one port cannot be accessed from another port or from tool use. ToolExecutor only supports one-off `terminal_exec` (Process, not PTY).

## Goal

Any terminal session can be named. Any companion, port, or tool use call can send input to a named terminal. Terminal output can be bridged to a channel so companions see what's happening.

---

## Step 1: Shared Terminal Registry

**Move terminal session management to AppState level.**

### New file: `TerminalRegistry.swift`

```swift
@MainActor
public final class TerminalRegistry: ObservableObject {
    /// All active terminal sessions, keyed by session ID.
    private var sessions: [String: TerminalBridge.Session] = []

    /// Named sessions: name → sessionId mapping.
    private var namedSessions: [String: String] = [:]

    /// Output observers: sessionId → [callback]
    private var outputObservers: [String: [(String, String) -> Void]] = []

    /// Channel bridge: sessionId → channelId (where output is posted)
    private var bridgedChannels: [String: String] = [:]

    func spawn(name: String?, shell: String, cwd: String?,
               cols: UInt16, rows: UInt16, env: [String: String]?) -> String?
    func send(sessionId: String, data: String) -> Bool
    func sendByName(name: String, data: String) -> Bool
    func resize(sessionId: String, cols: UInt16, rows: UInt16) -> Bool
    func kill(sessionId: String) -> Bool
    func list() -> [SessionInfo]
    func get(name: String) -> SessionInfo?

    // Output bridging
    func bridge(sessionId: String, channelId: String, filter: FilterMode)
    func unbridge(sessionId: String)
    func addOutputObserver(sessionId: String, callback: @escaping (String, String) -> Void)
}
```

### What changes

- `TerminalBridge` stays as-is but sessions are also registered in the shared registry
- `AppState` gets a `terminalRegistry: TerminalRegistry` property
- PortBridge's terminal methods delegate to the registry for named sessions
- ToolExecutor gets access to the registry for `terminal_send`, `terminal_list`, etc.

### Files to modify

| File | Change |
|------|--------|
| `TerminalRegistry.swift` | **New** — shared session registry |
| `TerminalBridge.swift` | Add `name` parameter to `spawn()`, register with registry |
| `AppState.swift` | Add `terminalRegistry` property |
| `PortBridge.swift` | `terminal.spawn` passes name to registry, other methods use registry |

---

## Step 2: Tool Use for Terminal Sessions

**Add interactive terminal tools alongside the existing `terminal_exec`.**

### New tool definitions

```swift
// In ToolDefinitions.swift
"terminal_spawn"  — spawn a named interactive terminal session
"terminal_send"   — send data to a named session
"terminal_list"   — list all active sessions
"terminal_get"    — get session info by name
"terminal_kill"   — kill a session by name
```

### ToolExecutor changes

- `terminal_spawn`: calls `terminalRegistry.spawn(name: ..., ...)`, returns sessionId
- `terminal_send`: calls `terminalRegistry.sendByName(name, data)`
- `terminal_list`: calls `terminalRegistry.list()`
- `terminal_get`: calls `terminalRegistry.get(name)`
- `terminal_kill`: calls `terminalRegistry.kill(sessionId)`
- Keep existing `terminal_exec` for one-off commands (simpler, no session management)

### Files to modify

| File | Change |
|------|--------|
| `ToolDefinitions.swift` | Add 5 new tool definitions |
| `ToolExecutor.swift` | Add implementations for new tools, access registry via appState |

---

## Step 3: Terminal Output Bridge

**Parse terminal output and post meaningful content to a channel.**

### New file: `TerminalOutputParser.swift`

```swift
public final class TerminalOutputParser {
    enum FilterMode { case all, smart, none }

    /// Strip ANSI escape sequences from raw terminal output.
    static func stripANSI(_ text: String) -> String

    /// Extract meaningful signals from stripped text.
    /// Returns lines that should be posted to the channel.
    static func extractSignals(_ text: String, mode: FilterMode) -> [String]
}
```

**ANSI stripping:** TerminalBridge already has `stripANSI()` (lines 99-111). Reuse or move to the parser.

**Smart filter logic:**
- Debounce: batch output over 500ms windows, don't post every character
- Skip empty/whitespace-only lines
- Skip repeated identical lines (progress bar updates)
- Skip lines that are only cursor movement sequences (after ANSI strip they're empty)
- Collapse rapid sequences of short lines into one message
- Detect prompts (lines ending with `$`, `>`, `%`) and skip them (noise)

**Channel posting:**
- When a session is bridged to a channel, the registry observes its output
- Parsed output is posted as a system message: `[terminal:session-name] output text`
- Messages are batched (don't flood the channel with per-character updates)

### Files to modify

| File | Change |
|------|--------|
| `TerminalOutputParser.swift` | **New** — ANSI strip + signal extraction |
| `TerminalRegistry.swift` | Wire bridge() to parser, post to channel via AppState |
| `AppState.swift` | Add method to post terminal bridge messages to channel |
| `DatabaseService.swift` | No changes (uses existing message save) |

---

## Step 4: Wire Port Terminal to Registry

**Existing port terminals register with the shared registry.**

When a port calls `terminal.spawn({ name: "claude-code" })`:
1. PortBridge calls TerminalBridge.spawn() as before (PTY creation)
2. TerminalBridge also registers the session in the shared TerminalRegistry
3. Other ports or tool use can now find it by name
4. Output events still push to the originating port's webview (for xterm.js rendering)
5. If bridged, output ALSO routes to the channel

When a port closes:
- Sessions it spawned keep running in the registry (they already outlive ports via weak ref)
- Named sessions persist until explicitly killed
- Unnamed sessions could be cleaned up on port close (existing behavior)

### Files to modify

| File | Change |
|------|--------|
| `PortBridge.swift` | Pass name to spawn, register with registry |
| `TerminalBridge.swift` | Accept registry reference, register on spawn |

---

## Build Order

```
Step 1: TerminalRegistry (shared session store)
Step 2: Tool definitions + ToolExecutor (terminal_spawn/send/list/get/kill)
Step 3: TerminalOutputParser (ANSI strip + smart filter)
Step 4: Wire bridge (output → channel posting)
Step 5: Wire ports (port terminal.spawn registers with registry)
```

Steps 1-2 are the minimum for named terminals (F-412).
Steps 3-4 add the output bridge (F-413).
Step 5 connects existing port terminals to the new system.

## Verification

1. In a swim, ask companion: "spawn a terminal named 'dev' and run ls"
2. In a channel, ask another companion: "send 'pwd' to the dev terminal"
3. Verify the command executes and output is visible
4. Bridge a terminal to a channel, run a build script, see output appear as messages
5. Open a port with a terminal, name it, then interact with it from chat
6. Kill a named terminal from chat
