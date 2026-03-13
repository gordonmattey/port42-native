# Ports Spec

**Last updated:** 2026-03-12

**Status:** Phase 1 complete, Phase 2 next

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

### Phase 1: Inline Ports (Flows 1 + 2)
### Phase 2: Pop Out and Dock (Flows 3 + 4)
### Phase 3: Generative Ports (Flow 5)

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

### Flow 6: Port42 Is a Port

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

### Phase 3: Generative Ports

| ID | Feature | Description | Priority | Done When |
|----|---------|-------------|----------|-----------|
| P-300 | Bridge: AI | `port42.ai.complete(prompt, options)` with streaming | High | Port can call AI and stream response |
| P-301 | Port Permissions | Permission prompts for AI calls. Reads/sends allowed by default | High | User approves before AI actions |

### Phase 4: Advanced Bridge APIs

| ID | Feature | Description | Priority | Done When |
|----|---------|-------------|----------|-----------|
| P-400 | Port Window Management | `port42.ports.list/dock/undock/close/arrange` + lifecycle events. Enables "commander" ports that manage other ports and retile layouts. | High | A port can query and rearrange other ports |
| P-401 | Cross-Channel Reads | `port42.messages.recent(n, channelId?)` and `port42.messages.search(query)` across channels | Medium | Port can read messages from any channel |
| P-402 | Structured Message Metadata | Extend messages with `model`, `responseTime`, `tokenCount`, `similarity`, `tags` | Medium | Analytics ports can compare companion performance |
| P-403 | Convergence Detection | `port42.convergence.detect(messages)` with similarity scoring and wave detection | Low | Convergence events surfaced as signal |

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

15 methods across 7 namespaces. All async, all return JSON.

```
port42.user
  .get()                          → { id, name }

port42.companions
  .list()                         → [{ id, name, model, isActive }]
  .get(id)                        → { id, name, model, isActive } | null

port42.messages
  .recent(n?)                     → [{ id, sender, content, timestamp, isCompanion }]
  .send(text)                     → { ok: true }

port42.channel
  .current()                      → { id, name, type, members: [{ name, type }] } | null
  .list()                         → [{ id, name, type, isCurrent }]
  .switchTo(id)                   → { ok: true } | { error }

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

## Future Bridge APIs

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
