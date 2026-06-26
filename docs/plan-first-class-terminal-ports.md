# First-class terminal ports — terminal.* API on native Ghostty

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

## Migration steps (incremental, verifiable)

1. Extract `spawnNativeTerminalPort` + port-id surface registry (no behaviour change yet;
   companion path uses it).
2. Re-point `terminal.spawn` → native; verify a companion "spawn a terminal" yields a
   `terminal` port (not `web`/xterm).
3. Re-point `terminal_send` / `terminal_bridge` to resolve Ghostty surfaces by id; verify
   send + output-to-space on a native terminal.
4. Fix the command-agent stdout regression (#5 above); verify a plain `bash` agent posts.
5. Apply D1 (remove or fence off the xterm path) once nothing depends on it.
6. spaceId audit (D3) across all spawn entry points.

## Verification

- Companion `@echo spawn a terminal` → a **`terminal`** port opens (native Ghostty), no xterm.
- `terminal_send <id> "ls\n"` → runs in that native terminal; `terminal_bridge` posts output.
- A `bash` `terminal` companion emitting `<p42>hi</p42>` → "hi" posts to the space (tee path).
- A background `bash` command agent printing raw text → posts again (regression fixed).
- A new terminal spawned by a CLI companion lands in **its** space (`PORT42_SPACE_ID`).
- No `web` port is ever created for a terminal request.
