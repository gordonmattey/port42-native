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

## Sequencing (rough)

1. **First-class terminal ports** (in progress — `docs/plan-first-class-terminal-ports.md`,
   Step 1 ready). Re-point `terminal.*` onto native `terminal` ports; D1 native-only.
2. **Per-(companion,space) terminal session ids** + per-(companion,space) routing.
3. **Swim → space collapse** + space-scoped relationship memory.

(2) and (3) are the Summer-2026 items above; (1) is the active build.
