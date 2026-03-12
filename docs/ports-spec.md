# Ports Spec

**Last updated:** 2026-03-11

**Status:** Working draft

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

### Phase 1: Inline Ports

| ID | Feature | Description | Done When |
|----|---------|-------------|-----------|
| P-100 | Port Detection | Detect ` ```port ` code fences in companion messages, render as live webview instead of text | Companion sends port block, it renders live in chat |
| P-101 | Inline Webview | Sandboxed WKWebView rendered inline in the message stream, auto-sized to content height | Port displays at correct height, no scrollbars on the message stream |
| P-102 | Bridge Core | Inject `port42.*` JS namespace into webview via WKUserScript. Async call/response over WKScriptMessageHandler | Port can call `port42.user.get()` and get a result |
| P-103 | Bridge: Companions | `port42.companions.list()`, `port42.companions.get(id)` | Port can display a list of companions |
| P-104 | Bridge: Messages | `port42.messages.recent(n)` returns last n messages in the current swim/channel | Port can read conversation history |
| P-105 | Bridge: User | `port42.user.get()` returns current user id, name | Port knows who is using it |
| P-106 | Bridge: Events | `port42.on(event, callback)` pushes live updates from native to JS | Port updates in real time without polling |
| P-107 | Companion Context | System prompt addition telling companions they can emit ports and describing available bridge APIs | Companion naturally emits ports when asked to build something interactive |
| P-108 | Port Sandbox | No network access, no filesystem, no navigation. All data through bridge only | Port cannot make external requests or access local files |
| P-109 | Port Theme | Default port42 theme injected (dark bg, green accent, monospace) so ports feel native without explicit styling | Unstyled port looks like it belongs in port42 |

### Phase 2: Pop Out and Dock

| ID | Feature | Description | Done When |
|----|---------|-------------|-----------|
| P-200 | Pop Out | Button on inline port to detach into floating panel inside port42 | User clicks pop out, port appears as panel |
| P-201 | Virtual Window | Floating panel inside port42 main window. Draggable, resizable, title bar | Port panel moves and resizes within port42 |
| P-202 | Docking | Snap port to right, bottom, or left edge. Chat resizes to accommodate | Docked port splits the view, chat stays usable |
| P-203 | Port Persistence | Popped-out ports survive channel switches | Switch channels, docked port stays |
| P-204 | Port Update | Companion sends new port, inline version replaces in place | Companion iterates on a port without duplicates |
| P-205 | Port Close | Close button dismisses. Inline collapses to code block preview | Closing is clean and reversible |
| P-206 | Multiple Ports | Multiple popped-out/docked ports at once | Two ports docked, or one docked and one floating |

### Phase 3: Generative Ports

| ID | Feature | Description | Done When |
|----|---------|-------------|-----------|
| P-300 | Bridge: AI | `port42.ai.complete(prompt, options)` with streaming callback | Port can ask AI and stream the response |
| P-301 | Bridge: Send | `port42.messages.send(text)` sends a message into the current swim/channel | Port can post messages into conversations |
| P-302 | Bridge: Channels | `port42.channels.list()` returns all channels | Port can show channel overview |
| P-303 | Port Permissions | Permission prompts for write capabilities (send, AI). Reads allowed by default | User approves before a port can act on their behalf |

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

### Bridge API

```
port42.companions
  .list()                → [{ id, name, status, model, isActive }]
  .get(id)               → Companion

port42.messages
  .recent(n)             → [{ id, sender, content, timestamp, isCompanion }]
  .send(text)            → send message into swim (phase 3)

port42.user
  .get()                 → { id, name }

port42.ai
  .complete(prompt, opts?) → string via streaming callback (phase 3)

port42.on(event, cb)     → subscribe to live updates
port42.port
  .close()               → self-close
  .resize(w, h)          → request dimensions
```

### Events

```
'message'              → new message in swim/channel
'companion.activity'   → companion started/stopped responding
'companion.joined'     → companion entered
'companion.left'       → companion left
'port.docked'          → user docked the port
'port.undocked'        → user undocked/floated the port
```

### Sandbox Rules

Ports CANNOT:
- Access filesystem
- Make network requests (no fetch, no XHR, no WebSocket)
- Access other ports
- Read outside their swim/channel context
- Persist data outside bridge API

Ports CAN ONLY:
- Call port42.* methods
- Render HTML/CSS/JS in their webview
- Receive events through port42.on()

---

## Swift Implementation

Three components:

### BridgeHandler

WKScriptMessageHandler that receives port42.* calls from JS.
Routes to appropriate swift services (DatabaseService, AppState,
LLMEngine). Returns results as JSON through callback.

### BridgeInjector

Injects port42.* namespace into webview via WKUserScript at
document start. Sets up message handlers before content loads.
Wraps JS calls in promises that resolve when swift calls back.
Also injects the port42 base theme CSS.

### EventPusher

Observes AppState changes (new messages, companion activity,
presence). Calls webview.evaluateJavaScript() to push events
into port42.on() listeners. Only pushes events relevant to
the port's swim/channel context.

---

## Future Bridge APIs

### Port Storage

```
port42.storage
  .set(key, value)       → persist data for this port
  .get(key)              → retrieve persisted data
  .delete(key)           → remove key
  .list()                → list all keys
```

Ports need persistent state. Currently every port re-fetches from scratch on load.
If a port can save data (transmission log, conversation stats, pattern detection
results), it becomes a tool instead of a widget. Storage is scoped per-port,
per-channel. Survives app restart.

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
