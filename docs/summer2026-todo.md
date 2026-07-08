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

## TODO: shim `.zshenv` recursion / job-table error on terminal startup

Observed on every native-terminal spawn (e.g. during `dev-reboot`):

```
/tmp/port42-shim-<id>/.zshenv:1: job table full or recursion limit exceeded
```

The per-session shim `ZDOTDIR` (`TerminalSessionBootstrap`) writes startup files that source the
user's real equivalent (`$PORT42_REAL_ZDOTDIR`, default `$HOME`). The error means the generated
`.zshenv` is **re-sourcing itself** (or the user's `.zshenv` re-enters the per-session dir) →
infinite recursion until zsh's job table fills. Non-fatal (the shell still comes up), but it
spams every terminal and risks subtle env breakage.

Fix direction: guard against re-entry — e.g. set a sentinel env var the first time the generated
`.zshenv` runs and bail if it's already set, and ensure sourcing the real `ZDOTDIR` can't point
back at the per-session dir. Verify with a clean spawn (no error line) + `which claude` still
resolves the shim function.

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
