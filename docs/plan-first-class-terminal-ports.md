# First-class terminal ports — terminal.* API on native Ghostty

## Status / resume (2026-06-27)

**⚠ ON RESTART — TRUST GIT, NOT THE CHAT.** This session's chat history reverts on reboot
(`--continue` resumes an older transcript; see dev-reboot notes). The code + commits are the only
truth. **Before re-planning, run `git log --oneline -10` and
`grep -rn spawnNativeTerminalPort Sources/`** and read the step table below against the tree.
Do NOT "start Step 1" — it's long done. Commit after every step so nothing rides uncommitted.

**Steps 1 AND 2 are DONE and committed** — `da42eb1` (Step 1: extract `spawnNativeTerminalPort`,
drop the dead `ghosttyTerminalSurfaces` dict) and `d05c89e` (Step 2: `terminal_spawn` tool →
`spawnNativeTerminalPort`, returns the port id). Build green.

**Next action is Step 3** — re-point `terminal_send` to resolve native controllers by id
(`terminalControllers[id] → controller.inject`); add a `[name: id]` alias for friendly-name
routing. NOTE **D4** (below): output-streaming is descoped and **`terminal_bridge` raw-output is
dropped**, so Step 3 is now just `terminal_send`, not `terminal_bridge`. **Step 3 is fully specified in
"## Step 3 — detailed plan" below — read that, not just this header.** Then Step 5 (D1 deletion
of `TerminalBridge` + PortBridge `terminal.*` cases — both still present) and Step 6 (spaceId).

**Motivation resolved — output-streaming is DESCOPED (see "Review + descope (2026-06-26)").**
The reason this work started today was to live-stream a claude terminal's output back into chat.
That need is *already met by the committed hooks/`turnComplete` path* — and raw-streaming a TUI
was the wrong mechanism anyway (claude is a TUI; teeing its bytes streams redraw garbage, which is
exactly why hooks terminals suppress the tee). So the remaining value is **not** streaming — it is
**giving companions a native terminal instead of a hand-rolled xterm `web` port**, plus cleanup.
`terminal_bridge` raw-output-to-space is dropped (D4).

Decisions still locked: D1 native-only / D2 `terminal_exec` headless / D3 spaceId.

Already-committed groundwork this is built on (HEAD ≈ `b9136bf`, all pushed except the latest
few local commits): native terminal companion messaging (typing/auto-reopen/routing/proactive
posts), space-membership API, command-agent shell-exec + stdout, startup crash guard, Ghostty
scroll/inject-submit/gate fixes, licensing + vendored GhosttyKit, dev-reboot settle fix.

Forward-looking model that should *steer* (not block) this build: **`docs/summer2026.md`** —
swim collapses into space (space-scoped relationship memory), and per-(companion,space) terminal
session ids (`UUIDv5(companion.id+space.id)`, `--session-id`/`--resume`, drop `--continue`).

## Problem

When a companion (or any caller) asks to "spawn a terminal," it gets a **web port running
xterm.js**, not a native Ghostty terminal. That throws away the whole point of the Ghostty
migration — GPU rendering, real PTY ownership, hooks, injection.

Observed: `@echo spawn a terminal port` → echo generated an HTML port using xterm.js (loaded
from CDN now that the bundle is gone). There is **no tool/API that creates a native terminal
port**, so companions fall back to hand-rolling xterm.

## Port types

Port42 has exactly three port types: **`web`**, **`chat`**, **`terminal`**.

- `web` — a WKWebView rendering arbitrary HTML/JS (a builder *may* embed xterm.js in their own
  HTML — that's their choice, inside their DOM).
- `chat` — the space's chat surface.
- `terminal` — a **native Ghostty surface** (Metal `NSView`), owns its PTY, with the
  inject + tee + hooks machinery built in Steps 1–9.

**A terminal must be a `terminal` port. Never a `web` port.** The bug is that the `terminal.*`
API and companion terminal-spawns currently produce `web`/xterm instead of `terminal`.

## Hard constraint (shapes the whole design)

**Ghostty renders into a native `NSView` (Metal). It cannot live inside a WKWebView's DOM.**
So a terminal *embedded inside a custom web port's HTML* can only be xterm.js — but a terminal
that is a *standalone surface* can and must be native Ghostty (`terminal` port). The platform's
`terminal.*` API yields standalone terminals, so it should always yield `terminal` ports.

## Current state — two disconnected systems

| | TerminalBridge (legacy) | Ghostty surface (native) |
|---|---|---|
| PTY | Port42 `forkpty` | Ghostty owns it (EXEC mode) |
| Render | bytes → JS → **xterm.js in a `web` port** | native Metal `NSView` (`terminal` port) |
| Input | `terminal.send` → PTY write | `ghostty_surface_text_input` |
| Output | byte callback → webview | tee callback → `<p42>` / hooks → space |
| Backs | `terminal.spawn`, `terminal_exec/send` | companion terminals (`spawnTerminalAgentPort`) |

Everything we need (spawn, inject, tee-to-space, hooks) already exists on the Ghostty side from
the companion work. The job is to **re-point the `terminal.*` API onto native `terminal` ports.**

## Goal

All terminal creation → a `terminal` port (native Ghostty surface), addressable by **port id**.
`terminal.send` / `terminal_send` / `terminal_bridge` operate on those surfaces. Companions get
native terminals on demand; nobody hand-rolls xterm.

## Design

1. **Generalize the spawn.** Extract `spawnTerminalAgentPort` →
   `spawnNativeTerminalPort(command:cwd:spaceId:companionName?:)` that creates a `terminal`
   port and returns its **port id**. The companion path becomes a thin caller of this.

2. **Register surfaces by port id.** Today `ghosttyTerminalSurfaces` is keyed by companion
   name; generalize to **port id** (companion terminals also get an id) so any caller can
   address a specific terminal. Keep a name→id alias for companion @mention routing.

3. **Re-point the API to native `terminal` ports:**
   - `terminal.spawn(opts)` / `terminal_exec` → `spawnNativeTerminalPort(...)`, return the id.
     (`terminal_exec`'s run-and-capture stays for headless one-shots; the *visible* terminal it
     may open is a `terminal` port.)
   - `terminal.send(id, data)` / `terminal_send` → resolve the id; if it's a Ghostty surface,
     `ghostty_surface_text_input`; (legacy `TerminalBridge` ports still resolve for back-compat
     during migration).
   - `terminal_bridge(name)` → the tee→space path already exists; point it at the surface tee.
   - `terminal.resize` → `ghostty_surface_set_size`; `terminal.kill` → teardown the port.

4. **`<p42>` + hooks come for free** — the native controller already runs `extractP42Tags` on
   the tee (non-hooks tools) and the hooks→turnComplete path (claude/gemini). So a `terminal`
   port spawned for `bash` posts its `<p42>` tags automatically; a claude one posts via hooks.

5. **Command-agent stdout regression (related).** `CommandAgent` (the *background*,
   non-terminal `mode=command` path) currently drops any stdout line that isn't NDJSON
   (`CommandAgent.swift:159`). Restore raw-stdout handling: treat non-JSON lines as plain
   content (accumulate) and run `<p42>` extraction over them, so a plain `bash` agent posts
   again. This is independent of the native-terminal work but in the same "terminals/agents
   produce output" theme.

## Decision points (for the walk-through)

- **D1 — fate of TerminalBridge / xterm.** Options:
  - (a) **Commit to native:** `terminal.*` always yields `terminal` ports; remove the
    xterm/`web` terminal path entirely. Cleanest; matches "terminals are `terminal` ports."
    Cost: a custom `web` port can no longer get a Port42-driven embedded terminal (it can still
    load its own xterm from a CDN if it really wants one).
  - (b) **Keep a low-level byte pipe** (`terminal.pipe`) for the rare embedded-in-HTML case,
    and make `terminal.spawn`/`terminal.open` native. Two methods, preserves the niche.
  - Recommendation: **(a)** unless we know a real consumer embeds terminals in custom HTML.

- **D2 — does `terminal_exec` open a visible terminal or stay headless?** Today it's headless
  (run + capture). Keep it headless; add `terminal.open`/make `terminal.spawn` the visible
  native path. (Avoids surprising windows from every `terminal_exec`.)

- **D3 — spaceId threading (Step 10.3).** Every spawn path must carry the caller's `spaceId`
  (a CLI companion has `PORT42_SPACE_ID`) so the new `terminal` port lands in the right space,
  not orphaned. Audit: chat tool-use, RPC `/call`, JS bridge, companion spawn.

## Decisions (resolved 2026-06-26)

- **D1 → native-only.** `terminal.*` always yields a `terminal` (Ghostty) port. Remove the
  xterm/`web` terminal path entirely: delete `TerminalBridge`, drop `port42.terminal.*` from
  the web-port JS bridge, strip the embedded-terminal section from `ports-context.txt`.
  Rationale: a web port hosting an embedded terminal is a niche nobody uses, and the port CSP
  blocks CDN xterm anyway — so keeping a fenced byte pipe buys nothing real.
- **D2 → `terminal_exec` stays headless** (run + capture). Visible terminals come only from
  the new native `terminal_spawn`.
- **D3 → thread `spaceId` into the remote path.** `RemoteToolExecutor` builds
  `ToolExecutor(spaceId: nil)` (`ToolExecutor.swift:1331`), so remote `/call` spawns orphan
  into the UI's current space. Default it from `input["space_id"]`, and have the new
  `terminal_spawn` tool doc tell companions to pass `space_id` (mirrors `messages.send`).

### Corrections found while tracing the code (supersede the prose above)

- **`ghosttyTerminalSurfaces` (`AppState.swift:732`) is dead** — declared, never read/written.
  Step 1's "re-key surfaces by port id" does not apply; surface binding happens via
  `controller.bindSurface($0)` (`PortWindowManager.swift:1094`). Action: delete the dead dict.
- **`terminalControllers` is already keyed by `panel.id` (the UDID)**, and `popOut` already
  returns that id (`PortWindowManager.swift:232`) — `spawnTerminalAgentPort` just discards it.
  Step 1 only needs to *capture and return* it.
- **Command-agent stdout regression (#5) is already fixed** — `CommandAgent.swift:207`
  accumulates `rawStdout`, runs `extractP42Tags`, and posts. Migration step 4 is now
  verify-only, not a fix.

## Review + descope (2026-06-26)

Done after tracing the code that Steps 2–6 actually touch. Supersedes the original migration-step
prose where they conflict.

- **D4 — drop output-streaming-to-chat.** The original `terminal_bridge` streamed raw PTY bytes
  into the space as messages (`autoStartOutputBridge` → `OutputBatcher`). The native equivalent is
  *technically* free to restore — the Ghostty PTY tee already feeds `TerminalOutputProcessor`,
  whose cleaned `onFlush` is currently discarded (`GhosttyTerminalController.swift:114`,
  `onFlush = { _ in }`) — but the **use case is dead**: claude output via the tee is TUI garbage,
  and claude's real reply already posts via `turnComplete`. So: keep the always-on `<p42>` +
  `turnComplete` posting (free, already wired); **remove `terminal_bridge` / `terminal_unbridge`
  and the auto-bridge raw-streaming path entirely.** A companion drives a terminal with
  `terminal_send`; meaningful output comes back via `<p42>` (bash) or `turnComplete` (claude).

- **`terminal_send` arming side-effect.** `controller.inject(_:)`
  (`GhosttyTerminalController.swift:170`) *arms the post gate* (next `turnComplete` broadcasts) and
  drops silently if no surface is bound (`:173`). For the `terminal_send` tool, add a **raw,
  non-arming send** path + a real "no live surface" error — don't reuse the companion message-
  inject path.

- **Step 3 / Step 5 scope is wider than the original list.** `TerminalBridge` is read in
  `PortBridge` (property + spawn/send/resize/kill/cwd `:46–955`), `PortWindowManager`
  (`terminalSession(forPortNamed:)` `:462–541`), `ToolExecutor` (`autoStartOutputBridge` + all
  terminal cases), **and AppState's whole inline-bridge machinery** (`inlineTerminalBridges`
  `:1333–1356, :1453–1461, :2575`). Step 3 must re-point or delete *every* read before Step 5 can
  compile. Upside: since `spawnNativeTerminalPort` always pops out a window, native terminals are
  never inline — so the `inlineTerminalBridges` path becomes **dead code to delete, not port**.

- **Inline placeholder (Step 5).** Native Ghostty can't render in the WKWebView DOM, but the chat
  should still show an inline artifact. Reuse `PortCompactBlock` (`ConversationContent.swift:965`,
  the collapsed "click to open" card used for non-autoplay ports): a `terminal` variant (terminal
  icon, "Open terminal") whose action pops out the floating native window. `spawnNativeTerminalPort`
  posts the placeholder rather than only auto-popping a floating window. This *is* the terminal's
  inline presence.

- **`name→id` alias is unnecessary.** Companions already resolve by value-scan over
  `terminalControllers.values` on `config.companionName` (`AppState.swift:1371, :1399`). Step 3
  just needs a native title/name resolver to replace the `TerminalBridge`-based
  `terminalSession(forPortNamed:)`.

- **Step 6 is narrower than written.** Don't mutate `RemoteToolExecutor`'s
  `ToolExecutor(spaceId: nil)` init (changes every remote tool). Resolve spaceId **inside the
  `terminal_spawn` case** with the existing 4×-used pattern
  `input["space_id"] as? String ?? spaceId ?? appState.currentSpace?.id ?? ""`.

- **Test coverage.** Pure pieces are covered (`TerminalOutputProcessorTests`,
  `CompanionPostGateTests`, `TerminalPortConfigTests`, `TerminalControllerDrainTests`). Gaps to add:
  Step 2 — assert `terminal_spawn` is in `ToolDefinitions` + `permission(for:) == .terminal` +
  spaceId resolution; Step 3 — factor a pure `resolveTerminalController(idOrName:)` and test
  id-hit / name-scan / not-found. Window-spawn + inline placeholder = manual verify (this codebase
  has ~no view tests). `TerminalBridgeTests` is deleted with the class in Step 5.

## Migration steps (incremental, verifiable)

1. **DONE (`da42eb1`).** Extracted `spawnNativeTerminalPort` returning the **port id**; deleted the
   dead `ghosttyTerminalSurfaces` dict (no behaviour change). **Detailed below.**
2. **(next)** Add a `terminal_spawn` tool (does not exist today — that absence is why companions
   hand-roll xterm) → calls `spawnNativeTerminalPort`, returns the id. Add it to the
   `permission(for:)` switch (`ToolDefinitions.swift:709`, `.terminal`) and resolve spaceId via the
   `input["space_id"] ?? spaceId ?? current` pattern. Verify a companion "spawn a terminal" yields a
   `terminal` port (not `web`/xterm).
3. Re-point `terminal_send` to resolve native controllers by id (`terminalControllers[id]`) with a
   **raw, non-arming send** + a native title/name resolver (replacing the `TerminalBridge`-based
   `terminalSession(forPortNamed:)`); `terminal_list` reads native controllers. **Remove
   `terminal_bridge`/`terminal_unbridge` + `autoStartOutputBridge` (D4).** Verify `terminal_send`
   drives a native terminal; `<p42>`/`turnComplete` posting still works.
4. Verify the command-agent stdout path still posts a plain `bash` agent (already fixed).
5. Apply D1 — delete `TerminalBridge`, the `terminal.*` cases in `PortBridge` (`:895–964`), the JS
   `terminal` object, the `ports-context.txt` terminal section, **and the now-dead
   `inlineTerminalBridges` machinery**. Add the `PortCompactBlock` terminal-placeholder variant so a
   spawned terminal has inline chat presence.
6. spaceId audit (D3): confirm `terminal_spawn` resolves spaceId in-case (done in Step 2); no
   `RemoteToolExecutor` init change.

## Step 1 — detailed plan

**Goal:** split `spawnTerminalAgentPort` (`AppState.swift:2427`) into a generic
`spawnNativeTerminalPort(...) -> String` (any caller gets a native `terminal` port + its id)
and a thin `spawnTerminalAgentPort` that keeps only the companion-specific bits. No behaviour
change — the companion path produces the identical port.

**The seam:**

```
func spawnNativeTerminalPort(
    command: String,           // "claude", "bash", "htop"
    args: [String] = [],
    cwd: String,
    spaceId: String,
    title: String,
    companionName: String,     // controller identity (defaults to title for non-companions)
    companionPrompt: String? = nil
) -> String                    // the port id (UDID)
```

Generic (moves into `spawnNativeTerminalPort`): hooks-name resolution (`isHooksCapable` →
bare name vs full path) + arg quoting → `startupCommand`; build `TerminalPortConfig`;
JSON-encode + `popOut(..., portType: "terminal")`; **capture and return** the id.

Companion-specific (stays in `spawnTerminalAgentPort`): resolve `companion.args`/`workingDir`;
build framing + user `systemPrompt` (`{{NAME}}`/`{{SPACE}}`) → `companionPrompt`; post the
"X joined" announcement; then call `spawnNativeTerminalPort(...)`.

**Edits:** (1) `AppState.swift` add `spawnNativeTerminalPort`, move lines ~2450–2488 into it,
rewrite `spawnTerminalAgentPort` as the thin caller. (2) Delete `ghosttyTerminalSurfaces`
(`:732`). (3) Caller at `:1420` unchanged.

**Out of step 1:** no `terminal_spawn` tool (step 2); no `terminal_send` re-point (step 3);
no name→id alias yet (step 3 — id-addressing already works via `terminalControllers[id]`).

**Verification:**
- The returned id **is** the registry key by construction: `popOut` returns `panel.id`; the
  same `panel` flows into `createWindow` → `makeTerminalController(for: panel)`
  (`PortWindowManager.swift:683`, synchronous within `popOut`) which keys
  `terminalControllers[panel.id]`. Not coincidence — an invariant to read off the code.
- Runtime: one temporary log at the spawn site —
  `NSLog("[verify-step1] spawned id=%@ controllerPresent=%@", id, terminalControllers[id] != nil ? "Y":"N")`.
  `./build.sh --run`, trigger a companion terminal → expect `controllerPresent=Y`, id matches.
- Build succeeds with the dead dict removed (proves it was dead); companion terminal behaves
  identically (hooks/`<p42>` still post). No isolated `@Test` — controller creation needs a
  real window + Ghostty surface, so verification is the construction trace + one-shot log.

## Step 3 — detailed plan

**Goal:** `terminal_send` / `terminal_list` operate on **native Ghostty controllers**
(`terminalControllers[id]`), not legacy `TerminalBridge`/xterm. Add a **raw, non-arming** send
with a real "no live surface" error. Delete the output-streaming-to-chat path entirely (D4):
`terminal_bridge`, `terminal_unbridge`, `autoStartOutputBridge`, `bridgeSpaceTerminals`.

**Why the current code misses native terminals:** every `terminal_send` branch resolves through
`panel.bridge.terminalBridge` (`ToolExecutor.swift:809, 818, 828`) or
`terminalSession(forPortNamed:)` (`PortWindowManager.swift:462`, also `terminalBridge`-based).
A native `terminal` port has **no `terminalBridge`** — it's tracked in
`appState.terminalControllers[panel.id]` (`AppState.swift:723, 2414`). So today every branch
misses and `terminal_send` falls to the error. Step 3 re-points resolution onto the controllers.

### The seam — a pure, testable resolver

Controllers aren't constructible in a unit test (need a real window + Ghostty surface), so split
resolution into a pure id/name matcher (tested) + a thin AppState wrapper (manual-verify):

```swift
// AppState.swift — pure, no controller construction, unit-testable
static func resolveTerminalId(_ idOrName: String,
                              candidates: [(id: String, name: String)]) -> String? {
    if candidates.contains(where: { $0.id == idOrName }) { return idOrName }     // 1. id-hit
    let q = idOrName.lowercased()
    if let m = candidates.first(where: { $0.name.lowercased() == q }) { return m.id }   // 2a. exact name
    if let m = candidates.first(where: { $0.name.lowercased().contains(q) }) { return m.id } // 2b. contains
    return nil                                                                    // 3. not-found
}

func resolveTerminalController(idOrName: String) -> GhosttyTerminalController? {
    let cands = terminalControllers.map { (id: $0.key, name: $0.value.config.companionName) }
    return AppState.resolveTerminalId(idOrName, candidates: cands).flatMap { terminalControllers[$0] }
}
```

`config.companionName` is the right name key: Step 1's seam sets `companionName: title` for
non-companion spawns (`terminal_spawn`), so one scan covers both companion @mention routing and
plain titled terminals. (Matches the existing value-scan at `AppState.swift:1371, 1399`.)

### The raw, non-arming send

`controller.inject(_:)` (`GhosttyTerminalController.swift:170`) **arms the post gate** and drops
silently when no surface is bound (`:173`). `terminal_send` must NOT arm (that's for company
message injection). Add a sibling:

```swift
// GhosttyTerminalController.swift — write to surface WITHOUT arming the gate
func sendRaw(_ data: String) -> Bool {
    guard let inject = injectToSurface else { return false }   // real "no live surface"
    inject(data)
    return true
}
```

### Edits

1. **`GhosttyTerminalController.swift`** — add `sendRaw(_:) -> Bool` (above).
2. **`AppState.swift`** — add `static resolveTerminalId` + `resolveTerminalController` (above).
3. **`ToolExecutor.swift` `terminal_send` (`:797–844`)** — replace all four legacy branches with:
   resolve via `appState.resolveTerminalController(idOrName: name)`; on hit
   `controller.sendRaw(processed)` → `"Sent to \(name)"`, or on `false`
   `"Error: terminal '\(name)' has no live surface"`; on miss, error listing native terminals
   from `terminalControllers` (`id` + `config.companionName`). Drop every `autoStartOutputBridge`
   call. Keep the `processEscapes` + `\r`-append preamble (`:802–806`).
4. **`ToolExecutor.swift` `terminal_list` (`:846–862`)** — read `appState.terminalControllers`:
   per entry emit `{id, name: config.companionName, surfaceBound: isSurfaceBound,
   capabilities:["terminal"]}`. Drop `sessionId`/`createdBy`/`bridged` (TerminalBridge-only).
5. **Delete (D4):** `terminal_bridge` case (`:864–875`), `terminal_unbridge` case (`:877–888`),
   `autoStartOutputBridge` (`:142–162`), `bridgeSpaceTerminals` (`:128–140`) **and its caller**
   `AppState.swift:131`, and the `outputBatchers` static (`:36`). `OutputBatcher` class
   (`:1299`) is then unreferenced → delete it too (build proves it).
6. **`ToolDefinitions.swift`** — delete the `terminal_bridge` (`:518`) + `terminal_unbridge`
   (`:529`) schemas; drop both names from the `permission(for:)` switch (`:722`); rewrite
   `terminal_send`'s description (`:502`) — remove "Automatically bridges output back…"; say
   output returns via the terminal's own `<p42>` tags (bash) or `turnComplete` (claude), read
   with `messages_recent`.

**Deferred to Step 5 (left as dead-but-compiling code, do NOT touch in Step 3):** the
`inlineTerminalBridges` machinery (`AppState.swift:718, 1356, 1455, 1461, 2575`), the now-idle
`TerminalAgentLoop` / `startTerminalLoop` / `terminalLoops` tick (`:1308–1356`), `bridgedTerminalNames`
(`:716`) + the SidebarView bridge indicator (`SidebarView.swift:314`), and `TerminalBridge` itself.
Removing autoStart/bridgeSpaceTerminals stops these being *driven*; their *deletion* rides with the
Step-5 TerminalBridge sweep so Step 3 stays a focused, green diff.

### Verification (Step 3)

- **Unit (Swift Testing), the only cleanly-testable piece:** `AppState.resolveTerminalId` —
  id-hit (exact id wins even if a name also matches), name-scan exact, name-scan contains,
  not-found → `nil`. Add to a new `TerminalResolverTests` suite.
- **Manual (`./build.sh --run`; no view tests in this codebase):**
  - `terminal_spawn` a `bash` terminal → `terminal_send <id> "ls\n"` runs in the native window.
  - Confirm **non-arming**: a bare `terminal_send` does **not** cause the next `turnComplete` to
    broadcast (gate stays disarmed) — distinct from a companion @mention inject.
  - `terminal_send` to a real id whose surface isn't bound (spawn, send before the window's
    surface binds) → `"…has no live surface"`, not a silent drop and not the not-found error.
  - `terminal_send bogus-id` → not-found error that lists the live native terminals.
  - `bash` terminal emitting `<p42>hi</p42>` → "hi" still posts (tee path unaffected).
  - claude terminal reply still posts via `turnComplete` (the original motivation, still wired).
  - `terminal_list` shows the native terminal with `surfaceBound: true` once open.
  - `terminal_bridge` / `terminal_unbridge` are gone from the tool list (D4).

#### Runnable test matrix (gateway / curl)

Status: **Step 3 committed `738c686`** (resolver unit test green: 6/6). **Gateway/curl matrix
rows 1–7 RUN & GREEN (2026-06-27)** — all passed via the local gateway against the live bundle
(row 6 posted `render-fix-ok` to the space; row 7 returned `Unknown tool: terminal_bridge`). The
3 subtler in-app behavioral checks below (non-arming, no-live-surface, claude `turnComplete`)
remain **not yet verified** — they need timing/observation inside the app, not curl. Drive the
matrix through the local gateway — dot-notation maps to the underscore tools
(`terminal.spawn → terminal_spawn`, etc.) via `RemoteToolExecutor`.

> Aside (resolved 2026-06-27): verifying this matrix surfaced a `SidebarView` render storm —
> synchronous per-render DB queries (`getAgentsForSpace`/`getUniqueSenders`) pegging the main
> thread and dropping the gateway host WS. Fixed in `77b266a` (reactive `spaceAgentIds`/
> `spaceSenderCounts` caches; `SidebarView.body` is now DB-free). Unrelated to terminal-ports.

Endpoint: `curl -s http://127.0.0.1:4242/call -d '{"method":"<m>","args":{...}}'`

| # | Call | Expect (proves) |
|---|------|-----------------|
| 1 | `terminal.spawn {command:"bash", title:"t1"}` | returns `{id, title}`; a **native Ghostty** window opens (not xterm) — Step 2 native path |
| 2 | `terminal.list` | lists `t1` with `surfaceBound:true` once open — `terminal_list` reads `terminalControllers` |
| 3 | `terminal.send {name:<id>, data:"ls\n"}` | `ls` runs in that window; `"Sent to t1"` — resolver id-hit + `sendRaw` |
| 4 | `terminal.send {name:"t1", data:"echo hi\n"}` | resolves by **name** too |
| 5 | `terminal.send {name:"bogus", data:"x"}` | `Error: no terminal found… Available terminals: 't1' (id: …)` — not-found lists natives |
| 6 | `terminal.send {name:"t1", data:"echo '<p42>hi</p42>'\n"}` | "hi" posts to the space — tee path unaffected |
| 7 | `terminal.bridge` / `terminal.unbridge` | method **gone** (D4) |

Subtler, eyeball in-app (not gateway-scriptable):
- **Non-arming (#8):** a bare `terminal_send` does **not** arm the next `turnComplete` to
  broadcast — distinct from a companion @mention inject.
- **No-live-surface:** `terminal_send` to a real id before its surface binds → `"…has no live
  surface"`, not a silent drop and not the not-found error.
- **claude `turnComplete`:** a `claude` terminal's reply still posts (the original motivation).

Run rows 1–7 in a throwaway space to avoid cluttering #port42-app.

## Verification

- Companion `@echo spawn a terminal` → a **`terminal`** port opens (native Ghostty), no xterm.
- The spawned terminal shows an inline `PortCompactBlock` placeholder in chat; clicking it pops out
  the floating native window.
- `terminal_send <id> "ls\n"` → runs in that native terminal (raw, non-arming send).
- A `bash` `terminal` companion emitting `<p42>hi</p42>` → "hi" posts to the space (tee path).
- A claude `terminal` companion's reply posts via `turnComplete` (the resolved original motivation).
- A background `bash` command agent printing raw text → posts again (regression fixed).
- A new terminal spawned by a CLI companion lands in **its** space (`PORT42_SPACE_ID`).
- No `web` port is ever created for a terminal request; `terminal_bridge`/`terminal_unbridge` no
  longer exist (D4).
