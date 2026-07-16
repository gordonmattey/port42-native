# Summer 2026 — north-star notes (TODO)

Forward-looking architecture direction. **Not built yet.** These are decisions about where the
model is heading, written down so they survive reboots and *steer* current work (don't entrench
patterns we've decided to collapse). Each item is tagged TODO.

---

## Priority — ranked for impact on "a great space experience" (2026-06-27)

The whole push is **a great space experience**: enter a space and see its world; companions feel
present and continuous there; know where you're needed across spaces at a glance; low noise.
Ranked against *that*, not raw feature value. (Effort in parens.)

**Tier 1 — make a space a real, legible place.** The spine; these share one theme and reinforce
each other (a space *has* a directory, ports, companions, memory — and you can see it all at a
glance, across spaces).
1. **Richer sidebar space rows / ambient activity** (medium) — *top pick.* "Where am I needed?"
   across all spaces; `waiting-for-input` is the highest-value signal. Best impact-per-effort —
   builds on the render-storm caching pattern (commit 77b266a). → "richer space rows" below.
2. **Ports scoped to space** (medium) — keystone: a space *has* its own ports; data model the dock
   view needs. → "ports scoped to space".
3. **A space has a working directory** (medium) — anchor a space to a real folder on disk so it's a
   *workspace*, not just chat; terminals/companions/file ops default to it. → "a space has a
   working directory".
4. **A dock / gallery view of ports** (medium) — *see* that world; depends on #2. → "a different
   dock view of ports".
5. **Swim *is* a space** (high) — backbone: relationship memory space-scoped → companions belong
   to the place. Architectural; sequence after #2's scoping pattern. → "a swim is a space".

**Tier 2 — companions more present & capable.**
6. **Per-(companion, space) terminal sessions** (medium) — fixes wrong-session resume; isolated
   thread per space. Pairs with #5 (and #3: the per-space cwd is the natural launch dir).
7. **Native terminal output-streaming bridge** (low-med) — build/log/agent output streams into the
   space → live workspace. Mechanism ~90% present (`onFlush`).

**Tier 3 — additive / DX / polish.**
8. **Browser port type** (high) — powerful but additive; largest build.
9. **`ports.list` JSON consistency** (low) — companion DX; capabilities half-done in 5a.
10. **Missing gateway APIs** (`port.position`, `screen.displays`) (low) — positioning/layout tooling.
11. **shim `.zshenv` recursion spam** (low) — papercut; cheap morale win.
12. **dev-reboot session-resume robustness** (—) — dev-only; doesn't touch the space experience.

Recommended arc: **1 → 2 → 3 → 4 → 5**, slotting #11 and #7 in as cheap wins. (#2 + #3 together are
what turn a space into a workspace — strong to pair.)

---

## TODO: a swim *is* a space (collapse the swim special-case)

**Decision:** there is no separate "swim" construct. A swim is just a **space** whose membership
is small/private. "Swim" / "DM" is a **presentation label** for that, not a data structure.

- Member count is not load-bearing. The machinery is N-member; the 2-member DM is just the
  common private case we *call* a swim.
- Today: swim id is the string `"swim-\(companion.id)"` (`Space.swift:47`), and relationship
  state (fold / creases / engravings) keys off `companionId` + that string
  (`AppState.swift:450` and the `db.fetch*` calls). That's the special-case to remove.

**Consequence — relationship memory becomes space-scoped, not companion-special.**
Fold/creases/engravings attach to a **space** (any space), looked up by `spaceId`. A 2-member DM
accumulates relationship memory; so could an N-member project channel. One mechanism.

**Consequence — the "swim id" question dissolves.**
- A swim is a normal space → a plain `UUID().uuidString` id (created the usual way).
- "Find the DM between A and B" = a **membership query** (the space whose members are exactly
  {A, B}), not a derived id. An optional derived-id index — `UUIDv5(sorted(partyA.id, partyB.id)
  + spaceContext)` — is a lookup optimization, *not* the architecture. This supersedes the
  earlier "derive a clever swim id" idea: the destination is "there is no swim id, just space
  ids."

**Steer current work:** do not deepen the `swim-\(companion.id)` special-casing; bias new code
toward space generality (membership + space-scoped state) so the eventual collapse is a
*deletion*, not a rewrite.

---

## TODO: disallow whitespace in space + companion names

**Symptom:** spaces (the character) in a **space name** or **companion name** appear to break
things — gordon hit this in practice. Likely blast radius: anywhere a name is used as / embedded in
an identifier or word-split token — mention parsing (`@name` in `AgentRouting`), invite-link
encoding, terminal session/bridge names (`terminal_bridge(name)`), shell command construction,
storage keys. Names should be display labels, but several paths treat them as tokens.

- **Fix direction:** validate at the input boundary — reject or auto-slugify whitespace (and
  probably other shell/url-unsafe chars) when creating/renaming a space or companion. Decide:
  hard-reject with inline error vs. silently slug (`my space` → `my-space`). Lean hard-reject for
  new input, slug existing on read.
- **Investigate first:** confirm *what* actually breaks (reproduce with a spaced name) so we fix the
  root token-vs-label confusion, not just paper over it with validation. The deeper fix may be
  decoupling display name from any id/token use entirely.
- Small, but a sharp UX paper-cut (silent breakage). Cheap to add validation; do the investigation
  before deciding reject-vs-slug.

---

## TODO: per-(companion, space) terminal session ids

**Problem:** a terminal companion spawns `claude` and resumes with `--continue`, which grabs the
most-recent session for the cwd — ambiguous when sessions overlap (caused a real "resumed the
wrong session / jumped back in time" bug; see the `dev-reboot.sh` flush fix already landed).

**Decision:** give each terminal companion a **stable, deterministic** session id, and resume by
it explicitly.

- `PORT42_SESSION_ID = UUIDv5(namespace, "<companion.id>:<space.id>")`
  - Per **(companion, space)** — a companion in multiple spaces gets an *isolated* thread each.
    (`companion.id` alone is wrong: it collides across spaces.)
  - **Stable** across relaunches and close/respawn (unlike the panel id, which is regenerated).
  - A valid UUID → usable with `--session-id`.
- Spawn logic: first launch `claude --session-id $PORT42_SESSION_ID`; thereafter
  `claude --resume $PORT42_SESSION_ID` (the `--session-id` flag errors if the id already exists).
  Port42 picks based on whether the transcript exists.
- **UX:** don't expose this as a user-editable arg — it's plumbing. Drop `--continue` from the
  default LLM-companion args; Port42 injects the session-id logic automatically at spawn (it
  already injects env + hooks).

**Prereq it interacts with:** routing is currently by companion *name* (one terminal per
companion, `routeMentionsToTerminals` scans `terminalControllers` by `config.companionName`). For
per-(companion,space) sessions to mean anything, terminal routing must become
per-(companion,space) too. Sequence the session-id change with that.

---

## TODO: dev-reboot session-resume robustness (partially done)

- **Done:** `dev-reboot.sh` now sleeps `${DEV_REBOOT_SETTLE:-8}` before `pkill` so the companion
  that triggered the reboot can flush its transcript (the fast cached build was killing it within
  ~2s).
- **Still open:** with concurrent claude sessions in one cwd, `--continue` can still resume a
  sibling session. The per-(companion,space) `--session-id`/`--resume` change above removes this
  class of bug entirely. Until then, the settle delay is a mitigation, not a guarantee.

---

## ~~TODO: shim `.zshenv` recursion / job-table error on terminal startup~~ — DONE 2026-07-15

Root cause found (differs from the guess below): an app instance **launched from inside a
Port42 terminal** inherits that terminal's shim `ZDOTDIR` (`open(1)` propagates the caller's
env); `TerminalSessionBootstrap` blessed it as `PORT42_REAL_ZDOTDIR`, so every new shim
sourced the old shim, whose own source line resolves to itself in the child → infinite
recursion. Fixed in `1e6816f`: `realZdotdir()` never accepts a `/tmp/port42-shim-*` path —
prefers the inherited `PORT42_REAL_ZDOTDIR` (the true original), else a non-shim `ZDOTDIR`,
else `$HOME`. Tier A: guard cases in `TerminalHooksServiceTests`; verified live by spawning
from a poisoned-env app instance.

---

## TODO: companion-global epistemic memory (creases/fold accumulate across spaces)

Today creases / fold / position / engravings are keyed **per-(companion, space)** — echo's 11
creases live under its DM space, and inspecting echo from any other space shows nothing (found
2026-07-15; scoping works as designed, but the design is wrong). A companion is ONE being: its
inner state should accumulate with the companion no matter which space you meet it in.

Fix direction: re-key the relationship tables to `companionId` alone (migration: merge existing
per-space rows — creases/engravings union, fold/position pick the most recent), update the
space-scoped bridge APIs (`creases.*`, `fold.*`, `position.*`) and `CreaseInspectorSheet` /
member-strip eye to read companion-global state. Decide whether space context stays as a *tag*
on each crease (provenance) rather than a partition. Also sweep the orphaned rows found in the
prod DB (creases/engravings under deleted space ids — space deletion doesn't cascade these).

---

## TODO: permission UX — one guided flow, not a dialog avalanche (2026-07-16)

**Found live** (building a mic port): first use fires **three dialogs back-to-back** — Port42's own
`.microphone` card, then macOS's **Microphone** consent, then macOS's **Speech Recognition** consent
(`SFSpeechRecognizer` needs its own separate TCC grant — nobody expects that one). GM: *"our
permission box should say: we're asking you for two permissions, Apple will show you the screens,
click Yes and Yes."*

**Fix:** Port42's card **owns and narrates the whole flow** — *"Port42 needs your microphone to
transcribe you. macOS will ask twice next — Microphone, then Speech Recognition. Say yes to both."*
One intentional sequence instead of an avalanche. (The macOS grants are one-time-per-app forever, so
this is a first-run cliff, not ongoing friction — but the first run is the one that matters.)

**Same session, same feature — the rest of the permission findings** (all feed the permission-prompt
shell surface, S4.x / Track A #1):
- **The card renders inside the chat tile** (`ChatView.swift:72-89`), so when you're focused on a
  port the prompt is **off-screen and the call silently hangs** — that's the "permissions haven't
  worked since the shell refactor" bug. `PortBridge.checkPermission` *does* set
  `activePermissionBridge` correctly (line ~200); only the **render site** is wrong. It must be a
  **shell-level overlay** (scrim + zIndex, like Settings/⌘K/inspector).
- **Grants are per-port** — each port is its own `PortBridge` with its own `grantedPermissions`
  (cached per port). Three AI-using ports = approving `.ai` three times, for ports *you authored*.
  Consider: batch several pending grants into one card; a "my own ports" / Settings pre-approval
  scope.
- Diagnostic worth keeping: the same bug has two faces — "no prompt at all" (focused on a port) and
  "a pile of prompts" (sitting on the desktop where the chat tile is visible).

---

## TODO: `ports.list` API consistency (raw text + capabilities)

Small API-consistency item found while verifying terminal-port spawns over the gateway:

- **`ports.list` returns a human-readable text blob, not JSON** (`"37 ports:\n\ntitle: …\nid:
  …"`), unlike the sibling `terminal.list` which returns JSON — so programmatic callers can't
  parse it. Likely the `ports_list` tool handler stringifies for LLM readability while
  `terminal_list` returns a JSON array; the two list endpoints were built with different output
  contracts.
- **Capabilities mismatch:** the *same* native terminal port reports `capabilities: []` in
  `ports.list` but `capabilities: ["terminal"]` in `terminal.list`. `capabilities` is computed
  in one path and not the other; a `terminal` port should report `["terminal"]` in both.

Fix direction: align the two list endpoints on a JSON contract (or at least make `ports.list`
JSON-parseable), and populate `capabilities` from the same source so terminal ports are
consistent. Look at the `ports_list` vs `terminal_list` handlers (`ToolExecutor.swift` /
`RemoteToolExecutor`) and the capabilities source on the panel model.

---

## TODO: documented gateway APIs that return `Unknown tool`

Several methods listed in the API reference (global `CLAUDE.md`) are **not implemented** in the
gateway / `RemoteToolExecutor`, so calling them over `http://127.0.0.1:4242/call` returns
`{"content":"Unknown tool: <name>"}`. Found while repositioning a floating terminal port:

- `port.position` → `Unknown tool: port_position` (docs say → `{x,y,width,height}`)
- `screen.displays` → `Unknown tool: screen_displays` (docs say → display bounds array,
  "no permissions required")
- `port.move` — untested; may also be missing (the documented write-side counterpart to
  `port.position`).

Impact: external callers can't read a port's geometry or the display layout, so they can't
compute a safe on-screen position (e.g. to rescue an off-screen / hidden floating port — the
exact case that surfaced this). Workaround used: `port.manage dock` then `undock` + `focus`.

Fix direction: either implement these in the gateway tool surface, or correct the API reference
so it only advertises what's wired. Corroborates the existing port-positioning-gap note.

---

## TODO: native terminal output-streaming bridge (revises D4)

**Use case:** a caller wants to *stream a terminal's output into the space* — a build, `tail -f`,
server logs, a training run, a long script. D4 (in `plan-first-class-terminal-ports.md`) dropped
the old `terminal_bridge` entirely, but its reasoning only held for **claude/TUI** terminals
(teeing a TUI = redraw garbage; claude posts via `turnComplete`). Line-oriented output is clean and
genuinely useful to stream — so the capability should come back, natively.

**The mechanism already exists, just unplugged.** `TerminalOutputProcessor` produces two streams;
`GhosttyTerminalController.swift:114` wires `onP42Output` (posts `<p42>` tags) but **discards
`onFlush`** (`TerminalOutputProcessor { _ in }`) — and `onFlush` is exactly the cleaned,
ANSI-stripped, batched line output we'd want. So the feature ≈ "connect `onFlush` to a post path",
not rebuilding the deleted `TerminalBridge` (which was raw forkpty bytes → xterm).

**Design:**
- Opt-in tool, e.g. `terminal_stream(id, on|off)` (or reinstate the `terminal_bridge` name) that
  flips a per-controller flag.
- When on: `onFlush` → batched post to the space (cleaned text, **not** raw bytes).
- **Guard TUIs:** refuse/warn when `hooksCapable` (claude/gemini) — `turnComplete` is their path;
  teeing them is garbage. Streaming is for plain `bash`/command terminals.
- Throttle/batch to avoid flooding the space (the `onFlush` batching already helps).
- **Actually test it** this time (the old `terminal_bridge` was removed before it was ever tested).

**Note for the Step 5a deletion sweep:** deleting the legacy `TerminalBridge` must NOT touch
`GhosttyTerminalController` / `TerminalOutputProcessor` (they're the native side) — so the `onFlush`
seam survives the sweep and this feature can wire onto it later.

---

## TODO: browser port type

A first-class **`browser`** port type — a real, navigable browser surface as a port (parallels how
`terminal` is a native Ghostty surface, distinct from a `web` port that just renders
companion-authored HTML). Today the four-ish port shapes are `web` / `chat` / `terminal`, and the
`browser.*` bridge API drives an out-of-band browser session; a browser *port* would make a live
web page a first-class, addressable, dockable/floatable port in the space.

Open questions to flesh out later: WKWebView vs a real browser engine; how it relates to the
existing `browser.*` API (back it onto the port? deprecate?); navigation/permission model;
whether companions can drive it (navigate/capture/execute) the way they drive terminals. Mirrors
the terminal-ports work — likely an analogous `browser_spawn`/`browser_*` tool surface + inline
card.

---

## TODO: WebRTC in browser ports — camera / mic / screen share (Meet, Jitsi, LiveKit, …)

A browser port pointed at a video-call app (Google Meet, Jitsi, Whereby, a LiveKit room) should
be able to **participate**, not just watch — your camera + mic in, and screen-share out. Today it
can't: `getUserMedia`/`getDisplayMedia` inside the port's `WKWebView` are denied. Motivating case
2026-07-15: "show a Google Meet in the shell / pipe video + audio into a port."

Current state (assessed 2026-07-15):
- ✅ `Info.plist` already has `NSCameraUsageDescription` + `NSMicrophoneUsageDescription` — the OS
  *can* prompt.
- ❌ Entitlements missing: neither `Port42.entitlements` nor `Port42.release.entitlements` has
  `com.apple.security.device.camera` or `com.apple.security.device.audio-input`. Under the
  hardened runtime (notarized release) WKWebView `getUserMedia` is silently denied without these.
- ❌ No `WKUIDelegate` media-capture handler: even with entitlements, WebKit won't hand a page the
  camera/mic until we implement
  `webView(_:requestMediaCapturePermissionFor:initiatedByFrame:type:decisionHandler:)` and grant.
  The browser port's webview sets no such delegate.

Fix direction:
1. Add the two device entitlements to BOTH entitlement files (verify notarization still passes —
   these are allowed under Developer ID + hardened runtime; they are NOT get-task-allow).
2. Wire a `WKUIDelegate` on the browser-port webview that answers the media-capture request —
   auto-grant, or (better) route through the S4 permission-prompt shell surface so the user sees
   "this port wants camera/mic" once, consistent with the rest of the permission model.
3. **Screen share out (`getDisplayMedia`)**: flakier in WKWebView — validate separately. May need a
   `ScreenCaptureKit`-backed path fed into the page, or the newer WebKit display-capture support;
   confirm what actually works on macOS 14+ before committing to an approach.
4. Ship-time gotchas to verify live: Google Meet **UA-sniffs** and may still show "browser not
   supported" in embedded WebKit even once capture works — test Meet specifically, and note Jitsi /
   LiveKit / Whereby as the open-protocol fallbacks that behave better in an embedded webview.

Relationship to Tier 3 (deferred, not this item): a NATIVE media/`video` port type (WebRTC or
own-capture composited into a port surface, reusing the existing `camera.capture` / `screen_capture`
native bridges) is the Port42-native end-state — better for open protocols and your own streams, but
can't join proprietary Meet (no public join SDK). This item is the pragmatic "make embedded video
calls work" step; the native port type is a separate, larger north star.

---

## TODO: ports scoped to space

Ports should belong to a **space**, not float globally. A port created in space X shows when you're
in space X (and is listed with it), rather than the current global pool. Likely: persist a
port's `spaceId` (already on the panel) as the scoping key for what's shown, switch the visible
port set when the active space changes, and decide cross-space behaviour (does a port stay open
when you leave its space — backgrounded? hidden? follow you?). Pairs with the inline cards
(Step 5b) which are already posted into a specific space.

## TODO: a different dock view of ports

A dedicated **dock / gallery view** for browsing my ports — distinct from the current
sidebar/background-ports list and the floating windows. Think a grid or shelf of all ports (per
space, per the item above) with previews, so you can see and reopen everything at a glance instead
of hunting floating windows or scrolling chat for cards. Open: thumbnail/live-preview rendering,
grouping (by space / type / recency), and how it interacts with dock/undock + the inline cards.

---

## TODO: richer space rows in the sidebar (ambient activity)

The sidebar space switcher should tell you **what's happening in each space without opening it** —
the core of cross-space awareness. Today a row shows name + unread count + online count. Add
per-space status signals:

- **Recent activity** — a one-line preview of the latest message / what just happened (and who).
- **Waiting-for-input** — a companion finished its turn and is awaiting *your* reply (distinct
  from unread): "your move" indicator.
- **Turn-complete** — a companion just completed a turn (transient ping/flash on the row).
- **Port generation in progress** — when a companion is generating a port, show a "building…"
  indicator on the space row (and clear when it lands / errors).

Design notes:
- These are *ambient*, glanceable signals — not another inbox. Prioritise "needs you" (waiting-for-
  input) visually over passive activity.
- **Performance:** derive every signal from cached/observed state, NOT per-render DB queries — see
  the SidebarView render-storm fix (commit 77b266a). Add reactive caches
  (`@Published` on AppState, fed by observations) the rows read; the body stays DB-free.
- Ties into: ambient awareness is the same goal as space-scoped ports + the dock view — together
  they make a space (and the set of spaces) legible at a glance.

---

## TODO: a space has a working directory

On create, a space can have a **filesystem working directory** you pick (a folder picker in the
new-space flow; editable later in space settings). That cwd anchors the space to a real
project/location, so the space *is* a workspace, not just a chat.

Consequences once a space has a cwd:
- **Terminals/companions default to it** — `terminal_spawn` / companion `workingDir` fall back to
  the space cwd instead of `~`. (Today `spawnNativeTerminalPort` defaults cwd to the home dir; it
  would default to the space cwd.) `terminal_exec` and file ops resolve relative to it.
- **Companion context** — companions can be told "this space works in <path>"; scoping file/tool
  access to the space cwd is a natural permission boundary.
- **Optional** — a space without a cwd still works (chat-only / DM); the cwd is an affordance for
  project spaces.

Design notes: persist `workingDir` on the Space model (new migration — append, never edit
existing); folder picker in `NewChannelSheet`; surface + edit in space settings; decide whether a
swim/DM inherits a cwd (probably not). Pairs with space-scoped ports and the dock view — together a
space becomes a real place: its directory, its ports, its companions, its memory.

---

## TODO: adopt agent-comms standards — ACP + friends (interop for chat/agent comms)

**Direction:** speak the open **agent-communication protocols** so Port42 isn't a walled garden —
companions can be driven by / talk to external agents and clients over standard wires, and external
tools can drive Port42 companions the same way. Today comms are Port42-internal (the bridge API +
the WebSocket sync hub); this adds standard surfaces on top.

Standards to map (pick the ones that earn their weight):
- **ACP (Agent Client Protocol)** — the agent↔client/editor standard (Zed et al.). Lets a Port42
  companion be an ACP *agent* an external client can drive, and/or Port42 be an ACP *client* that
  hosts an external agent as a companion. Highest-fit for "chat comms with an outside agent."
- **MCP (Model Context Protocol)** — already partly present (`port42-mcp.js` resource). Firm up:
  Port42 as an MCP *server* (expose spaces/ports/companions as tools/resources) and as an MCP
  *client* (a companion consumes external MCP servers). Clarify which direction is wired vs aspirational.
- **A2A (Agent-to-Agent)** — companion↔companion across instances/vendors; overlaps the sync hub's
  cross-peer mentions but as an open wire, not our bespoke protocol.

Design notes / open questions:
- **Map to the existing model, don't fork it.** A remote agent should appear as an `AgentConfig`
  (a `Command`/remote mode) and land in a space's crew like any companion — reuse routing, the
  member row, ports. The protocol is a transport, not a new entity.
- Which protocol is inbound (drive Port42) vs outbound (Port42 drives external) vs both.
- Auth/permission model for an external agent acting in a space (reuse the per-companion permission
  bucket + secrets).
- Streaming/turn semantics must fit `typingAgentNamesBySpace` + `turnComplete` so status/member-row
  signals work for remote agents too.
- Sequence after the companion loop lands (the internal contract is the thing we'd expose).

---

# New frontiers (2026-06-29) — bigger north stars

Two larger directions added after the shell-prototype session. Both have written plans + working
throwaway proofs; they sit above the space-experience polish as *platform* moves.

## TODO: synchronous agentic-CLI invoke from ports (command-companion call/await) (2026-07-11)

**Gap found while dogfooding the generative-interface engine** (`port42-growth/gi-engine/`). A port
that builds surfaces via `port42.ai.complete` gets one-shot raw-model output — no iteration, no
self-critique. Claude Code (a *command* companion) would build far better surfaces, but there is
**no synchronous way for a port to invoke a command companion and get its result back**:

- `port42.companions.invoke(id, prompt)` works for LLM companions only (tested: `echo` → "pong" in
  1.7s). Command companions are **hard-rejected**: `"companion 'claude' is not an LLM companion"`
  (~3ms, confirmed against two separately-created `claude` command companions).
- `port42.ai.complete` is likewise raw one-shot.
- The only path to a CLI companion today is **async channel messaging**: `messages.send` (@mention) →
  the CLI runs → its reply lands in the channel later → the caller must poll `messages.recent` and
  parse. A port cannot call-and-await it.

Want: a first-class **call/await for command companions** so a surface can ask Claude Code (or
gemini/codex) to produce a result and get it back inline. Shape options: (a) extend
`companions.invoke` to accept command companions and resolve when the CLI turn completes (reuse the
Ghostty `turnComplete` signal already wired for terminal companions); (b) a dedicated
`companions.run(id, prompt) → Promise<text>` that spawns/uses a headless CLI turn. Either way it
fits the loop model: only the heavy **Regenerate** loop pays the agentic cost; Patch stays on
`ai.complete`; Morph stays local. Connects to the generative-interface work — the engine's model
client is already injected, so a loop-routed client (agentic build → fast patch → local morph) drops
straight in once the call/await exists.

Interim (no new API, buildable now): a purpose-built **LLM** "surface-builder" companion whose system
prompt carries the DSL + design guidance, invoked via the existing `companions.invoke` — better
primed than an inline prompt, synchronous (~1.7s), still one-shot (not agentic).

## TODO: migrate injected context → installable skills (general fix) (2026-06-25)

Port42 currently injects large context blocks into companion system prompts inside the app —
`ports-context.txt` (~1100 lines), `llms.txt`, the companion-relationship preamble. Outside the app
(Claude Code, Cursor, any external agent) none of it exists, and generic built-ins fill the gap
(e.g. `artifact-design` teaches a non-Port42 aesthetic for what should be *ports*). The general fix:
**move this context out of always-injected prompt blocks and into installable Agent Skills**, so the
same knowledge (a) loads on-demand instead of costing every turn, and (b) travels to any agent, not
just in-app companions.

Skills suite (each = "what lives inside the app, packaged to ship everywhere"):
- **`port42-ports`** — the port surface language: `port42.*` bridge, read-before-patch discipline,
  stateful-app pattern, and the port42 design system (overrides `artifact-design` for port tasks).
  *v0 scaffolded in `port42-growth/port42-ports/`.*
- **`port42-companion`** — relationship state (fold/position/creases/engravings). *Built.*
- **`port42-channels`** — the standalone channel runtime / gateway. *Spec stage.*

Work: (1) make `sync-docs.sh` the single source so the skill's `bridge-and-patterns.txt` never
drifts from the injected `ports-context.txt`; (2) install script writes `skillOverrides:
{"artifact-design": "off"}` in Port42-managed config; (3) decide which in-app injections become
lazy skills vs stay resident (safety-critical prompt bits stay; reference material becomes skills).
Connects to the loop/generative-interface work — the port design system carries the loop-affordance
vocabulary.

## TODO: GUI shell — replace the desktop, not the OS (→ `docs/plan-port42-shell.md`)

Port42 boots into a **fullscreen surface with no macOS Dock and no menu bar**, and the desktop is
made of **live ports** over a living ambient background. macOS stays the substrate; Port42 owns 100%
of what the human sees. **Prototype built + run** (`prototypes/p42shell/`); the WKWebView re-parent
crux is spike-proven (`prototypes/wkspike/`).

Key findings (de-risks it hard):
- **~70% of the bones already exist.** `PortWindowManager` already does per-space, persisted,
  dockable, positioned ports, and **chat is already a port** (`ensureChatPort`/`isChatPort`).
  `TransitionRoot`/`DreamscapeVideoLayer`/`AquariumBreakout` are the **ambient surface** already.
- **The ambient surface unifies screensaver = lock = desktop background.** One persistent surface,
  three layers (ambient / transition / summoned chrome+ports); idle dissolves the chrome back to the
  dreamscape. This *is* the screensaver.
- **Takeover is ~15 lines** (`presentationOptions = [.hideDock,.hideMenuBar]` + borderless fullscreen)
  extending the AppDelegate window-grab that already runs at launch.
- **Modes (meta-spaces).** A mode is a whole-shell state — its own accent, its own dock apps, its own
  set of Port42 **spaces**, its own default layout — not just a desktop. Switching a mode reconfigures
  the workspace. Within a mode, spaces are visualized by a **space rail** + a **spaces overview**
  (zoom out to cards showing each space's ports). This directly subsumes "ports scoped to space" +
  "a different dock view of ports" above (the shell is that dock view, fullscreen).
- **Boot-into-Port42** tiers: launch-at-login (Tier 1, easy/reversible) → MDM Autonomous Single App
  Mode (Tier 2, kiosk-grade, a settings toggle for app-level lockdown; true lockdown needs the MDM
  profile). Tier 3 (replace `loginwindow`) is not possible on macOS — known ceiling.
- **Chrome migration:** the global status/action cluster (gateway/tunnel/key/pause/usage/settings,
  `ContentView.swift:185`) moves into a top Chrome; the **PORT42 mark returns top-left** in the freed
  traffic-light gap. Modes sit **left of the notch/camera** (don't center under it; don't inset away
  real estate).

Build arc: flag-gated `ShellWindow` → desktop of ports over the ambient surface + Chrome → tile↔float
re-parent (no reload) → companion-driven desktop → boot surface + idle-out. Reuses registry + bridge
+ `port.create`, doesn't rebuild.

## TODO: computer use — the operator loop (→ `docs/plan-computer-use.md`)

A single bridge primitive **`computer.act({action}) → { screenshot, … }`** that **fuses see + act**:
every action returns the fresh post-action frame, so the companion loops perceive→act→perceive
(Anthropic-style computer use, native to Port42). Drives *any* app on screen, not just ports.

- **Small because the pieces exist:** `screen_capture` (see), `automation.runJXA/AppleScript` System
  Events (keystroke/click/scroll/drag), `screen.windows`, `clipboard.*`, `browser.*`. Unified API
  means a bridge method is a companion tool for free — the feature is *composing* these into one
  act-then-observe call. (Proven by hand this session: capture→keystroke→capture drove the shell.)
- **Coordinate hygiene** is the #1 footgun (pixels vs points, Retina/scaled capture) — bake the
  mapping into the primitive; the model clicks "where it sees."
- **Permissions/safety drive the whole machine:** a new **"Operate"** bucket (clicks need
  Accessibility, keys need Automation — both surfaced), an **always-visible indicator + stop**, and
  **guardrails on destructive actions**. Non-negotiable, not polish.
- Build: keyboard-only operator (`screenshot`+`key`+`type`) → pointer actions → safety layer →
  optional `computer.operate({goal})` server-side loop.

## NORTH STAR (concept): native ports = actors (query-in / stream-out), not pixels — "streaming video is a hack" (2026-07-15)

**The thesis under the media plane.** A port is not pixels — it is an **addressable endpoint /
actor**: you send it **queries (the bridge: `push`/`exec`/`patch`/`update`)** and it emits a **data
stream (its events/state: `port42:data`, state deltas, PTY bytes, `turnComplete`)**. `type + state +
render` is the object; **query-in / stream-out is its contract.** Pixel/video streaming is the
**fallback for opaque surfaces you don't own** — it throws away the query interface and ships dead
pixels — never the mechanism for a port you *do* own. (GM: "streaming video is a hack… you just send
queries to ports and the response is some data stream… native ports is going to be a big thing.")

**Three things fall out of the actor framing (the payoff):**
- **Location transparency.** A query-in/stream-out interface doesn't care WHERE the port runs — local,
  another instance, a server. Distribution/multiplayer comes nearly free because the interface is
  **message-based, not pixel-based**; the gateway just routes queries + streams (it already routes
  messages). Video breaks this — grabbing pixels pins the port to one machine.
- **Rendering is just ONE subscriber to the stream.** The local view draws; a remote peer is another
  subscriber; **an agent is another subscriber** (querying a port + consuming its stream is how a
  companion "sees" it); a recorder is another. So *render / share / agent-observe / persist* collapse
  into **one mechanism: "subscribe to a port's stream."**
- **Half of it already exists.** The unified-API thesis IS this: humans query ports via UI→bridge,
  agents via tool-use→bridge — the same methods. A port is already an endpoint both humans and agents
  query. What's new is only: let a subscriber live on another instance, and let queries arrive from
  one. **The bridge doesn't change; its transport extends across the network.**

**Chat already proves it.** The chat port (Swift) is shared across instances not by screen-sharing
but by **syncing messages** — each renders its own native SwiftUI. Nobody would stream chat as
video. That's the model for *every* port; chat just got there first because messages were always
data.

**The replication ladder, by how much state you own:**
- **Chat port** → sync messages. **DONE today** — the template.
- **Terminal port (Ghostty)** → state = the **PTY byte stream** (+ grid/cursor/scrollback). Stream
  bytes over a data channel; each end runs its own Ghostty, renders identically; input goes to the
  one real process on the origin host. Collaborative `tmux`/`mosh` — I/O, not pixels.
- **HTML/web port** → state = **HTML + the bridge event stream**, and **the port bridge is ALREADY a
  replication protocol**: `getHtml` = snapshot, `push` = state delta in, `patch` = targeted mutation,
  `update`/`exec` = apply state. Share = replicate via `getHtml` then mirror the `push`/`patch`/
  `update` stream across instances; bidirectional = each side's interactions become pushes that sync.
- **Opaque surface** (webpage you don't control, arbitrary macOS app via computer-use) → **the ONLY
  tier where video isn't a hack** — the honest pixel fallback for things outside the port model.

**So "native ports" = a port is a self-describing, replicable unit of live interactive state.** Its
definition suffices to reconstruct it anywhere — which is *why* it already persists across restart,
moves between spaces, and adopts onto another desktop. Sharing to a peer is the next verb on the same
object: the remote gets a **live port** (typeable, zoomable, adoptable), **not a video of one.** That
is the whole difference between Port42 and screen-sharing.

**Consequence for the media plane below:** most port-sharing is a **data-channel problem (state
replication)**; only the opaque-surface fallback is a **media problem**. This is *why* libp2p/Iroh
datagrams matter more than WebRTC media tracks for our case — replication rides datagrams, video is
the exception. Sequence this concept BEFORE heavy media work: the first multiplayer win is a shared
HTML/terminal port over a data channel (state replication), not a video call.

---

## TODO: live media plane — WebRTC streaming across instances; ports & agents as tracks (2026-07-15)

**Direction:** make real-time **audio/video/data** a first-class plane in Port42, streamed
**peer-to-peer over WebRTC between instances**, with **ports and agents as the media sources and
sinks**. The end-state is *multiplayer Port42*: live shared ports, native voice/video rooms per
space, and — the part nobody's built — **agents that call humans, join rooms with other humans and
other agents, and have a rendered (even 3D) presence in the video space.** This is the Tier-3
end-state noted in "WebRTC in browser ports" above; that item is the pragmatic embed-a-Meet step,
**this is the native platform move.**

**The load-bearing insight (why this is smaller than it looks):** WebRTC's genuinely hard problem
is **signaling** — exchanging SDP offers/answers + ICE candidates to bootstrap a peer connection —
and *Port42 already has the signaling plane.* The sync layer (`SyncService` ↔ `gateway.go`) already
routes typed, E2E-encrypted messages between instances, with a `call`/`response` pair already in the
switch. Adding a `signal` message type beside `typing`/`call`/`response` is a small, in-pattern
extension. **We don't build the hard part of WebRTC — we already have it.**

**Three-plane architecture:**
- **Signaling plane = the existing sync channel.** SDP/ICE ride the encrypted WebSocket; the gateway
  does routing + presence, exactly what signaling needs. New `signal` message type; near-zero new
  infra.
- **Media/data plane = WebRTC peer connections.** Once signaled, peers connect **directly (P2P)** and
  the gateway leaves the media path (streaming doesn't hammer the relay). Two flows: **media tracks**
  (camera, mic, screen, *a port's rendered surface*) and **data channels** (low-latency — live port
  state, cursors, an agent's token stream).
- **Sources & sinks = ports and agents.** *Anything* is a track. A port's surface → a video track
  (co-watch a running port across machines). An agent → a **source** (streams a generated avatar /
  voice / `audio.speak` track — incl. **3D rendered presence** via SceneKit/Metal or WebGL frames
  published like any participant) *or* a **sink** (consumes your screen/camera track in real time =
  live computer-use-with-vision). Native `camera.capture`/`screen_capture` bridges already give
  outbound tracks with **no WKWebView entitlement mess** (that's the browser-port item's problem, not
  this one's).

**Scope decision (GM, 2026-07-15): audio + screen-share + 3D avatars — DROP camera video.** Camera
is the heaviest, most commoditized, least-differentiated piece; cutting it changes the physics and
leans into what's novel:
- **Audio** ~40 kbps; **screen share** is caller-controlled + often paused; **3D avatars are the
  sleeper win because they're a DATA-CHANNEL problem, not a media track.** Don't stream avatar video
  — stream **parameters** (audio + pose + visemes) and **render the avatar locally** on each peer
  (VRChat / Rec Room / Meta Codec Avatars model). Cost = *kilobits of motion data*, not megabits of
  pixels; degrades gracefully (drop a pose frame → the avatar just smooths).
- **Consequence:** per-participant payload = 1 audio track + optional screen track + a tiny pose
  data-channel. So light that **rooms may not need a heavy SFU** — forwarding audio + pose for N
  people is cheap, and mesh scales to more participants than camera-video ever could. The part we
  drop is exactly the expensive/face-staring part; what remains is the differentiated part.

**NAT traversal — how P2P is actually solved, and what it means here:**
- **STUN** (free, majority of cases): a public server tells each peer its public IP:port; peers swap
  via signaling + **UDP hole-punch** a direct path. **ICE** orchestrates candidate gathering/checks.
- **TURN** (the ~10–20% fallback): symmetric-NAT-on-both-ends can't hole-punch → a relay with a
  public IP both peers reach; media flows through it. Rent (Cloudflare/Twilio/Xirsys) or self-host
  `coturn`.
- **The Port42-native answer — the gateway IS the supernode (decentralized TURN).** Historical
  lineage the model comes from: Napster (1999, central index + P2P transfer) → **FastTrack/KaZaA
  (2001) introduced supernodes** (well-connected peers relay for leaf nodes) → **Skype (2003, same
  builders) relayed NAT'd calls through supernodes** (Microsoft later centralized them onto hosted
  servers ~2012). A supernode is just decentralized TURN — a peer with a public IP doing the relay.

**Two planes — do NOT conflate (the load-bearing networking distinction):**
- **Control plane (signaling) = TCP; ngrok/reverse-proxy stays exactly as-is.** SDP/ICE exchange,
  presence, the invite page — low-bandwidth, latency-tolerant. This is the reverse-proxy job the
  gateway + ngrok already do. Unchanged.
- **Media plane (audio / screen / pose packets) = UDP; NEVER rides ngrok.** Real-time media wants
  UDP (loss-tolerant, no TCP head-of-line stutter). Two sub-paths:
  - **Direct (the good path, ~80%):** STUN + ICE + **UDP hole-punch** → peers talk UDP-to-UDP with
    **no server in the media path** — lowest latency, zero relay bandwidth. **This is why we still
    need NAT traversal: it's not a burden, it's what keeps most media serverless.** Always tried first.
  - **Relay fallback (~20%, symmetric-NAT-both-ends):** needs a box **actually UDP-reachable on a
    public IP**. **Correction to avoid the trap:** an ngrok-tunneled gateway is NOT this — ngrok gives
    the gateway a public *TCP/HTTP* face while it sits behind NAT; it does **not** make it UDP-reachable
    for media relay. So: **gateway on a public-IP host (VPS / home UDP port-forward)** → runs `coturn`
    there and genuinely IS the supernode; **gateway only ngrok-reachable (home box)** → rely on direct
    hole-punch for the majority + point the fallback at a **shared/rented UDP TURN** (`coturn` on a
    ~$5 VPS; audio+pose bandwidth is tiny → cheap). ngrok is not in the media path.
- **Fallback ladder** (worst→best): direct UDP → relayed UDP (real TURN) → relayed TCP
  (TURN-over-TCP, last resort for locked-down networks — the only rung ngrok could carry, and it's
  the bottom, not the plan).

**Prior art — do NOT build the traversal stack from scratch.** The NAT/relay problem is solved by
existing P2P transport libraries; evaluate before writing any ICE/TURN code:
- **libp2p** (Protocol Labs; **go-libp2p**, rust, js): AutoNAT + **Circuit Relay v2** (relay = the
  supernode role) + **DCUtR** (hole-punch coordinated *through* the relay, then upgrade to direct —
  exactly our pattern) + identity/encryption/QUIC. Battle-tested (IPFS, Filecoin, eth consensus,
  Polkadot). **Fit note: our gateway is already Go → go-libp2p drops in as a native lib**, no Rust
  sidecar/FFI.
- **Iroh** (n0/number0): Rust, **QUIC/UDP-native**, "dial by node ID," aggressive hole-punch → DERP-
  style **self-hostable relay** fallback → upgrade to direct. The self-hostable relay **IS the
  gateway-as-supernode**, prebuilt. (Rust → needs FFI or a sidecar next to the Go gateway.)
- **Reference:** Tailscale's **DERP** + their "How NAT traversal works" post — canonical.
- **The crucial fork — these are TRANSPORT, not MEDIA.** They give a NAT-traversed, encrypted
  byte/datagram channel by node-ID (solves the connectivity problem we kept hitting) but **no Opus /
  jitter buffer / video codec** (WebRTC gives both — that's its value, and TURN is its cost). Mapped
  onto the scoped payload: **avatar pose/visemes = small datagrams → libp2p/Iroh is *ideal* (no media
  engine)**; **audio = Opus over their datagram stream** (own it, bounded); **screen = a video codec**
  (the most work — the one place WebRTC's engine most earns its keep). Clean candidate architecture:
  **go-libp2p transport substrate** (traversal + relay + identity + encryption, self-hostable relay =
  supernode) + pose/control on datagrams + Opus audio + WebRTC media only where a turnkey codec is
  wanted. Tradeoff: own more of the media stack, but the NAT/relay problem is solved + self-hostable
  and fits a native, data-heavy, agents-as-sources app better than a generic video stack. **Decide
  libp2p/Iroh vs raw-WebRTC at P0 — it's the foundational choice.**
- **Rooms: mesh may suffice given the light payload; SFU only if needed.** Mesh P2P is N² connections
  and normally collapses past ~4–5 peers — but with audio+pose-only streams the per-peer cost is tiny,
  so mesh stretches further. Fall back to a **Selective Forwarding Unit** (self-host LiveKit/mediasoup,
  or managed LiveKit Cloud / Cloudflare Realtime; also sidesteps NAT) only when participant counts or
  screen-share load demand it. Decide empirically, not upfront.

**The WebRTC engine (open question):** link **libwebrtc** (heavy Google C++ lib) vs the pragmatic
**WKWebView-as-engine** trick (a headless-ish webview runs the `RTCPeerConnection`; bridge media in/out
to native surfaces — reuses WebKit's mature stack, cost is native↔webview media plumbing). Decide by
prototype.

**Why it earns a north-star slot:** no one has shipped agents *calling* humans, joining mixed
human+agent rooms, with synthetic/3D presence. It's native to this architecture (agent = a media
source is just another track), not bolted on. Stitches into the other north stars: a streaming
agent-with-vision **is** the computer-use operator loop with a live feed; shared ports **are** the
collaborative shell; and it rides the pluggable-primitives *up*-invariant (a stream surfaces as a
port/peek).

**Phased (leads with the cheap proof; scope = audio + screen + avatars, no camera):** **P0** add the
`signal` message type to sync + a throwaway 1:1 P2P **audio** call between two dev instances over
public STUN (proves signaling-is-free) → **P1** a port's surface as an outbound **screen-share**
track (co-watch one port across instances) → **P2** relay fallback = **gateway-as-supernode**
(measure UDP-over-ngrok quality; `coturn` only if it fails) + a real 1:1 agent↔human call (agent as
audio source via `audio.speak`/TTS, sink via frame→vision) → **P3** **avatars as a pose/viseme
data-channel**, rendered locally → **P4** rooms (mesh-first given the light payload; SFU only if
counts/screen-share demand it), mixed human/agent, with synthetic/3D agent presence. Open infra
decisions to settle before P2: **relay** (gateway/ngrok vs real UDP TURN) and **engine** (libwebrtc
vs WKWebView-as-engine).

---

# Pluggable primitives + Hermes as reference engine (2026-07-08)

## TODO: pluggable engine-primitives — Port42 as the composition layer (→ `docs/pluggable-primitives-architecture.md`)

**Direction:** stop hand-building the agent brain; make the engine-facing capabilities a set of
**pluggable slots** and let the user plug in *anything*. Port42 becomes the **composition layer**
that owns the **user-facing** primitives (`port`, `space`, `permission`, the zoom/peek/adopt/dismiss
grammar) and the slot **contracts**; engine-facing primitives (reasoning / autonomy / execution /
skills / memory / tools) are rented. **Hermes Agent** (Nous, MIT, self-improving skills, local +
model-agnostic) is the **reference external plugin** that proves the slots are real. Its properties
are *representative members of an open set*, not a fixed list. Full analysis in four docs:
[thesis](./shell-with-intelligence-thesis.md) · [investigation](./hermes-engine-investigation.md) ·
[integration-map](./hermes-integration-map.md) · [architecture](./pluggable-primitives-architecture.md).

Why it earns a north-star slot:
- **Payoff = focus.** Renting the engine slots lets the team pour effort into the user-facing
  primitives — the only place we're differentiated (the whole shell thesis).
- **We're not hollow on the engine side.** `tick` (loop engine + execution backends) is the *native*
  provider for the Autonomy + Execution slots; `fs`/`storage` (kv) + creases/fold are the native
  Memory slot; the bridge via `port42-mcp` is the Tools slot. So every slot ships a Port42-native
  provider *and* accepts a foreign one. The slot Hermes most uniquely fills is **skills /
  self-improvement** (no native equivalent yet — candidate for `tick` to grow).
- **This lands the OS-vs-app question on OS.** Moat = the user-facing grammar + slot contracts +
  the bridge, none of which an engine vendor builds. Relates to / subsumes the earlier
  "adopt agent-comms standards — ACP + friends" item (the slot contracts are the open wire).

Load-bearing rules (don't violate as current work touches routing/tools/memory):
- **The one invariant, two-directional (both surfaces Port42-owned):** *Up* — an engine primitive
  reaches the user only through a user-facing primitive (a skill surfaces as a port/command/…; a
  proactive tick surfaces as a peek). *Down* — an engine primitive touches the machine only through
  the bridge (permission-gated). An engine may keep its own sandbox for *ephemeral* compute, but
  host-touching = our gate. Testable: any leak (an engine's own chat UI up; raw host access down) =
  boundary broken.
- **Anti-"Hermes-in-a-trenchcoat" guard:** define every slot contract against **≥2 providers**
  (`tick` *and* Hermes) from day one. A slot that only makes sense with Hermes plugged in is a fake
  abstraction. **The slot contracts are the product-defining work — not the Hermes adapter.**

Open (unresolved) — **skill ↔ port relationship.** A skill is engine-facing (a persistent
*procedure*); a port is user-facing (a disposable *surface*). Not the same axis — a skill may
produce zero/one/many ports, and a port needn't come from a skill. "Skill = disposable render" is
too tidy. The real question the *up*-invariant forces: **how does a persisted engine-side skill
surface in the user layer** (command? dock item? space object? a port it spins up?). Design work,
not a settled mapping.

Phased (leads with contracts, not wiring): **P0** write the slot contracts on paper, validated
against `tick` + Hermes simultaneously → **P1** prove the *down*-invariant (Hermes → `port42-mcp` as
its only host-touching tool; "create a port showing X" renders through the gated bridge; near-zero
Swift via the existing MCP server) → **P2** Autonomy slot behind one contract (`tick` vs Hermes
daemon; proactive output → peeks) → **P3** Skills slot + the *up*-question → **P4** Memory ownership
line + local-model default (the local-first payoff). Onboarding an external engine reuses the
proven `OpenClawService` playbook + `AgentMode.remote`.

---

## Sequencing (rough)

1. **First-class terminal ports** (in progress — `docs/plan-first-class-terminal-ports.md`,
   Step 1 ready). Re-point `terminal.*` onto native `terminal` ports; D1 native-only.
2. **Per-(companion,space) terminal session ids** + per-(companion,space) routing.
3. **Swim → space collapse** + space-scoped relationship memory.

(2) and (3) are the Summer-2026 items above; (1) is the active build.
