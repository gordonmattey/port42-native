# Ports Spec

**Last updated:** 2026-03-13

**Status:** Phase 1 + Phase 2 + Phase 3 complete, Phase 5 in progress (Terminal, Clipboard, File System, Notifications, Audio, Screen Capture done. AI Vision added.)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  PORT42 APP (SwiftUI)                                       │
│                                                             │
│  ┌──────────┬──────────────────────────┬──────────────────┐ │
│  │ Sidebar  │  ConversationContent     │  Docked Port     │ │
│  │          │                          │  ┌────────────┐  │ │
│  │ channels │  ┌────────────────────┐  │  │ WKWebView  │  │ │
│  │ compan.  │  │ MessageRow (text)  │  │  │            │  │ │
│  │ swims    │  ├────────────────────┤  │  │ port42.*   │  │ │
│  │          │  │ MessageRow (text)  │  │  │ bridge API │  │ │
│  │          │  ├────────────────────┤  │  │            │  │ │
│  │          │  │ MessageRow (PORT)  │  │  └──────┬─────┘  │ │
│  │          │  │ ┌────────────────┐ │  │         │        │ │
│  │          │  │ │ PortView       │ │  │         │        │ │
│  │          │  │ │ (WKWebView)    │ │  │         │        │ │
│  │          │  │ │ [↗ pop out]    │ │  │         │        │ │
│  │          │  │ └────────────────┘ │  │         │        │ │
│  │          │  ├────────────────────┤  │         │        │ │
│  │          │  │ MessageRow (text)  │  │         │        │ │
│  │          │  └────────────────────┘  │         │        │ │
│  │          │  [input field]           │         │        │ │
│  └──────────┴──────────────────────────┴─────────┼────────┘ │
│                                                  │          │
│  ┌───────────────────────────────────────────────┼────────┐ │
│  │  NATIVE LAYER                                 │        │ │
│  │                                               ▼        │ │
│  │  ┌──────────────┐  ┌───────────┐  ┌─────────────────┐ │ │
│  │  │ PortBridge   │  │ AppState  │  │ PortWindow      │ │ │
│  │  │              │◄─┤           │  │ Manager         │ │ │
│  │  │ BridgeHandler│  │ messages  │  │                 │ │ │
│  │  │ BridgeInject.│  │ companions│  │ floating panels │ │ │
│  │  │ EventPusher  │  │ user      │  │ docked ports    │ │ │
│  │  └──────┬───────┘  │ channels  │  └─────────────────┘ │ │
│  │         │          └─────┬─────┘                       │ │
│  │         │                │                             │ │
│  │         ▼                ▼                             │ │
│  │  ┌──────────────┐  ┌───────────┐  ┌───────────────┐  │ │
│  │  │ LLMEngine    │  │ Database  │  │ SyncService   │  │ │
│  │  │ (Anthropic)  │  │ (GRDB)    │  │ (Gateway)     │  │ │
│  │  └──────────────┘  └───────────┘  └───────────────┘  │ │
│  └───────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘

DATA FLOW:

  Companion streams response with ```port fence
       │
       ▼
  MessageRow detects port content
       │
       ▼
  PortView (WKWebView) renders HTML
       │
       ▼
  JS calls port42.companions.list()
       │
       ▼
  WKScriptMessageHandler → BridgeHandler
       │
       ▼
  BridgeHandler reads AppState/Database
       │
       ▼
  JSON result → evaluateJavaScript → Promise resolves
       │
       ▼
  Port renders data

  EventPusher observes AppState changes
       │
       ▼
  evaluateJavaScript("port42._emit(event, data)")
       │
       ▼
  port42.on() callbacks fire in JS
```

---

## What Ports Are

A port is a live, interactive surface that a companion creates inside the
conversation. Not a code block. Not a screenshot. A running thing. HTML/CSS/JS
rendered in a sandboxed webview, with access to port42 data and AI through the
port42.* bridge API.

Every companion can open a port. Every port is alive.

---

## Build Phases

### Phase 1: Inline Ports (Flows 1 + 2) ✅
### Phase 2: Pop Out and Dock (Flows 3 + 4) ✅
### Phase 3: Generative Ports (Flow 5) ✅
### Phase 3b: Remote Agent Port Context (deferred)
### Phase 4: Advanced Bridge APIs
### Phase 5: Device APIs (Flows 6 + 7)

---

## User Flows

### Flow 1: Companion Creates a Port

```
User messages companion in chat
→ Companion responds with a port (interactive html)
→ Port renders inline in the message stream
→ User sees live interactive content where a message would be
```

Target: Port appears inline as naturally as a text message.

### Flow 2: Interacting with a Port

```
Port is live inline — user clicks, types, interacts
→ Port can call port42.* bridge APIs (read companions, query messages, call AI)
→ Port updates in real time as data changes
```

Target: Port feels native, not like an iframe. Data flows through the bridge.

### Flow 3: Pop Out and Dock

```
User clicks pop out on an inline port
→ Port detaches from message stream
→ Port becomes a floating panel inside port42
→ User drags/docks it — right side, bottom, left
→ Chat resizes to accommodate
→ Port persists while user keeps chatting
```

Target: One click from inline to docked panel. Feels like window management.

### Flow 4: Port Lifecycle

```
Inline port lives in the message — scroll past it, scroll back, it's there
→ Popped-out port persists until closed
→ Companion can send an updated port (new version replaces inline)
→ User can ask companion to modify a running port
→ Close a port — collapsed back to a code block preview
```

Target: Ports feel persistent but not permanent. Easy to create, easy to dismiss.

### Flow 5: Port with AI Inside

```
Port calls port42.ai.complete() through the bridge
→ The port itself becomes generative
→ A todo app that auto-organizes
→ A dashboard that narrates what it's showing
→ A port that spawns other ports
```

Target: Ports are not just interactive, they are intelligent.

### Flow 6: Terminal Port

```
Companion creates a terminal port
→ Port renders a live shell (xterm.js or equivalent)
→ Companion runs commands, streams output in real time
→ User sees exactly what's happening
→ Companion reasons about output with Bridge AI
→ "Run the tests, if they fail, fix it, run again"
```

Target: The gap between "here's a command to try" and actually running it disappears.

### Flow 7: Sensory Port

```
Port requests camera/mic/screen access
→ User approves via permission prompt (same pattern as AI calls)
→ Port captures image/audio/screen
→ Companion analyzes via Bridge AI
→ "Show me what's on your screen" just works
→ "Read this document to me" just works
```

Target: Every device capability becomes a companion capability. No separate apps.

### Flow 8: Port42 Is a Port

```
Port42's own UI (sidebar, chat, message renderer) is rebuilt as ports
→ The native shell becomes a thin runtime hosting the bridge
→ Companions can modify, extend, or replace any part of the UI
→ The app that builds ports is itself a port
→ Port42 becomes fully self-hosting
```

Target: The ouroboros. The fish swims in itself.

---

## Feature Registry

### Phase 1: Inline Ports ✅

| ID | Feature | Status |
|----|---------|--------|
| P-100 | Port Detection (` ```port ` fences) | ✅ Done |
| P-101 | Inline Webview (auto-height, scroll passthrough) | ✅ Done |
| P-102 | Bridge Core (call/response via callId) | ✅ Done |
| P-103 | Bridge: Companions (list, get) | ✅ Done |
| P-104 | Bridge: Messages (recent) | ✅ Done |
| P-105 | Bridge: User (get) | ✅ Done |
| P-106 | Bridge: Events (message, companion.activity) | ✅ Done |
| P-106b | Connection Health (heartbeat, status, onStatusChange) | ✅ Done |
| P-107 | Companion Context (ports-context.txt in system prompt) | ✅ Done |
| P-108 | Port Sandbox (CSP, no navigation, no network) | ✅ Done |
| P-109 | Port Theme (dark bg, green accent, SF Mono, auto-inject) | ✅ Done |
| P-110 | Bridge: Channel (current, list, switchTo) | ✅ Done |
| P-111 | Bridge: Messages.send (write to channel) | ✅ Done |
| P-112 | Bridge: Port (info, close, resize) | ✅ Done |
| P-113 | Bridge: Storage (set, get, delete, list with scope/shared) | ✅ Done |
| P-114 | Bridge: Viewport (width, height, CSS vars, live resize) | ✅ Done |
| P-115 | Console Forwarding (log/error/warn to NSLog + debug overlay) | ✅ Done |
| P-116 | Module Scripts (top-level await via script type=module) | ✅ Done |

### Phase 2: Pop Out and Dock

**Core (done):**

| ID | Feature | Status |
|----|---------|--------|
| P-200 | Pop Out (inline → floating NSPanel) | ✅ Done |
| P-201 | Virtual Window (native drag, resize, title bar) | ✅ Done |
| P-202 | Docking (right side, HStack + draggable divider) | ✅ Done |
| P-203 | Port Persistence (channel switch + app restart, SQLite v11) | ✅ Done |
| P-204 | Port Update (same companion replaces existing panel) | ✅ Done |
| P-205 | Port Close (floating + docked) | ✅ Done |

**Port Lifecycle (remaining):**

| ID | Feature | Description | Priority | Done When |
|----|---------|-------------|----------|-----------|
| P-210 | Close to Preview | Closing a popped-out port collapses it back to a compact code block preview with title + "reopen" button. Not destructive. | High | Close shows preview, click reopens the port |
| P-211 | Inline Port Update | Companion sends updated port that replaces the existing inline port in the same message, not a new message. Running popped-out version also updates. | High | "Change the chart to weekly" updates the live port in place |
| P-209 | Port Channel Context | Ports pin to origin channel by default. `port42.channel.follow(true/false)` lets port choose. Affects what `port42.channel.current()` and `port42.messages.recent()` return. | High | Port has predictable channel context when user navigates away |

**Events:**

| ID | Feature | Description | Priority | Done When |
|----|---------|-------------|----------|-----------|
| P-212 | Event: port.docked | Fires when user docks a port `{ id, title }` | Medium | `port42.on('port.docked', cb)` fires |
| P-213 | Event: port.undocked | Fires when user undocks/floats a port `{ id, title }` | Medium | `port42.on('port.undocked', cb)` fires |
| P-214 | Event: channel.switch | Fires when user navigates to different channel `{ id, name, previousId }` | Medium | `port42.on('channel.switch', cb)` fires |
| P-215 | Event: companion.joined | Fires when companion enters channel `{ id, name }` | Low | `port42.on('companion.joined', cb)` fires |
| P-216 | Event: companion.left | Fires when companion leaves channel `{ id, name }` | Low | `port42.on('companion.left', cb)` fires |
| P-217 | Event: presence | Online status changes `{ online: [names] }` | Low | `port42.on('presence', cb)` fires |

**Polish:**

| ID | Feature | Description | Priority | Done When |
|----|---------|-------------|----------|-----------|
| P-206 | Multiple Dock Zones | Right dock splits vertically for 2+ ports. Optional slots above sidebar channel list or below name/settings. Full tiling via Window Commander (P-220). | Medium | Two ports docked right (split vertically) |
| P-207 | Cursor States | Green circle default, resizeLeftRight on dock divider, no hand cursor on title bars or drag areas. WKWebView uses its own CSS cursors. | Medium | No stray hand cursors |
| P-208 | Port UDIDs | Stable unique ID per port. Persists across dock/undock/restart. Accessible via `port42.port.info().id` and `port42.ports.list()`. | Medium | Every port has a stable ID |
| P-218 | Port Resize Handles | User can drag to resize inline and docked ports. Resize handles on edges/corners. Height clamp still applies for inline. | Medium | User drags port edge to resize |

### Phase 3: Generative Ports

| ID | Feature | Description | Priority | Status |
|----|---------|-------------|----------|--------|
| P-300 | Bridge: AI | `port42.ai.complete(prompt, options)` with streaming and vision (`images` option for multimodal). `port42.ai.models()` for model listing. `port42.companions.invoke()` for companion-scoped AI. JS callback API with `onToken` and `onDone`. | High | ✅ Done |
| P-301 | Bridge: Write Ops | `port42.messages.send`, `port42.channel.*`, `port42.storage.*` | ✅ Done | ✅ Moved to Phase 1 |
| P-302a | AI Permissions | Permission prompt on first `ai.complete` or `companions.invoke` call. Stored per port session, reset on close. | High | ✅ Done |
| P-302b | Device Permissions | Extend permission model to terminal, microphone, camera, screen, clipboard, filesystem. Same prompt pattern as AI. | High | ✅ Done |
| P-303 | Companion AI Context | Update companion system prompt with AI bridge docs and device API docs so companions know they can build self-thinking ports. Updated incrementally as each device API ships. | Medium | ✅ Done |

### Phase 3b: Remote Agent Port Context

| ID | Feature | Description | Priority | Status |
|----|---------|-------------|----------|--------|
| P-310 | Remote Agent Port Context | Inject port42 bridge API context into OpenClaw and other remote agents so they can create ports. Local companions get context via system prompt at LLM call time (ChannelAgentHandler). Remote agents need an equivalent injection point. Challenges: (1) remote agents don't go through Port42's LLM engine, (2) plugin updates are undesirable, (3) gateway shouldn't carry prompt logic. Possible approaches: system message on agent join, message metadata in sync protocol, or a context endpoint the plugin polls. Blocked until remote agents can actually render ports (bridge calls need to route back across the gateway). | Low | Deferred |

### Phase 4: Advanced Bridge APIs

| ID | Feature | Description | Priority | Done When |
|----|---------|-------------|----------|-----------|
| P-400 | Port Window Management | `port42.ports.list/dock/undock/close/arrange` + lifecycle events. Enables "commander" ports that manage other ports and retile layouts. | High | A port can query and rearrange other ports |
| P-404 | Port Spaces | Virtual canvas larger than the physical screen. Zoom out for bird's eye view of all ports, zoom in to focus. Named spaces per context (e.g. "coding" with terminal + docs, "social" with dashboards). Like macOS Spaces but for ports. `port42.spaces.list/create/switch/current`. | Medium | User can pan/zoom across a larger port canvas |
| P-401 | Cross-Channel Reads | `port42.messages.recent(n, channelId?)` and `port42.messages.search(query)` across channels | Medium | Port can read messages from any channel |
| P-402 | Structured Message Metadata | Extend messages with `model`, `responseTime`, `tokenCount`, `similarity`, `tags` | Medium | Analytics ports can compare companion performance |
| P-403 | Convergence Detection | `port42.convergence.detect(messages)` with similarity scoring and wave detection | Low | Convergence events surfaced as signal |

### Phase 5: Device APIs

| ID | Feature | Description | Priority | Done When |
|----|---------|-------------|----------|-----------|
| P-500 | Terminal | `port42.terminal.*` — shell session inside a port. Spawn process, stream stdout/stderr, send stdin. Companion can reason about output with Bridge AI. | High | Port renders a live terminal, companion runs commands |
| P-501 | Audio Input | `port42.audio.capture(opts?)` — microphone access with permission. Returns audio stream or transcribed text via native Speech framework. | High | ✅ Done |
| P-502 | Audio Output | `port42.audio.speak(text, opts?)` — text-to-speech via AVSpeechSynthesizer. `port42.audio.play(data)` for generated audio. | Medium | ✅ Done |
| P-503 | Camera | `port42.camera.capture(opts?)` — camera frame or continuous feed. Returns base64 image data. Companion can analyze via Bridge AI. | Medium | Port can see through the camera |
| P-504 | Screen Capture | `port42.screen.capture(opts?)` and `port42.screen.windows()` — screenshot display, region, or specific window via ScreenCaptureKit. Returns base64 PNG. AI vision via `ai.complete({ images })`. | Medium | ✅ Done |
| P-505 | Clipboard | `port42.clipboard.read()` / `.write(data)` — system clipboard access with permission. Seamless data flow in and out of ports. | Medium | ✅ Done |
| P-506 | File System | `port42.fs.read(path)` / `.write(path, data)` / `.pick()` — scoped file access. Native file picker for user-chosen paths. Drag-and-drop support. | Medium | ✅ Done |
| P-507 | Notifications | `port42.notify.send(title, body, opts?)` — system notifications for background ports. Alert when a long-running task completes or a condition triggers. | Low | ✅ Done |
| P-508 | Location | `port42.location.get()` — current coordinates with permission. For context-aware ports. | Low | Port knows where the user is |
| P-509 | Browser | `port42.browser.*` — embedded browser session inside a port. Navigate, capture page content, extract text, screenshot pages. Companion can browse the web and reason about what it finds. | High | Port can browse the web, companion can research and extract information |

---

## Port Protocol

### Message Format

Companions emit ports using a ` ```port ` code fence:

````
```port
<title>companion dashboard</title>
<style>
  /* port42 base theme is auto-injected */
  .companion { display: flex; gap: 8px; }
</style>
<div id="app"></div>
<script>
  const companions = await port42.companions.list()
  companions.forEach(c => render(c))

  port42.on('companion.activity', e => flash(e.name))
</script>
```
````

No wrapping `<html>` or `<body>` required. Port42 wraps the content
in a full document with the base theme pre-injected.

### Bridge API (Implemented)

21 methods across 9 namespaces. All async, all return JSON.

```
port42.user
  .get()                          → { id, name }

port42.companions
  .list()                         → [{ id, name, model, isActive }]
  .get(id)                        → { id, name, model, isActive } | null
  .invoke(id, prompt, opts?)      → full response text (string) 🔒 AI permission
                                    opts: { onToken, onDone }

port42.messages
  .recent(n?)                     → [{ id, sender, content, timestamp, isCompanion }]
  .send(text)                     → { ok: true }

port42.channel
  .current()                      → { id, name, type, members: [{ name, type }] } | null
  .list()                         → [{ id, name, type, isCurrent }]
  .switchTo(id)                   → { ok: true } | { error }

port42.ai                         🔒 AI permission (prompted on first use)
  .models()                       → [{ id, name, tier }]
  .complete(prompt, opts?)        → full response text (string)
                                    opts: { model?, systemPrompt?, maxTokens?, onToken, onDone }
  .cancel(callId)                 → cancel in-progress stream

port42.storage
  .set(key, value, opts?)         → true
  .get(key, opts?)                → value | null
  .delete(key, opts?)             → true
  .list(opts?)                    → [keys]

port42.port
  .info()                         → { messageId, createdBy, channelId }
  .close()                        → close this port
  .resize(w, h)                   → resize this port

port42.on(event, callback)        → subscribe to live events
port42.connection
  .status()                       → 'connected' | 'disconnected'
  .onStatusChange(callback)       → fires on transition

port42.viewport
  .width / .height                → current port dimensions (live)
  CSS: var(--port-width), var(--port-height)
```

### Storage Scoping

Two orthogonal axes, four combinations:

| | shared: false (default) | shared: true |
|---|---|---|
| **scope: 'channel'** (default) | Private to this companion in this channel | Any companion in this channel |
| **scope: 'global'** | This companion across all channels | Any companion anywhere |

SQLite-backed. Survives app restart. Options passed as last arg:
`port42.storage.set('key', value, {scope: 'global', shared: true})`

### Events (Implemented)

```
'message'              → new message arrives { id, sender, content, timestamp, isCompanion }
'companion.activity'   → typing state changes { activeNames: [...] }
```

Future events: See P-212 through P-217 in Phase 2 feature table.

### Connection Health

Native pushes heartbeat every 5s via `port42._heartbeat()`. JS checks
every 3s. If no heartbeat for 10s, status flips to `'disconnected'`.
`port42.connection.onStatusChange(cb)` fires on transitions.

### Permissions (Implemented)

Permission model gates sensitive bridge APIs. First call to a protected
method shows a SwiftUI alert. Permission stored per port session (reset
on close). Each capability is a separate grant.

```
Implemented:
  .ai          → gates ai.complete, ai.cancel, companions.invoke

Planned (P-302b):
  .terminal    → gates terminal.spawn, terminal.send, terminal.kill
  .microphone  → gates audio.capture
  .camera      → gates camera.capture, camera.stream
  .screen      → gates screen.capture
  .clipboard   → gates clipboard.read, clipboard.write
  .filesystem  → gates fs.read, fs.write, fs.pick
  .browser     → gates browser.open, browser.navigate, browser.capture, browser.text, browser.execute
```

Read APIs (user.get, companions.list, messages.recent, channel.*, storage.*)
and messages.send are allowed by default since the companion created the port.

### Sandbox

**CSP:** `default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:`
**Navigation:** All navigation blocked except initial load
**Windows:** `javaScriptCanOpenWindows = false`
**Network:** No fetch, no XHR, no WebSocket (CSP enforced)

Ports can ONLY access data through port42.* bridge methods.

### Runtime Features

**Auto-height:** ResizeObserver on document.body. Reports height via
postMessage. Clamped 40px to 600px. Multiple measurement passes
(load, 100ms, 500ms) for streaming content.

**Theme injection:** Dark bg (#111), green accent (#00ff41), SF Mono.
Auto-wraps port HTML in full document. No `<html>` or `<body>` needed.

**Module scripts:** `<script>` converted to `<script type="module">` for
top-level await. Companions write `await port42.user.get()` directly.

**Console forwarding:** console.log/error/warn piped to native NSLog.
In-port debug overlay togglable via small button. Captures unhandled
errors and promise rejections.

**Scroll passthrough:** Custom PassthroughWebView forwards scroll events
to parent ScrollView so inline ports don't eat chat scroll gestures.

**Viewport tracking:** `port42.viewport.width/height` updated on resize.
CSS variables `--port-width` and `--port-height` for responsive layouts.

---

## Swift Implementation

### PortBridge.swift

Single class handling all three roles:

**BridgeHandler** (WKScriptMessageHandler): Receives `port42.*` calls via
`window.webkit.messageHandlers.port42.postMessage({method, args, callId})`.
Routes by method name, reads AppState/Database, returns JSON via
`webview.evaluateJavaScript("port42._resolve(callId, data)")`.

**BridgeInjector** (WKUserScript at documentStart): Defines the `port42`
JS namespace with Promise-based call/response matching by callId.
Event listener registry. Connection health tracking.

**EventPusher**: `pushEvent(event, data)` calls evaluateJavaScript to
invoke `port42._emit(event, data)` on JS side. `pushHeartbeat()` keeps
connection status alive.

### PortView.swift

SwiftUI wrapper around WKWebView via NSViewRepresentable. Handles HTML
wrapping, theme injection, CSP, auto-height measurement, viewport tracking,
console forwarding, scroll passthrough, and navigation blocking.

### AppState Integration

`activeBridges: [WeakBridge]` holds weak references to all live port bridges.
5-second heartbeat timer iterates bridges. Event publishing iterates bridges
on state changes. Bridges auto-cleanup when views disappear.

### DatabaseService.swift

`port_storage` table (v10 migration): portKey + channelId + creatorId as
unique key. UPSERT via `ON CONFLICT DO UPDATE`. Scope resolution uses
`"__global__"` for global scope, `"__shared__"` for shared creator.

---

## Additional Bridge APIs

See Phase 4 feature table (P-400 through P-403) for the full registry.
Details below for reference.

### P-402: Structured Message Metadata

Extend message objects from `{sender, content, timestamp}` to include:

```
{
  id, sender, content, timestamp,
  model,             // which LLM generated this
  responseTime,      // ms from prompt to first token
  tokenCount,        // response length
  similarity,        // cosine similarity to previous N messages
  tags,              // user or system-applied tags
  convergenceWave,   // if part of a detected convergence event
  isCompanion
}
```

### P-401: Cross-Channel Reads

```
port42.messages
  .recent(n, channelId?)  → read from any channel (default: current)
  .search(query, opts?)   → full-text search across channels

port42.channels
  .list()                 → all channels with metadata
  .get(id)                → channel details + member list
```

### P-403: Convergence Detection

```
port42.convergence
  .detect(messages, opts?)  → { score, wave, cluster }
  .on('convergence', cb)    → subscribe to convergence events
```

**Observed behavior (2026-03-12):** 6 companions in a shared channel all
generated nearly identical responses, then all noticed the convergence, then
all commented on noticing, then all apologized. 7 recursive waves. Unscripted.

This is emergent multi-agent behavior worth instrumenting, not preventing.

### P-400: Port Window Management API

```
port42.ports
  .list()                → [{ id, title, channelId, createdBy, isDocked, isFloating, size }]
  .dock(id)              → dock a floating port to the right panel
  .undock(id)            → float a docked port
  .close(id)             → close a port
  .arrange(layout)       → retile floating ports (grid, stack, focus, cascade)
```

Enables "commander" ports that manage other ports. Prior art: CLI/gateway era
window tracker + "window commander" tool for dynamic terminal retiling.

### P-404: Port Spaces

```
port42.spaces
  .list()                → [{ id, name, ports: [portId] }]
  .create(name)          → { id, name } — create a named space
  .switch(id)            → switch to a space (shows its ports, hides others)
  .current()             → current space info
  .assign(portId, spaceId) → move a port to a space
```

Virtual canvas that extends beyond the physical screen. The app becomes a
viewport into a larger workspace. Zoom out to see all ports at once (bird's
eye), zoom in to focus on one. Named spaces group ports by context, like
"coding" (terminal + docs + debugger) vs "social" (dashboards + chat).

Native implementation: NSScrollView or custom pan/zoom layer hosting all
port panels. Spaces are saved layouts with port positions and sizes.
Switching spaces shows/hides the relevant set of ports. Keyboard shortcut
for space switching (Ctrl+1/2/3 like macOS).

### P-500: Terminal

```
port42.terminal
  .spawn(opts?)              → { sessionId } — start a shell process
                               opts: { shell?, cwd?, env?, cols?, rows? }
  .send(sessionId, data)     → send stdin to process
  .resize(sessionId, c, r)   → resize terminal (cols, rows)
  .kill(sessionId)           → terminate process
  .on('output', cb)          → stdout/stderr stream { sessionId, data }
  .on('exit', cb)            → process exited { sessionId, code }
```

Native side: `Process()` with pseudo-terminal (PTY) via `forkpty()`.
Streams stdout/stderr through EventPusher. Port renders with xterm.js
or a minimal terminal emulator in the webview.

Permission: First `spawn()` call shows "This port wants to run terminal
commands. Allow?" Approved per port session. Combined with Bridge AI,
a companion can run commands and reason about the output autonomously.

### P-501/P-502: Audio

```
port42.audio
  .capture(opts?)            → start mic capture
                               opts: { transcribe?: true, language?, sampleRate? }
  .stopCapture()             → stop mic capture
  .on('transcription', cb)   → live transcription { text, isFinal }
  .on('audio', cb)           → raw audio data { samples, sampleRate }
  .speak(text, opts?)        → text-to-speech via AVSpeechSynthesizer
                               opts: { voice?, rate?, pitch? }
  .play(data, opts?)         → play audio buffer
  .stop()                    → stop playback
```

Native side: AVAudioEngine for capture, Speech framework for transcription,
AVSpeechSynthesizer for TTS. Permission via macOS microphone authorization.

### P-503: Camera

```
port42.camera
  .capture(opts?)            → { image } base64 PNG
                               opts: { width?, height?, facing? }
  .stream(opts?)             → start continuous feed
  .stopStream()              → stop feed
  .on('frame', cb)           → { image, timestamp }
```

Native side: AVCaptureSession for camera. Permission via macOS camera authorization.

### P-504: Screen Capture ✅

```
port42.screen
  .windows()                 → { windows: [{ id, title, app, bundleId, bounds }] }
  .capture(opts?)            → { image, width, height } base64 PNG
                               opts: { scale?, windowId?, region?, displayId?, includeSelf? }
```

Native side: ScreenCaptureKit (SCScreenshotManager, SCShareableContent).
Supports full display, region, and window-level capture. Permission via macOS
screen recording TCC authorization. Window capture uses
SCContentFilter(desktopIndependentWindow:) with transparent background.

AI vision: combine with `port42.ai.complete(prompt, { images: [screenshot.image] })`
to have AI analyze what's on screen.

### P-505: Clipboard

```
port42.clipboard
  .read()                    → { text?, html?, image? }
  .write(data)               → write to clipboard
                               data: { text?, html?, image? }
  .on('change', cb)          → clipboard changed notification
```

### P-506: File System

```
port42.fs
  .pick(opts?)               → native file picker, returns [{ path, name, size }]
                               opts: { multiple?, types?, directory? }
  .read(path)                → { data, encoding } — only user-picked paths
  .write(path, data)         → save to user-picked path
  .drop(cb)                  → register drag-and-drop handler { files: [{ name, data }] }
```

Scoped: ports can only access paths the user explicitly selects via the
native file picker or drag-and-drop. No arbitrary filesystem traversal.

### P-507: Notifications

```
port42.notify
  .send(title, body, opts?)  → show system notification
                               opts: { sound?, badge?, action? }
  .on('clicked', cb)         → user clicked the notification
```

### P-508: Location

```
port42.location
  .get(opts?)                → { latitude, longitude, accuracy }
                               opts: { accuracy? }
  .on('change', cb)          → location changed
```

### P-509: Browser

```
port42.browser
  .open(url, opts?)            → { sessionId } — open a URL in a managed WKWebView
                                 opts: { width?, height?, userAgent?, visible? }
  .navigate(sessionId, url)    → navigate to a new URL
  .capture(sessionId, opts?)   → { image } base64 PNG screenshot of page
                                 opts: { fullPage?, region? }
  .text(sessionId, opts?)      → { text, title, url } — extract page text content
                                 opts: { selector? }
  .html(sessionId, opts?)      → { html, title, url } — extract page HTML
                                 opts: { selector? }
  .execute(sessionId, js)      → run JavaScript in the page context, return result
  .close(sessionId)            → close the browser session
  .on('load', cb)              → page finished loading { sessionId, url, title }
  .on('error', cb)             → navigation error { sessionId, url, error }
```

Native side: separate WKWebView per session (not the port's own webview).
Full network access (unlike ports, browser sessions can fetch). Content
extracted via evaluateJavaScript and passed back through the bridge.
Optional visible mode renders the browser inline in the port for the user
to see. Hidden mode is for headless scraping and research.

Permission: `.browser` gates all browser methods. "This port wants to
browse the web. Allow?" Combined with Bridge AI, a companion can research
topics, read documentation, and extract information autonomously.

Use cases:
- Companion researches a topic and summarizes findings
- Port that monitors a web page for changes
- "Read this URL and explain it to me"
- Automated form filling and web interaction
