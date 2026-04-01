# Plan: CLI Terminal Output Capture

Route terminal output from CLI companions (Claude Code, Gemini CLI) back into the channel/Swim as companion messages.

## Problem

When a CLI companion (e.g. `claude --continue`) is running in a terminal port and the user sends a message, the input is routed correctly to the terminal via `routeMentionsToTerminals`. The CLI responds — visible in the terminal — but the response never appears in the channel or Swim because no output capture is wired up.

The existing `OutputBatcher` does similar work but feeds into `TerminalAgentLoop` → LLM companion, which is the OpenClaw/bridge pattern — not what we want here. CLI terminal companions ARE the agent; their output should post directly as companion messages.

## Architecture

All companion types converge on the same final act: `db.saveMessage` + `sync.sendMessage`. The new CLI terminal path is one more route to that same destination:

```
LLM companion     → ChannelAgentHandler    → saveMessage + syncMessage
Command companion → CommandAgentHandler    → saveMessage + syncMessage
Remote companion  → SyncService            → saveMessage + syncMessage
CLI terminal      → TerminalOutputProcessor → saveMessage + syncMessage  ← new
Bridge (OpenClaw) → OutputBatcher → TerminalAgentLoop → LLM → saveMessage + syncMessage
```

The bridge/OpenClaw path stays intact. CLI terminal gets a direct path using shared processing primitives.

## Steps

### Step 1 — Extract `TerminalOutputProcessor` into its own file

**File:** `Sources/Port42Lib/Services/TerminalOutputProcessor.swift`

Move out of `OutputBatcher` in `ToolExecutor.swift`:
- `buffer: String` accumulation
- 10s debounce timer
- Force flush at 8KB
- `lastPosted` dedup
- `stripANSI(_:)` static method
- `collapseAndFilter(_:)` static method
- `flush()` logic

Constructor takes a single callback:
```swift
init(onFlush: @escaping @MainActor (String) -> Void)
```

No AppState dependency. No channel knowledge. Pure pipeline: raw bytes in → cleaned string out via callback.

**Testing scope** (`Tests/Port42Tests/TerminalOutputProcessorTests.swift`):
- `stripANSI`: SGR codes, cursor movement, OSC title, bare CR, plain passthrough, private-mode sequences
- `collapseAndFilter`: CR overwrite collapse, spinner/noise filtering, token counter drop, signal line preservation (`error:`, `⏺`, `$`), build phase collapse (Compiling/Linking), deduplication, 60-line cap (trailing lines kept)
- `TerminalOutputProcessor` pipeline: empty flush fires no callback, explicit flush delivers cleaned content, 8KB force-flush fires, cross-flush dedup (same content → one call), different content → two calls, 2000-char truncation with suffix
- ✅ **Done** — 29 tests, all passing

### Step 2 — Slim `OutputBatcher` to a thin wrapper

`OutputBatcher` keeps its existing public API (`portName`, `channelId`, `companionName`, `appState`, `receive(_:)`) but delegates all processing to an internal `TerminalOutputProcessor`. Its `onFlush` closure does what the current `flush()` does:
1. Call `appState.noteBridgeActivity(...)`
2. Call `appState.terminalLoop(for: channelId)?.receiveOutput(content)`

No observable behaviour change to the existing bridge path.

**Testing scope:**
- No new tests needed — `TerminalOutputProcessor` is already covered by Step 1.
- Regression: open a channel with an OpenClaw/bridge companion, send a message, confirm terminal output still flows back as companion messages. The existing bridge path must be unchanged.
- ✅ **Done** — `OutputBatcher` now delegates to `TerminalOutputProcessor`; bridge/OpenClaw path identical

### Step 3 — Add processor storage to AppState

```swift
// AppState.swift
private var terminalOutputProcessors: [String: TerminalOutputProcessor] = [:]
```

Keyed by `panelId`. Keeps processors alive — without a strong reference they'd be deallocated after setup.

**Testing scope:**
- Unit test: after `bridgeTerminalPort` is called for an `openInTerminal` companion, `terminalOutputProcessors[panelId]` is non-nil.
- Unit test: after `deleteCompanion`, the entry is removed (Step 5 verifies the other direction).
- These are AppState integration tests; use `DatabaseService(inMemory: true)`.

### Step 4 — Wire up capture in `bridgeTerminalPort`

`bridgeTerminalPort` is called from JS (`port42.terminal.bridge(sessionId, channelId, name)`) after both `terminal.spawn` and the 600ms delay. The terminal session is guaranteed to exist at this point. This is the right place to hook in.

After updating `bridgedTerminalNames`, check if any companion with that `displayName` has `openInTerminal == true`. If so:

1. Create a `TerminalOutputProcessor` whose `onFlush` closure:
   - Constructs a `Message` with `senderType: "agent"`, `senderId: companion.id`, `senderName: companion.displayName`, `content: cleaned`
   - Calls `db.saveMessage(msg)` + `sync.sendMessage(msg)`
2. Register it as an output observer: `tb.session(for: sessionId)?.addOutputObserver { processor.receive($0) }`
3. Store in `terminalOutputProcessors[panelId]`

**Testing scope:**
- Integration: spawn a CLI terminal companion (Claude Code preset), send a message in the Swim, confirm a companion message appears in the channel with `senderType == "agent"` and `senderId == companion.id`.
- Unit test: `bridgeTerminalPort` called with an `openInTerminal` companion → `terminalOutputProcessors[panelId] != nil` and `addOutputObserver` was registered (verify via output flowing to a mock processor).
- Negative: `bridgeTerminalPort` called for a non-`openInTerminal` companion → no processor created, `terminalOutputProcessors` unchanged.

### Step 5 — Clean up on companion delete

In `deleteCompanion`, after closing panels, remove their processor entries:

```swift
for panel in panelsToClose {
    terminalOutputProcessors.removeValue(forKey: panel.id)
    portWindows.close(panel.id)
}
```

**Testing scope:**
- Unit test: create a CLI terminal companion, bridge it (processor stored), delete the companion → `terminalOutputProcessors` is empty.
- Verify no memory leak: processor is deallocated after removal (weak reference in the `addOutputObserver` closure holds nothing alive once the dict entry is gone).
- Regression: deleting a non-terminal companion → unrelated processors unaffected.

## Data Flow (end-to-end)

```
User sends "hi" in Swim
  → routeMentionsToTerminals (implicit swim companion)
    → tb.sendToFirst("[gordon]: hi\r")
      → pty → Claude Code reads it, responds
        → terminal output fires addOutputObserver callback
          → TerminalOutputProcessor.receive(raw)
            → debounce 10s / force flush at 8KB
              → stripANSI + collapseAndFilter
                → onFlush(cleaned)
                  → db.saveMessage + sync.sendMessage
                    → message appears in Swim ✓
```

## Post-Plan Bugs to Fix

- **OpenClaw agent not appearing as companion**: When an OpenClaw agent connects to a channel via the plugin, it appears in the member list but not as a companion entry in the sidebar. Needs investigation after Step 5 is complete.
- **OpenClaw agent not responding to messages (trigger="mention")**: Root cause identified — `port42-openclaw@0.4.8` has a bug in `connection.js`: `new RegExp("@" + name + "\b")` uses `"\b"` (backspace char) instead of `"\\b"` (word boundary), so the mention regex never matches. Workaround: use trigger="all" when connecting agents. Fix is in the plugin (their bug, not ours) — check for a newer version.

## Out of Scope (this plan)

- **Stuck typing indicator**: `CommandAgentHandler` is still invoked for `openInTerminal` companions, sets a typing indicator that never clears. Fix separately — skip `.command` dispatch when `agent.openInTerminal == true`.
- **Broader terminal output architecture refactor**: `OutputBatcher`, `TerminalAgentLoop`, `routeTerminalOutput` could all be unified. Deferred.
- **`@` prefix bug for channel @mentions**: Already fixed in `routeMentionsToTerminals` (`.dropFirst()` added).

