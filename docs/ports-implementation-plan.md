# Ports Implementation Plan

**Last updated:** 2026-03-12

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

## Phase 2: Pop Out and Dock (P-200 through P-206)

### Design Decisions

These apply across all Phase 2 steps:

1. **WebView transfer, not recreation.** When popping out, transfer the existing
   WKWebView from inline to floating. This preserves JS state, storage, event
   listeners, and DOM. The port doesn't "restart" on pop-out.

2. **Bridge lifecycle extends.** Currently bridges die when inline view scrolls
   away. For popped ports, PortWindowManager owns the PortPanel which holds the
   bridge reference. Same weak-ref cleanup pattern, longer lifetime.

3. **Single dock slot first.** One docked port (right side only). Multiple docks
   and bottom docking are future work. Keep it simple.

4. **Popped port is independent.** Once popped, it lives outside the message
   stream. Source message deletion does not kill it.

5. **Port update matching.** New ```port from same companion in same channel
   replaces the existing popped port's HTML rather than creating a duplicate.
   Matching key: (createdBy, channelId).

6. **Scroll preservation.** When ChatView transitions to HSplitView for docking,
   use ScrollViewReader to preserve chat scroll position.

---

### Step 7a: PortWindowManager + Pop-Out Button (P-200)

**Goal:** User clicks pop out, port detaches from chat into a floating panel.

**Files to create:**
- `Sources/Port42Lib/Views/PortWindowManager.swift` — manages floating/docked port panels

**Files to modify:**
- `Sources/Port42Lib/Views/ConversationContent.swift` — add pop-out button to InlinePortView
- `Sources/Port42Lib/Views/ContentView.swift` — overlay floating panels

**What to build:**

1. `PortPanel` struct: `{ id, html, bridge, position, size, isDocked, title, channelId, createdBy, messageId }`.
   Title extracted from `<title>` tag in HTML, fallback "port".

2. `PortWindowManager` as `@Published` property on AppState (or standalone
   ObservableObject). Holds `panels: [PortPanel]`.

3. "↗" pop-out button in top-right corner of InlinePortView. On click:
   - Creates PortPanel from current inline port state
   - Transfers bridge reference (not recreated)
   - Inline port collapses to a placeholder ("port popped out")

4. ContentView overlays floating panels via `.overlay { ForEach(panels) { ... } }`.
   Same pattern already used for QuickSwitcher and HelpOverlay.

**Unit tests:**
- `testPortWindowManagerAdd` — adding panel increases count
- `testPortWindowManagerRemove` — removing panel decreases count
- `testPortPanelTitleExtraction` — title parsed from HTML `<title>` tag
- `testPortPanelTitleFallback` — no title tag returns "port"

**User test:**
- Render inline port, click ↗, verify panel appears floating
- Verify inline port shows "popped out" placeholder
- Verify chat still scrolls normally underneath

---

### Step 7b: Draggable + Resizable Panel (P-201)

**Goal:** Floating panel feels like a real window inside port42.

**Files to modify:**
- `Sources/Port42Lib/Views/PortWindowManager.swift` — FloatingPortView

**What to build:**

1. FloatingPortView with title bar: drag handle area, title text, close button.
   DragGesture on title bar updates panel position.

2. Resize handle in bottom-right corner. DragGesture updates panel size.
   Minimum size: 200x150. Maximum: parent bounds.

3. Close button removes from PortWindowManager. Bridge cleaned up via
   weak reference pattern (automatic).

4. Z-ordering: clicking a panel brings it to front (reorder in array).

**User test:**
- Drag panel by title bar, verify smooth repositioning
- Resize from corner, verify content reflows
- Close panel, verify clean removal
- Multiple panels, click one to bring to front

---

### Step 8: Docking (P-202)

**Goal:** Snap floating port to right edge, splitting the view.

**Files to modify:**
- `Sources/Port42Lib/Views/ContentView.swift` — conditional HSplitView layout
- `Sources/Port42Lib/Views/PortWindowManager.swift` — dock/undock state

**What to build:**

1. Dock button in floating panel title bar (or drag-to-edge snap).
   Sets `panel.isDocked = true`. Only one panel can be docked at a time.

2. ContentView detail pane becomes conditional:
   ```
   if dockedPanel exists:
     HSplitView { ChatView() | DockedPortView }
   else:
     ChatView()
   ```
   HSplitView nested inside NavigationSplitView detail pane (confirmed compatible).

3. Undock button in docked port header. Returns to floating.

4. Resizable divider between chat and docked port (HSplitView default behavior).

5. ScrollViewReader preserves chat scroll position across layout transitions.

**Unit tests:**
- `testDockRight` — sets isDocked, only one docked at a time
- `testUndock` — clears isDocked, returns to floating with position
- `testDockReplacesExisting` — docking new port undocks previous

**User test:**
- Pop out a port, click dock button, verify it snaps to right
- Verify chat resizes, divider is draggable
- Click undock, verify it floats again
- Dock a different port, verify first one undocks
- Verify sidebar, channels, companions all unaffected

---

### Step 9: Persistence, Update, Close, Multiple (P-203 through P-206)

**Goal:** Ports survive channel switches, update in place, close cleanly, coexist.

**What to build:**

1. **Persistence:** PortWindowManager lives on AppState. Panels survive channel
   switch. Bridge stays bound to original channel context (channelId captured at
   pop-out time). When switching back to port's channel, events resume normally.

2. **Update:** New ```port from same companion (createdBy) in same channel updates
   existing popped/docked port HTML via `webView.loadHTMLString()`. Otherwise
   creates new inline. Bridge and JS state preserved where possible.

3. **Close:** Close button removes from manager. If inline source message still
   visible, it un-collapses back to inline port (or stays as code preview).

4. **Multiple floating:** Array of panels. All float independently. Only one
   can be docked. Z-ordering managed by click-to-front.

**Unit tests:**
- `testPortSurvivesChannelSwitch` — switch channel, port panel still exists
- `testPortUpdateReplacesContent` — same companion sends new port, content updates
- `testPortClose` — close removes from manager
- `testMultiplePorts` — two floating ports coexist
- `testDockOnlyOne` — docking second port undocks first

**User test:**
- Open port, switch channels, switch back, port still docked
- Ask companion to update the port, verify it refreshes in place
- Close port, verify clean removal
- Open two ports, verify both visible and functional

---

## Phase 3: Generative Ports (P-300 through P-303)

### Step 10: Bridge AI (P-300)

**Goal:** Ports can call LLMs through the bridge.

**What to build:**

1. `port42.ai.complete(prompt, options)` routes through BridgeHandler to
   LLMEngine. Streams tokens back via evaluateJavaScript callback.

2. Options: { model?, maxTokens?, systemPrompt? }. Uses companion auth.

3. JS API with streaming callback:
   ```js
   port42.ai.complete("summarize", {
     onToken: (t) => append(t),
     onDone: (full) => done(full)
   })
   ```

**Unit tests:**
- `testAICompleteRouting` — verify bridge routes to LLMEngine
- `testAICompleteStreaming` — tokens arrive via callback
- `testAICompleteError` — auth failure returns error, no crash

**User test:**
- Port with a text input and "summarize" button that calls port42.ai.complete()
- Verify streaming tokens appear in the port
- Verify existing companion chat streaming unaffected

---

### Step 11: Bridge Write Operations (P-301, P-302) ✅

Already implemented ahead of schedule during Phase 1:

- `port42.messages.send(text)` — sends message to current channel ✅
- `port42.channel.list()` — returns all channels ✅
- `port42.channel.current()` — returns current channel with members ✅
- `port42.channel.switchTo(id)` — switch to channel by ID ✅
- `port42.storage.*` — full CRUD with channel/global/shared scoping ✅

---

### Step 12: Permissions (P-303)

**Goal:** User approves before ports take AI actions.

**What to build:**

1. First call to `port42.ai.complete()` shows SwiftUI alert:
   "This port wants to use AI. Allow?"
2. Permission stored per port session. Reset on close.
3. Read APIs and messages.send are allowed by default (companion created the port).

**Unit tests:**
- `testPermissionPromptOnFirstAI` — first AI call triggers prompt
- `testPermissionCached` — second AI call skips prompt
- `testPermissionResetOnClose` — new port session requires new approval

**User test:**
- Port tries AI call — verify alert appears
- Approve — verify response streams
- Close port, reopen — verify prompt appears again

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

Step 7a: PortWindowManager + pop-out button  → ports detach from chat     ← NEXT
Step 7b: Draggable + resizable panels       → ports feel like windows
Step 8:  Docking (right side, single slot)  → ports snap to side
Step 9:  Persistence + update + close       → ports are managed
Phase 2 ──────────────────────────────────────────────────────────────────

Step 10: Bridge AI                          → ports think
Step 11: Bridge write ops                   → DONE (moved to Phase 1)    ✅
Step 12: Permissions                        → user controls AI calls
Phase 3 ──────────────────────────────────────────────────────────────────
```

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
