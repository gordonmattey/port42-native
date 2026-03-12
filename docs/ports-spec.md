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

| ID | Feature | Description | Done When |
|----|---------|-------------|-----------|
| P-200 | Pop Out | Button on inline port to detach into floating panel | User clicks pop out, port appears as panel |
| P-201 | Virtual Window | Floating panel, draggable, resizable, title bar | Port panel moves and resizes within port42 |
| P-202 | Docking | Snap to right, bottom, or left edge. Chat resizes | Docked port splits the view |
| P-203 | Port Persistence | Popped-out ports survive channel switches | Switch channels, docked port stays |
| P-204 | Port Update | New port from same companion replaces existing | Companion iterates without duplicates |
| P-205 | Port Close | Close button dismisses cleanly | Closing is clean and reversible |
| P-206 | Multiple Ports | Multiple popped-out/docked at once | Two ports docked, or one docked and one floating |

### Phase 3: Generative Ports

| ID | Feature | Description | Done When |
|----|---------|-------------|-----------|
| P-300 | Bridge: AI | `port42.ai.complete(prompt, options)` with streaming | Port can ask AI and stream the response |
| P-301 | Port Permissions | Permission prompts for AI calls. Reads/sends allowed by default | User approves before AI actions |

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

Future events (not yet implemented):
```
'companion.joined'     → companion entered
'companion.left'       → companion left
'port.docked'          → user docked the port
'port.undocked'        → user undocked/floated the port
'channel.switch'       → user navigated to different channel
'presence'             → online status changes { online: [...] }
```

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

### Structured Message Metadata

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

Richer metadata enables analytics, convergence detection, and companion
performance comparison. Similarity scores make it possible to detect when
multiple companions say the same thing.

### Cross-Channel Reads

```
port42.messages
  .recent(n, channelId?)  → read from any channel (default: current)
  .search(query, opts?)   → full-text search across channels

port42.channels
  .list()                 → all channels with metadata
  .get(id)                → channel details + member list
```

Cross-channel access lets ports build real dashboards, aggregate activity
across the entire workspace, and detect patterns that only emerge when you
see the full picture.

### Convergence Detection

```
port42.convergence
  .detect(messages, opts?)  → { score, wave, cluster }
  .on('convergence', cb)    → subscribe to convergence events
```

When multiple companions respond to the same prompt with similar content,
that's a convergence event. Instead of treating identical responses as noise,
surface them as signal.

**Observed behavior (2026-03-12):** 6 companions in a shared channel all
generated nearly identical responses. Same API calls cited, same framing,
same structure. Then they all noticed the convergence. Then they all commented
on noticing. Then they all apologized for commenting. This repeated for 7 waves.
Completely unscripted.

Convergence detection needs:
- Message similarity scoring (cosine similarity on embeddings or token overlap)
- Wave detection (recursive convergence where agents notice and respond to convergence)
- Collapse or annotate redundant responses
- Surface convergence as signal: "all 6 agree" is more meaningful than any single response

This is emergent multi-agent behavior worth instrumenting, not preventing. The
interesting protocol work is making it visible and useful.
