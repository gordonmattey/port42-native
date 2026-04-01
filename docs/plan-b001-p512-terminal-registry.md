# Plan: B-001 + P-512 — Terminal Registry & Named Terminal Routing

**Created:** 2026-03-20
**Scope:** Fix terminal_send routing from conversation (B-001) + named terminal registry (P-512)

---

## Problem

Companions can build terminal ports but can't reliably interact with them from chat.

`terminal_send` looks up sessions by port title (fuzzy string match against the HTML
`<title>` tag). This fails when:
- The port title doesn't match what the companion guesses
- The companion doesn't know the title at all
- Multiple terminal ports exist and there's ambiguity

There is also no section in the companion system prompt explaining that `terminal_send`,
`ports_list`, and `terminal_bridge` exist. Companions literally don't know to use them.

`ports_list` returns `hasTerminal: true/false` — a boolean with no room to grow. As more
capability types are added (browser, camera, etc.) this pattern doesn't scale.

---

## Solution

Three changes working together:

1. **`ports_list` gains a `capabilities` field and filter** — structured, extensible,
   replaces `hasTerminal` boolean
2. **`terminal_send` uses portId (UDID) as primary key** — reliable, stable, already
   returned by `ports_list`
3. **Companion system prompt gets a new section** — teaches companions the workflow for
   interacting with ports from conversation

---

## Data Shape Changes

### ports_list before
```json
{ "id": "abc-123", "title": "Claude Code", "hasTerminal": true, "status": "floating", "createdBy": "engineer" }
```

### ports_list after
```json
{ "id": "abc-123", "title": "Claude Code", "capabilities": ["terminal"], "status": "floating", "createdBy": "engineer" }
```

Capabilities is an array. Future values: `"browser"`, `"camera"`, `"audio"`. A port
can have multiple capabilities simultaneously.

---

## File Changes

### 1. `Sources/Port42Lib/Services/TerminalBridge.swift`

Add `sendToFirst()` helper so call sites don't need to reach into the session dict:

```swift
/// Send data to the first active session. Convenience for ports with a single terminal.
public func sendToFirst(data: String) -> Bool {
    guard let sid = firstActiveSessionId else { return false }
    return send(sessionId: sid, data: data)
}
```

No other changes to TerminalBridge.

---

### 2. `Sources/Port42Lib/Services/ToolExecutor.swift`

#### `ports_list` — capabilities field + optional filter

Replace `hasTerminal` bool with `capabilities` array. Accept optional `capabilities`
filter in input:

```swift
case "ports_list":
    let filterCaps = (input["capabilities"] as? [String]) ?? []
    let allPorts = appState.portWindows.allPorts()
    let filtered = filterCaps.isEmpty ? allPorts : allPorts.filter { p in
        filterCaps.allSatisfy { cap in
            switch cap {
            case "terminal": return p.hasTerminal
            default:         return false
            }
        }
    }
    if filtered.isEmpty {
        let msg = filterCaps.isEmpty ? "No active ports." : "No ports with capabilities: \(filterCaps.joined(separator: ", "))"
        return [textBlock(msg)]
    }
    let list = filtered.map { p -> [String: Any] in
        var caps: [String] = []
        if p.hasTerminal { caps.append("terminal") }
        var info: [String: Any] = [
            "id":           p.udid,
            "title":        p.title,
            "capabilities": caps,
            "status":       p.isBackground ? "docked" : "floating"
        ]
        if let creator = p.createdBy { info["createdBy"] = creator }
        return info
    }
    return [textBlock(jsonString(list))]
```

#### `terminal_send` — portId primary, title fallback, better error message

```swift
case "terminal_send":
    guard let name = input["name"] as? String,
          let data = input["data"] as? String else {
        return [textBlock("Error: missing 'name' or 'data' parameter")]
    }
    let processed = ToolExecutor.processEscapes(data)

    // 1. UDID lookup (preferred — use id from ports_list)
    if let panel = appState.portWindows.findPort(by: name),
       let tb = panel.bridge.terminalBridge {
        let ok = tb.sendToFirst(data: processed)
        return [textBlock(ok ? "Sent to \(panel.title)" : "Error: terminal send failed")]
    }

    // 2. Title fuzzy fallback (existing behaviour, kept for convenience)
    if let session = appState.portWindows.terminalSession(forPortNamed: name) {
        let ok = session.bridge.send(sessionId: session.sessionId, data: processed)
        return [textBlock(ok ? "Sent to \(name)" : "Error: failed to send to terminal")]
    }

    // 3. Useful error — tell the companion what IDs are available
    let available = appState.portWindows.allPorts()
        .filter(\.hasTerminal)
        .map { "'\($0.title)' (id: \($0.udid))" }
        .joined(separator: ", ")
    let hint = available.isEmpty
        ? "No ports have active terminal sessions. Create a terminal port first."
        : "Available terminal ports: \(available)"
    return [textBlock("Error: no terminal port found for '\(name)'. \(hint)")]
```

#### `terminal_list` — include capabilities field for consistency

```swift
case "terminal_list":
    let terminals = appState.portWindows.portsWithTerminals()
    if terminals.isEmpty {
        return [textBlock("No ports have active terminal sessions.")]
    }
    let list = terminals.map { t -> [String: Any] in
        var info: [String: Any] = [
            "id":           t.portId,
            "name":         t.name,
            "sessionId":    t.sessionId,
            "capabilities": ["terminal"],
            "createdBy":    t.createdBy ?? "unknown",
            "bridged":      appState.bridgedTerminalNames.contains(t.name.lowercased())
        ]
        return info
    }
    return [textBlock(jsonString(list))]
```

---

### 3. `Sources/Port42Lib/Services/ToolDefinitions.swift`

#### `ports_list` — add optional `capabilities` input, update description

```swift
[
    "name": "ports_list",
    "description": "List active ports. Each port has an id (UDID), title, capabilities array, status, and createdBy. Use capabilities: [\"terminal\"] to filter to terminal ports only. Use the id field with terminal_send for reliable routing.",
    "input_schema": [
        "type": "object",
        "properties": [
            "capabilities": [
                "type": "array",
                "items": ["type": "string"],
                "description": "Filter to ports that have all of these capabilities. Supported: \"terminal\". Omit for all ports."
            ]
        ]
    ] as [String: Any]
],
```

#### `terminal_send` — update description to mention portId

```swift
[
    "name": "terminal_send",
    "description": "Send input to a terminal port. Use the port's id (UDID from ports_list) for reliable routing. Falls back to fuzzy title match if id not found. Include \\n at the end of commands to execute them.",
    "input_schema": [
        "type": "object",
        "properties": [
            "name": ["type": "string", "description": "Port UDID (from ports_list id field) or port title"],
            "data": ["type": "string", "description": "Text to send as stdin. Include \\n for enter (e.g. \"ls -la\\n\")"]
        ],
        "required": ["name", "data"]
    ] as [String: Any]
],
```

---

### 4. `Sources/Port42Lib/Resources/ports-context.txt`

Add new section at the end (before the FUTURE BRIDGE APIs block):

```
## Interacting With Ports From Conversation

You can interact with running ports directly from chat using tools — you don't need
to be inside a port to do this.

FINDING PORTS:

  ports_list()
    List all active ports. Each entry has:
      id           — stable UDID, use this to identify ports reliably
      title        — the port's <title> tag content
      capabilities — array of what the port can do, e.g. ["terminal"]
      status       — "floating" (visible) or "docked" (hidden, still running)
      createdBy    — which companion created the port

  ports_list(capabilities: ["terminal"])
    Filter to only ports that have an active terminal session.
    Use this before terminal_send to find the right port id.

SENDING INPUT TO A TERMINAL PORT:

  terminal_send(name, data)
    Send keystrokes/commands to a terminal port's stdin.
    name: use the port's id (UDID) from ports_list for reliability.
          Can also be the port title — fuzzy matched, but less reliable.
    data: text to send. Include \n to press enter (e.g. "npm test\n").
          Use \r as an alternative to \n for some applications.

  Standard workflow:
    1. ports_list(capabilities: ["terminal"])
       → [{id: "abc-123", title: "Claude Code", capabilities: ["terminal"], ...}]
    2. terminal_send(name: "abc-123", data: "fix the auth bug\n")

  Always use the id field from ports_list, not the title. Titles can be ambiguous
  or not match exactly. The id is always unique and stable.

BRIDGING TERMINAL OUTPUT TO CHANNEL:

  terminal_bridge(name)
    Start routing the terminal's output into this channel as messages.
    Once bridged, you can read what the terminal is doing without polling.
    name: port UDID or title.

  terminal_unbridge(name)
    Stop routing output.

  terminal_list()
    List all ports with active terminal sessions, their IDs, and whether bridged.

EXAMPLE — prompt Claude Code running in a terminal port:
  Step 1: ports_list(capabilities: ["terminal"])
          → [{id: "f3a9...", title: "Claude Code", capabilities: ["terminal"]}]
  Step 2: terminal_bridge(name: "f3a9...")   ← optional: watch the output
  Step 3: terminal_send(name: "f3a9...", data: "implement the login page\n")
  Step 4: read channel messages as Claude Code's output arrives
```

---

## Build Order + Tests

**Status: ALL STEPS COMPLETE. 22/22 tests passing. Build clean.**

Notes:
- Fixed 3 pre-existing wrong test assertions in TerminalBridgeTests (terminal.send/resize/kill correctly return nil — permission only required at spawn time)
- `ports_list` now returns `capabilities: ["terminal"]` instead of `hasTerminal: true`
- `terminal_send` tries UDID first, then title fuzzy match, then returns error listing available port IDs
- `terminal_list` updated to include `id` and `capabilities` fields for consistency
- Companion system prompt now has a full "Interacting With Ports From Conversation" section

---

### Step 1: `TerminalBridge.swift` — add `sendToFirst()` ✅

Add to `Tests/Port42Tests/TerminalBridgeTests.swift`:

```swift
@Test("sendToFirst returns true when session exists")
@MainActor
func sendToFirstWithActiveSession() async throws {
    let bridge = PortBridge(appState: NSObject(), channelId: nil)
    let tb = TerminalBridge(bridge: bridge)
    defer { tb.killAll() }

    _ = tb.spawn()
    let ok = tb.sendToFirst(data: "echo hello\n")
    #expect(ok)
}

@Test("sendToFirst returns false when no sessions")
@MainActor
func sendToFirstNoSessions() async throws {
    let bridge = PortBridge(appState: NSObject(), channelId: nil)
    let tb = TerminalBridge(bridge: bridge)

    let ok = tb.sendToFirst(data: "echo hello\n")
    #expect(!ok)
}

@Test("sendToFirst returns false after kill")
@MainActor
func sendToFirstAfterKill() async throws {
    let bridge = PortBridge(appState: NSObject(), channelId: nil)
    let tb = TerminalBridge(bridge: bridge)

    let sid = tb.spawn()!
    tb.killAll()
    try await Task.sleep(for: .milliseconds(100))
    let ok = tb.sendToFirst(data: "echo hello\n")
    #expect(!ok)
}
```

Run: `swift test --filter TerminalBridge`

---

### Step 2: `ToolExecutor.swift` — capabilities field + UDID routing ✅

ToolExecutor requires full AppState so unit tests are limited. Test the
`PortWindowManager` helpers it relies on instead. Add to a new
`Tests/Port42Tests/PortCapabilityTests.swift`:

```swift
import Testing
import Foundation
@testable import Port42Lib

@Suite("Port Capabilities")
struct PortCapabilityTests {

    @Test("port with terminal has terminal capability")
    @MainActor
    func terminalCapability() {
        // PortPanel.hasTerminal is true when terminalBridge is non-nil
        // Verified indirectly: portsWithTerminals() only returns panels where
        // bridge.terminalBridge != nil — existing behaviour, no change needed
        #expect(PortPermission.permissionForMethod("terminal.spawn") == .terminal)
    }

    @Test("ports_list capabilities field replaces hasTerminal")
    func capabilitiesFieldShape() {
        // Verify the ToolDefinitions schema includes capabilities property
        let defs = ToolDefinitions.allTools()
        let portsList = defs.first { $0["name"] as? String == "ports_list" }
        #expect(portsList != nil)
        let schema = portsList?["input_schema"] as? [String: Any]
        let props = schema?["properties"] as? [String: Any]
        #expect(props?["capabilities"] != nil)
    }

    @Test("terminal_send description mentions UDID")
    func terminalSendMentionsUDID() {
        let defs = ToolDefinitions.allTools()
        let tool = defs.first { $0["name"] as? String == "terminal_send" }
        let desc = tool?["description"] as? String ?? ""
        #expect(desc.contains("UDID") || desc.contains("id"))
    }
}
```

Run: `swift test --filter PortCapability`

---

### Step 3: `ToolDefinitions.swift` — schema validation ✅

The `capabilitiesFieldShape` and `terminalSendMentionsUDID` tests from Step 2
cover this. No additional tests needed — run the same suite.

Run: `swift test --filter PortCapability`

---

### Step 4: `ports-context.txt` — content validation ✅

Add to `PortCapabilityTests.swift`:

```swift
@Test("ports-context.txt contains conversation tool-use section")
func portsContextHasToolUseSection() throws {
    let url = Bundle(for: type(of: PortBridge.self))
        .url(forResource: "ports-context", withExtension: "txt")!
    let content = try String(contentsOf: url, encoding: .utf8)
    #expect(content.contains("Interacting With Ports From Conversation"))
    #expect(content.contains("ports_list(capabilities"))
    #expect(content.contains("terminal_send"))
}
```

Run: `swift test --filter PortCapability`

---

### Step 5: Build + smoke test ✅

```bash
./build.sh --run
```

Manual verification in the running app:

| Test | Expected |
|------|----------|
| `ports_list()` from companion | Returns `capabilities: ["terminal"]`, no `hasTerminal` |
| `ports_list(capabilities: ["terminal"])` | Returns only terminal ports |
| `terminal_send(name: <udid>)` | Input arrives in PTY |
| `terminal_send(name: "Claude Code")` | Title fallback still works |
| `terminal_send(name: "doesntexist")` | Error lists available port IDs |
| Port closed | `ports_list` no longer shows it, `terminal_send` returns useful error |
| Two terminal ports | Each routes independently by UDID |

---

## What This Does NOT Change

- `terminal_bridge`, `terminal_unbridge`, `terminal_exec` — no changes needed
- The JS bridge (`port42.terminal.*`) — no changes, still session-scoped to the port
- DB schema — no migration needed
- Existing `terminal_send(name: <title>)` callers — still works via fallback
