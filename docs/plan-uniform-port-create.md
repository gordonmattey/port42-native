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

## Backlog (out of scope, noted so it's not lost)

- **Permission hardening** for `port.create({type:terminal, command})` from an untrusted web port
  (deferred per D-perm; harder to retrofit — accepted).
- Native terminal output-streaming bridge + `ports.list` JSON-vs-text format (already in
  `summer2026-todo.md`).
