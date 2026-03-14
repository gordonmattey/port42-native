# Phase 3: Generative Ports (P-300 + P-302)

**Last updated:** 2026-03-12

**Status:** Planning

**Branch:** `phase3-generative-ports`

---

## Context

Ports are live interactive HTML/CSS/JS surfaces in Port42's chat, rendered in sandboxed WKWebViews. They can read data through the `port42.*` bridge API but cannot yet call LLMs or take protected actions. Phase 3 adds AI capabilities at two levels and a permission system to gate them.

---

## API Shape: Three Levels, Two Entry Points

### Level 1: Raw AI (`port42.ai.complete`)

Just tokens, no personality. Port provides its own context or none.

```js
const answer = await port42.ai.complete("summarize this data", {
    model: "claude-sonnet-4-6",    // optional
    systemPrompt: "be concise",     // optional
    maxTokens: 1024,                // optional
    onToken: (token) => {},         // optional streaming
    onDone: (fullText) => {}        // optional completion
});
```

### Level 2: Companion Invoke (`port42.companions.invoke`)

Full companion personality + channel conversation context. Response is
port-private (does NOT appear in chat). Companion is NOT aware it was invoked.

```js
const analysis = await port42.companions.invoke("sage", "what do you think?", {
    onToken: (token) => {},
    onDone: (fullText) => {}
});
```

### Level 3: Multi-Companion (port-side pattern, no API needed)

```js
const results = await Promise.all(
    ["echo", "sage", "analyst"].map(c =>
        port42.companions.invoke(c, "rate this 1-10")
    )
);
```

---

## Design Decisions

1. **Channel context for companion invoke:** Yes. The companion sees recent
   channel messages. This is what makes it a companion call, not just raw AI
   with a system prompt. The companion reasons within the conversation.

2. **Response visibility:** Port-private only. Nothing appears in the chat
   stream. The port asked, the port got the answer, the port decides what to
   do with it. If the port wants to surface something, it calls
   `port42.messages.send()`.

3. **Companion awareness:** The invoked companion is NOT notified. No
   synthetic message injected. The port borrows a lens, not creates a social
   interaction.

4. **One permission for all AI:** `ai.complete` and `companions.invoke` share
   the same `.ai` permission grant. "This port wants to use AI" covers both.
   No permission fatigue.

5. **Model resolution chain:** Explicit option → invoked companion's config →
   creating companion's config → system default (`claude-opus-4-6`).

6. **No ensemble API:** Level 3 is a `Promise.all` pattern. Convergence
   detection (P-403) can layer on top later. No special bridge plumbing.

---

## Streaming Architecture

Token streaming reuses the existing callId mechanism with a new token
callback channel.

### JS Side

- `port42.ai.complete()` and `port42.companions.invoke()` generate a callId
- Store `onToken` callback in `_tokenCallbacks[callId]`
- Store promise resolve/reject + `onDone` in resolvers
- Native pushes tokens via `port42._tokenCallback(callId, token)`
  (evaluateJavaScript)
- Native resolves via `port42._resolve(callId, fullText)` on completion

### Native Side

- `handleMethod("ai.complete", ...)` checks permission, creates `LLMEngine`,
  wraps it in `PortAIHandler` implementing `LLMStreamDelegate`
- Each call creates its own `LLMEngine` instance (engine is
  one-request-at-a-time, concurrent port streams need separate engines)
- `llmDidReceiveToken` →
  `evaluateJavaScript("port42._tokenCallback(\(callId), \(token))")`
- `llmDidFinish` →
  `evaluateJavaScript("port42._resolve(\(callId), \(fullText))")` + cleanup
- `llmDidError` →
  `evaluateJavaScript("port42._reject(\(callId), \(errorMsg))")` + cleanup

### Deferred Resolution

`handleMethod` currently always returns a value that gets resolved
immediately. For streaming calls, it returns a sentinel
`["__deferred__": true]` and `userContentController(didReceive:)` checks
for this and skips the automatic `_resolve` call. The `PortAIHandler`
resolves the promise later when the stream completes.

---

## Permission Architecture

- `PortPermission` enum: `.ai` (later: `.terminal`, `.microphone`, `.camera`,
  `.screen`, `.clipboard`, `.fileSystem`)
- `PortBridge` gains:
  - `grantedPermissions: Set<PortPermission>`
  - `@Published var pendingPermission: PortPermission?`
  - `permissionContinuation: CheckedContinuation<Bool, Never>?`
- Permission guard runs in `handleMethod` before the method switch. If
  permission needed and not granted, suspends via continuation.
- Parent SwiftUI view observes `bridge.pendingPermission` and shows
  `.confirmationDialog`
- Allow → `bridge.grantPermission()` resumes continuation with `true`,
  inserts into `grantedPermissions`
- Deny → `bridge.denyPermission()` resumes with `false`, returns error
- Permission persists for port session lifetime. Reset when bridge is
  deallocated (port closed).

---

## Components

### New Files

#### `Sources/Port42Lib/Services/PortPermission.swift`

```
PortPermission enum
  .ai
  .terminal      (future)
  .microphone    (future)
  .camera        (future)
  .screen        (future)
  .clipboard     (future)
  .fileSystem    (future)

permissionForMethod(_ method: String) -> PortPermission?
  "ai.complete"        → .ai
  "companions.invoke"  → .ai
  "ai.cancel"          → nil
  everything else      → nil

permissionDescription(_ perm: PortPermission) -> (title: String, message: String)
  .ai → ("AI Access", "This port wants to use AI. Allow?")
```

#### `Sources/Port42Lib/Services/PortAIHandler.swift`

```
PortAIHandler: NSObject, LLMStreamDelegate
  callId: Int
  engine: LLMEngine          (strong ref, one per stream)
  bridge: PortBridge          (weak ref)

  llmDidReceiveToken(_ token: String)
    → bridge?.pushToken(callId, token)

  llmDidFinish(fullResponse: String)
    → bridge?.resolveCall(callId, fullResponse)
    → bridge?.removeStream(callId)

  llmDidError(_ error: Error)
    → bridge?.rejectCall(callId, error.localizedDescription)
    → bridge?.removeStream(callId)
```

### Modified Files

#### `Sources/Port42Lib/Services/PortBridge.swift`

Properties to add:
- `grantedPermissions: Set<PortPermission>`
- `activeStreams: [Int: PortAIHandler]` (keyed by callId)
- `@Published var pendingPermission: PortPermission?`
- `permissionContinuation: CheckedContinuation<Bool, Never>?`

Methods to add:
- `grantPermission()` / `denyPermission()` — resume continuation
- `pushToken(_ callId: Int, _ token: String)` — evaluateJavaScript
- `resolveCall(_ callId: Int, _ result: String)` — evaluateJavaScript
- `rejectCall(_ callId: Int, _ error: String)` — evaluateJavaScript
- `removeStream(_ callId: Int)` — cleanup activeStreams

handleMethod additions:
- Permission guard before switch statement
- `"ai.complete"` case: extract prompt/options, create PortAIHandler, start
  LLMEngine, return `["__deferred__": true]`
- `"ai.cancel"` case: find stream by callId, cancel engine, cleanup
- `"companions.invoke"` case: resolve companion by name/id, build system
  prompt + channel context messages, create PortAIHandler with companion's
  model config, return `["__deferred__": true]`

userContentController modification:
- Check for `["__deferred__": true]` sentinel in result, skip `_resolve` call

bridgeJS additions:

```js
// Token callback channel
port42._tokenCallbacks = {};
port42._tokenCallback = function(callId, token) {
    const cb = port42._tokenCallbacks[callId];
    if (cb) try { cb(token); } catch(e) { console.error(e); }
};

// Reject channel
port42._reject = function(callId, error) {
    const r = _pending[callId];
    if (r) { delete _pending[callId]; r({"error": error}); }
};

port42.ai = {
    complete: function(prompt, opts) {
        opts = opts || {};
        const id = ++_callId;
        if (opts.onToken) port42._tokenCallbacks[id] = opts.onToken;
        return call('ai.complete', [prompt, {
            model: opts.model,
            systemPrompt: opts.systemPrompt,
            maxTokens: opts.maxTokens
        }]).then(function(r) {
            delete port42._tokenCallbacks[id];
            if (r && r.error) throw new Error(r.error);
            if (opts.onDone) opts.onDone(r);
            return r;
        });
    },
    cancel: function(callId) { return call('ai.cancel', [callId]); }
};

// Extend existing companions namespace
port42.companions.invoke = function(id, prompt, opts) {
    opts = opts || {};
    const cid = ++_callId;
    if (opts.onToken) port42._tokenCallbacks[cid] = opts.onToken;
    return call('companions.invoke', [id, prompt]).then(function(r) {
        delete port42._tokenCallbacks[cid];
        if (r && r.error) throw new Error(r.error);
        if (opts.onDone) opts.onDone(r);
        return r;
    });
};
```

#### `Sources/Port42Lib/Views/ConversationContent.swift`

`InlinePortView`: add `.confirmationDialog` bound to `bridge.pendingPermission`

#### `Sources/Port42Lib/Views/PortWindowManager.swift`

`PortPanelContentView`: add `.confirmationDialog` bound to panel's bridge

#### `Sources/Port42Lib/Views/ContentView.swift`

`DockedPortView`: add `.confirmationDialog` bound to panel's bridge

#### `Sources/Port42Lib/Resources/ports-context.txt`

- Move `port42.ai.complete` from "FUTURE" to main "BRIDGE API REFERENCE"
- Add `port42.companions.invoke` to main reference
- Add permission and streaming docs
- Add example port using AI

---

## Implementation Order

### Step 1: Permission Infrastructure

- Create `PortPermission.swift` (enum + mapping + descriptions)
- Add permission state and guard to `PortBridge`
- Write `PortPermissionTests.swift`
- No UI yet. Ungranted permissions return error to JS.

### Step 2: Permission UI

- Add `.confirmationDialog` to `InlinePortView`, `PortPanelContentView`,
  `DockedPortView`
- All three observe `bridge.pendingPermission` and call
  `bridge.grantPermission()` / `denyPermission()`
- Manual test: port calling `ai.complete` shows dialog in all three states

### Step 3: Raw AI (`ai.complete`)

- Create `PortAIHandler.swift`
- Add deferred resolution, `pushToken`, `resolveCall`, `rejectCall`,
  `removeStream` to `PortBridge`
- Add `"ai.complete"` and `"ai.cancel"` cases to `handleMethod`
- Add `port42.ai` namespace to `bridgeJS`
- Write `PortAITests.swift`

### Step 4: Companion Invoke (`companions.invoke`)

- Add `"companions.invoke"` case to `handleMethod`
- Resolve companion by name or id from `appState.companions`
- Build messages array: companion's system prompt + recent channel messages +
  port's prompt as latest user message
- Create `PortAIHandler` with companion's model config
- Add `port42.companions.invoke` to `bridgeJS`
- Small addition on top of Step 3 infrastructure

### Step 5: Companion Context + Docs

- Update `ports-context.txt` with AI and invoke docs
- Move `ai.complete` from "FUTURE" to live API reference
- Add example ports

### Step 6: Integration Testing

- Test all three port states (inline, floating, docked)
- Test concurrent streams
- Test permission flow end-to-end
- Test companion invoke with channel context
- Test error paths (no auth, permission denied, unknown companion)

---

## Testing Strategy

### Unit Tests: `PortPermissionTests.swift`

```
@Suite("Port Permissions")
- permissionForMethod maps "ai.complete" → .ai
- permissionForMethod maps "companions.invoke" → .ai (same permission)
- permissionForMethod returns nil for "user.get", "companions.list", etc
- New bridge has empty grantedPermissions
- Granting .ai persists within session
```

### Unit Tests: `PortAITests.swift`

```
@Suite("Port AI")
- PortAIHandler token callback routes to bridge.pushToken
- PortAIHandler finish callback routes to bridge.resolveCall
- PortAIHandler error callback routes to bridge.rejectCall
- activeStreams cleanup on finish
- activeStreams cleanup on error
- ai.cancel removes stream and cancels engine
- ai.complete model resolution: explicit > companion default > system default
- companions.invoke resolves companion by name
- companions.invoke resolves companion by id
- companions.invoke with unknown companion returns error
- companions.invoke injects companion system prompt
- companions.invoke includes recent channel messages
```

### Manual Tests

1. Port with `await port42.ai.complete("hello")` → permission prompt → allow
   → response appears
2. Permission prompt → deny → error shown in port
3. Second AI call skips prompt (permission cached)
4. Close port, reopen → prompt appears again
5. Streaming with `onToken` shows real-time tokens
6. `port42.companions.invoke("sage", "what do you think?")` → response has
   sage's personality
7. Invoke three companions with `Promise.all` → three distinct responses
8. Pop-out port AI call → permission prompt on floating window
9. Docked port AI call → permission prompt on docked panel
10. Cancel mid-stream → no more tokens
11. Normal companion chat in channel is completely unaffected by port AI calls

---

## Dependencies

```
PortPermission.swift ──────────────────────────┐
                                               │
PortBridge.swift (permission guard) ◄──────────┘
        │
        ├── Permission UI (3 views) ◄──── .confirmationDialog
        │
        ├── PortAIHandler.swift ◄──── LLMStreamDelegate
        │       │
        │       └── LLMEngine (one per stream)
        │               │
        │               └── AgentAuthResolver.shared
        │
        ├── "ai.complete" handler
        │
        ├── "companions.invoke" handler
        │       │
        │       ├── AppState.companions (resolve by name/id)
        │       ├── AgentConfig (system prompt, model)
        │       └── AppState.messages (channel context)
        │
        └── bridgeJS (port42.ai namespace)
```
