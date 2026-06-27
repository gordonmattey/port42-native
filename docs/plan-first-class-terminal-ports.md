# First-class terminal ports — terminal.* API on native Ghostty

## Status / resume (2026-06-27)

**Nothing in this plan is implemented yet — Step 1 is the next action.** All decisions are
locked (D1 native-only / D2 `terminal_exec` headless / D3 spaceId threading) and the code has
been traced (see "Corrections found while tracing"). Begin at **Migration step 1** →
**"Step 1 — detailed plan"** below: extract `spawnNativeTerminalPort` returning the port id and
delete the dead `ghosttyTerminalSurfaces` dict (no behavior change).

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

## Migration steps (incremental, verifiable)

1. Extract `spawnNativeTerminalPort` returning the **port id**; delete the dead
   `ghosttyTerminalSurfaces` dict (no behaviour change; companion path uses it). **Detailed below.**
2. Add a `terminal_spawn` tool (does not exist today — that absence is why companions
   hand-roll xterm) → calls `spawnNativeTerminalPort`, returns the id. Verify a companion
   "spawn a terminal" yields a `terminal` port (not `web`/xterm).
3. Re-point `terminal_send` / `terminal_bridge` to resolve native controllers by id
   (`terminalControllers[id]` → `controller.inject`); today they only find legacy
   `TerminalBridge`/inline/title sessions. Add a `[name: id]` alias for non-companion
   friendly-name routing. Verify send + output-to-space on a native terminal.
4. Verify the command-agent stdout path still posts a plain `bash` agent (already fixed).
5. Apply D1 — delete `TerminalBridge`, the `terminal.*` cases in `PortBridge` (`:895–964`),
   the JS `terminal` object, and the `ports-context.txt` terminal section.
6. spaceId audit (D3): default `RemoteToolExecutor` spaceId from `input["space_id"]`.

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

## Verification

- Companion `@echo spawn a terminal` → a **`terminal`** port opens (native Ghostty), no xterm.
- `terminal_send <id> "ls\n"` → runs in that native terminal; `terminal_bridge` posts output.
- A `bash` `terminal` companion emitting `<p42>hi</p42>` → "hi" posts to the space (tee path).
- A background `bash` command agent printing raw text → posts again (regression fixed).
- A new terminal spawned by a CLI companion lands in **its** space (`PORT42_SPACE_ID`).
- No `web` port is ever created for a terminal request.
