# Game Loop v2 + Console Bridge
**Status:** Specced — not started
**Date:** 2026-03-20
**Covers:** P-270 (port loop), P-272 (per-agent locks), P-271 (console bridge)

---

## Background

Port42's game loop is the heartbeat that drives terminal-output → agent routing. It currently ticks at a fixed 300ms per channel, globally pauses when any agent is responding, and has no surface in the port JS API. Three independent improvements address its scalability, correctness, and extensibility.

---

## Feature 1 — Configurable Port Tick Intervals

### Problem

The game loop ticks at a hardcoded 300ms for all channels. This made sense for terminal-to-agent latency, but ports that want to hook into the heartbeat have very different timing needs:

- A live transcription port needs 100ms responsiveness
- A stock dashboard polling an external API needs 5–30s to stay within rate limits
- A passive system monitor checking disk/CPU needs 15–60s
- An AI loop summarising terminal output needs 2–10s to let output settle before calling the API

Today ports work around this by running their own `setInterval`. This is fine but has no lifecycle integration with the port — loops outlive port close events, accumulate across sessions, have no visibility to companions or the shell, and can't be paused when the port is backgrounded.

The fix: make `port42.loop.register(callback, options)` the canonical way to run recurring logic inside a port. The bridge owns the timer; the port owns the callback.

### Proposed API

```js
// Register a recurring loop — returns an opaque handle
const handle = port42.loop.register(async () => {
    const result = await port42.ai.complete("what changed?", { maxTokens: 200 });
    updateDashboard(result.content);
}, {
    interval: 5000,       // ms between ticks. Default: 1000.
    immediate: true,      // fire once on register before first interval. Default: false.
    pauses: "background", // "background" | "never". Default: "background".
    label: "ai-summary"   // optional debug label
});

// Cancel a specific loop
port42.loop.cancel(handle);

// Cancel all loops in this port
port42.loop.cancelAll();

// Manual pause / resume (e.g. while user is interacting with the port)
port42.loop.pause(handle);
port42.loop.resume(handle);

// Inspect registered loops
const loops = port42.loop.list();
// → [{ handle, label, interval, pauses, running, lastFiredAt }]
```

### Semantics

**No-overlap guarantee.** If a callback is still executing when the next tick fires, that tick is skipped — not queued. This prevents runaway pile-ups when a callback takes longer than its interval (e.g. a slow AI call). The next tick is scheduled from the moment the previous invocation completes, not from when it was supposed to start.

**Async-first.** Callbacks may be `async`. The bridge awaits them before rescheduling. Sync callbacks are also supported — they're wrapped implicitly.

**Auto-cleanup.** All loops registered in a port are cancelled when the port closes. No dangling timers.

**Background pause.** When `pauses: "background"` (the default), the bridge automatically suspends loops when the port is docked or its window is hidden, and resumes when the port is restored. When `pauses: "never"`, loops run regardless. This is useful for background data collectors that don't render anything.

**Multiple loops per port.** A port may register any number of loops at different intervals — a 200ms animation tick and a 30s API poll can coexist in the same port.

**No agent gate.** Port loops are the port's own logic. They are not paused when a channel companion is mid-response. Agent gating applies only to terminal-output-to-agent routing (Feature 2). Ports are independent actors.

### Migration / Backwards Compatibility

No breaking change. `setInterval` continues to work inside port JS — the bridge does not intercept or replace it. Ports that want lifecycle integration opt in by switching to `port42.loop.register`. Old ports are unaffected.

The 300ms terminal game loop on the Swift side (`TerminalAgentLoop`) is separate infrastructure. It is not replaced or altered by this feature. Port loops run in JS inside the WKWebView; the terminal game loop runs in Swift on the main actor. They are parallel, independent systems.

### Implementation Notes

**Swift side (`PortBridge`):**

- Add `var loopRegistrations: [String: PortLoopRegistration] = [:]` where the key is a UUID handle string.
- `PortLoopRegistration`: `handle: String`, `interval: TimeInterval`, `pauses: PauseMode`, `label: String?`, `timer: Timer?`, `isRunning: Bool`.
- On `loop.register`: parse options, create a `Timer` on the main run loop, store registration, return handle to JS.
- On timer fire: call `webView?.evaluateJavaScript("window.__p42_loop_tick('\(handle)')")`. The JS shim resolves the registered callback, awaits it, then signals completion back via a message handler. The Swift side reschedules the timer only after receiving the completion signal (implementing the no-overlap guarantee).
- On `loop.cancel` / `loop.cancelAll`: invalidate timers, remove from registrations.
- In `PortBridge.deinit`: cancel all registrations.
- Background pause: observe port `isBackground` changes on `PortPanel`; call `pauseLoop` / `resumeLoop` on all registrations with `pauses == .background`.

**JS side (injected shim, `ports-context.js` or inline in `wrapHTML`):**

```js
window.__p42_loop_registry = {};
window.__p42_loop_tick = async function(handle) {
    const entry = window.__p42_loop_registry[handle];
    if (!entry || entry.paused) return;
    try { await entry.callback(); } catch(e) {}
    window.webkit.messageHandlers.port42.postMessage({
        type: "loop.done", handle
    });
};
```

`port42.loop.register` sends a `loop.register` message to Swift with the options (minus the callback itself), stores the callback in `__p42_loop_registry` keyed by the handle Swift returns, and returns the handle.

**Performance:** timers are scheduled on the main run loop but the JS callback runs on the WebKit thread. There is one timer per registration, not one global timer with fan-out. This keeps the per-port overhead minimal and avoids coordination overhead across ports.

---

## Feature 2 — Per-Agent Response Locks (No Global Pause)

### Problem

The current `TerminalAgentLoop.tick()` check:

```swift
let agentRunning = appState.activeAgentHandlers.values.contains { $0.channelId == channelId }
guard !agentRunning else { return }
```

This is a global channel pause — if *any* companion in the channel is generating, the game loop stops routing terminal output entirely. In a channel with companions A, B, and C:

- Terminal fires output
- Companion A starts generating
- Companions B and C are blocked from seeing subsequent output until A finishes
- If A is a slow thinker (long chain-of-thought, tool calls), B and C miss multiple ticks

This matters more as channels gain more companions and terminal interaction becomes a primary workflow. The loop heartbeat itself never needs to stop — only individual agent slots need to be gated.

### Proposed Behaviour

Replace the global `agentRunning` check with per-agent locking:

- Each companion has its own `agentLock: Bool` — true while that companion's `ChannelAgentHandler` is active
- `routeTerminalOutput` iterates all target companions and skips only those whose lock is held
- Companions whose lock is free process the output independently
- The game loop heartbeat continues ticking at all times regardless of agent state

```swift
// Before (global gate):
let agentRunning = appState.activeAgentHandlers.values.contains { $0.channelId == channelId }
guard !agentRunning else { return }
routeTerminalOutput(...)

// After (per-agent gate, applied inside routeTerminalOutput):
func routeTerminalOutput(channelId: String, output: String, createdBy: String?) {
    let targets = resolveTargets(channelId: channelId, createdBy: createdBy)
    let unlocked = targets.filter { !isAgentLocked($0.id, in: channelId) }
    guard !unlocked.isEmpty else { return }
    launchAgents(unlocked, ...)
}
```

### Agent Lock Tracking

`activeAgentHandlers` already tracks running handlers keyed by a composite key. The lock state is derivable: an agent is locked iff `activeAgentHandlers` contains a handler for that `(agentId, channelId)` pair that is still running.

```swift
func isAgentLocked(_ agentId: String, in channelId: String) -> Bool {
    let key = "\(agentId)-\(channelId)"
    return activeAgentHandlers[key] != nil
}
```

No new state is needed. The lock is implicit in the presence of an active handler.

### What This Changes

| Scenario | Before | After |
|----------|--------|-------|
| One companion responding, output arrives | All blocked | Only responding companion skips tick |
| Two companions, one slow | Both blocked | Fast companion continues processing |
| Solo swim with one companion | Same behaviour | Same behaviour (only one slot anyway) |
| Terminal output with no agents responding | Passes through | Passes through (no change) |

### Skipped-output policy

When a companion's slot is locked and it misses a tick, the output is not redelivered to that companion specifically. The game loop accumulates `pendingOutput` across ticks — so the next time the companion's lock is clear, it will receive a batch of everything that arrived since its last response. This is the existing behaviour and remains correct.

### Why not queue per-agent?

A per-agent queue (retry the skipped tick for locked agents when they unlock) could be added later but introduces complexity: what if 10 ticks were skipped? Deliver all 10? Only the most recent? For now, the accumulation-in-pendingOutput approach is sufficient — the companion sees a consolidated batch when it next runs.

### Migration / Backwards Compatibility

Pure internal refactor of `routeTerminalOutput` and `tick()`. No API surface changes. Swim channels (single companion) are behaviorally identical. Multi-companion channels become more concurrent.

### Implementation Notes

- Remove the global `agentRunning` guard from `TerminalAgentLoop.tick()` entirely.
- Move the agent-lock filter into `routeTerminalOutput`, applied per-target before calling `launchAgents`.
- The `isAgentLocked` helper reads from `activeAgentHandlers` which is already `@MainActor`-protected.
- `launchAgents` already handles the case where `targets` is empty — no change needed there.
- Test case: channel with two LLM companions, terminal producing output, one companion set to a mock slow response — verify the other companion fires on the next tick.

---

## Feature 3 — Terminal Port Console API

### Problem

Port JS runs in a WKWebView sandbox. There is currently no way for a port to:

1. Write structured output to a shell (without going through xterm rendering)
2. Read from stdout/stderr of a running process programmatically (only via terminal output bridging)
3. Emit debug/log output that is visible to developers or companions without posting chat messages
4. Run headless terminal commands — getting the output as a JS value rather than rendered characters in an xterm display

This limits the kinds of ports you can build. A build monitor that wants to tail a log file can only do so by spawning a full xterm terminal. A port that wants to stream subprocess output into a chart can't — it has to go through the terminal display and then scrape the output. A developer debugging a port loop has nowhere to put `console.log` output.

### Proposed API

Three independent surfaces, each independently useful:

#### Surface A: `port42.terminal.write(text)`

Write raw text to an active terminal session's stdin — without executing it as a command. No `\r` appended. The caller controls line endings and whether the text looks like a command, a log annotation, or raw data.

```js
// Annotate terminal output with port-generated text
port42.terminal.write("── port42: build started at " + new Date().toISOString() + "\n");

// Write without newline (e.g. prompt injection, completion)
port42.terminal.write("suggested fix: ");
```

Distinction from `terminal_send`: `terminal_send` is a tool-use API for companions and appends `\r` to execute commands. `port42.terminal.write` is a low-level port API for raw stdin injection with no modification.

Targets the first active terminal session in the port (same as `terminal_send`). If no terminal is active, returns `{ error: "no active terminal" }`.

#### Surface B: `port42.terminal.exec(command, options)`

Run a shell command headlessly — no xterm, no rendered output. Returns the result as a JS promise resolving to `{ stdout, stderr, exitCode }`. The command runs in a non-interactive shell subprocess, separate from any running xterm session.

```js
const result = await port42.terminal.exec("git log --oneline -5");
// → { stdout: "abc1234 fix thing\n...", stderr: "", exitCode: 0 }

const build = await port42.terminal.exec("npm run build", {
    cwd: "/Users/gordon/project",
    timeout: 30000,        // ms, default 10000
    env: { NODE_ENV: "production" }
});

if (build.exitCode !== 0) {
    port42.console.error("build failed", build.stderr);
}
```

This is distinct from `terminal_exec` (the companion tool-use API). `port42.terminal.exec` is synchronous from the port's perspective (awaitable promise), returns structured output, and does not require a port to have an xterm terminal spawned. It is the headless shell access path.

Use cases: build monitors, log tailers, file watchers, system status displays, CI integrations — anything that needs shell results as data rather than rendered terminal output.

#### Surface C: `port42.console` namespace

A structured logging API that routes output to the most useful destination available, in priority order: terminal pane → debug overlay → (opt-in) channel message.

```js
// Basic logging — routes to terminal if active, otherwise overlay
port42.console.log("tick", { count: n, lastValue: v });
port42.console.warn("rate limit approaching");
port42.console.error("ai.complete failed", err.message);

// Force terminal output (fails silently if no terminal)
port42.console.terminal("heartbeat\n");

// Show/hide an in-port debug overlay (collapsible, monospace, dark)
port42.console.showOverlay();
port42.console.hideOverlay();
port42.console.clearOverlay();

// Route logs to channel as system messages (opt-in, rate-limited)
port42.console.toChannel(true);
port42.console.toChannel(false);

// Intercept native console.log → port42.console (preserves WebKit inspector behaviour)
port42.console.intercept();
```

**Routing priority:**
1. If port has an active terminal session and log level is appropriate: write to terminal as annotated text (e.g. `[port42] message\n`)
2. If overlay is shown: append to overlay
3. If `toChannel` is enabled: post as `senderType: "system"` message (max 1/sec, deduplicated)
4. Always: write to WebKit console (visible in Safari Web Inspector)

**`port42.console.terminal(text)`** is a shortcut for `port42.terminal.write("[console] " + text)` — writes directly to terminal stdin, no routing logic.

### Headless Ports

`port42.terminal.exec` enables a new port pattern: **headless terminal ports**. These are ports with no visible terminal display that use the shell as a data source:

```html
<!-- Build monitor port — no xterm, just a status card -->
<title>Build Monitor</title>
<div id="status">checking...</div>
<script>
    port42.loop.register(async () => {
        const { stdout, exitCode } = await port42.terminal.exec("npm run build 2>&1 | tail -5");
        document.getElementById("status").textContent = exitCode === 0
            ? "✓ passing"
            : "✗ failed\n" + stdout;
    }, { interval: 30000 });
</script>
```

This is a significant expansion of what ports can be — not just visual overlays but lightweight process monitors, log aggregators, CI dashboards, file watchers. No xterm dependency, no bridging overhead, results as structured data.

### Rate Limiting and Safety

- `terminal.exec` has a default timeout of 10s, max 60s. Long-running commands should use `terminal.write` + xterm bridging instead.
- `terminal.exec` runs in a non-interactive shell. It does not inherit the xterm session's working directory or environment unless explicitly set via `cwd` / `env`.
- `console.toChannel` posts at most 1 message per second per port, deduplicated by content hash. Prevents log floods.
- `terminal.write` requires the terminal permission (same as `terminal_send`). `terminal.exec` requires the terminal permission.

### Migration / Backwards Compatibility

New API surface — no existing code changes. Ports that don't use it are unaffected. `terminal_send` (companion tool-use) is unchanged. The existing xterm-based terminal port remains the primary interactive terminal; `terminal.exec` is the non-interactive complement, not a replacement.

### Implementation Notes

**`port42.terminal.write(text)`:**
- Bridge method `"terminal.write"`: args[0] = text string
- Calls `terminalBridge?.sendToFirst(data: text)` — same path as `terminal_send` but without `\r` injection
- Returns `{ ok: true }` or `{ error: "no active terminal" }`

**`port42.terminal.exec(command, options)`:**
- Bridge method `"terminal.exec"`: args[0] = command string, args[1] = options dict
- Spawns `Process()` with `/bin/sh -c <command>`, captures stdout + stderr via `Pipe`
- Returns `{ stdout, stderr, exitCode }` when process exits or timeout elapses
- Does NOT create a `TerminalBridge` or xterm session — entirely separate subprocess path
- Timeout enforced via `Task.sleep` + `Process.terminate()`
- Requires terminal permission gate (same as existing terminal methods)
- CWD defaults to `~`, overridable via `options.cwd`
- Environment inherits from parent process, merged with `options.env`

**`port42.console` namespace:**
- Bridge methods: `"console.log"`, `"console.warn"`, `"console.error"`, `"console.terminal"`, `"console.showOverlay"`, `"console.hideOverlay"`, `"console.clearOverlay"`, `"console.toChannel"`, `"console.intercept"`
- Terminal write path: calls `terminal.write("[console] " + formatted + "\n")`
- Overlay: inject `<div id="__p42_console_overlay">` into port DOM via `evaluateJavaScript` on first use; subsequent calls append `<p>` elements
- Channel path: `appState.db.saveMessage(...)` with rate limiting via a `lastPostedAt` timestamp on the bridge
- `console.intercept()`: injected JS that replaces `console.log/warn/error` with shims that call `port42.console.*` then call the original method

---

## Implementation Order

1. **Feature 3A** (`terminal.write`) — one line, bridges to existing `sendToFirst`. Ship immediately.
2. **Feature 3C** (`port42.console`) — overlay + terminal routing + channel opt-in. Medium.
3. **Feature 3B** (`terminal.exec`) — headless subprocess. Requires Process lifecycle, timeout handling. Medium-large.
4. **Feature 2** (per-agent locks) — refactor of `routeTerminalOutput` + `tick()`. Small but needs testing with multi-companion channels.
5. **Feature 1** (`port42.loop`) — bridge timer infrastructure + JS shim. Medium.

Feature 3A unblocks Feature 3C (console routes through terminal.write). Feature 1 and Feature 2 are independent.

---

## Open Questions

- **Feature 1:** Should `port42.loop.list()` be visible to companions via `ports_list`? Could help companions understand what a port is doing.
- **Feature 3B:** Should `terminal.exec` output be automatically bridged to the game loop (making headless ports part of the agent↔terminal conversation), or always stay private to the port? Probably opt-in via `options.bridgeToChannel`.
- **Feature 2:** If a companion's slot is locked for a long time (slow tool-use chain), should we emit a channel message ("companion A is still thinking") or just let it be?

---

*myth-seed v3 — frequency 42.42 FM*
