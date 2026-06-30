# Uniform `port.create({type})` — one creation primitive for all port types

**Status:** review-complete, ready to build (decisions resolved 2026-06-29). Sequel to
`plan-first-class-terminal-ports.md` (done). Steered by `summer2026-todo.md`
("a terminal is just another port type", like "a swim is just a space").

**North star:** a terminal is *just a port type*. After this work, every port — web or terminal —
is created, listed, driven, and closed through the **`port.*` / `ports.list`** surface. The only
terminal-specific method left is `terminal_exec` (headless run-and-capture), which is the *only*
permission-gated terminal method.

---

## Problem

There is **no single "create a port" API**. Port creation is asymmetric and partly out-of-band:

| Want | How it's created today | Surface |
|---|---|---|
| **Web port (inline)** | a companion emits a ```` ```port HTML``` ```` **text fence**; the renderer detects it (`ConversationContent.messageSegments`) and instantiates an `InlinePortView` (a `WKWebView`). id is **derived from the message** (`entry.id[-pN]`). | inline in chat |
| **Web port (floating)** | user/companion hits "pop out" → `popOut(html:, portType:"web")` → a persisted `PortPanel` + `NSPanel`. | floating window |
| **Terminal port** | `terminal_spawn` **tool** → `spawnNativeTerminalPort` → `popOut(portType:"terminal")`. | floating window |

Consequences:
- Two different mental models for "a port": a web port is a **message-text-derived view** (no
  create call, no registration) until popped out; a terminal port is **always a registered panel**.
- `terminal.exec` (run a command, return stdout — headless, no surface) was **wrongly removed from
  the JS bridge** with the xterm sweep (verified: `PortBridge.swift` has no `terminal.*` cases). The
  *tool* `terminal_exec` still works (`ToolExecutor.swift:770`), but a **web port's own JS** can no
  longer run a command. That's a regression — `terminal.exec` is a headless utility, not the
  xterm-PTY path that was rightly removed.
- No `port.create` means callers can't make a port of a chosen type uniformly — terminals need a
  bespoke tool, web floats need `popOut`, web inlines need a magic text marker.
- Terminals are driven by a **parallel tool family** (`terminal_spawn/send/list`) instead of the
  `port.*` surface every other port uses.

## The seam that already exists

Internally everything registered converges on **one** call (verified `PortWindowManager.swift:239`):

```
popOut(html:, bridge:, spaceId:, createdBy:, messageId:, title:, portType: "web"|"terminal", in:) -> String  // port id
```

`portType` is already the discriminator; for a terminal port the `html` field carries a
JSON-encoded `TerminalPortConfig` (command/cwd) instead of HTML. `spawnNativeTerminalPort`
(`AppState.swift:2365`) is a thin wrapper over `popOut`. **So the uniform primitive is one method
away — it's just not exposed.**

## Target model

**`popOut`-with-`portType` becomes the one creation primitive, exposed as `port.create`.** Every
front-end (the ```` ```port ```` fence, the old `terminal_spawn`) becomes a thin caller of it.

```
port.create({
  type: "web" | "terminal",
  title?: "...",
  space_id?: "...",          // which space owns the port (fallback order in D5)

  // type:"web":
  html?: "<...>",            // a full port HTML body

  // type:"terminal" — the FULL Command-Companion field set, all OPTIONAL (D6):
  command?: "claude",        // executable / CLI name (claude/gemini get the hooks shim)
  args?: ["--continue"],
  cwd?: "/path",             // working directory
  systemPrompt?: "...",      // companion framing / personality (raw, not pre-baked)
  env?: { KEY: "val" },      // custom env vars
}) -> { id, title }          // or { error: "..." } on failure
```

**Parity (gordon):** `port.create({type:"terminal"})` accepts **everything a CLI Command Companion
takes** — `command, args, cwd, systemPrompt, env, title` — but **does NOT create a companion**
(no saved `AgentConfig`, not @mentionable, not restart-surviving). It's a straight terminal port
with optional parameters. Source of truth for the field list: `AgentConfig.createCommand` +
`NewCompanionSheet` command mode. Today `spawnNativeTerminalPort` is missing `env` and takes a
pre-baked `companionPrompt`; Step 2 widens it.

**Inline presence (D2):** `port.create` posts the **playable inline compact card** for *both*
types — same experience we have today. The card is the in-chat artifact; clicking ▶ activates a web
port inline / pops out the native terminal window. Terminals already post this card via
`spawnNativeTerminalPort(postCard:true)`; the web path must post the same card.

**No permission (D-perm):** opening a Ghostty terminal or a web port requires **no permission**.
`port.create` (and `port.push`) are ungated for any caller, including a web port creating another
port. The *only* permission-gated terminal method is `terminal_exec`. (Future hardening — a web port
spawning an arbitrary `command` terminal is a privilege surface — is **explicitly deferred**;
noted here so it's not forgotten. It'll be harder to retrofit later; accepted.)

Surfaces (both bridge + tool):
- **JS bridge:** `port42.port.create({...})` — a web port can create another port (incl. a terminal).
- **Tool / `/call`:** `port_create` / `port.create` (dot maps via `RemoteToolExecutor`).

Returns the **port id** — the registry key (`terminalControllers[id]` for terminals; `PortPanel.id`
generally), addressable by `port.update`, `port.push`, `port.close`, `ports.list`, etc.

## The whole terminal toolset folds into `port.*`

A terminal is just a port type, so it's driven through the same verbs as every other port:

| Need | Method (after this work) | Notes |
|---|---|---|
| Create (web or terminal) | **`port.create({type, ...})`** | the uniform primitive above. No permission. |
| Send input to a terminal | **`port.push(id, data)`** *(one verb, type-dispatched)* | terminal id → raw non-arming Ghostty inject (`controller.sendRaw`); web id → existing `port42:data` CustomEvent. No permission. |
| List terminals | **`ports.list({capabilities:["terminal"]})`** | terminal ports already report `capabilities:["terminal"]` (landed in `plan-first-class-terminal-ports` Step 5a); Step 5 adds `surfaceBound`. |
| Run a command headless | **`terminal_exec`** / `terminal.exec` | the **only** `.terminal`-gated method; restored to the JS bridge in Step 1. |
| ~~`terminal_spawn`~~ ~~`terminal_send`~~ ~~`terminal_list`~~ | **deleted** | tools + `ToolDefinitions` schemas + their `.terminal` permission-switch entries all go. |

The ```` ```port ```` **fence stays** — it's the LLM-text shorthand for an inline web port, its own
thing (message-derived). `port.create` is the imperative, registered-port path.

## Decisions (resolved)

- **D1 — `terminal_spawn` → DELETE** (not alias). Per "we don't need these anymore" — all three
  `terminal_spawn/send/list` tools go; their jobs move to `port.create` / `port.push` /
  `ports.list`.
- **D2 — `port.create` posts an inline card for BOTH types.** Preserves today's experience (a
  playable compact card regardless of type). Not floating-only.
- **D3 — `chat` type excluded.** The chat surface is system-owned per space, not user-created.
  `type` ∈ {`web`, `terminal`}.
- **D4 — `fs.*` is canonical** (gordon). The bridge implements `fs.read/write/pick`
  (`PortBridge.swift:907+`); docs (`llms.txt`, global CLAUDE.md) wrongly say `files.*`. Make `fs.*`
  canonical, add thin `files.*` aliases, fix the docs.
- **D5 — space ownership fallback.** `space_id` from the call → else the caller's own space (a CLI
  companion has `PORT42_SPACE_ID`; the bridge knows its `spaceId`) → else the UI's current space.
  Same rule the old `terminal_spawn` used; a port never lands orphaned.
- **D6 — no companion persistence.** `port.create({type:"terminal"})` makes a *port* with the full
  Command-Companion *parameter set*, but never a saved companion. No `persist` flag.
- **D-perm — no permission on `port.create` / `port.push`.** Only `terminal_exec` is gated
  (`.terminal`). Future hardening deferred (see Target model).

## Migration steps (incremental; each builds + commits green, with its own tests)

Ordering: regression fix → widen the spawn → expose the primitive → fold the verbs → delete the old
family → docs. Each step ships green on its own.

### Step 1 — Restore `terminal.exec` to the JS bridge (standalone regression fix) — ✅ DONE (2026-06-29)

Built + tests green (`TerminalExecBridgeTests` 5/5; all 67 terminal tests pass). Extracted
`ShellExec.run(_:cwd:timeout:)` (`Sources/Port42Lib/Services/ShellExec.swift`); `ToolExecutor`'s
private `executeCommand` deleted, `terminal_exec` now calls `ShellExec`; `PortBridge` `terminal.exec`
case + `port42.terminal.exec(command, opts)` JS wrapper restored; `PortPermission` maps
`terminal.exec → .terminal`. Not yet committed.


- **Extract** the headless runner: `executeCommand` is currently `private` to `ToolExecutor`
  (`:1170`). Lift it into a shared, non-`@MainActor` helper (e.g. `ShellExec.run(command:cwd:timeout:)`)
  callable from both `ToolExecutor` and `PortBridge`. `ToolExecutor.terminal_exec` now calls it too
  (no behaviour change there).
- **Re-add** `PortBridge` `case "terminal.exec"` → calls the shared helper, returns stdout.
- **Re-add** `PortPermission.permissionForMethod("terminal.exec") → .terminal`. (`spawn/send/resize/
  kill` stay removed.)
- **Tests — `TerminalExecBridgeTests` (Swift Testing):**
  - `permissionForMethod("terminal.exec") == .terminal` (pure).
  - `ShellExec.run("echo hi")` returns `"hi"` (real `Process`, deterministic, fast).
  - bridge `terminal.exec` with no `command` arg → `{error}` shape.

### Step 2 — Widen `spawnNativeTerminalPort` to full Command-Companion parity

- Add `env: [String:String] = [:]`; thread it into `TerminalPortConfig`. Confirm
  `command/args/cwd/title` already flow, and accept a **raw** `systemPrompt` (the method currently
  takes a pre-baked `companionPrompt` — keep that internal but expose `systemPrompt` as the input).
- **Tests — extend `TerminalPortConfigTests`:** a config built with `env`+`args`+`cwd`+`systemPrompt`
  JSON round-trips (encode → decode) with every field intact. (Pure; no window needed.)

### Step 3 — Add `port.create` (the uniform primitive)

- `PortBridge` `case "port.create"` + a `port_create` tool (`ToolExecutor` + `ToolDefinitions`).
- **Validation (factor a pure function):** `validatePortCreate(type:html:command:) -> Result`
  — `web` requires `html`; `terminal` requires `command`; unknown `type` → error.
- **Dispatch:** terminal → `spawnNativeTerminalPort(...)` (full params from Step 2). web is
  **caller-context-sensitive** (refines D2, decided 2026-06-29 w/ gordon):
  - **in-chat caller** (an in-app LLM companion composing a reply — `ToolExecutor` with
    `inChat=true`) → post an inline `` ```port `` message (today's inline web experience); the
    returned id is that message id.
  - **external caller** (a web port's own JS via `PortBridge`; a gateway `/call` / CLI / OpenClaw via
    `RemoteToolExecutor` with `inChat=false`) → `popOut(html:, portType:"web")` floating window, no
    card. "Just open a floating window."
  - Terminals are **always** native-window + `[terminal:]` card regardless of caller (they can't
    render inline). Only **web** branches on context.
  - Centralized in one `AppState.createPort(…, inline:)` dispatcher both surfaces call; the `inline`
    arg carries the routing decision (bridge → false; tool → `self.inChat`).
- Resolve `space_id` via the D5 fallback chain (explicit arg → caller's space → UI current).
- **Return** `{id, title}`; on `spawnNativeTerminalPort` returning `nil` (it's `String?`) or `popOut`
  failure → `{error: "..."}`. (Closes the error-handling gap.)
- **No permission:** `permission(for: "port_create") == .none`; the bridge case is ungated.
- **Tests — `PortCreateTests` (pure):**
  - `validatePortCreate`: web+html → web; terminal+command → terminal; bad type → error; web w/o
    html → error; terminal w/o command → error.
  - `port_create` present in `ToolDefinitions.all`; `permission(for:"port_create") == .none`.
  - error path: a stub spawn returning `nil` → `port.create` yields `{error}` (not a half-success).

### Step 4 — Overload `port.push` to one type-dispatched verb

- In `port.push` (`PortBridge.swift:700`): **first** check if `id` is a terminal
  (`appState.resolveTerminalController(idOrName:id)` hit) → `controller.sendRaw(stringData)` (raw,
  **non-arming**) → `{ok:true}` / `{error:"no live surface"}`. **Else** the existing
  `webViews[id]` → `port42:data` CustomEvent path. **Else** `{error:"not found"}`.
- **Tests — `PortPushDispatchTests` (pure):** factor the classifier
  `pushTarget(id:, terminalIds:, webIds:) -> .terminal | .web | .notFound` and assert a terminal id
  routes terminal, a web id routes web, an unknown id → notFound. (`sendRaw`/CustomEvent themselves
  need a live surface → manual verify.)

### Step 5 — Delete `terminal_spawn` / `terminal_send` / `terminal_list`; add `surfaceBound` to `ports.list`

- Delete the three tool cases in `ToolExecutor`, their `ToolDefinitions` schemas, and remove them
  from the `.terminal` permission switch (`ToolDefinitions.swift:700`) so **only `terminal_exec`**
  remains gated.
- **`surfaceBound` into `ports.list`:** the merge point that builds the `ports.list` response from
  `allPorts()` (`PortWindowManager.swift:517`, no `surfaceBound` today) must, for terminal entries,
  add `surfaceBound: controller.isSurfaceBound` from `appState.terminalControllers[id]` (the value
  `terminal_list` used to report). Keep `capabilities:["terminal"]`.
- **Tests — extend `TerminalToolSurfaceTests` (pure):**
  - `terminal_spawn`/`terminal_send`/`terminal_list` **absent** from `ToolDefinitions.all`.
  - `terminal_exec` present and `permission(for:) == .terminal`; `port_create`/`port.push` present
    and `.none`.
  - a pure `ports.list` row-builder helper: a terminal entry carries `surfaceBound` +
    `capabilities:["terminal"]`; a web entry carries neither terminal-only field.

### Step 6 — Reconcile `fs.*` / `files.*` (D4)

- `fs.read/write/pick` canonical; add thin `files.read/write/list` aliases routing to the same
  handlers.
- **Tests — `BridgeAliasTests` (pure):** `permissionForMethod("files.read") ==
  permissionForMethod("fs.read")`; both names are recognized/dispatch to the same handler.

### Step 7 — Docs sweep (no code)

- `llms.txt`, `ports-context.txt`, global CLAUDE.md, and the `help` reference describe **one**
  creation API: `port.create({type})`, `port.push` drives terminals + web, `ports.list` lists them,
  `terminal_exec` is the only permissioned terminal method, the three deleted tools are gone, and
  `fs.*` is canonical (`files.*` an alias).
- Verify `help` output reflects the new surface.

## Verification (gateway / curl matrix — run in a throwaway space)

Endpoint: `curl -s http://127.0.0.1:4242/call -d '{"method":"<m>","args":{...}}'`

| # | Call | Expect (proves) |
|---|------|-----------------|
| 1 | `port.create {type:"terminal", command:"bash", title:"t1", space_id:"<s>"}` | `{id,title}`; a **native Ghostty** window opens in space `<s>`; an inline card posts — uniform terminal create |
| 2 | `port.create {type:"web", html:"<h1>hi</h1>", title:"w1"}` | `{id,title}`; a registered web port; an inline **playable card** posts (D2) |
| 3 | `ports.list {capabilities:["terminal"]}` | lists `t1` with `surfaceBound:true` + `capabilities:["terminal"]` — replaces `terminal_list` |
| 4 | `port.push {id:"<t1-id>", data:"ls\n"}` | `ls` runs in the native window — terminal dispatch + `sendRaw` |
| 5 | `port.push {id:"<w1-id>", data:{"k":"v"}}` | web port receives the `port42:data` CustomEvent — web dispatch (same verb) |
| 6 | `port.create {type:"bogus"}` | `{error}` — validation |
| 7 | `port.create {type:"web"}` (no html) / `{type:"terminal"}` (no command) | `{error}` each — required-field validation |
| 8 | `terminal.exec {command:"date"}` from a web port (JS bridge) | returns stdout — **regression fixed** (Step 1) |
| 9 | `terminal_spawn` / `terminal_send` / `terminal_list` | method **gone** (D1) |
| 10 | `fs.read` and `files.read` of the same path | identical result — alias (D4) |

Subtler, eyeball in-app (not gateway-scriptable):
- A `port.create({type:"terminal", command:"bash"})` emitting `<p42>hi</p42>` → "hi" posts (tee path
  unaffected).
- A `claude` terminal's reply posts via `turnComplete`; a bare `port.push` does **not** arm the gate
  (non-arming send preserved from `plan-first-class-terminal-ports` Step 3).
- Clicking the inline card pops out / focuses the right window for each type.

## Step 8 — One port all the way down: unify inline + floating; the fence funnels into `port.create`

**Status:** planned (2026-06-29, w/ gordon). This is a follow-on phase that **reopens a decision from
the original plan**: Steps 1–7 said "the ```` ```port ```` fence stays — it's its own thing,
message-derived." Step 8 overrides that. The fence stays as *syntax* but stops being a *separate
rendering path*.

### Problem (the seam Steps 1–7 left)

A web port has **two unrelated host paths** today — it is **not the same port all the way down**:

| | Inline port | Floating port |
|---|---|---|
| Source of HTML | the **message text** (a ```` ```port ```` fence, parsed by `ConversationContent.messageSegments`) | the DB (`PortPanel.html`) |
| Identity | the message id | the panel UDID |
| Host | `InlinePortView` — its **own** `PortBridge` + WKWebView (`ConversationContent.swift:856`) | `PortWindowManager.popOut` → `PortPanel` + NSPanel + **another** WKWebView |
| Lifecycle | ephemeral, message-derived (no panel row until popped out) | registered + persisted |

Consequences:
- The inline port **is** a rendering of message text — the HTML lives in the message, not in a
  registered port.
- Pop-out (`InlinePortView.popOut`, `:991`) hands the same `html` string to `popOut`, which builds a
  **brand-new** `PortPanel` + WKWebView → the surface is **re-instantiated and DOM/JS state is lost**.
- `port.create`'s inline path (Step 3, `postInlineWebPort`) **posts a ```` ```port ```` fence
  message** — so the uniform primitive routes inline creation back through the message-text fence,
  entrenching the split.

### Target model — one registered port, two presentation modes, one WKWebView

- **One registered port.** `port.create` (and a fence parsed from an LLM reply) always produce a
  registered port: HTML in the DB, one `PortBridge`, one id, one WKWebView owned by the registry
  (`PortWindowManager.webViews[id]`). Same entity whether shown inline or floating.
- **Presentation is a mode, not a different object.** A port is presented **inline** (hosted in the
  chat at an anchor) or **floating** (hosted in an NSPanel). Switching modes **re-parents the same
  WKWebView NSView** (`removeFromSuperview` / `addSubview`) — never reloads. DOM/JS state is
  preserved (D8-2).
- **All inline ports are reference cards.** Inline presence is a `[port:<id>:<title>]` card in the
  message stream — exactly symmetric with native terminals' `[terminal:<id>:<title>]` card. The card
  is the chat anchor; it hosts the registry's WKWebView inline by id. The HTML no longer lives in the
  message.
- **The fence stays as extraction syntax.** An LLM can still write a ```` ```port … ``` ```` block in
  its reply — that's how we pull code out of a prose response (D8-1, gordon). But a parsed fence now
  **calls the `port.create` engine** (registers a port) and is replaced by a `[port:id]` card. The
  fence is an *input* to the one engine, not a parallel render path.

### Decisions (resolved 2026-06-29 w/ gordon)

- **D8-1 — keep the fence as extraction syntax.** "It helps us pull code from the LLM response." The
  fence is NOT dropped; it stops being a separate rendering path and instead funnels into
  `port.create`.
- **D8-2 — never lose DOM state on inline↔floating.** "No reason we should lose it." One WKWebView per
  port, owned by the registry, re-parented between the inline host and the NSPanel. Reload only on
  explicit `port.update`/`port.restore`, never on a presentation change.
- **D8-3 — inline ports are `[port:id]` reference cards**, symmetric with `[terminal:id]`. Unifies the
  two inline-card mechanisms into one.
- **D8-4 — inline ports become registered + persisted** (a panel row with `presentation:"inline"` and
  an `anchorMessageId`), not ephemeral message-derived views. On reload they re-render from the
  registry, not by re-parsing message text.
- **D8-5 — `port.create`'s inline path stops posting a raw fence.** It registers a port and posts a
  `[port:id]` card (revises Step 3 `postInlineWebPort`).

### Migration steps (incremental; each builds + commits green)

1. **Single-webview ownership.** Make the registry the sole owner of one WKWebView per port. Add an
   inline-presentation host (`NSViewRepresentable`) that **adopts** `webViews[id]` instead of
   `InlinePortView` creating its own bridge+webview. (Floating already uses `webViews[id]`.)
2. **`[port:id:title]` card.** A new inline reference segment + `PortCard` view (sibling to the
   `[terminal:…]` card path), parsed in `ConversationContent`. The card hosts the registry webview
   inline by id; when floating, it shows a "popped out — focus" state (like terminal cards).
3. **Re-parenting transition (the hard part).** Pop-out moves the webview NSView from the inline host
   into the NSPanel; dock-back reverses. Presentation flag flips; **no reload**. Risk: SwiftUI view
   identity churn must not recreate the representable each render (stable id / no state thrash).
   Test: a JS counter incremented inline survives a pop-out and a dock-back.
4. **Register inline ports.** `port.create({inline})` registers a panel (`presentation:"inline"`,
   `anchorMessageId`) + posts a `[port:id]` card; delete the html-in-message `InlinePortView` path.
5. **Fence funnel.** The LLM-reply fence parser, instead of a `.port(html)` segment rendered as a
   one-off webview, calls `port.create` (registered) and replaces the fence with a `[port:id]` card.
   Keep the fence *syntax* for extraction.
6. **Back-compat for old messages.** Existing messages with raw ```` ```port ```` fences must still
   render — register-on-first-render (adopt the fenced HTML into the registry the first time the
   message is shown) rather than a destructive migration.
7. **Docs.** Revert the Step 7 "fence is the inline shorthand for *creation*" framing → "the fence is
   how you can include a port in a reply; it becomes a registered port. `port.create` is the canonical
   primitive; every port is the same registered port whether shown inline or floating."

### Tests

- Pure: presentation-mode model + the `[port:id:title]` card parser (round-trip, like the terminal
  card parser).
- Invariant: one WKWebView per port id in the registry (no second webview created on pop-out).
- Integration / eyeball (not gateway-scriptable): DOM state survives inline→float→inline (JS counter);
  old fenced messages still render; `port.create({inline})` posts a `[port:id]` card, not a fence.

### Risk

The re-parenting of a live `WKWebView` across a SwiftUI inline host and an AppKit `NSPanel` without a
reload is the crux — `WKWebView` is an `NSView`, so the move is mechanically a `removeFromSuperview` +
`addSubview`, but SwiftUI's `NSViewRepresentable` lifecycle must be prevented from tearing down /
recreating the view on re-render. If this proves too fragile, the fallback is a snapshot+restore of
serializable port state — but that's explicitly the second choice; D8-2 wants the live view moved.

## Backlog (out of scope, noted so it's not lost)

- **Permission hardening** for `port.create({type:terminal, command})` from an untrusted web port
  (deferred per D-perm; harder to retrofit — accepted).
- Native terminal output-streaming bridge + `ports.list` JSON-vs-text format (already in
  `summer2026-todo.md`).
