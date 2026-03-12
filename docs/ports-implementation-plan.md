# Ports Implementation Plan

**Last updated:** 2026-03-11

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

### Step 7: Pop Out and Virtual Window (P-200, P-201)

**Goal:** User clicks pop out on inline port, it becomes a floating panel.

**Files to create:**
- `Sources/Port42Lib/Views/PortWindowManager.swift` — manages port panels

**Files to modify:**
- `Sources/Port42Lib/Views/PortView.swift` — add pop-out button overlay
- `Sources/Port42Lib/Views/ContentView.swift` — overlay floating panels

**What to build:**

1. "↗" button in top-right corner of inline PortView.

2. PortWindowManager (ObservableObject on AppState). Array of PortPanel
   structs: { id, html, position, size, isDocked, title, channelId }.

3. Pop out adds PortPanel. Inline port collapses to placeholder.

4. ContentView overlays floating panels. Each is draggable, resizable,
   has title bar (from `<title>` or "port"), close button, drag handle.

**Unit tests:**
- `testPortWindowManagerAdd` — adding panel increases count
- `testPortWindowManagerRemove` — removing panel decreases count
- `testPortPanelTitleExtraction` — title parsed from HTML `<title>` tag

**User test:**
- Render inline port, click pop out, verify panel appears floating
- Drag panel around inside port42 window
- Verify inline port collapses to placeholder
- Verify chat still scrolls and functions normally underneath

---

### Step 8: Docking (P-202)

**Goal:** Snap floating port to side, splitting the view.

**Files to modify:**
- `Sources/Port42Lib/Views/ContentView.swift` — HSplit/VSplit layout
- `Sources/Port42Lib/Views/PortWindowManager.swift` — dock state

**What to build:**

1. Drag to right edge → dock right. ContentView becomes HSplitView.
2. Drag to bottom → dock bottom. ContentView becomes VSplitView.
3. Undock button → back to floating.
4. Resizable divider between chat and docked port.

**Unit tests:**
- `testDockRight` — sets isDocked, dockPosition = .right
- `testDockBottom` — sets isDocked, dockPosition = .bottom
- `testUndock` — clears isDocked, returns to floating

**User test:**
- Pop out a port, drag to right edge, verify it docks
- Verify chat resizes, divider is draggable
- Click undock, verify it floats again
- Verify sidebar, channels, companions all unaffected

---

### Step 9: Persistence, Update, Close, Multiple (P-203 through P-206)

**Goal:** Ports survive channel switches, update, close cleanly, coexist.

**What to build:**

1. **Persistence:** PortWindowManager on AppState. Ports survive channel switch.
   Bridge stays bound to original channel context.

2. **Update:** New ```port from same companion in same channel updates existing
   popped-out port HTML. Otherwise creates new inline.

3. **Close:** Close button removes from manager. Inline collapses to code preview.

4. **Multiple:** Array of panels. Multiple docked (stacked) or floating.

**Unit tests:**
- `testPortSurvivesChannelSwitch` — switch channel, port panel still exists
- `testPortUpdateReplacesContent` — same companion sends new port, content updates
- `testPortClose` — close removes from manager
- `testMultiplePorts` — two ports coexist

**User test:**
- Open port, switch channels, switch back — port still docked
- Ask companion to update the port — verify it refreshes in place
- Close port — verify clean removal
- Open two ports — verify both visible and functional

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

### Step 11: Bridge Write Operations (P-301, P-302)

**Goal:** Ports can send messages and list channels.

**What to build:**

1. `port42.messages.send(text)` calls appState.sendMessage().
2. `port42.channels.list()` returns channels from AppState.

**Unit tests:**
- `testMessageSend` — verify message appears in channel
- `testChannelsList` — returns all channels with correct fields

**User test:**
- Port with a button that sends a predefined message — click it, verify message appears in chat
- Verify message syncs to peers as normal

---

### Step 12: Permissions (P-303)

**Goal:** User approves before ports take write actions.

**What to build:**

1. First call to `port42.ai.complete()` or `port42.messages.send()` shows
   SwiftUI alert: "This port wants to [action]. Allow?"
2. Permission stored per port session. Reset on close.

**Unit tests:**
- `testPermissionPromptOnFirstWrite` — first write triggers prompt
- `testPermissionCached` — second write skips prompt
- `testPermissionResetOnClose` — new port session requires new approval

**User test:**
- Port tries to send message — verify alert appears
- Approve — verify message sends
- Close port, reopen — verify prompt appears again

---

## Build Order Summary

```
Step 1:  Port detection + static render     → ports appear in chat
Step 2:  Bridge core                        → ports talk to native
Step 3:  Bridge read APIs                   → ports read data
Step 4:  Bridge events                      → ports update live
Step 5:  Sandbox                            → ports can't escape
Step 6:  Companion context                  → companions know about ports
Phase 1 complete ─────────────────────────────────────────────

Step 7:  Pop out + virtual window           → ports detach from chat
Step 8:  Docking                            → ports snap to sides
Step 9:  Persistence + update + close       → ports are managed
Phase 2 complete ─────────────────────────────────────────────

Step 10: Bridge AI                          → ports think
Step 11: Bridge write ops                   → ports act
Step 12: Permissions                        → user controls ports
Phase 3 complete ─────────────────────────────────────────────
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
