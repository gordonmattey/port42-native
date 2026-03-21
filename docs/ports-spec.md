# Ports Spec

**Last updated:** 2026-03-20

**Status:** Phase 1 + Phase 2 + Phase 3 + Phase 5 complete (all device APIs shipped). Phase 2b complete (bugs fixed, background ports, window persistence, UDIDs, port_update, ports_list, dock/undock, docking removed, edge snap/tiling removed in favour of manual arrangement). Phase 6 in progress (Automation done). Phase 7 specced (Agent Embed Protocol). B-001 (terminal_send routing), B-003 (multiple ports per message), B-004 (capabilities metadata) all fixed. Permission attribution (P-261) and persistence per companion+channel (P-260) fixed. Outstanding bugs: fs.pick() never opens NSOpenPanel (B-002). Port version history (P-219), inline compact block (P-241), multi-companion activity (P-262), and port HTML retrieval (P-263) are pending.

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

## The Unified API

The port42 bridge API has two surfaces but is one API:

1. **Ports** (JS in webview): `port42.clipboard.read()` called from JavaScript
2. **Tool use** (LLM conversation): `clipboard_read` called as a tool during chat

Same methods. Same permissions. Same data. A companion can read your clipboard
from a port or from a conversation. Take a screenshot from a floating panel or
from a swim. Run a terminal command from an interactive terminal port or by
asking in chat. The API is the capability layer. The surface is just how you
access it.

Every companion can open a port. Every port is alive.

---

## Build Phases

### Phase 1: Inline Ports (Flows 1 + 2) ✅
### Phase 2: Pop Out and Dock (Flows 3 + 4) ✅
### Phase 2b: Port Windowing System (Flow 4 + Flow 10)
### Phase 3: Generative Ports (Flow 5) ✅
### Phase 3b: Remote Agent Port Context (deferred)
### Phase 4: Advanced Bridge APIs
### Phase 5: Device APIs (Flows 6 + 7)
### Phase 7: Agent Embed Protocol (Flow 9)

---

## User Flows

### Flow 1: Companion Creates a Port ✅

```
User messages companion in chat
→ Companion responds with a port (interactive html)
→ Port renders inline in the message stream
→ User sees live interactive content where a message would be
```

Target: Port appears inline as naturally as a text message.

### Flow 2: Interacting with a Port ✅

```
Port is live inline — user clicks, types, interacts
→ Port can call port42.* bridge APIs (read companions, query messages, call AI)
→ Port updates in real time as data changes
```

Target: Port feels native, not like an iframe. Data flows through the bridge.

### Flow 3: Pop Out ✅

```
User clicks pop out on an inline port
→ Port detaches from message stream
→ Port becomes a floating NSPanel window
→ User arranges it freely (position persists across restart)
→ Multiple ports each get their own window
→ Port persists while user keeps chatting
```

Target: One click from inline to floating window. Feels like native macOS.

### Flow 4: Port Lifecycle (partial)

```
Inline port lives in the message — scroll past it, scroll back, it's there  ✅
→ Popped-out port persists until closed  ✅
→ Companion can send an updated port (new version replaces inline)
→ User can ask companion to modify a running port  ✅
→ Close a port — collapsed back to a code block preview
→ Port history — browse and reopen any previous port
→ Ports survive app restart  ✅ (verify not broken)
→ Stop button kills a running port
→ Restart button re-executes from scratch
```

Target: Ports are ephemeral by default. Easy to create, easy to dismiss, recoverable from history.

### Flow 10: Port Windowing (partial) ✅

```
User pops out a port
→ Port appears as a native floating window (NSPanel)               ✅
→ User arranges freely, position/size persists across restart       ✅
→ Pin button keeps port always-on-top                               ✅
→ Minimize sends to background (listed in sidebar, click restores)  ✅
→ Granted permissions persist across restart                        ✅
→ Multiple ports from same companion each get their own window      ✅
→ Manual arrangement (users tile windows freely)                    ✅
→ Startup maximized, restore positions after sign-in                pending (P-239)
→ Window sets per channel/swim context                              future (P-240)
```

Target: Port windowing feels like macOS window management. Free-form arrangement now, edge snapping next.

### Flow 5: Port with AI Inside ✅

```
Port calls port42.ai.complete() through the bridge
→ The port itself becomes generative
→ A todo app that auto-organizes
→ A dashboard that narrates what it's showing
→ A port that spawns other ports
```

Target: Ports are not just interactive, they are intelligent.

### Flow 6: Terminal Port ✅

```
Companion creates a terminal port
→ Port renders a live shell (xterm.js or equivalent)
→ Companion runs commands, streams output in real time
→ User sees exactly what's happening
→ Companion reasons about output with Bridge AI
→ "Run the tests, if they fail, fix it, run again"
```

Target: The gap between "here's a command to try" and actually running it disappears.

### Flow 7: Sensory Port ✅

```
Port requests camera/mic/screen access  ✅
→ User approves via permission prompt (same pattern as AI calls)  ✅
→ Port captures image/audio/screen  ✅
→ Companion analyzes via Bridge AI  ✅
→ "Show me what's on your screen" just works  ✅
→ "Read this document to me" just works  ✅
```

Target: Every device capability becomes a companion capability. No separate apps.

### Flow 9: Agent From Any Website

```
User is on posthog.com and sees "Add to Port42" button
→ Clicks it, Port42 opens with install dialog
→ Shows agent name, icon, what it can do, what permissions it needs
→ User approves, picks a channel
→ PostHog's AI agent appears in that channel alongside local companions
→ User asks @PostHog "what's our retention this week?"
→ Agent processes on PostHog's servers, responds inside Port42
→ Agent creates a port with a live retention chart
→ Agent runs on PostHog's infrastructure, UI runs in Port42
```

Target: Any website can make their AI agent available to Port42 users with a button and a JSON manifest. No infrastructure changes for the third party. The agent's backend stays where it is.

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
| P-202 | ~~Docking~~ Removed. Replaced by free-form window arrangement with position persistence. | ❌ Removed |
| P-203 | Port Persistence (channel switch + app restart, SQLite v11-v14). Window position, size, always-on-top, and granted permissions all persist across restart. | ✅ Done |
| P-204 | Port Update (same message replaces existing panel, preserves position and state) | ✅ Done |
| P-205 | Port Close (floating) | ✅ Done |

**Port Lifecycle:**

| ID | Feature | Description | Priority | Done When |
|----|---------|-------------|----------|-----------|
| P-241 | Inline Port Compact Block | Inline ports in the message stream render as a compact block (icon + title) rather than a full-width live webview. Click to expand inline or pop out. Reduces visual noise when scrolling through chat. Currently still rendering full webviews inline. | High | Inline port shows as a small titled block, not a full webview |
| P-211 | Inline Port Update | Companion sends updated port that replaces the existing inline port in the same message, not a new message. Running popped-out version also updates. | High | "Change the chart to weekly" updates the live port in place |
| P-209 | Port Channel Context | Ports pin to origin channel by default. `port42.channel.follow(true/false)` lets port choose. Affects what `port42.channel.current()` and `port42.messages.recent()` return. | High | Port has predictable channel context when user navigates away |
| P-219 | Port History | Browseable list of all ports created in this session and past sessions. Reopen any port from history without scrolling through chat. Accessible from sidebar or command palette. Each port history entry stores: creating companion, creating prompt (the user message that triggered it), HTML snapshot, and timestamp. Multiple companions overwriting a port is a problem: if companion A creates a port and companion B calls `port_update` on the same port, the HTML is silently replaced with no record of what it was. History should be per-author per-version (like git log). Needs a `port_get_html(id)` tool so companions can read the current HTML of an existing port before deciding to update it (see P-263). | High | User can find and reopen any previous port; overwrite history is preserved per companion |
| P-220 | Port Controls | Stop button (kill running port), running indicator (green dot), restart button (re-execute from scratch). Visible in port title bar. | High | ✅ Done |
| P-242 | Port Title Attribution | Port title bar shows the port name (from `<title>` tag) and the companion that created it (e.g. "channel pulse · engineer"). Applies to inline blocks, floating panels, and background port list. | High | User can see at a glance what a port is and who made it |
| P-221 | Port Restart Persistence | Verify and fix ports surviving app restart (P-203 may be broken). Port HTML and state restored on launch. | High | Ports reappear after quit and relaunch |
| P-260 | Permission Persistence per Companion+Channel | Granted permissions are currently stored per port instance (messageId). Close a port, reopen it, and every permission is re-prompted. **Fix applied (2026-03-20):** On grant, permissions are saved to UserDefaults keyed by `portPerms.{createdBy}.{channelId}`. On bridge init, companion-level permissions are auto-restored via `formUnion` alongside message-level cache. No prompt shown on auto-restore. Denial not persisted (stays opt-in). | High | ✅ Fixed |
| P-261 | Permission Attribution | The permission dialog currently says "This port wants to access your terminal." It should say which companion is asking. **Fix applied (2026-03-20):** `PortPermissionOverlay` now accepts `createdBy: String?` and shows the companion name in accent color above the permission title. Fixed in both inline port path (ChatView) and floating panel path (PortWindowManager). `createdBy` made public on PortBridge. Verified in production. | High | ✅ Fixed |
| P-262 | Multi-Companion Port Activity | When multiple companions are simultaneously creating or updating ports, the user sees all of them listed: "engineer is building a port... analyst is updating dashboard..." Each active port-creation shows the companion name, a preview of what's being built (port title from the streaming fence if available), and progress state (streaming / rendering / ready). Visible in a small overlay or the sidebar's port section. | Medium | User sees all companions actively building ports at once |
| P-263 | Port HTML Retrieval API | Companions can read the current HTML of an existing port via `port_get_html(id)` tool and `port42.port.html()` bridge method. This lets a companion inspect what's already rendered before deciding to update it. Without this, a companion updating a port is writing blind — it may overwrite work from another companion or miss state it should preserve. Also needed for the version history re-generation flow. | High | Companion can read existing port HTML before updating it |
| P-264 | Media Capture Visibility in Chat | When a companion calls a capture API (screen.capture, camera.capture, audio.capture) the result should appear inline in the chat thread — not just get returned to the companion silently. The image/audio should be shown as a message bubble attributed to the companion ("engineer captured your screen"), same visual weight as a regular message. Additionally the capture should be saved to disk (e.g. `~/Library/Application Support/Port42/captures/`) and recorded in a DB table so the user can find them later. Applies to: screen captures, camera frames, audio recordings. Does not apply to streaming camera frames or headless browser screenshots (too high frequency). | High | Companion calls screen.capture, image appears in chat and is saved to disk |

**Bugs:**

| ID | Feature | Description | Priority | Status |
|----|---------|-------------|----------|--------|
| P-222 | Terminal Resize | Terminal ports don't observe viewport resize events. Viewport JS injected into panel webviews. | Critical | ✅ Fixed |
| P-223 | Resize Permission Re-trigger | Resizing a port re-triggers the permission dialog. Fixed: `@State` + `onReceive` pattern replaces computed Binding. | Critical | ✅ Fixed |
| P-224 | Permission Dialog Timing | `@Published` fires in `willSet`, causing cascaded publisher chains to read stale values. Fixed by checking `bridge != nil` instead of `bridge?.pendingPermission != nil`. | Critical | ✅ Fixed |
| P-225 | Floating Panel Permission | `confirmationDialog` requires key window. Fixed by calling `bringToFront()` when permission requested. | Critical | ✅ Fixed |
| P-226 | Docked Panel Permission | `DockedPortView` used `onChange` instead of `onReceive`. Fixed. (Moot now, docking removed.) | Critical | ✅ Fixed |
| P-227 | Permission Persistence | Granted permissions lost on restart. Fixed: permissions stored in `port_panels` DB table (v14 migration). | Critical | ✅ Fixed |
| P-228 | Title Bar Buttons | `PortDragNSView.mouseDown` consumed all clicks, preventing button actions. Fixed: drag area restricted to title region only, not behind buttons. | Critical | ✅ Fixed |
| B-001 | terminal_send Companion Tool Not Delivering | **Steps:** Launch Claude Code in a terminal port. Use companion-side `terminal_send` tool to push a prompt. Message does not arrive in the PTY session. **Root cause:** Terminal sessions are owned by `PortBridge` instances (one per webview). The companion-side `terminal_send` tool has no way to look up which bridge owns a session — there is no shared registry on AppState. `terminal.send()` from within the same port (JS side) works because it calls into the owning bridge directly. **Fix applied (2026-03-20):** `terminal_send` now uses port UDID as primary key via `PortWindowManager.findPort(by:)`, which already does UDID-first lookup. `ports_list` now returns `capabilities: ["terminal"]` instead of `hasTerminal: bool`. Companion system prompt updated with UDID workflow. Verified: echo hello sends correctly. | Critical | ✅ Fixed |
| B-002 | fs.pick() Never Opens NSOpenPanel | **Steps:** Call `port42.fs.pick()` from any port. The permission dialog may or may not appear, but NSOpenPanel/NSSavePanel never opens. The promise hangs silently — no error thrown, no result returned. **Impact:** Any port with file import/export is broken. Markdown editors, CSV importers, export tools. **Workaround:** Use companion-side `terminal_exec` to read/write files, pass content via `port42.storage`. **Likely cause:** `fs.pick()` may be waiting on a main-thread dispatch that is deadlocking, or the panel's sheet parent window is nil. Needs investigation in `PortBridge.swift` file system handler. | Critical | File picker opens and returns selected paths |
| B-003 | Only First Port Block Per Message Opens | **Steps:** Ask a companion to create two terminal ports in one message. Companion returns two ` ```port ` fences. Only the first opens. **Root cause:** `portContent: String?` called `content.range(of: "```port")` which returns the first match only. **Fix applied (2026-03-20):** Replaced `portContent/textBeforePort/textAfterPort` with `messageSegments: [MessageSegment]` (enum: `.text(String)` or `.port(String)`). `MessageRow` now iterates segments via `ForEach`, renders each port block independently with its own activation state (`activatedPortIndices: Set<Int>`). Port IDs are `entry.id` for first port, `entry.id + "-p\(n)"` for subsequent ones (backwards compatible). | Medium | ✅ Fixed |
| B-004 | Capabilities Metadata Not Visible in Companion Tool Responses | **Steps:** Ask companion to list ports. Companion calls `ports_list()` — data returned includes `capabilities: ["terminal"]` correctly. But companion formats as a markdown table, drops the array column, and presents only title/creator/status. **Root cause:** Raw JSON return — companion reformats freely and strips structured fields. **Fix applied (2026-03-20):** `ports_list` now returns pre-formatted labelled text (title/id/capabilities/status/createdBy per port) instead of raw JSON. Companions pass through labelled fields rather than reformatting. Tool description and ports-context.txt also updated with explicit instruction to preserve id and capabilities. | Low | ✅ Fixed |

**Port Windowing System:**

| ID | Feature | Description | Priority | Done When |
|----|---------|-------------|----------|-----------|
| P-230 | ~~Edge Snap~~ | Removed. Replaced by manual window arrangement. Smart tiling (grid snap, edge snap, auto-arrange) deferred to future phase. | ~~Critical~~ | ❌ N/A |
| P-231 | ~~Screen Edge Snap~~ | Removed. See P-230. | ~~High~~ | ❌ N/A |
| P-232 | ~~Multi-Port Tiling~~ | Removed. See P-230. | ~~High~~ | ❌ N/A |
| P-239 | Startup Window Behavior | Main window fills screen on launch. After sign-in, main window and port panels restore to saved positions/sizes. | High | ✅ Done |
| P-240 | Window Sets | Ports associate with channel/swim context. Switching context shows/hides relevant ports. Supersedes P-404 Port Spaces with a grounded design. | Medium | Switch channel, see that channel's ports |
| P-233 | Always-on-Top | Port can be pinned to float above all other content (including chat). Toggle in port title bar. Persists across restart. | Medium | ✅ Done |
| P-234 | Background Ports | Minimize to background (hidden but running). Listed in sidebar. Click to restore as floating window. Persists across restart. | Medium | ✅ Done |
| P-235 | ~~Snap Restore~~ | Superseded. With docking removed, ports are always free-form floating windows with position persistence. | ~~High~~ | ❌ N/A |
| P-236 | Port Chrome | Title bar with pin, minimize, close buttons. 24x24 hit targets. Drag area restricted to title region. Source/Run toggle. | Medium | ✅ Done |
| P-237 | Window Position Persistence | Port window position and size saved on move/resize (NSWindow notifications). Restored exactly on restart. DB migration v13. | Critical | ✅ Done |
| P-238 | Per-Message Port Identity | Ports identified by messageId, not createdBy+channelId. Multiple ports from same companion each get their own window. | High | ✅ Done |

**Events:**

| ID | Feature | Description | Priority | Done When |
|----|---------|-------------|----------|-----------|
| P-212 | ~~Event: port.docked~~ | Removed (docking removed). | ~~Medium~~ | ❌ N/A |
| P-213 | ~~Event: port.undocked~~ | Removed (docking removed). | ~~Medium~~ | ❌ N/A |
| P-214 | Event: channel.switch | Fires when user navigates to different channel `{ id, name, previousId }` | Medium | `port42.on('channel.switch', cb)` fires |
| P-215 | Event: companion.joined | Fires when companion enters channel `{ id, name }` | Low | `port42.on('companion.joined', cb)` fires |
| P-216 | Event: companion.left | Fires when companion leaves channel `{ id, name }` | Low | `port42.on('companion.left', cb)` fires |
| P-217 | Event: presence | Online status changes `{ online: [names] }` | Low | `port42.on('presence', cb)` fires |

**Polish:**

| ID | Feature | Description | Priority | Done When |
|----|---------|-------------|----------|-----------|
| P-207 | Cursor States | Green circle default, resizeLeftRight on dock divider, no hand cursor on title bars or drag areas. WKWebView uses its own CSS cursors. | Medium | No stray hand cursors |
| P-208 | Port UDIDs | Stable unique ID per port. Persists across dock/undock/restart. Accessible via `port42.port.info().id` and `port42.ports.list()`. | Medium | Every port has a stable ID |
| P-218 | Port Resize Handles | User can drag to resize inline and docked ports. Resize handles on edges/corners. Height clamp still applies for inline. | Medium | ✅ Done |

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
| P-400 | Port Window Management | `port42.ports.list/close/arrange/resize/position` + lifecycle events. Enables "commander" ports that manage other ports and retile layouts. | High | A port can query and rearrange other ports |
| P-404 | ~~Port Spaces~~ | Superseded by P-240 Window Sets. Instead of a virtual canvas, ports associate with channel/swim context. Switching context shows/hides ports. Grounded in actual usage patterns rather than abstract spatial metaphor. | ~~Medium~~ | ❌ Superseded |
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
| P-509 | Browser (Headless) | `port42.browser.*` — headless WKWebView sessions. Open, navigate, capture screenshots, extract text/HTML, execute JS, close. Max 5 concurrent sessions. Non-persistent data stores. `.browser` permission. | High | ✅ Done |
| P-512 | Named Terminals | Terminal sessions can be registered with a name (e.g. "claude-code"). Any companion or port can send input to a named terminal via `terminal_send(name, data)`. Enables companions to push prompts into a running Claude Code session from chat. Sessions stored in a shared registry on AppState, accessible from both ports (JS) and tool use (conversation). | High | Pending |
| P-513 | Terminal Output Bridge | Terminal output from a named session is parsed, ANSI-stripped, and meaningful content is posted to the channel as system messages. Companions can react to what Claude Code is doing without copy-pasting. Signal extractor filters TUI chrome (cursor moves, redraws) and surfaces file edits, tool calls, completions, and response text. | High | Pending |
| P-510 | Browser (Visible) | `port42.browser.open(url, { visible: true })` opens a navigable WKWebView panel (no sandbox, no CSP). User can browse and interact with the page directly. Companion can still observe/control via bridge (screenshot, extract, navigate, execute JS). Shared cookie/session state between visible and headless sessions. | High | Pending |
| P-511 | Browser Auth / OAuth | Shared authentication system for browser sessions. User authenticates once (Google, Microsoft, Slack, GitHub, etc.) and sessions share that auth state. OAuth flow management with token storage in Keychain. Companions can request auth for specific services. | High | Pending |

### Phase 6: System Integration APIs

| ID | Feature | Description | Priority | Done When |
|----|---------|-------------|----------|-----------|
| P-601 | Automation | `port42.automation.runAppleScript(source, opts?)` / `.runJXA(source, opts?)` — execute AppleScript or JXA. Control other apps, get Safari tabs, move Finder windows, trigger system actions. Returns script output. `.automation` permission. Timeout default 30s, max 120s. | Critical | ✅ Done |
| P-603 | Accessibility | `port42.accessibility.windows()` / `.elements(pid, query?)` / `.click(pid, element)` / `.type(pid, text)` — read and interact with other apps' UI via Accessibility API (AXUIElement). `.accessibility` permission. | Critical | Companion can see and interact with any app's UI |
| P-606 | Spotlight | `port42.spotlight.search(query, opts?)` — search files by content or metadata via NSMetadataQuery. opts: `{ types?, folders?, limit? }`. Returns file paths, names, metadata. No file permission needed for metadata; reading content requires fs.pick flow. | High | Companion can find files without browsing |
| P-605 | Calendar | `port42.calendar.events(range?)` / `.reminders()` / `.create(event)` — read/write calendar events and reminders via EventKit. `.calendar` permission. | High | Port can show schedule, create events, manage reminders |
| P-607 | File Watching | `port42.fs.watch(path, callback)` / `.unwatch(watchId)` — monitor directories for changes via FSEvents. Callback receives `{ path, type: 'created'\|'modified'\|'deleted' }`. Requires filesystem permission. | High | Port reacts to file changes in real time |
| P-600 | System Info | `port42.system.info()` — battery level/charging, CPU usage, memory pressure, disk space, network interfaces. `port42.system.on('battery', cb)` for live updates. Lightweight IOKit/sysctl queries. No permission needed. | Medium | Port can build system monitoring dashboards |
| P-602 | Shortcuts | `port42.shortcuts.list()` / `.run(name, input?)` — list and trigger the user's Shortcuts. Input/output passed as JSON. `.shortcuts` permission. | Medium | Port can trigger user's existing workflows |
| P-609 | Drag and Drop | `port42.port.on('drop', cb)` — accept drag-and-drop from other apps into a port. Callback receives `{ files: [{path, name, type}], text? }`. Requires filesystem permission for file access. | Medium | User can drag files from Finder into a port |
| P-604 | Contacts | `port42.contacts.search(query)` / `.get(id)` — read contacts via CNContactStore. Returns name, email, phone, etc. `.contacts` permission. | Low | Port has personal context for communication tools |
| P-503 | Camera | `port42.camera.capture(opts?)` / `.stream(opts?)` / `.stopStream()` — single frame or continuous feed via AVCaptureSession. Returns base64 PNG. `.camera` permission. | Low | ✅ Done |
| P-508 | Location | `port42.location.get()` — current coordinates with permission via CoreLocation. `.location` permission. | Low | Port knows where the user is |
| P-610 | Native Pickers | `port42.picker.color()` / `.date(opts?)` / `.font()` — present native macOS picker dialogs. Returns selected value. No permission needed. | Low | Port uses native UI for color/date/font selection |
| P-608 | Bluetooth | `port42.bluetooth.scan(opts?)` / `.connect(id)` / `.send(id, data)` / `.on('data', cb)` — scan, connect, and communicate with BLE peripherals via CoreBluetooth. `.bluetooth` permission. | Low | Port can interact with hardware devices |
| P-611 | USB/Serial | `port42.serial.list()` / `.open(port, opts?)` / `.send(id, data)` / `.on('data', cb)` / `.close(id)` — communicate with USB serial devices via IOKit. opts: `{ baudRate?, dataBits?, parity? }`. `.serial` permission. | Low | Port can talk to Arduino, lab equipment, etc |

### Phase 7: Port Lifecycle

| ID | Feature | Description | Priority | Done When |
|----|---------|-------------|----------|-----------|
| P-700 | Port Update | `port_update(id, html)` tool. Companions update an existing port's HTML by UDID or title. Works for windowed and minimized ports. `ports_list()` tool for discovery. No fence syntax change. | Critical | Companion updates a port in place without creating a new one |
| P-701 | Port UDIDs | Every port gets a stable UUID on creation. Persisted in DB. Accessible via `port42.port.info().id` from JS and `ports_list` from tool use. Migration backfills existing ports. | Critical | Every port has a stable identity across its lifecycle |
| P-702 | Daemon Ports | Ports that run continuously in the background without being manually opened. Start on app launch, run on a schedule, or trigger on events. A companion can create a daemon port that monitors a URL, polls an API, watches a directory, or runs periodic tasks. Survives app restart. Managed via `port42.daemon.create(opts)` / `.list()` / `.stop(id)`. | High | A port runs a background task that persists across restarts without user intervention |
| P-703 | Scheduled Ports | Extension of daemon ports with cron-like scheduling. `port42.daemon.create({ schedule: "*/5 * * * *", html: "..." })` runs a port every 5 minutes. The port executes, does its work (fetch data, send notification, update storage), then sleeps until next run. Lightweight alternative to always-on background ports. | Medium | A port runs on a schedule like a cron job |

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

23 methods across 10 namespaces. All async, all return JSON.

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
  .html()                         → current HTML of this port (P-263, pending)
  .close()                        → close this port
  .resize(w, h)                   → resize this port

port42.on(event, callback)        → subscribe to live events
port42.connection
  .status()                       → 'connected' | 'disconnected'
  .onStatusChange(callback)       → fires on transition

port42.automation                 🔒 Automation permission
  .runAppleScript(source, opts?)  → { result } | { error }
  .runJXA(source, opts?)          → { result } | { error }
                                    opts: { timeout? } (default 30s, max 120s)

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

**Known gaps:** Permissions reset every time a port is closed and reopened — there is no persistence per companion+channel (P-260). The permission dialog does not name the requesting companion (P-261).

```
Implemented:
  .ai          → gates ai.complete, ai.cancel, companions.invoke

Implemented:
  .terminal    → gates terminal.spawn, terminal.send, terminal.kill
  .microphone  → gates audio.capture
  .camera      → gates camera.capture, camera.stream
  .screen      → gates screen.capture
  .clipboard   → gates clipboard.read, clipboard.write
  .filesystem  → gates fs.read, fs.write, fs.pick
  .browser     → gates browser.open, browser.navigate, browser.capture, browser.text, browser.html, browser.execute, browser.close
  .automation  → gates automation.runAppleScript, automation.runJXA
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
  .list()                → [{ id, title, channelId, createdBy, isBackground, isAlwaysOnTop, size, position }]
  .minimize(id)          → send a port to background
  .restore(id)           → restore a background port to floating
  .close(id)             → close a port
  .arrange(layout)       → retile floating ports (grid, stack, focus, cascade)
```

Enables "commander" ports that manage other ports. Prior art: CLI/gateway era
window tracker + "window commander" tool for dynamic terminal retiling.

### ~~P-404: Port Spaces~~ → Superseded by P-240: Window Sets

The virtual canvas concept is superseded by **Window Sets** (P-240), which ties
port visibility to the channel or swim context. When you switch channels, the
ports associated with that channel appear and others hide. This is grounded in
how people actually use Port42 rather than introducing a new spatial metaphor.

Future API (P-240):

```
port42.windowSet
  .current()             → { contextId, contextType, ports: [portId] }
  .list()                → [{ contextId, contextType, ports: [portId] }]
```

~~Original P-404 spec preserved for reference:~~

~~Virtual canvas that extends beyond the physical screen. The app becomes a
viewport into a larger workspace. Zoom out to see all ports at once (bird's
eye), zoom in to focus on one. Named spaces group ports by context, like
"coding" (terminal + docs + debugger) vs "social" (dashboards + chat).~~

~~Native implementation: NSScrollView or custom pan/zoom layer hosting all
port panels. Spaces are saved layouts with port positions and sizes.
Switching spaces shows/hides the relevant set of ports. Keyboard shortcut
for space switching (Ctrl+1/2/3 like macOS).~~

### P-500: Terminal✅

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

### P-512: Named Terminals

```
port42.terminal
  .spawn(opts?)              → { sessionId } — opts gains `name?` field
                               name: "claude-code" — registers in shared registry
  .list()                    → [{ sessionId, name?, pid, isRunning }]
  .send(name, data)          → send stdin by name (not just sessionId)
  .get(name)                 → { sessionId, pid, isRunning } — lookup by name
```

Terminal sessions move from per-PortBridge to a shared registry on AppState.
Any companion or port can interact with any named terminal. This enables:

- Port spawns Claude Code terminal, registers as "claude-code"
- Companion in chat calls `terminal_send(name: "claude-code", data: "fix the auth bug\n")`
- Claude Code receives the prompt and starts working
- Another companion watching the output can react

Tool use additions:
- `terminal_send` — send data to a named terminal session
- `terminal_list` — list all active terminal sessions
- `terminal_get` — get session info by name

### P-513: Terminal Output Bridge

```
port42.terminal
  .bridge(sessionId, opts?)  → start bridging output to channel
                               opts: { channelId?, filter?: "smart"|"all"|"none" }
  .unbridge(sessionId)       → stop bridging
```

Two streams:

**Terminal → Channel:**
1. Raw PTY output passes through an ANSI stripper (remove escape sequences,
   cursor movements, color codes, screen redraws)
2. Signal extractor identifies meaningful content:
   - File edits: "wrote Sources/Port42Lib/..." → post to channel
   - Tool calls: "Running terminal command..." → post to channel
   - Response text: the actual assistant response → post to channel
   - Filters out: thinking indicators, progress bars, TUI chrome
3. Extracted signals posted to channel as system messages with terminal attribution

**Channel → Terminal:**
Already works via `terminal.send()` / `terminal_send` tool. Companions or
humans type in the channel, message routes to the terminal's stdin.

Works with any CLI tool, not just Claude Code. A `npm run dev` terminal
bridges build output to the channel. A `docker logs -f` terminal surfaces
container events. A `vim` session lets companions see what you're editing.

Filter modes:
- **all**: post every non-empty line (after ANSI strip)
- **smart** (default): debounce rapid output, skip repeated lines,
  collapse progress bars, surface state changes
- **none**: no bridging, manual only via tool use

Claude Code specific patterns (auto-detected when process is `claude`):
- Lines starting with `⏺` are tool headers
- Lines between `⎿` markers are tool output
- Markdown-formatted text blocks are the response
- ANSI color sequences indicate status (green = success, red = error)

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

### P-503: Camera ✅ Done

```
port42.camera
  .capture(opts?)            → { image, width, height } base64 PNG
                               opts: { scale?: 0.5 }
  .stream(opts?)             → { ok: true } start continuous feed
                               opts: { scale?: 0.25 }
  .stopStream()              → { ok: true }
  .on('frame', cb)           → { image, width, height }
```

Implementation: CameraBridge.swift with FrameHandler delegate class.
AVCaptureSession with .high preset. Single frame capture via continuation
(start session, grab first frame, stop). Continuous streaming pushes
camera.frame events to JS. Scale factor controls output resolution
(lower for streaming performance). FrameHandler runs on background queue,
dispatches results to MainActor for bridge event pushing.

Permission: `.camera` gates all camera methods. macOS camera TCC prompt
on first use. 4 tests passing.

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

### P-505: Clipboard✅

```
port42.clipboard
  .read()                    → { text?, html?, image? }
  .write(data)               → write to clipboard
                               data: { text?, html?, image? }
  .on('change', cb)          → clipboard changed notification
```

### P-506: File System✅

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

### P-509: Browser ✅ Done

```
port42.browser
  .open(url, opts?)            → { sessionId, url, title }
                                 opts: { width?, height?, userAgent? }
  .navigate(sessionId, url)    → { url, title }
  .capture(sessionId, opts?)   → { image, width, height } base64 PNG
                                 opts: { region? }
  .text(sessionId, opts?)      → { text, title, url }
                                 opts: { selector? }
  .html(sessionId, opts?)      → { html, title, url }
                                 opts: { selector? }
  .execute(sessionId, js)      → { result }
  .close(sessionId)            → { ok: true }
  .on('load', cb)              → { sessionId, url, title }
  .on('error', cb)             → { sessionId, url, error }
  .on('redirect', cb)          → { sessionId, url }
```

Implementation: BrowserBridge.swift with BrowserSession inner class.
Separate WKWebView per session (not the port's own webview). Max 5
concurrent sessions per port. Non-persistent data stores (no shared
cookies). URL validation (http/https/data only). Text truncated at
500KB, HTML at 1MB. 30s navigation timeout. Sessions cleaned up on
port close.

Permission: `.browser` gates all browser methods. "This port wants to
browse the web." Combined with Bridge AI, a companion can research
topics, read documentation, and extract information autonomously.

UX pattern: iframes don't work for most sites (X-Frame-Options/CSP).
Use headless browser.capture() screenshots as the visual preview instead.

---

### P-600: System Info

```
port42.system
  .info()                        → { battery, cpu, memory, disk, network }
  .on('battery', cb)             → { level, charging, timeRemaining }
```

battery: `{ level: 0-100, charging: bool, timeRemaining: minutes }`.
cpu: `{ usage: 0-100, cores, model }`.
memory: `{ total, used, available, pressure: 'nominal'|'warn'|'critical' }`.
disk: `{ total, used, available }` in bytes.
network: `[{ name, type: 'wifi'|'ethernet'|'vpn', ip, active }]`.

Native side: IOKit for battery, sysctl/host_statistics for CPU/memory,
statvfs for disk, getifaddrs for network. Lightweight, no permission needed.

---

### P-601: Automation (AppleScript/JXA) ✅ Done

```
port42.automation
  .runAppleScript(source, opts?) → { result } | { error }
  .runJXA(source, opts?)         → { result } | { error }
                                   opts: { timeout? } (default 30s, max 120s)
```

Two separate methods for AppleScript and JXA. AppleScript executes via
NSAppleScript on a background thread. JXA executes via `/usr/bin/osascript -l JavaScript`.
Both return script output as a string or an error dict.

Implementation: AutomationBridge.swift. Stateless bridge (no persistent resources,
no cleanup needed in deinit). ContinuationGuard ensures thread-safe single resume
for timeout races. Timeout clamped to 1...120s.

Permission: `.automation` — "This port wants to control other apps on your Mac
using automation scripts. It can send commands to Finder, Mail, and other
scriptable applications. Allow?"

Entitlements: `com.apple.security.automation.apple-events` (dev + release).
Info.plist: `NSAppleEventsUsageDescription` for macOS TCC prompt.

This is the most powerful API. A companion can:
- Get list of open Safari tabs and their URLs
- Move and resize windows
- Control Music.app playback
- Read/write from apps that support AppleScript
- Chain with browser.text or ai.complete for research workflows

Security: each script execution requires the port to already have
.automation permission. macOS may also show its own TCC prompt for
specific app targets (e.g. "Port42 wants to control Safari").

7 tests passing (permission mapping, description, timeout clamping, error handling).

---

### P-603: Accessibility

```
port42.accessibility
  .windows()                     → [{ pid, app, title, bounds }]
  .elements(pid, query?)         → [{ role, title, value, bounds, id }]
  .click(pid, elementId)         → { ok: true }
  .type(pid, text)               → { ok: true }
  .getAttribute(pid, elementId, attr) → value
```

Read and interact with any app's UI via the macOS Accessibility API.
query can filter by role ("AXButton"), title, or subrole.

Permission: `.accessibility` — "This port wants to read and interact
with other applications' interfaces. Allow?" Also requires macOS
Accessibility permission in System Settings.

Combined with screen capture and AI vision, a companion can see what's
on screen, understand the UI, and take actions. Full GUI automation.

---

### P-606: Spotlight

```
port42.spotlight
  .search(query, opts?)          → [{ path, name, type, size, modified, snippet? }]
                                   opts: { types?, folders?, limit? }
```

Search files by content or metadata via NSMetadataQuery. Returns file
metadata (path, name, content type, size, modification date). Optional
content snippet when searching by text content.

types: array of UTIs or extensions (e.g. ['public.image', 'swift']).
folders: array of paths to scope the search.
limit: max results (default 50).

No permission needed for metadata search. Reading file contents still
requires the fs.pick flow.

---

### P-607: File Watching

```
port42.fs
  .watch(path, callback)         → { watchId }
  .unwatch(watchId)              → { ok: true }
```

Monitor a directory for changes via FSEvents. Callback receives
`{ path, type: 'created'|'modified'|'deleted' }`. Only watches
paths previously granted via fs.pick. Requires filesystem permission.

Use cases: hot-reload ports, build watchers, log tailers.

---

## Phase 7: Agent Embed Protocol

External agents from any website can connect into Port42 through the front door. A site like PostHog, Linear, or Vercel installs a button/snippet on their platform. When a Port42 user clicks it, that site's AI agent loads into Port42 as a companion inside a port. The agent's backend stays where it is. No migration, no infrastructure changes for the third party.

This is different from OpenClaw (where the user configures a channel adapter manually) and different from P-310 (where remote agents learn to create ports). This is one-click agent installation from any website into Port42.

### Feature Registry

| ID | Feature | Description | Priority | Done When |
|----|---------|-------------|----------|-----------|
| P-700 | Agent Embed Protocol | Wire protocol for external agents to connect through Port42's gateway. Agent declares its capabilities, endpoint, and identity. Port42 routes messages and bridge calls. The agent's backend handles its own LLM calls and logic. Port42 provides the UI surface (port) and the user's context. | Critical | External agent sends messages and creates ports inside Port42 |
| P-701 | Embed Button / Snippet | JavaScript snippet or `<port42-connect>` web component that sites install. Shows a "Connect to Port42" button. On click, opens `port42://agent-embed?...` deep link or OAuth-style redirect that registers the agent in the user's Port42 instance. | Critical | User clicks button on posthog.com, PostHog agent appears in Port42 |
| P-702 | Agent Manifest | JSON manifest that describes an embeddable agent: name, icon, description, endpoint URL, capabilities (can create ports, needs terminal, etc.), auth requirements. Hosted at a well-known URL on the third party's site (e.g. `/.well-known/port42-agent.json`). | High | Port42 reads manifest and shows agent info before install |
| P-703 | Agent Registry UI | In-app view for managing connected external agents. See which agents are installed, which channels they're in, revoke access, view activity. | High | User can see and manage all external agents |
| P-704 | Agent Sandbox | Permission and capability scoping for external agents. External agents get a restricted permission set by default (no terminal, no automation, no filesystem unless user explicitly grants). Separate trust level from local companions. | High | External agent cannot access terminal without explicit user grant |
| P-705 | Agent Discovery | Optional public directory where developers can list their Port42-compatible agents. Users browse and one-click install. Like a lightweight app store for agents. | Medium | User finds and installs agents from a catalog |
| P-706 | Agent Auth | OAuth2 or token-based auth between Port42 and the external agent's backend. The agent endpoint needs to verify requests come from an authorized Port42 instance. Port42 needs to verify the agent is who it claims to be. | High | Mutual authentication between Port42 and external agent |
| P-707 | Agent Billing Bridge | Protocol for external agents to communicate usage/billing back to their platform. PostHog's agent uses PostHog's API quota, not Port42's. The agent owns its own costs. | Medium | External agent's usage is billed to the agent provider, not the Port42 user |

---

### P-700: Agent Embed Protocol

The core wire protocol. An external agent connects to Port42's gateway as a special peer type.

```
Agent Backend (PostHog's servers)
    ↕ HTTPS/WebSocket
Port42 Gateway
    ↕ existing sync protocol
Port42 App
    ↕ bridge API
Port (agent's UI surface)
```

The external agent's backend:
- Receives messages from channels it's been added to
- Sends responses (text, ports, rich content)
- Handles its own LLM inference, tool calls, and business logic
- Runs on the third party's infrastructure (no migration needed)

Port42 provides:
- The conversation context (messages, companions, user identity)
- The rendering surface (ports with full bridge API access)
- The permission layer (user controls what the agent can do)
- The social graph (the agent participates alongside local companions)

Key design principle: the agent's backend is opaque to Port42. Port42 doesn't care if it runs Claude, GPT, Llama, or a deterministic state machine. It just routes messages and renders ports.

---

### P-701: Embed Button

```html
<!-- On posthog.com -->
<script src="https://port42.ai/embed.js"></script>
<port42-connect
  agent="https://posthog.com/.well-known/port42-agent.json"
  label="Add to Port42"
/>
```

Clicking the button:
1. Reads the agent manifest from the `agent` URL
2. Opens `port42://agent-embed?manifest=<url>&callback=<url>` deep link
3. Port42 shows an install dialog with agent name, icon, capabilities, permissions requested
4. User approves, picks which channel(s) to add the agent to
5. Port42 registers the agent endpoint and opens a persistent connection
6. Callback URL receives a confirmation token

For users without Port42 installed, the button links to the download page.

---

### P-702: Agent Manifest

```json
{
  "name": "PostHog AI",
  "icon": "https://posthog.com/icon-256.png",
  "description": "Your PostHog data analyst. Ask about funnels, retention, and user behavior.",
  "endpoint": "wss://posthog.com/port42/agent",
  "capabilities": ["messages", "ports"],
  "permissions_requested": ["ai"],
  "auth": {
    "type": "oauth2",
    "authorize_url": "https://posthog.com/oauth/authorize",
    "token_url": "https://posthog.com/oauth/token",
    "scopes": ["read:insights", "read:events"]
  },
  "version": "1.0",
  "homepage": "https://posthog.com/port42"
}
```

---

### P-704: Agent Sandbox

External agents are untrusted by default. Separate trust tier from local companions.

| Capability | Local Companion | External Agent (default) | External Agent (granted) |
|---|---|---|---|
| Send messages | Yes | Yes | Yes |
| Create ports | Yes | Yes | Yes |
| AI (use Port42's LLM) | Prompted | No (uses own) | No (uses own) |
| Terminal | Prompted | Blocked | Prompted |
| Automation | Prompted | Blocked | Prompted |
| Filesystem | Prompted | Blocked | Prompted |
| Clipboard | Prompted | Blocked | Prompted |
| Screen | Prompted | Blocked | Prompted |
| Browser | Prompted | Yes | Yes |

External agents bring their own AI. They don't consume the user's Port42 API tokens. They can create ports and use the browser bridge (for rendering), but system-level capabilities require explicit user escalation.

---

## Future Features

### P-800: Share a Port

Share a live port with another Port42 user over an encrypted channel. The recipient sees the port rendered in their app, with full interactivity — not a screenshot, a live session.

**Sharing mechanisms:**

- **Channel share**: Post a port to a shared channel. All members see the live port inline in their message history, each with their own bridge context (independent JS runtime, shared port HTML/JS source).
- **Direct share link**: Generate a `port42://port?id=<udid>&channel=<id>` deep link. Recipient clicks it, port opens in their app. Works over ngrok for cross-machine sharing.
- **Clone to channel**: Recipient can pin a shared port to their own channel, creating their own independent instance seeded from the same HTML/JS source.

**API additions (in the port's JS runtime):**

```
port42.port
  .share(opts?)              → { link } — generate a shareable deep link
                               opts: { channelId? } — share into specific channel
  .clone()                   → { portId } — clone this port's source into a new port
```

**Native side:**

- Port HTML/JS source stored alongside the message in the database (already the case for generative ports)
- Sync service transmits port source as part of the message payload (E2E encrypted)
- Recipient's app reconstructs the port from source and loads it in a fresh WKWebView
- Each recipient gets an independent JS runtime — state is not shared, only the source

**Permission model:** sharing a port exposes its HTML/JS source to the recipient. No extra permission needed (the source is already visible to the user who created it). System-level bridge permissions (terminal, automation, etc.) are re-prompted for each new recipient's instance.

**Priority:** Medium. Enables collaborative port workflows and is the natural complement to channel sync.

---

## Proposals

These are ideas that are not yet specced into a phase. Candidates for Phase 8+.

### Proposal: Channel Working Directory

**Problem:** No way to anchor a channel to a project directory. Every terminal spawn, file operation, and tool call needs explicit absolute paths. Companions have no default context about where they're working.

**Proposed API:**
```js
await port42.channel.setCwd('/Users/gordon/Code/myapp');

// All subsequent operations inherit it:
const result = await port42.terminal.spawn();  // auto-cwd
const file = await port42.fs.read('src/index.ts');  // relative paths work
```

**Companion-side tool:** `channel_set_cwd(path)` / `channel_get_cwd()`.

**Benefits:** Terminal spawns default to project root. File operations accept relative paths. Companions have project context without being told every time. Persists per-channel via storage. Drag a directory into the Port42 window to set it.

---

### Proposal: Port-to-Port Pipelines

**Problem:** Ports are isolated. A dashboard and a terminal are fully isolated. No cross-port communication exists. You can't chain operations where one port's output feeds another's input.

**Workaround today (polling via shared storage):**
```js
// Port A (producer)
await port42.storage.set('pipe:step1', output, {shared: true});
// Port B (consumer)
setInterval(async () => {
  const data = await port42.storage.get('pipe:step2', {shared: true});
  if (data) render(data);
}, 500);
```

**Proposed first-class API:**
```js
const pipeline = port42.pipeline.create([
  { name: 'scraper',   html: scraperHTML },
  { name: 'analyzer',  html: analyzerHTML },
  { name: 'dashboard', html: dashboardHTML }
]);

// Inside each port — unix pipe semantics:
port42.pipeline.onInput((data) => {
  const result = transform(data);
  port42.pipeline.emit(result);  // feeds next stage
});
```

Unix pipes but for interactive UI stages. Each port is a transform node. Supports fan-out (one-to-many), merge (many-to-one), and conditional branching.

**Use cases:** scrape page → extract entities → visualize as graph. Mic input → transcription → sentiment analysis → live dashboard. CSV upload → clean → chart.

---

### Proposal: Native App Launcher API

**Problem:** Companions can generate files but can't open them in the right app. Write a markdown file, open it in Typora. Generate a diagram, open it in Preview. A CSV? Open in Numbers. Right now the human has to go find the file and double-click it.

**Proposed API:**
```js
port42.apps.open(path, {app: 'Typora'})     // open file in specific app
port42.apps.open(path)                       // open in default app
port42.apps.launch('com.typora.Typora')      // just launch an app
port42.apps.list()                           // list installed apps
```

**Companion-side tool:** `open_app(path, app?)` / `open_app(bundleId)`.

**This completes the file lifecycle:** generate (companion writes file) → open (companion opens in right app) → edit (human edits) → read back (companion reads updated file). Without step 2, there's a gap where the human navigates manually. That breaks the flow.

**Permission:** same model as other tools. First use prompts for approval. Path must already be approved or created by the companion.

---

### Proposal: Port Prompt Provenance

**Problem:** Ports are generated from user prompts, but the prompt that created a port is lost. You can't inspect a port and see what the user was trying to do or what the companion interpreted. Makes debugging, iterating, and sharing ports harder.

**Proposed change to `port42.port.info()`:**
```js
{
  messageId: '...',
  createdBy: 'engineer',
  channelId: '...',
  prompt: 'build me a terminal port that runs claude code',  // NEW
  systemContext: '...',  // optional: companion system prompt or relevant context
  createdAt: '2025-01-15T...',
  version: 1  // increments on port_update
}
```

**Every `port_update` also stores its prompt.** A port becomes a chain of prompts and resulting HTML. You can scrub through history like git commits.

**Benefits:** debugging (see exactly what generated a broken port), iteration ("regenerate this port" replays the prompt), sharing (export as prompt + HTML so others can regenerate or fork), learning (companions inspect past ports to improve).

