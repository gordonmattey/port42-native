# Computer use — the operator loop (`computer.act`: see + act in one primitive)

**Status:** spec (2026-06-29, w/ gordon). Born from the shell session: the assistant drove the
desktop by hand — `screen_capture` → reason → `automation.runJXA` keystroke → `screen_capture` — and
the obvious move is to **fuse see + act into one tool** so a companion can operate the machine in a
loop. This is Anthropic-style **computer use**, native to Port42.

**One line:** a single bridge primitive — `computer.act({action}) → { screenshot, … }` — where every
action **returns the fresh post-action frame**, closing perceive → act → perceive in one call. The
companion then loops: look, decide, act, look.

---

## 1. Why this is small (the pieces already exist)

Port42 already exposes every raw capability; they're just **not fused** and the model has to hand-roll
the loop:

| Need | Already in Port42 |
|---|---|
| **See** the screen | `screen_capture(scale?) → { image, width, height }` |
| Know window/app layout | `screen.windows → { windows:[{ title, app, bounds }] }`; `screen.displays` |
| **Act** — keystrokes | `automation.runAppleScript` / `runJXA` → System Events `keystroke`, `key code` |
| **Act** — clicks/scroll/drag | System Events `click at {x,y}` via the same automation methods |
| Carry data | `clipboard.read/write` |
| Web specifically | `browser.*` (already a clean see/act loop for pages) |

The Unified API means a **bridge method is automatically a companion tool** (`ToolDefinitions` ⇄
`ToolExecutor`). So the entire feature is: **add a `computer.*` toolset that composes these into one
act-then-observe primitive**, plus permissions + coordinate hygiene + safety. No new engine.

This proved out by hand during the shell build: `screen_capture` frames drove every iteration, and a
`runAppleScript` "keystroke e using command down" toggled the prototype's ⌘E overlay live. Fusing the
two is the whole idea.

---

## 2. The primitive

```
computer.act({ action, ... }) -> { screenshot, width, height, scale, cursor?, ok, error? }

  action:
    "screenshot"                              // observe only
    "click"      { x, y, button?="left" }     // also "double_click", "right_click"
    "move"       { x, y }
    "type"       { text }                     // unicode literal typing
    "key"        { chord: "cmd+shift+4" }      // chord grammar → keystroke / key code
    "scroll"     { x, y, dy, dx? }
    "drag"       { from:{x,y}, to:{x,y} }
    "wait"       { ms }                        // let the UI settle, then re-shoot
```

**Every action returns the screenshot taken *after* it lands** (plus a short settle delay). That is
the fusion — one tool call = act + observe. `action:"screenshot"` is the pure look. Returning
`scale` + `width/height` lets the model map what it sees to where it clicks (see §4).

**Higher-level sugar (optional, later):** `computer.operate({ goal })` runs the loop server-side with
`ai.complete` until the goal is met or a step budget is hit — but the **primitive is `computer.act`**;
the loop belongs to the model's tool-use turn, exactly like Anthropic computer use.

---

## 3. How the companion uses it (the loop)

Standard agentic computer-use turn, now native:

```
loop:
  frame = computer.act({action:"screenshot"})
  decide next action from the frame (+ goal)
  result = computer.act({action:"click"/"type"/"key", ...})   // returns next frame
  until goal satisfied or step budget exhausted
```

Because it's a bridge method, this works from **chat tool-use** *and* from a **port's JS** — same
method, same permissions (the Unified API invariant). A port could even render the operator's live
view (the returned frames) as it works.

---

## 4. Coordinate hygiene (the #1 footgun)

`screen_capture` returns **pixels**; macOS input APIs (`click at`) want **points**. On Retina they
differ by the backing scale, and a captured frame may be downscaled (`scale:0.5`).

- `computer.act` returns `scale` and the point-space `width/height`, and **accepts coordinates in the
  returned frame's pixel space**, converting to points internally — so the model clicks "where it
  sees," never doing the math.
- Alternatively accept **normalized 0–1** coords (resolution-independent). Decide one; lean
  normalized-optional + pixel-default.
- Multi-display: coordinates are display-relative; include `display` id (from `screen.displays`).
  Origin convention must be stated (capture is top-left; AppleScript `click at` is top-left — keep
  top-left end to end and document it).

---

## 5. Permissions & safety (this drives the whole machine)

This is the most powerful, most dual-use capability in Port42 — it can operate anything on screen.

- **New "Operate" permission bucket**, distinct from Screen/Automation, so granting "see" never
  silently grants "act." Note the macOS reality: synthetic **mouse clicks need Accessibility** (a
  separate TCC grant) while **keystrokes need Automation/Apple Events** — surface both clearly in the
  grant flow; detect-and-prompt when missing rather than failing opaquely.
- **Always-visible indicator** while operating (a border/HUD), like screen-sharing — never silent
  control. The shell's escape-hatch discipline applies: an obvious, always-available **stop**.
- **Guardrails on destructive-looking actions** — confirm (or policy-gate) before clicks on things
  like Trash/Delete/Send/Move, typing into password fields, or actions in sensitive apps. Start
  conservative; loosen with explicit user policy.
- **Scope option** — restrict operation to a target window/app (via `screen.windows` bounds) so a
  companion drives *one* app, not the whole desktop, when that's the intent.
- **Audit log** of actions taken (for trust + debugging the loop).

---

## 5a. Real-time voice steering — the operator listens while it works (gordon, 2026-06-30)

A computer-use loop should **not** be fire-and-forget. While it operates, the user can **speak**
and the loop incorporates it **in real time** — barge-in, like correcting a person mid-task:
"no, the other button", "stop", "scroll down first", "yes that one". This turns the operator from a
batch job into a **collaborator you talk over its shoulder.**

- **Out-of-band feedback channel.** The loop reads a live instruction stream *between steps* (and an
  interrupt can preempt the current step). Each iteration's prompt includes "latest user
  steering since last step," so a spoken correction redirects the very next action.
- **"Stop" is instant.** A spoken stop/abort is the always-available kill (ties to §5's indicator +
  stop) — highest-priority, bypasses the step boundary.
- **New capability needed — listening.** Port42 today has `audio.speak`/`audio.play` (output) but **no
  mic capture / speech-to-text** in the bridge. This wants an `audio.listen` / live-transcription
  primitive (streaming partial transcripts) feeding the steering channel. That's a prerequisite, noted
  here so it's not lost. (Pairs naturally with the companion *speaking back* what it's about to do —
  full duplex: it narrates intent via `audio.speak`, you correct via voice, it adjusts.)
- **Loop shape becomes:** `observe → (merge latest voice steering) → decide → act → speak intent →
  observe`, with a preemptible "stop/redirect" check that doesn't wait for the step to finish.

This is the difference between "run this macro" and "drive my computer *with* me." It's the headline
UX for the whole feature.

## 6. Relationship to other plans

- **Unified API** (CLAUDE.md) — `computer.*` is just more bridge methods; the tool schemas come for
  free. This is the cleanest expression of "same methods from ports and from chat."
- **`plan-port42-shell.md`** — the shell is Port42 *being* your surface; computer-use is the
  companion *operating* surfaces (incl. other apps). Complementary: inside the shell, a companion
  could operate a port; outside, it can drive any macOS app. Same see/act discipline, same
  indicator + stop ethos.
- **`browser.*`** — the existing per-page see/act loop is the proof-of-pattern at web scope;
  `computer.*` generalizes it to the whole screen.
- **Anthropic computer use** — same loop shape (screenshot → action → screenshot). Port42's angle:
  it's a *local, permissioned, companion-native* operator, not a remote VM.

---

## 7. Implementation steps (incremental; each ships usable)

### Step 1 — `computer.screenshot` + `computer.act{key,type}` (keyboard-only operator)
- Bridge cases + tool schemas. `screenshot` wraps `screen_capture` and adds `scale`/dims; `key`/`type`
  route through the existing JXA/AppleScript path, then re-shoot. Keyboard-only avoids the
  Accessibility-click TCC for v1 and already enables a lot (Spotlight, menus, text).
- Permission: new `.operate` bucket → maps to Automation today. Indicator HUD on.
- **Proves** the fused act-then-observe loop end to end (e.g. "⌘Space, type 'Safari', return").

### Step 2 — pointer actions (`click`/`move`/`scroll`/`drag`)
- Add System Events `click at {x,y}` etc.; wire the Accessibility permission detect-and-prompt.
- Coordinate mapping (§4) returned + accepted in frame space.

### Step 3 — safety layer
- Destructive-action guardrail/confirm; window/app scoping; audit log; always-visible indicator + a
  global stop.

### Step 4 (optional) — `computer.operate({goal})`
- Server-side loop via `ai.complete` with a step budget + the safety layer, for "just do X" ergonomics.
  The primitive stays `computer.act`.

---

## 8. Risks / open questions

- **TCC friction** — Accessibility + Automation are separate, easily-denied grants; the prompt flow
  must be legible or the feature feels broken.
- **Coordinate drift** — Retina/scaled-capture math is the classic computer-use bug; bake mapping
  into the primitive, don't push it onto the model.
- **Trust** — silent machine control is a non-starter; the indicator + stop + guardrails are
  load-bearing, not polish.
- **Reliability** — synthetic events can race UI animations; the built-in settle delay + a `wait`
  action mitigate, but flakiness is inherent to GUI automation.
- **Sandboxing** — a future hardening (which apps a given companion may operate) parallels the shell's
  deferred web-port-spawns-terminal hardening.
```
