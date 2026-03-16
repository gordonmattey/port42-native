# Implementation Plan: Named Terminals & Terminal Output Bridge

**Features:** P-512, P-513, F-412, F-413

**Last updated:** 2026-03-15

---

## Insight

Named terminals are just named ports. A port with a terminal session already
has a title, persists across restart, and manages a PTY session. No new
registry needed. Just make existing port terminals addressable by name from
tool use and bridge their output to channels.

## Current State

- Ports have titles (from `<title>` tag), persist in SQLite, managed by PortWindowManager
- Each port's PortBridge has a TerminalBridge with `sessions` dict
- ToolExecutor has `terminal_exec` for one-off commands (Process, not PTY)
- No way to interact with a port's terminal from outside that port

## Goal

- Companions can send input to a running terminal port by name from chat
- Terminal output can be bridged to the channel so companions see what's happening

---

## Step 1: Port Lookup by Name

Add a method to PortWindowManager to find a port's terminal by title.

```swift
// PortWindowManager
func terminalBridge(forPortNamed name: String) -> TerminalBridge?
func terminalSession(forPortNamed name: String) -> (bridge: TerminalBridge, sessionId: String)?
```

Searches `panels` by title (case-insensitive), returns the port's TerminalBridge
and its first active session. Simple lookup, no new data structures.

### Files to modify

| File | Change |
|------|--------|
| `PortWindowManager.swift` | Add `terminalBridge(forPortNamed:)` and `terminalSession(forPortNamed:)` |

---

## Step 2: Tool Use for Port Terminals

Add tools that interact with port terminals by name.

### New tool definitions

```
terminal_send   — send input to a named port's terminal
terminal_list   — list all ports that have active terminal sessions
```

Keep existing `terminal_exec` for one-off commands (no session needed).

### ToolExecutor implementation

- `terminal_send(name, data)`: calls `appState.portWindows.terminalSession(forPortNamed: name)`,
  then `bridge.send(sessionId: sid, data: data)`. Returns success/error.
- `terminal_list`: iterates `appState.portWindows.panels`, finds ones with active
  terminal sessions, returns `[{name, sessionId, isRunning}]`.

### Files to modify

| File | Change |
|------|--------|
| `ToolDefinitions.swift` | Add `terminal_send` and `terminal_list` tool schemas |
| `ToolExecutor.swift` | Add implementations that look up ports by name |

---

## Step 3: Terminal Output Bridge

Parse terminal output and post meaningful content to the channel.

### Approach

Add an output observer to a port's terminal session. When bridged:
1. Raw PTY output passes through ANSI stripper (reuse existing `TerminalBridge.stripANSI`)
2. Smart filter debounces, deduplicates, skips TUI chrome
3. Meaningful output posted to channel as system message

### New tool

```
terminal_bridge(name, channelId?)  — start bridging a port's terminal output to channel
terminal_unbridge(name)            — stop bridging
```

### Implementation

- TerminalBridge.Session already has `onOutput` callback (runs on main actor)
- Add a second observer path: when bridged, output also routes through the parser
  to channel messages
- Batching: accumulate output over 500ms windows before posting
- System messages attributed as `[terminal:port-name]`

### Files to modify

| File | Change |
|------|--------|
| `TerminalBridge.swift` | Add output observer list (alongside existing onOutput callback) |
| `ToolDefinitions.swift` | Add `terminal_bridge` and `terminal_unbridge` tool schemas |
| `ToolExecutor.swift` | Add bridge/unbridge implementations |
| `AppState.swift` | Method to post terminal bridge messages to channel |

---

## Build Order

```
Step 1: Port lookup by name                    → ports are addressable
Step 2: terminal_send + terminal_list tools    → companions interact with port terminals
Step 3: Output bridge + parser                 → terminal output flows to channel
```

Step 1 is trivial (one method on PortWindowManager).
Step 2 is the core feature (companions push prompts into terminals).
Step 3 is the advanced feature (terminals broadcast to channels).

## Verification

1. Open a terminal port named "dev" (companion builds it or manually)
2. In chat: "@companion send 'ls -la' to the dev terminal"
3. Companion calls `terminal_send(name: "dev", data: "ls -la\n")`
4. Terminal port shows the command executing
5. In chat: "@companion bridge the dev terminal to this channel"
6. Run a build script in the terminal port
7. Build output appears as messages in the channel
8. Companions react to the output
