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

### Step 7a: PortWindowManager + Pop-Out Button (P-200) ✅

Pop-out button on inline ports. PortWindowManager holds floating panels.
WebView transferred (not recreated) to preserve JS state.

---

### Step 7b: Draggable + Resizable Panel (P-201) ✅

Floating panels with title bar drag, resize handles, close button, z-ordering.

---

### Step 8: Docking (P-202) ✅

Dock button snaps floating port to right side. HStack layout with draggable
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

### Step 14: Audio APIs (P-501, P-502)

**Goal:** Ports can listen through the mic and speak through the speaker.

**Files to create:**
- `Sources/Port42Lib/Services/AudioBridge.swift` — mic capture, TTS, playback

**What to build:**

1. Mic capture via AVAudioEngine. Push audio buffers or transcribed text
   (via Speech framework) to port via EventPusher.

2. `port42.audio.capture({ transcribe: true })` — starts mic with live
   transcription. `'transcription'` events stream partial and final results.

3. `port42.audio.speak(text, opts?)` — AVSpeechSynthesizer TTS.

4. Permission via macOS microphone authorization (system dialog).

**User test:**
- Port with a "listen" button that transcribes speech in real time
- Port that reads messages aloud via TTS
- Companion that responds to voice commands

---

### Step 15: Camera and Screen (P-503, P-504)

**Goal:** Ports can see through the camera and capture the screen.

**Files to create:**
- `Sources/Port42Lib/Services/CameraBridge.swift` — camera capture, screen capture

**What to build:**

1. Camera capture via AVCaptureSession. Single frame or continuous stream.
   Returns base64 PNG via bridge callback.

2. Screen capture via CGWindowListCreateImage. Whole screen or region.

3. Permission via macOS camera and screen recording authorization.

4. Combined with Bridge AI: "look at this screenshot and tell me what's wrong."

**User test:**
- Port that shows a live camera preview
- "Take a screenshot" — companion analyzes the image via Bridge AI

---

### Step 16: Clipboard, File System, Notifications (P-505, P-506, P-507)

**Goal:** Ports can move data in and out of the system.

**What to build:**

1. **Clipboard:** NSPasteboard read/write. Permission on first access.

2. **File System:** NSOpenPanel/NSSavePanel for user-chosen paths only.
   Drag-and-drop via WKWebView's drop target support. No arbitrary traversal.

3. **Notifications:** UNUserNotificationCenter for background alerts.
   Port registers for notification click callbacks.

**User test:**
- Paste an image into a port from clipboard
- Drag a CSV onto a port, port parses and visualizes it
- Background port notifies when a long-running task completes

---

### Step 17: Browser (P-509)

**Goal:** Ports can browse the web, extract content, and take screenshots of pages.

**Files to create:**
- `Sources/Port42Lib/Services/BrowserBridge.swift` — managed WKWebView sessions, content extraction

**What to build:**

1. `port42.browser.open(url, opts?)` — create a new WKWebView session (separate
   from the port's own webview). Full network access. Optional visible mode
   renders the browser inline in the port. Hidden mode for headless research.

2. `port42.browser.navigate(sessionId, url)` — navigate to a new URL.

3. `port42.browser.capture(sessionId, opts?)` — screenshot the page as base64 PNG.
   Uses WKWebView's `takeSnapshot`. Full page or region.

4. `port42.browser.text(sessionId, opts?)` — extract text content via
   `evaluateJavaScript("document.body.innerText")`. Optional CSS selector to
   scope extraction.

5. `port42.browser.html(sessionId, opts?)` — extract HTML content. Optional selector.

6. `port42.browser.execute(sessionId, js)` — run arbitrary JavaScript in the
   browsed page context. Returns the result.

7. `port42.browser.close(sessionId)` — close the session, deallocate the webview.

8. Events: `'load'` fires when page finishes loading. `'error'` fires on
   navigation failure.

9. Permission: `.browser` gates all methods. "This port wants to browse the web. Allow?"

**User test:**
- Port with a URL input that loads and screenshots any webpage
- Companion that researches a topic by browsing multiple pages and summarizing
- "Read this URL and explain it" using browser.text + AI.complete
- Port that monitors a webpage for changes

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
Step 8:  Docking                            → snap to right side         ✅
Step 9:  Persistence + update + close       → ports are managed          ✅
Step 9b: Unified title bar (source/run)     → consistent controls        ✅
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
  P-218: Port resize handles                → user drags to resize inline/docked ports

Phase 2.5 (new events):
  P-212: Event: port.docked
  P-213: Event: port.undocked
  P-214: Event: channel.switch
  P-215: Event: companion.joined
  P-216: Event: companion.left
  P-217: Event: presence

Phase 2.5 (infrastructure):
  P-206: Multiple dock zones                → vertical split for 2+ docked
  P-207: Cursor states                      → green circle, resize cursors
  P-208: Port UDIDs                         → stable IDs across lifecycle

Phase 4 (advanced APIs):
  P-400: Port window management API         → ports manage other ports
  P-401: Cross-channel reads                → read any channel
  P-402: Structured message metadata        → model, tokens, timing
  P-403: Convergence detection              → similarity scoring

Step 13: Terminal (P-500)                   → ports run commands          ✅
Step 14: Audio (mic + TTS)                  → ports listen and speak      ← NEXT
Step 15: Camera + screen                    → ports see
Step 16: Clipboard + files + notifications  → ports move data            ✅
Step 17: Browser (P-509)                    → ports browse the web
Phase 5 (device APIs) ───────────────────────────────────────────────
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
