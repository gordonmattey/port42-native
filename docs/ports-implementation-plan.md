# Ports Implementation Plan

**Last updated:** 2026-03-13

**Constraint:** No breaking changes. All existing chat, swim, and sync
functionality must continue working at every step.

---

## Phase 1: Inline Ports (P-100 through P-109)

### Step 1: Port Detection and Static Render (P-100, P-101, P-109) ✅

**Goal:** Companion sends a ```port block, it renders as a live webview inline in chat.

**Files to create:**
- `Sources/Port42Lib/Views/PortView.swift` — SwiftUI wrapper around WKWebView

**Files to modify:**
- `Sources/Port42Lib/Views/ConversationContent.swift` — MessageRow checks for port content, renders PortView instead of Text

**What to build:**

1. Add `containsPort` and `portContent` computed properties on ChatEntry.
   Detects ```port code fences. Extracts HTML between fences.

2. Create `PortView` — SwiftUI view wrapping `WKWebView` via
   `NSViewRepresentable`. Takes raw HTML string. Wraps in full document
   with port42 base theme. Configures: no navigation, data-only content,
   auto-resize height via JS callback on document.body.scrollHeight.

3. In MessageRow, if `entry.containsPort`, render `PortView(html:)`
   instead of text content. Text before/after the fence renders normally.

4. Inject base theme CSS into the document wrapper:
   ```css
   body {
     margin: 0; padding: 12px;
     background: #111; color: #e0e0e0;
     font-family: "SF Mono", "Fira Code", monospace;
     font-size: 13px;
   }
   a { color: #00ff41; }
   ```

**Unit tests:**
- `testContainsPort` — ChatEntry with ```port fence returns true
- `testContainsPortNegative` — normal text returns false
- `testPortContentExtraction` — extracts HTML between fences correctly
- `testPortContentWithSurroundingText` — extracts port and preserves text before/after
- `testPartialFence` — incomplete fence returns false (no crash on streaming)

**User test:**
- Send a message manually containing a ```port block with a simple counter button
- Verify it renders inline as a live webview, button clicks work
- Verify normal text messages still render exactly as before
- Verify scrolling, message selection, typing indicators all unaffected

---

### Step 2: Bridge Core (P-102) ✅

**Goal:** Ports can call `port42.*` methods and get results back.

**Files to create:**
- `Sources/Port42Lib/Services/PortBridge.swift` — bridge handler, injector, event pusher

**What to build:**

1. `PortBridge` class holding reference to `AppState` and `WKWebView`.

2. **BridgeInjector:** WKUserScript (documentStart) defining `port42` JS namespace.
   Each method returns a Promise. Sends via
   `window.webkit.messageHandlers.port42.postMessage({method, args, callId})`.
   Native resolves via `webview.evaluateJavaScript("port42._resolve(callId, data)")`.

3. **BridgeHandler:** WKScriptMessageHandler. Receives message, switches on
   `method`, calls swift, serializes JSON, calls back via evaluateJavaScript.

4. Wire into PortView. Attach user script and message handler on webview creation.

**Unit tests:**
- `testBridgeInjectorScript` — verify the injected JS defines port42 namespace
- `testBridgeMethodRouting` — verify handler routes "user.get" to correct swift path
- `testBridgeCallIdMatching` — verify responses match requests by callId
- `testBridgeUnknownMethod` — verify unknown method returns error, doesn't crash

**User test:**
- Create a port that calls `port42.user.get()` on load and displays user's name
- Verify name appears in the port
- Verify existing chat functionality unaffected

---

### Step 3: Bridge Read APIs (P-103, P-104, P-105) ✅

**Goal:** Ports can read companions, messages, and user data.

**Files to modify:**
- `Sources/Port42Lib/Services/PortBridge.swift` — add method handlers

**What to build:**

1. `port42.companions.list()` — serialize appState.companions to JSON
   with: id, name, status (idle/responding), model, isActive.

2. `port42.companions.get(id)` — find by ID, return single or null.

3. `port42.messages.recent(n)` — last n messages from current channel/swim.
   Serialize with: id, sender, content, timestamp (ISO), isCompanion.

4. `port42.user.get()` — return { id, name }.

5. Pass channelId or swimCompanionId into PortBridge for context scoping.

**Unit tests:**
- `testCompanionsList` — returns all companions with correct fields
- `testCompanionsGet` — returns single companion by ID
- `testCompanionsGetNotFound` — returns null for unknown ID
- `testMessagesRecent` — returns last n messages in order
- `testMessagesRecentEmpty` — returns empty array for empty channel
- `testUserGet` — returns current user id and name

**User test:**
- Build companion dashboard port: calls companions.list(), renders each as a card
- Verify companions appear with correct names and status
- Verify existing companion chat routing unaffected

---

### Step 4: Bridge Events (P-106) ✅

**Goal:** Ports receive live updates without polling.

**Files to modify:**
- `Sources/Port42Lib/Services/PortBridge.swift` — add EventPusher

**What to build:**

1. **EventPusher:** Observe AppState published properties. Push events to
   webview via evaluateJavaScript when state changes.

2. **JS side:** `port42.on(event, callback)` stores callbacks in a map.
   Native calls `port42._emit(event, data)` to invoke them.

3. Events: `'message'` (new message in channel), `'companion.activity'`
   (typing state change).

4. Scope events to port's channel/swim context only.

**Unit tests:**
- `testEventRegistration` — port42.on stores callback
- `testEventEmit` — _emit invokes registered callback
- `testEventScoping` — events from other channels not pushed
- `testMultipleListeners` — multiple callbacks for same event all fire

**User test:**
- Companion dashboard with live typing indicator
- Send a message to a companion, verify dashboard shows activity flash
- Verify typing indicators in normal chat still work

---

### Step 4b: Connection Health (P-106b) ✅

**Goal:** Ports know whether push events are alive and get notified if they drop.

**Files to modify:**
- `Sources/Port42Lib/Services/PortBridge.swift` — add heartbeat + connection API
- `Sources/Port42Lib/Services/AppState.swift` — heartbeat timer

**What to build:**

1. `port42.connection.status()` — returns `'connected'` or `'disconnected'`.
   Backed by a heartbeat: native pings the webview every 5s via
   `port42._heartbeat()`. JS side tracks last heartbeat timestamp.
   If no heartbeat for 10s, status flips to `'disconnected'`.

2. `port42.connection.onStatusChange(callback)` — fires when status
   changes. Ports can show a visual indicator or attempt recovery.

3. Native heartbeat timer on AppState, iterates `activeBridges` and
   calls `pushHeartbeat()` every 5s.

**Unit tests:**
- `testConnectionStatusConnected` — returns connected when heartbeat recent
- `testConnectionStatusDisconnected` — returns disconnected after timeout
- `testOnStatusChangeCallback` — callback fires on transition

**User test:**
- Port with connection indicator dot (green = connected, red = disconnected)
- Kill and restart app, verify port reconnects and dot goes green
- Verify existing event push still works alongside heartbeat

---

### Step 5: Port Sandbox (P-108) ✅

**Goal:** Ports cannot escape the bridge.

**Files to modify:**
- `Sources/Port42Lib/Views/PortView.swift` — webview configuration

**What to build:**

1. WKWebViewConfiguration: `javaScriptCanOpenWindows = false`.
   Load via `loadHTMLString` only (no base URL).

2. WKNavigationDelegate: `.cancel` for all navigation actions.

3. Content Security Policy in HTML wrapper:
   `default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline';`

**Unit tests:**
- `testSandboxBlocksFetch` — fetch() inside port fails
- `testSandboxBlocksNavigation` — location change blocked
- `testSandboxBlocksWindowOpen` — window.open blocked
- `testSandboxAllowsInlineScript` — inline JS executes normally

**User test:**
- Port with `fetch("https://example.com")` — verify it fails silently
- Port with normal bridge calls — verify they still work
- Verify existing app networking (sync, LLM calls) unaffected

---

### Step 6: Companion Context (P-107) ✅

**Goal:** Companions know they can emit ports and what APIs are available.

**Files to modify:**
- System prompt construction in AppState or ChannelAgentHandler

**What to build:**

1. Append port capability context to companion system prompts:
   ```
   You can create interactive ports by wrapping HTML/CSS/JS in a ```port
   code fence. Ports render as live interactive surfaces in the user's
   chat. Available bridge APIs:
   - port42.companions.list() / .get(id)
   - port42.messages.recent(n)
   - port42.user.get()
   - port42.on(event, callback) — events: 'message', 'companion.activity'
   - port42.port.close() / .resize(w, h)
   The port42 dark theme is auto-injected. No <html>/<body> needed.
   Use ports when asked to build something interactive.
   ```

2. Add to context block, not user system prompt. No personality interference.

**Unit tests:**
- `testSystemPromptIncludesPortContext` — verify port instructions present
- `testCustomSystemPromptPreserved` — user's companion prompt unchanged

**User test:**
- Ask companion "build me a clock" — verify it responds with a ```port block
- Verify the clock renders inline and ticks
- Verify companion personality and behavior otherwise unchanged

---

## Phase 2: Pop Out (P-200 through P-205)

### Design Decisions

These apply across all Phase 2 steps:

1. **WebView transfer, not recreation.** When popping out, transfer the existing
   WKWebView from inline to floating. This preserves JS state, storage, event
   listeners, and DOM. The port doesn't "restart" on pop-out.

2. **Bridge lifecycle extends.** Currently bridges die when inline view scrolls
   away. For popped ports, PortWindowManager owns the PortPanel which holds the
   bridge reference. Same weak-ref cleanup pattern, longer lifetime.

3. **Free-form floating windows.** Each port gets its own NSPanel. No docking.
   Users arrange windows freely. Position/size persists across restart.

4. **Popped port is independent.** Once popped, it lives outside the message
   stream. Source message deletion does not kill it.

5. **Port update matching.** New ```port from same message replaces the existing
   popped port's HTML rather than creating a duplicate. Matching key: messageId.
   Different ports from the same companion each get their own window.

6. **Permission persistence.** Granted permissions (terminal, AI, etc.) persist
   in the port_panels DB table. No re-prompting on restart.

---

### Step 7a: PortWindowManager + Pop-Out Button (P-200) ✅

Pop-out button on inline ports. PortWindowManager holds floating panels.
WebView transferred (not recreated) to preserve JS state.

---

### Step 7b: Draggable + Resizable Panel (P-201) ✅

Floating panels with title bar drag, resize handles, close button, z-ordering.

---

### Step 8: ~~Docking (P-202)~~ Removed

Docking was removed in favor of free-form window arrangement with position
persistence. Previously: dock button snaps floating port to right side. HStack layout with draggable
divider. Only one docked at a time. Undock returns to floating.

---

### Step 9: Persistence, Update, Close, Multiple (P-203 through P-206) ✅

Panels survive channel switch (AppState owned). Same-companion port updates
replace existing panel HTML. Close removes cleanly. Multiple floating panels
coexist with click-to-front z-ordering.

---

### Step 9b: Unified Port Title Bar ✅

Source/Run toggle and pop-out button appear consistently across all three port
states (inline, docked, floating). Green dot + title + Source/Run + controls.
Fixed height jitter when toggling source/run on inline ports.

---

## Phase 2b: Port Windowing System (P-220 through P-236)

### Design Decisions

1. **Ports are ephemeral by default.** Creating a port is cheap, closing is normal.
   History makes them recoverable, not persistence. Don't fight the transience.

2. **Edge snap over manual docking.** User drags to an edge and it snaps. No dock
   button, no menu. The gesture is the UI. Same mental model as macOS window tiling.

3. **Main content always yields.** When a port snaps to an edge, chat shrinks.
   When the port closes, chat restores. The port owns the space it claims.

4. **Windowing is geometry, not hierarchy.** A snapped port and a floating port are
   the same object in different positions. No state machine for "docked" vs "floating"
   vs "snapped." Just position + constraints.

5. **Port chrome follows macOS conventions where possible.** Red close, yellow minimize
   (background), green zoom (expand). Plus port-specific controls: stop, restart.

---

### Build Order

Priority order based on user impact:

1. ~~**P-222 + P-223: Bug fixes**~~ ✅ (terminal resize, permission re-trigger)
2. **P-230: Edge Snap** (drag to edge of main window, snap right/left/bottom)
3. ~~**P-235: Snap Restore**~~ N/A (replaced by free-form window arrangement)
4. **P-232: Multi-Port Tiling** (multiple ports split the snap zone)
5. ~~**P-233: Always-on-Top**~~ ✅ (pin a port above everything)
6. **P-220: Port Controls** (stop, running indicator, restart)
7. **P-219: Port History** (browse and reopen previous ports)
8. ~~**P-234: Background Ports**~~ ✅ (hidden but running)
9. **P-231: Screen Edge Snap** (snap to screen edge, main window resizes)
10. ~~**P-236: Port Chrome**~~ ✅ (reconcile macOS buttons with port controls)
11. **P-210: Close to Preview** (collapse to compact preview)
12. ~~**P-221: Restart Persistence**~~ ✅ (ports survive app restart, including position and permissions)

---

### Step 9c: Bug Fixes (P-222, P-223, P-224 through P-228) ✅

**P-222: Terminal Resize** ✅ Fixed.

**P-223: Resize Permission Re-trigger** ✅ Fixed.

**P-224: Port Overwrite** ✅ Fixed. Changed reuse matching from `createdBy + channelId`
to `messageId` so different ports from the same companion don't overwrite each other.

**P-225: Title Bar Buttons Unresponsive** ✅ Fixed. Root cause was `PortDragArea` as
background of entire HStack making all content draggable. Scoped drag area to title
text region only.

**P-226: Permission Dialog Not Showing** ✅ Fixed. Floating panels need key window
status for `confirmationDialog`. Added `bringToFront()` on permission prompt.

**P-227: Permission Not Persisting** ✅ Fixed. Added `grantedPermissions` column
(v14 migration), serialize/restore on app restart.

**P-228: Window Position Not Persisting** ✅ Fixed. Added `posX`, `posY` columns
(v13 migration), observe NSWindow move/resize notifications, restore on restart.

---

### Step 9d: Edge Snap (P-230, P-235)

**Goal:** Drag a floating port to the right/left/bottom edge of the main window.
Port snaps to that edge. Main content (chat) shrinks to accommodate. Closing the
snapped port restores main content to full size.

**Approach:**

1. Detect drag near edge (within ~20pt threshold) during port panel drag
2. Show a snap preview (highlight zone) when hovering near an edge
3. On drop in snap zone, transition port from floating to snapped:
   - Remove from floating panels
   - Add to snap layout (right: HStack, bottom: VStack, left: HStack reversed)
   - Animate main content resize
4. Draggable divider between snapped port and main content
5. Drag away from snap zone returns to floating at previous size
6. Close snapped port: animate main content back to full width

**Files to modify:**
- `PortWindowManager.swift` — snap zone detection, layout management
- `ContentView.swift` — conditional HStack/VStack layout for snapped ports
- `PortPanel.swift` — drag gesture recognizer with snap detection

---

### Step 9e: Multi-Port Tiling (P-232)

Multiple ports snapped to the same edge split the zone. Right edge: vertical
split. Bottom edge: horizontal split. Draggable dividers between ports. Same
close-restores-space behavior.

---

### Step 9f: Always-on-Top (P-233) ✅

Pin button in port title bar. Pinned ports use `.floating` NSWindow level to stay
above all content. Toggle on/off. Persisted to DB across restart.

---

### Step 9g: Port Controls and History (P-220, P-219)

**Port Controls (P-220):**
- Stop button: kills the port's webview, shows "stopped" state
- Running indicator: green dot when port JS is executing
- Restart button: tears down webview and re-injects original HTML

**Port History (P-219):**
- Store port metadata (title, HTML, companion, channel, timestamp) in SQLite
- History view accessible from sidebar or Quick Switcher
- Reopen recreates the port from stored HTML
- Search by title or companion name

---

## Phase 3: Generative Ports (P-300 through P-303)

### Step 10: Bridge AI (P-300) ✅

**Implemented:**
- `port42.ai.complete(prompt, options)` with streaming via `onToken`/`onDone` callbacks
- `port42.ai.models()` returns available models with id, name, tier
- `port42.ai.cancel(callId)` cancels in-progress streams
- `port42.companions.invoke(id, prompt, options)` for companion-scoped AI calls
- `PortAIHandler` bridges LLMEngine streams to JS context via PortBridge
- Options: `{ model?, maxTokens?, systemPrompt?, onToken, onDone }`

---

### Step 11: Bridge Write Operations (P-301) ✅

Already implemented ahead of schedule during Phase 1:

- `port42.messages.send(text)` — sends message to current channel ✅
- `port42.channel.list()` — returns all channels ✅
- `port42.channel.current()` — returns current channel with members ✅
- `port42.channel.switchTo(id)` — switch to channel by ID ✅
- `port42.storage.*` — full CRUD with channel/global/shared scoping ✅

---

### Step 12a: AI Permissions (P-302a) ✅

**Implemented:**
- `PortPermission` enum with `.ai` case (gates `ai.complete`, `ai.cancel`, `companions.invoke`)
- `permissionForMethod()` maps bridge method names to required permissions
- First call shows SwiftUI alert with human-readable description
- Permission stored per port session in `PortBridge.grantedPermissions: Set<PortPermission>`
- Reset on close. Read APIs and messages.send allowed by default.

---

### Step 12b: Device Permissions (P-302b) ✅

Implemented device permission cases (`.terminal`, `.microphone`, `.camera`, `.screen`,
`.clipboard`, `.filesystem`) with human-readable descriptions and method mappings.

---

### Step 12c: Companion Device Context (P-303) ✅

Companion context (ports-context.txt) is updated incrementally as each device
API ships. AI bridge docs and terminal docs are live. New device API docs added
alongside each implementation step.

---

## Phase 5: Device APIs (P-500 through P-508)

### Design Decisions

1. **Permission model extends P-301.** Same pattern as AI permissions. First
   call to any device API shows a SwiftUI prompt. Permission stored per port
   session. Reset on close. Each capability is a separate permission grant
   (terminal, mic, camera, screen, clipboard, fs).

2. **Bridge namespace per device.** Each device API gets its own namespace
   (`port42.terminal.*`, `port42.audio.*`, etc.) and its own Swift handler
   class implementing a common `BridgeCapability` protocol.

3. **Sandbox preserved.** Device APIs go through the bridge, not through
   relaxed CSP. The webview still has no network access. All device data
   flows through native Swift and is pushed to JS via the bridge.

4. **Companion context updated.** System prompt includes available device
   APIs so companions know what they can do. Same pattern as Step 6 (P-107).

---

### Step 13: Terminal Port (P-500) ✅

Implemented TerminalBridge with forkpty(), PTY management, stdin/stdout streaming,
resize, kill, and xterm.js rendering. Permission prompt on first spawn.

---

### Step 14: Audio APIs (P-501, P-502) ✅

**Implemented:**
- AudioBridge.swift with AVAudioEngine mic capture, SFSpeechRecognizer transcription,
  AVSpeechSynthesizer TTS, audio playback
- 5 methods: capture, stopCapture, speak, play, stop
- 2 events: transcription, data
- `.microphone` permission for capture, output requires no permission

---

### Step 15: Camera and Screen (P-503, P-504)

**Goal:** Ports can see through the camera and capture the screen.

**P-504 Screen Capture: ✅ Done**

- `Sources/Port42Lib/Services/ScreenBridge.swift` — display + window capture via ScreenCaptureKit
- `port42.screen.windows()` lists visible windows with id, title, app, bounds
- `port42.screen.capture({ windowId })` captures a specific window
- `port42.screen.capture({ scale, region, displayId, includeSelf })` captures display
- AI vision: `port42.ai.complete(prompt, { images: [base64] })` sends multimodal content blocks
- `LLMEngine.send` updated to accept `[[String: Any]]` for multimodal messages
- 4 tests passing

**P-503 Camera: ✅ Done**

- `Sources/Port42Lib/Services/CameraBridge.swift` with FrameHandler delegate
- `port42.camera.capture(opts?)` for single frame, `.stream(opts?)` for continuous
- AVCaptureSession with .high preset, scale factor for output resolution
- FrameHandler on background queue, MainActor dispatch for events
- `.camera` permission, 4 tests passing

**User test:**
- Port with window picker dropdown that screenshots selected window
- "Take a screenshot" then "Describe" with AI vision

---

### Step 16: Clipboard, File System, Notifications (P-505, P-506, P-507) ✅

**Implemented:**
- ClipboardBridge.swift — NSPasteboard read/write (text + image). `.clipboard` permission.
- FileBridge.swift — NSOpenPanel/NSSavePanel for user-chosen paths. Read/write with
  encoding options. Security-scoped bookmarks. `.filesystem` permission.
- NotificationBridge.swift — UNUserNotificationCenter. `.notification` permission.

---

### Step 17: Browser (P-509) ✅

**Implemented:**
- `Sources/Port42Lib/Services/BrowserBridge.swift` with BrowserSession inner class
- 7 methods: open, navigate, capture, text, html, execute, close
- 3 events: browser.load, browser.error, browser.redirect
- Max 5 concurrent headless WKWebView sessions per port
- Non-persistent data stores (no shared cookies between sessions)
- URL validation (http/https/data only), 30s timeout, text/HTML truncation limits
- `.browser` permission gates all methods
- 8 tests passing
- Companion context updated with browser API docs and UX tips

---

## Build Order Summary

```
Step 1:  Port detection + static render     → ports appear in chat       ✅
Step 2:  Bridge core                        → ports talk to native       ✅
Step 3:  Bridge read APIs                   → ports read data            ✅
Step 4:  Bridge events + connection health  → ports update live          ✅
Step 5:  Sandbox                            → ports can't escape         ✅
Step 6:  Companion context                  → companions know about ports ✅
  bonus: channel APIs, messages.send, storage, viewport, console, modules ✅
Phase 1 complete ─────────────────────────────────────────────────────────

Step 7a: PortWindowManager + pop-out        → ports detach from chat     ✅
Step 7b: Draggable + resizable panels       → ports feel like windows    ✅
Step 8:  ~~Docking~~                         → removed (free-form windows)
Step 9:  Persistence + update + close       → ports are managed          ✅
Step 9b: Unified title bar (source/run)     → consistent controls        ✅
Step 9c: Bug fixes (P-222–P-228)            → buttons, perms, position   ✅
Step 9f: Always-on-Top (P-233)              → pin above everything       ✅
Phase 2 complete ─────────────────────────────────────────────────────────

Step 10:  Bridge AI (P-300)                 → ports think                ✅
Step 11:  Bridge write ops (P-301)          → DONE (moved to Phase 1)    ✅
Step 12a: AI permissions (P-302a)           → user approves AI calls     ✅
Step 12b: Device permissions (P-302b)       → user approves device APIs  ✅
Step 12c: Companion device context (P-303)  → companions know about APIs
Step 12c: Companion device context (P-303)  → companions know about APIs ✅
Phase 3 complete ─────────────────────────────────────────────────────────

Phase 3b (deferred):
  P-310: Remote agent port context           → OpenClaw agents learn port APIs

Phase 2.5 (polish, no new infra):
  P-210: Close to preview                   → non-destructive close
  P-211: Inline port update                 → companion updates in-place
  P-209: Port channel context               → follow/pin channel control
  P-218: Port resize handles                → user drags to resize inline ports

Phase 2.5 (new events):
  P-212: ~~Event: port.docked~~             → N/A (docking removed)
  P-213: ~~Event: port.undocked~~           → N/A (docking removed)
  P-214: Event: channel.switch
  P-215: Event: companion.joined
  P-216: Event: companion.left
  P-217: Event: presence

Phase 2.5 (infrastructure):
  P-206: ~~Multiple dock zones~~            → N/A (docking removed)
  P-207: Cursor states                      → green circle, resize cursors
  P-208: Port UDIDs                         → stable IDs across lifecycle

Phase 4 (advanced APIs):
  P-400: Port window management API         → ports manage other ports
  P-401: Cross-channel reads                → read any channel
  P-402: Structured message metadata        → model, tokens, timing
  P-403: Convergence detection              → similarity scoring

Step 13: Terminal (P-500)                   → ports run commands          ✅
Step 14: Audio (mic + TTS)                  → ports listen and speak      ✅
Step 15: Camera + screen                    → ports see                   ✅
Step 16: Clipboard + files + notifications  → ports move data            ✅
Step 17: Browser (P-509)                    → ports browse the web       ✅
Phase 5 (device APIs) ───────────────────────────────────────────────

Step 18: Automation (P-601)                 → ports control other apps    ✅
Step 19: Accessibility (P-603)              → ports interact with any UI
Step 20: Spotlight (P-606)                  → ports find files
Step 21: Calendar (P-605)                   → ports know your schedule
Step 22: File watching (P-607)              → ports react to changes
Step 23: System info (P-600)                → ports monitor the system
Step 24: Shortcuts (P-602)                  → ports trigger workflows
Step 25: Drag and drop (P-609)              → ports accept drops
Step 26: Remaining (P-503/504/508/610/608/611) → camera, contacts, location, pickers, hardware
Phase 6 (system integration) ───────────────────────────────────────

Step 27: Agent embed protocol (P-700)          → external agents connect through the front door
Step 28: Embed button / snippet (P-701)        → one-click install from any website
Step 29: Agent manifest (P-702)                → agents describe themselves
Step 30: Agent registry UI (P-703)             → manage connected external agents
Step 31: Agent sandbox (P-704)                 → permission scoping for untrusted agents
Step 32: Agent auth (P-706)                    → mutual authentication
Step 33: Agent discovery (P-705)               → browsable agent catalog
Step 34: Agent billing bridge (P-707)          → agents own their own costs
Phase 7 (agent embed protocol) ─────────────────────────────────────
```

## Phase 6: System Integration (P-600 through P-611)

### Design Decisions

1. **Same bridge pattern.** Each API gets its own Swift bridge class, lazy-init
   in PortBridge, permission-gated, cleanup in deinit. Same as Phase 5.

2. **Automation is the highest-leverage API.** AppleScript/JXA gives broad
   action across the entire OS. Combined with screen capture + AI vision,
   the agent can perceive, reason, and act. This is the bridge from "smart
   dashboard" to "actual agent."

3. **Accessibility complements automation.** AppleScript works with apps that
   support it (most Apple apps, many third-party). Accessibility works with
   everything via the UI tree. Together they cover nearly all interaction.

4. **Permission escalation model.** Automation and accessibility are the most
   powerful permissions. Their prompts should be clear about the scope:
   automation can run scripts that control apps, accessibility can read and
   click any UI element.

---

### Step 18: Automation (P-601) ✅

**Implemented:**
- `Sources/Port42Lib/Services/AutomationBridge.swift` — stateless bridge with two methods
- `port42.automation.runAppleScript(source, opts?)` via NSAppleScript on background thread
- `port42.automation.runJXA(source, opts?)` via `/usr/bin/osascript -l JavaScript`
- Timeout enforcement: default 30s, max 120s, clamped via ContinuationGuard
- `.automation` permission with descriptive prompt
- `com.apple.security.automation.apple-events` entitlement (added to dev, already in release)
- `NSAppleEventsUsageDescription` in Info.plist for macOS TCC
- JS namespace: `port42.automation.runAppleScript(source, opts?)` / `.runJXA(source, opts?)`
- 7 tests passing (permission mapping, description, timeout, error handling)
- Companion context updated with Automation API docs

---

### Step 19: Accessibility (P-603)

**Goal:** Ports can read and interact with any application's UI.

**Files to create:**
- `Sources/Port42Lib/Services/AccessibilityBridge.swift` — AXUIElement wrapper

**What to build:**

1. `port42.accessibility.windows()` — list all windows with pid, app, title, bounds
2. `port42.accessibility.elements(pid, query?)` — query UI tree for elements
3. `port42.accessibility.click(pid, elementId)` — perform click action
4. `port42.accessibility.type(pid, text)` — type text into focused element
5. Permission: `.accessibility` plus macOS Accessibility permission in System Settings

**User test:**
- Port that reads the UI tree of a running app
- Companion that clicks a button in another app based on screen + AI vision
- Automated form filling

---

### Step 20: Spotlight (P-606)

**Goal:** Ports can search for files by content or metadata.

**Files to create:**
- `Sources/Port42Lib/Services/SpotlightBridge.swift` — NSMetadataQuery wrapper

**What to build:**

1. `port42.spotlight.search(query, opts?)` — async search returning file
   metadata. No permission needed for metadata. Content requires fs.pick.

**User test:**
- "Find all PDFs I downloaded this week"
- Companion that locates relevant files for a project

---

### Step 21: Calendar (P-605)

**Goal:** Ports can read and create calendar events and reminders.

**Files to create:**
- `Sources/Port42Lib/Services/CalendarBridge.swift` — EventKit wrapper

**What to build:**

1. `port42.calendar.events(range?)` — list events in date range
2. `port42.calendar.reminders()` — list reminders
3. `port42.calendar.create(event)` — create event or reminder
4. Permission: `.calendar` plus EventKit authorization

**User test:**
- Daily agenda port showing today's schedule
- Companion that creates calendar events from conversation

---

### Step 22: File Watching (P-607)

**Goal:** Ports can monitor directories for changes.

**What to build:**

1. `port42.fs.watch(path, callback)` — FSEvents stream for a directory
2. `port42.fs.unwatch(watchId)` — stop watching
3. Only paths previously granted via fs.pick. Requires filesystem permission.

**User test:**
- Hot-reload port that re-renders when a file changes
- Log tailer that processes new entries in real time

---

### Step 23: System Info (P-600)

**Goal:** Ports can read system state.

**Files to create:**
- `Sources/Port42Lib/Services/SystemBridge.swift` — IOKit/sysctl queries

**What to build:**

1. `port42.system.info()` — battery, CPU, memory, disk, network
2. `port42.system.on('battery', cb)` — live battery updates
3. No permission needed (read-only system info)

**User test:**
- System monitoring dashboard port
- Battery-aware companion that defers heavy tasks on low power

---

## Phase 7: Agent Embed Protocol (P-700 through P-707)

### Design Decisions

1. **Front door, not side door.** External agents connect through the same gateway
   protocol that local companions and OpenClaw agents use. No new transport layer.
   The gateway gains a new peer type ("agent-embed") with metadata about the
   external endpoint, but the message routing is identical.

2. **Agent owns its backend.** Port42 never runs the external agent's inference.
   PostHog's agent runs on PostHog's servers, uses PostHog's models, costs PostHog
   money. Port42 is the UI and context layer, not the compute layer.

3. **One-click install via deep link.** The embed button on a website opens
   `port42://agent-embed?manifest=<url>`. Port42 fetches the manifest, shows
   an install dialog, and registers the agent. No config files, no CLI, no tokens
   to copy-paste.

4. **Untrusted by default.** External agents get a restricted permission set.
   They can send messages and create ports, but system capabilities (terminal,
   automation, filesystem) are blocked until the user explicitly grants them.
   This is a different trust tier from local companions.

5. **Builds on OpenClaw adapter.** The wire protocol extends the existing gateway
   sync protocol. An external agent is essentially an always-on remote peer with
   its own LLM backend. The OpenClaw channel adapter is a precursor to this.

---

### Step 27: Agent Embed Protocol (P-700)

**Goal:** Define the wire protocol for external agents connecting through the gateway.

**What to build:**

1. New peer type `"agent-embed"` in the gateway identify handshake. Carries
   additional metadata: manifest URL, endpoint URL, capabilities declared.

2. Gateway routes messages to/from agent-embed peers identically to regular
   peers. No special handling beyond the metadata.

3. Port42 app recognizes agent-embed peers and displays them with a distinct
   badge (external agent vs local companion).

4. Agent backend connects via WebSocket to the gateway and follows the
   identify/welcome/join protocol. Messages flow bidirectionally.

**User test:**
- External agent connects to gateway, sends a message, it appears in Port42
- External agent sends a ```port block, it renders inline

---

### Step 28: Embed Button (P-701)

**Goal:** Websites can add a button that installs their agent into Port42.

**What to build:**

1. `port42://agent-embed?manifest=<url>&callback=<url>` deep link handler
   in Port42. Fetches manifest, shows install dialog.

2. `https://port42.ai/embed.js` script that renders a `<port42-connect>`
   web component. Handles deep link with fallback to download page.

3. Install dialog shows agent name, icon, description, permissions requested.
   User picks channel(s) and approves.

4. Callback URL receives confirmation so the website knows the agent was installed.

**User test:**
- Click "Add to Port42" button on a test website
- Port42 opens with install dialog
- Approve, agent appears in chosen channel

---

### Step 29: Agent Manifest (P-702)

**Goal:** Agents describe themselves in a standard JSON format.

**What to build:**

1. JSON schema for agent manifest at `/.well-known/port42-agent.json`
2. Port42 fetches and validates manifest during install
3. Manifest fields: name, icon, description, endpoint, capabilities,
   permissions_requested, auth config, version, homepage

**User test:**
- Port42 fetches manifest from URL, displays agent info correctly
- Invalid manifest shows clear error

---

### Step 30: Agent Registry UI (P-703)

**Goal:** Users can see and manage connected external agents.

**What to build:**

1. Settings panel listing all installed external agents
2. Per-agent: name, icon, source website, channels, permissions granted, activity
3. Revoke access (disconnect agent, remove from channels)
4. Modify permissions per agent

**User test:**
- View all installed agents, revoke one, verify it disconnects

---

### Step 31: Agent Sandbox (P-704)

**Goal:** External agents have restricted permissions by default.

**What to build:**

1. `PortPermission` gains a trust tier: `.local` vs `.external`
2. External agents blocked from terminal, automation, filesystem, clipboard,
   screen by default. User can escalate per agent.
3. External agents use their own AI (no Port42 LLM token consumption)
4. Bridge methods check trust tier before permission prompt

**User test:**
- External agent tries to call `terminal.spawn`, gets blocked
- User grants terminal permission to specific agent, it works

---

### Step 32: Agent Auth (P-706)

**Goal:** Mutual authentication between Port42 and external agent backends.

**What to build:**

1. OAuth2 flow for agents that require user auth on their platform
2. Token exchange during install (user authorizes Port42 on the agent's platform)
3. Signed requests between Port42 gateway and agent endpoint

**User test:**
- Install agent that requires OAuth, complete the flow, agent connects

---

## First Demo

After Phase 1, build the companion dashboard:

```
you: @engineer build me a companion dashboard that shows all my
     companions and flashes when any of them is active

engineer responds with a ```port block:
  - calls port42.companions.list()
  - renders each as a card with name and status
  - subscribes to port42.on('companion.activity')
  - styled with port42 theme automatically

→ renders inline in chat
→ companion cards visible, active ones pulse
→ the first port is alive
```
