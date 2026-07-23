# Summer 2026 — north-star notes (TODO)

Forward-looking architecture direction. **Not built yet.** These are decisions about where the
model is heading, written down so they survive reboots and *steer* current work (don't entrench
patterns we've decided to collapse). Each item is tagged TODO.

---

## TODO (2026-07-23, GM): inspect a port's console output via the API

Today a port's `console.log/warn/error` is forwarded by the `portConsole` WKScriptMessageHandler
straight to **NSLog** (`PortWindowManager.swift:1196`, `PortView.swift:186`) — it lands in the dev log
file (`~/port42-build/Port42Dev*.log`) and nowhere else. There is **no bridge method** to read a port's
console (`grep console BridgeMethods.swift` = nothing). So an agent/companion that **builds** a
generative port cannot see that port's runtime errors through the API — it debugs blind (surfaced when a
pushed-data shape bug threw `TypeError` in a port's `render()` every frame, visible only in the log).

**This is the "platform hides its failures" class** (backlog through-line #2): a real error with no
legible signal to the caller that produced it.

**Proposal (two shapes, likely both):**
- **`port.console(id, {tail})`** — a read method returning the port's recent console lines (level +
  message + ts), from a small per-port ring buffer the `portConsole` handler fills (instead of only
  NSLog).
- **Console as a Notify stream** — console output as a subscribable per-port event, so an agent can
  *watch* a port's console live while it iterates on it. This is a clean facet of the L1
  Subscribe→Notify bus (`plan-port42-protocol-local-bus.md`): a port is an actor; its console is one of
  its out-streams, alongside `port42:data` / height / presentation.

**Why it matters:** generative ports are built BY agents (companions ask an LLM to build a port). When
the port errors at runtime, the agent currently has no API-visible feedback loop — it can't self-correct.
This closes that loop and pairs with the never-rejecting-bridge / make-failure-visible work.

**Sizing:** S for the ring-buffer + `port.console` read; the Notify-stream version rides on L1.

---

## TODO (2026-07-22, GM): peek notifications when a Claude Code session needs attention

When a Claude Code session running in a space (a `claude`/hooks **companion CLI** — e.g. Maker/Critic)
**ends its turn and needs the human**, surface a **peek** into the human's current space so they know
which session is waiting. With many sessions running at once you can't watch them all; this is the
"where am I needed" signal made concrete.

**Fit:** a concrete first slice of the membrane's **Gatekeeper + Watcher** (`membrane-architecture.md`:
what reaches you, the calm view of all agents) and directly serves backlog **1.4** (the
*waiting-for-input* signal, the highest-value space signal per the 06-27 ranking).

**Substrate that exists:**
- **turnComplete** — hooks companions already emit a turn-complete event (the clean-transcript path in
  `GhosttyTerminalController`); that is the turn-end trigger.
- **peeks** — the shell peek mechanism (a live surface that pops into a space with an attention beat,
  including cross-space peeks) is built.
- companion/terminal ports + member rows already carry the session identity + space.

**Scope sketch:**
- **Classify** turn-end: distinguish *needs attention* (awaiting input / asked a question / blocked /
  errored) from *done, no action needed* — only the former peeks. Peeking every `turnComplete` is noise;
  suppressing the rest is exactly the Gatekeeper's job.
- **Route** to the human's current space; if the session's space isn't active, a cross-space peek that
  names the session + space with a jump-to.
- **Ack/dedup:** clear on look/respond; don't re-peek the same waiting state; coalesce when several
  sessions need attention at once.

**Open questions:**
- The classifier is the hard part: `turnComplete` alone does not say "needs YOU." Does the hook/transcript
  expose *awaiting-input* vs *finished*? If not, heuristic (ended on a question, a pending
  tool/permission, idle-after-turn) or a session-side signal.
- In-space companion CLIs only, or also external `claude` sessions not registered as companions?
- In-shell peek vs a macOS notification (`notify.send`) when the human is away — ties to the
  Sensor/Presenter modality choice (peek when present, OS notification when not).

**Sizing:** M. The peek + `turnComplete` substrate exist; the real work is the **classifier**
(needs-attention vs done) and the gatekeeping — the membrane's hard part, not the plumbing.

---

## TODO (2026-07-22, GM): native video ports (an AVKit/AVPlayer port type)

A new **first-class port type** that renders and plays video **natively** (AVPlayer / AVPlayerLayer),
not an HTML5 `<video>` inside a web port. Same port-unit model (inline in chat · tiled · parked · peek),
same addressable-actor contract as every other port.

**Why native, not a web port with `<video>`.**
- A web `<video>` carries WKWebView decode/memory overhead and a second WebContent process per clip;
  CSP/asset friction (data: URIs, no external hosts); no native scrubber, Picture-in-Picture, or AirPlay;
  and weaker codec/format coverage.
- We already **produce** video: `screen.record` writes .mp4/.mov, and camera/`screen.stream` are live
  frame sources. A native video port is the natural inline **playback/preview** surface for them.
- Native buys hardware decode, AVKit transport (or custom Port42-styled controls), PiP, AirPlay,
  scrubbing/loop, and clean teardown (release `AVPlayer`/`AVPlayerItem` on close/park/deinit — squarely
  the "nothing releases what it acquired" class, backlog 0.5).

**Fits the bus/actor model** (`membrane/bus-architecture.md`): query-in = play/pause/seek/rate/stop
(Update verbs); stream-out = position/state/`ended` (Notify events); temporal = seek/as-of. A video port
is a clean actor, so it rides the same L0 address + L1 Subscribe→Notify work as everything else.

**Precedent lowers the risk.** The native **Ghostty terminal** port already proves "a non-web native
port type": the create path, the tile/inline/parked presentation plumbing, the re-parentable host view,
and the teardown seam all exist. A `NativeVideoController` (analogous to `GhosttyTerminalController`) with
an `AVPlayerLayer` host is the second native type.

**Source variants (the first slice is a scoping decision — GM to confirm):**
- (a) **local file** (space-cwd / a path) — playback of `screen.record` output. *Likely first slice.*
- (b) **remote URL** — a hosted video.
- (c) **live feed** — camera / `screen.stream` / an `AVCaptureSession` rendered as a port.
- (d) **shared/streamed** video — gates on the live-media-plane / WebRTC north stars (largest).

**Scope sketch (slice a):** `port.create({type:"video", src})` → a `NativeVideoController` + AVPlayer
host, re-parented across inline/tile like the webview; map `port.push`/a small transport API to
play/pause/seek; emit playback Notify events; `.filesystem` permission for local sources; release the
player on teardown.

**Open questions:** primary use case / first source (sets the slice); native transport chrome
(`AVPlayerView`) vs custom controls; **audio routing** (a video port has audio — interacts with the
audio/mic teardown and with multiple concurrent ports); whether `screen.record` should auto-open a video
port on finish; and the addressing/Notify shape (transport = Update, playback state = Notify) as part of
the protocol work.

**Sizing:** M for slice (a) (new port type, but the port-unit/tile/teardown plumbing + the terminal-port
precedent de-risk it); live-feed (c) and shared (d) are L and gate on the media-plane / WebRTC north
stars. Related: "Browser port type" / "WebRTC in browser ports" / "Live media plane (WebRTC P2P)" in the
Tier-4 north stars (`backlog-review-2026-07-20.md`).

---

## BUG (TODO, 2026-07-22): dev gateway shares prod's store-and-forward DB (no dev/prod isolation)

Surfaced while clearing the dev fundemos chat. The dev gateway (:4243) and the prod gateway
(`/Applications/Port42.app`, :4242) both hold the **same** store-and-forward file open:
`~/Library/Application Support/Port42/gateway-messages.sqlite` (table `channel_messages`, keyed by
`channel_id`). It is NOT namespaced to `Port42Dev/`. Confirmed by `lsof` on both gateway PIDs.

**Consequences.**
- Dev chat is durable across dev relaunches via prod's store: clearing only the dev app DB
  (`Port42Dev/port42.sqlite`) does nothing, because the shared gateway store replays the messages
  back on rejoin. A true clear required deleting the space's rows from the shared store too, which
  means writing to a file the prod gateway holds open.
- "Test in dev only (:4243)" does not fully isolate store-and-forward state. Dev and prod messages
  co-mingle in one file (5000+ rows across ~200 channels, incl. prod spaces and swim channels).
- Any dev-side maintenance on that store touches prod infrastructure.

**Likely cause.** The gateway's message-store path is derived from a fixed `Port42/` app-support
dir rather than the app's actual (possibly Dev-namespaced) data dir. The dev app's gateway
subprocess inherits the prod path.

**Direction.** Namespace the gateway store per instance (Dev vs prod vs the other variants that also
exist: Port42B, Port42-Peer, Port42Dev*), e.g. derive `gateway-messages.sqlite` under the same
data dir the app uses, so `:4243` and `:4242` never share a store. Small, isolates dev cleanly, and
removes the "clearing dev chat means touching prod" hazard. For consideration, not yet scoped.

---

## BUG (TODO, 2026-07-21): message to a command companion animates its terminal but never arrives

A `messages.send` posted to the space that @mentions a command (terminal) companion — here a curl
`messages.send` from another companion, mentioning `@terminal` — shows the message in chat AND triggers
animating terminal activity on the target companion, but NO message actually hits the terminal (nothing
is injected into the companion's stdin). Observed live 2026-07-21: the message landed in chat, the
`@terminal` companion's terminal animated as if receiving, but no message reached it.

The animation firing without delivery suggests the routing/turn kicks the companion but the injection of
the message text never happens (or targets the wrong session). Adjacent to the earlier "chat-driven CLI
companion replies on screen but never posts" bug, but the INBOUND direction: a message TO the companion
is dropped. Look at MentionParser/AgentRouter (AgentRouting.swift) → the command-companion inject path
(AgentProcess / the NDJSON stdin write in AgentProtocol.swift).

---

## BUG (TODO, 2026-07-21): shim's PORT42_CLAUDE_SESSION_ID breaks `claude --resume`

A command companion / terminal launched through the shim inherits `PORT42_CLAUDE_SESSION_ID` in its
env. When the user then runs `claude --resume` in that terminal, the CLI errors:
`--session-id can only be used with --continue or --resume if --fork-session is also specified.` The
env var is being consumed as `--session-id` on a resume path that has no `--fork-session`.

Workaround (confirmed live): `unset PORT42_CLAUDE_SESSION_ID` then `claude --resume <id>`.

Fix: the shim's env handling should scrub `PORT42_CLAUDE_SESSION_ID` on the resume/continue path (the
same `sanitizeEnv` discipline that already scrubs `CLAUDE_CODE_SESSION_ID` / `_CHILD_SESSION` /
`_BRIDGE_SESSION_ID` before exec, per CLAUDE.md). Same env-leak class as the earlier
companion-transcript bug. Lives in the shim (`port42-claude-shim`) / AgentProcess env setup.

---

## ~~BUG: restored/launched surface lands under everything + wrong restore animation origin~~ — FIXED 2026-07-22 (verified live)

Two related defects on the park-rail (dock) restore path and the new chat/terminal path. Both fixed;
RCA + plan in `docs/plan-dock-restore-bugs.md`.

1. **Z-order — FIXED.** Root cause was NOT a missing stamp on the create/restore paths (those now call
   `bringToFront`). It was two z authorities drifting: `ShellState.nextZ()` (a counter) and
   `PortWindowManager.bringToFront` (max+1). Terminal focus and other paths stamped panels up to z=171
   via max+1 while the shell counter sat at 80, so `nextZ()` returned a value UNDER existing tiles and
   every fresh port landed behind (measured live: counter 80, live tiles 171). Fix: `nextZ()` re-seeds
   against the live max on every call (`zCounter = max(zCounter, panels.max.z) + 1`), so the shell
   authority can never fall behind the manager authority. Plus the create/restore paths stamp frontmost:
   `handlePortCreated` same-space branch, the chip-restore button, and `openChat`. Three regression
   tests in `ShellStateTests` (birth frontmost, restore frontmost, and the drift case).
2. **Restore animation origin — FIXED.** A `matchedGeometryEffect` shared namespace between the park
   chip (source) and the tile (dest) morphs the tile OUT of the chip's location on restore; the
   `arrangeBump` re-grid was dropped from the chip path so the morph is the only motion. Because tiles
   are absolutely positioned via `.position`, the match is **position-anchored** (the tile flies from
   the chip to its slot; a size-grow from chip-size would fight `.position` and is a deferred polish).

---

## ~~BUG: chat-driven CLI companion replies on screen but never posts~~ — FIXED 2026-07-20

**Fixed on shell-s1** (`docs/plan-companion-cwd.md`, commits a9c6834..40e4a76). Two root causes,
both closed:
1. **Shared transcript from a shared cwd + `--continue`.** Command companions all defaulted to cwd
   `/Users/gordon` and resumed the most-recent session there, colliding on one transcript. Fixed:
   per-space working directory (`Space.workingDirectory`, migration v41, Settings picker); command
   cwd defaults to the space dir; each command port pins a deterministic UUIDv5 `--session-id`
   (per-(space,companion), ad-hoc keys on panel id) via the shim, so companions can share a dir yet
   keep separate transcripts; `--continue` dropped (the shim owns resume via `--session-id`/`--resume`).
2. **Inherited Claude Code session env (found during live validation).** A Port42 app launched from
   inside a Claude Code session leaks `CLAUDE_CODE_SESSION_ID` / `_CHILD_SESSION` / `_BRIDGE_SESSION_ID`
   into every spawned claude, making it a NESTED CHILD that replies on screen but never persists its
   transcript at the path its Stop hook reports — so every reply read empty, masking the fix
   entirely. The shim now scrubs those three before exec (`sanitizeEnv`).

**Live-validated in Port42Dev:** Maker + Critic, both in `/Users/gordon` (the original collision dir),
driven from chat, each wrote its own distinct transcript and POSTED its own reply ("Maker here" /
"Critic here") — previously both `NOT posted (skip=empty)`. Two companions in a shared
`workingDirectory` likewise wrote distinct transcripts with correct content.

Historical diagnosis below (kept for the record).

---

## BUG (original diagnosis): chat-driven CLI companion replies on screen but never posts (2026-07-19, INSTRUMENTED)

**Symptom:** a claude/gemini terminal companion driven from space chat receives the injected
message and replies IN ITS TERMINAL, but the reply never reaches the space. Confirmed live in Dev:
the gate logs `event=turnComplete armed=true exit=0 len=0 ... NOT posted (skip=empty)`. So the
whole chain works except the shim read an EMPTY reply out of the transcript.

**Where it breaks (verified):** on the Stop hook, the shim reads `transcript_path` from the hook
payload and pulls the last assistant turn (`shim/main.go` `lastAssistantText`). It came back empty.
The gate then correctly refuses to post nothing.

**What is NOT the cause (earlier guess retracted):** I first blamed `--fork-session`. Port42 does
NOT pass fork-session or --resume — it types the bare word `claude` and the ZDOTDIR shell-function
adds only `--settings` (AppState.swift:2636-2643). The `--fork-session --resume` processes seen in
`ps` were unrelated claude daemon sessions in other cwds, not the companions. Root cause of the
empty transcript is still OPEN.

**Instrumentation added + committed (214cbd1):** the shim carries transcript path + on-disk size to
the app over the hooks socket; `TerminalHooksService` logs `turnComplete: transcript=… bytes=… len=…`
on every turn.

**ROOT CAUSE FOUND (2026-07-20, via that instrument).** Companions collide on ONE shared transcript
because they all launch with **cwd = /Users/gordon** (the home dir — no cwd was specified at spawn,
so it defaulted to home; verified: Maker, Critic, clitest, logtest all `cwd=/Users/gordon`). Claude
2.x keys its session/transcript on the project = cwd, so every companion in that dir maps to the
SAME project transcript `~/.claude/projects/-Users-gordon/7aacc5af….jsonl`. The instrument showed
three consecutive turnCompletes ALL reporting that one path, `bytes=628212` FROZEN, `len=205`
identical — and the value was a STALE reply ("You're in /Users/gordon. Nothing pending…") from an
earlier unrelated turn. The live reply the user saw on screen ("acknowledged") is NOT in that file
(`grep -c` = 0). So the hook hands the shim a shared/stale project transcript; `lastAssistantText`
returns either nothing (→ empty, no post) or a previous turn (→ stale text, wrong post, then
dedup). Both observed failure modes are this one cause.

**Fix direction (design in a fresh session — touches the launch path + claude 2.x daemon behavior,
do NOT do blind):** GM's model (2026-07-20): a **per-space working directory** with a **port-level
cwd override**; default the cwd to the SPACE dir, not home. Plus **unique claude session ids per
port** as insurance (isolates even two companions sharing one project dir; cwd is the load-bearing
fix, session id is belt-and-suspenders). Verify against claude 2.x's daemon session-keying before
choosing. Prerequisite for the auto-register-companion feature below.

**Same root, second symptom — the API-only join instructions default to a colliding name.** The
CLI-join prompt (generated by an EXTERNAL tool, not in this repo — could not locate the generator)
suggests `NAME=$(basename "$PWD")` and warns "not gordon (the host)". But the default cwd is
`/Users/gordon`, so `basename $PWD` = `gordon` = the host — the exact collision it warns against.
Fixing the cwd default (space dir, not home) fixes this too. The rest of that prompt is accurate
against the live API (verified 2026-07-20): space.current shape, messages.send with senderName
→ senderType "agent", messages.recent returning isCompanion, and the self/other-skip loop (a CLI
agent's own sends come back isCompanion:true, so two CLI agents correctly skip each other).

---

## ~~TODO: any `claude` in any terminal port auto-registers as a space companion~~ — FIRST CUT DONE 2026-07-20

**Shipped** (shell-s1, commits 33118f2 + 9d6fb65). The shim emits `sessionStarted` (SessionStart
hook); on it, a terminal whose name isn't already a named companion auto-registers as a mention-gated
space companion (roster member + `@`-addressable, but its post gate still arms on inject so private
turns aren't broadcast), and is removed when the terminal tears down. Names are deterministic
adjective-animal codenames (`CompanionCodename`, seeded by panel id, stable across respawn); dock
terminals get one at spawn (a CLI companion's name is baked at spawn, can't re-bake without respawn).
Live-validated: a claude terminal auto-registered ("witty-lynx"), replied + POSTED when `@`-mentioned,
and left the roster on close.

**Follow-ups (not done):**
- **Routing is over-broad:** during the live test the auto-registered companion was injected with a
  message that mentioned a DIFFERENT companion (`@Maker`), so it replied unbidden. `mentionOnly`
  should mean "only when I'm named." Tighten `routeMentionsToTerminals` mention matching.
- **Surfaced-status mode:** option (a) from the design (turns surface as member-strip activity)
  is not built; only the mention-gated roster membership is.
- **Explicit-join affordance:** option (b) (a one-click join prompt) is not built; registration is
  silent-but-mention-gated. Revisit if silent roster entries feel surprising.
- Boot-time re-register: persisted ad-hoc terminals (clitest/logtest) re-fire SessionStart on restart
  and re-register; harmless (they clean up on close) but worth confirming it's the desired behavior.

---

## TODO (superseded): any `claude` in any terminal port auto-registers as a space companion (2026-07-19, GM)

**Want:** when a user opens `claude` (or another hooks-capable CLI) in ANY terminal port — not just
one spawned as a named companion — that live session should appear as a companion in the space and
be addressable from chat. Today only ports spawned via the companion path get the identity + the
inject/turnComplete loop; an ad-hoc `claude` typed into a plain terminal port has the hooks shim
(so turnComplete fires) but no space-membership registration and no display identity.

**Unblocked 2026-07-20:** the reply-post bug is fixed, and a plain terminal already passes every
hook/session/env parameter (hooks socket, space id, per-panel `--session-id`, env-scrub, even the
baked framing prompt), so `claude` in a dock terminal hooks up mechanically identical to a companion.
The only gap is identity + registration + arming policy.

**Design (agreed with GM 2026-07-20):**

- **Detection hook:** `sessionStarted` (shim → `GhosttyTerminalController.swift:162`, currently just
  logs/flushes). On it, if the port has no companion identity, register.
- **Register =** mint a command `AgentConfig` for the panel, `saveAgent` + `assignAgentToSpace` +
  `addCompanionToSpace` → roster member, `@`-mentionable.
- **Arming follows INTENT, not global.** The gate waits for an inject on purpose: a claude terminal
  fires `turnComplete` on every turn (private commands, exploratory questions, each intermediate
  tool round), so arm-always would flood chat with the user's private work. Two safe shapes, pick
  one: (a) **addressable + turns-as-status** — member + mention-gated chat posts, turns surface as
  lightweight member-strip activity; or (b) **explicit join** — on `sessionStarted` surface a
  one-click "claude joined #space, add as companion?" affordance (explicit intent, no surprise
  broadcast). Prefer starting with (b).
- **Name:** deterministic + stable from the panel/session id (a friendly adjective-animal codename,
  e.g. "claude · quiet-otter"), so a respawn keeps the name. `basename $PWD` is a fine *label* now
  that spaces have working dirs, but two terminals in one dir collide, so it is not the identity.
  **Rename constraint (GM):** a CLI companion's name is baked into `PORT42_COMPANION_PROMPT` at spawn,
  so renaming the display name later does NOT re-bake the prompt until the terminal restarts. So pick
  a good name at spawn; a later rename needs a respawn to fully take.
- **Self-post loop:** a registered companion that posts MUST skip its own messages. The routing-side
  `isCompanion:true` skip already covers this; keep it watertight when arming is flipped on.

Status: design agreed, not built. First cut = the explicit-join shape.

---

## RESOLVED: coalescing test raced its own registration and hung the suite (2026-07-19)

Found during Phase 3 item B (the PermissionRequester collapse), fixed same session.
`PermissionCoordinatorTests/coalescesAndResumesAll` settled on `current != nil`, which was already
true from its FIRST ask, so `resolveCurrent` could run before asks two and three registered on the
main actor. Those asks then coalesced onto a fresh card nobody answers, and their `await`s hung the
whole test process forever (0% CPU, no output — looks exactly like the SwiftPM lock wedge, but
`ps` shows the helper running and no lock holder). Latent since the suite was written; the item-B
type swap only perturbed scheduling enough to make it deterministic. Fix: `PermissionRequest` grew
a public read-only `awaiterCount` (continuations stay private) and the test settles on
`awaiterCount == 3` — registration, not card presence. Lesson for async coordinator tests: settle
conditions must assert the thing the next step consumes, not a proxy that an earlier step already
satisfied.

---

## BUG: gateway up but "no host available" — RESOLVED 2026-07-19 (two distinct causes)

**RCA complete (2026-07-19, live-reproduced and bisected).** The recurring symptom had two
independent causes, one primary and fixed, one secondary with a fix identified but not yet applied.

**Cause 1 (primary, FIXED): fragment NSException wedges the main queue.** `PortBridge`'s port-JS
resolve path serialized results with `JSONSerialization.data(withJSONObject:)` and no
`.fragmentsAllowed`. A registry method returning a bare string (`crease.read`'s "No creases yet")
raised an ObjC NSException that `try?` cannot catch; it unwound through the main-queue drain and
permanently corrupted it: no dispatch block or main-actor task ever ran again, while the run loop
kept pumping (timers/events fine, app looks alive, TCP fine). Every queued action was dead: RPC
replies (hence "no host" style timeouts), clicks, video loop re-enqueue. Trigger in the wild: the
step-2 live-verification port `proxycheck` persisted in the dev workspace; its onload script called
`creases.read` on every boot, wedging the app before unlock. Proven by data bisection (poison port
alone reproduces; without it 14 ms RPC) and a main-queue watchdog that stopped ticking at exactly
the serialization line. Fixed with `.fragmentsAllowed` (matching the streaming resolve path) and
swept across the other fragment-capable sites (PortBridge push/pushEvent/storage-old-path,
SyncService RPC response, ToolExecutor push + jsonString). Regression test still TODO: a
port-surface resolve of every registry method's return shape must not throw.

**Cause 2 (secondary, fix identified, NOT yet applied): stale-gateway reclaim is dead code.**
`AppState.killProcessOnPort` (AppState.swift:1204) invokes `/usr/bin/lsof`, which does not exist on
this macOS (`lsof` lives at `/usr/sbin/lsof`), so it throws "file doesn't exist" every time. An
orphaned gateway from a prior run keeps the port bound; the new app's own gateway exits
("process terminated") and the app attaches to the stale hostless gateway, giving the literal
`no host available` error. Live-reproduced by planting an orphan on :4243 and watching the reclaim
fail. Fix: point at `/usr/sbin/lsof` (or probe both paths). The earlier orphan observations below
were this cause.

**Observed this instance (facts, not a diagnosis):**
- Installed prod app `/Applications/Port42.app` (PID 83444) running ~12h; its host was NOT reachable
  via `:4242`.
- The gateway bound to `:4242` (PID 42716) answered `/health` = ok but reported no host. Its **ppid was
  1** (orphaned/reparented), uptime ~12h36m, and its path was
  `/Users/gordon/port42-build/Port42.app/.../port42-gateway` — i.e. spawned by a **port42-build** copy,
  not the installed `/Applications` app that is currently running.
- For contrast the dev gateway `:4243` (PID 72844) had ppid 72812 = its Port42Dev app (correctly
  parented), and its host WAS reachable.

**Hypothesis to verify (NOT confirmed):** a prior port42-build Port42 exited without reaping its
`port42-gateway` subprocess; the gateway orphaned (ppid 1) and kept `:4242` bound; a later app's
gateway then can't bind the port, so its host never registers on `:4242`. Restart frees the port.
If that holds, the fix is reaping the gateway subprocess on app exit (and/or the app detecting a
foreign gateway on its port at startup and refusing/reclaiming). GM pushed back on the orphan theory,
so treat this as one hypothesis among others until reproduced.

---

## HARDENING: stream continuation can dangle on non-cancel silent engine death (2026-07-18)

Follow-up from `docs/rca-aicomplete-cancel-hang.md` (§8 residual). The cancel-hang is fixed
(settlement is core-owned on cancel). But the general class remains: a streaming call's continuation is
settled only by `LLMStreamCollector.finish`, driven by an engine terminal callback OR the cancel path.
If a backend dies/deallocs mid-flight without any terminal event and without a cancel, the continuation
dangles and the JS promise never settles. Low frequency, but it is the same root class.

**Fix (proposed):** a collector-level safety net — a deinit guard and/or a max-duration timeout that
settles the continuation as an error if no terminal event arrives. Closes the class fully so no engine
misbehavior can leak a pending promise. Add a test: a backend that emits nothing ever, assert the call
settles (errors) rather than hangs.

**FIXED 2026-07-22.** Finding during the fix: a pure `deinit` guard would NOT close the class, because
the collector is held in the owner's strong `_activeStreamCollectors` and is removed only on
`finish`/cancel — so on a silent death it stays retained forever and never deallocs (deinit never fires).
The effective fix is a **max-duration watchdog** in `LLMStreamCollector`: a `Task` that settles the call
as an `ai_timeout` error after `timeout` (default 300s, injectable), which ALSO drops the retention via
`onDone`. It is cancelled on a normal finish. A `deinit` guard is added too as a cheap net for the
dealloc-while-pending case. Regression test `StreamCollectorHardeningTests`: a backend that emits nothing
settles with an error (0.2s watchdog) rather than hanging. The cancel-hang + 120s request timeout still
stand; this closes the exotic no-callback-no-throw-retained tail.

---

## ~~BUG: ports.list ignores space_id~~ — FIXED 2026-07-19 (sweep part 1)

`ports.list` honors `space_id` server-side AND every entry carries its `spaceId` for client-side
filtering; gated in `BridgePortsTests/listScopedToSpace`. Rode along: `port.move` on an unknown id
threw a silent `{ok}` no-op, now `not_found`. The once-missing gateway methods (`screen.displays`,
`port.position`, `port.move`) were verified serving from the registry. Same sweep, parts 2-3: the
last parallel permission table (`permissionForMethod`) is dead — the registry is the ONLY
permission table (scan-gated); the port document wrapper (CSP + theme) is ONE function with
overflow as the only per-presentation difference (scan-gated); a real drop-grant bug fell out
(dropped paths were granted to the messageId while a companion-created port reads as its creator —
dropped files were unreadable; grant now keys on the principal). The "liveness signal" remainder
below stays open. Original report:

## Original: BUG: ports.list ignores space_id — can't scope ports to a space (2026-07-18)

**Severity:** High. Blocks any per-space port UI and silently misleads callers.

**Environment:** dev gateway `127.0.0.1:4243`.

**Summary:** `ports.list` returns the same set regardless of the `space_id` arg, and ports carry no
space field. No way to know a port's space or list just the current space's ports.

**Repro:**
```
curl -s http://127.0.0.1:4243/call -d '{"method":"ports.list","args":{"space_id":"79118500-3C0D-4C45-900D-306294EEE2C2"}}'   # fundemos
curl -s http://127.0.0.1:4243/call -d '{"method":"ports.list","args":{"space_id":"1E45D87C-D954-4A8B-8AAC-38B8AE77B7D2"}}'   # general
```

**Expected:** each returns only that space's ports (or errors if `space_id` is unsupported).

**Actual:** both return the identical 46-port set. `space_id` is a silent no-op. Port objects expose
only `capabilities, createdBy, id, status, surfaceBound, title, x, y` — no space. `status` is only ever
`tiled`/`parked`, so it doesn't distinguish spaces either.

**Fix (either/both):** honor `space_id` server-side, or add a `space_id` field per port for client-side
filtering.

**Related (maybe split out):** `ports.list` membership is an unreliable liveness signal — a port can be
absent from the list yet still alive and addressable by id, then later return `not_found` once actually
closed.

---

## ~~BUG: 6 pre-existing unit-test failures in the local test env~~ — RESOLVED 2026-07-20 (a218660, 4c40b17)

All six attributed and cleared; **none were logic regressions** (as suspected). SenderOwner:
stale test hit the local @owner-strip path (now uses a synced entry). AgentRouting x2: trigger
gating moved out of findTargetAgents into the AppState pipeline (tests rewritten to the
membership/mention contract). AgentConfig x2: CLIPreset.systemPrompt is empty by design (framing
baked at spawn; tests assert empty). Last-space: the code is right (DMs aren't galaxy spaces so a
fresh general is recreated; test corrected). Historical diagnosis below.

### (historical) 6 pre-existing unit-test failures in the local test env (2026-07-18)

**Found:** a full `swift test` run during item-8 streaming work. **Not caused by that work** — proven
statically: the item-8 diff (C1+C2) touches only 6 bridge/AI source files; none of the source these
tests exercise is in the diff (the one shared file, `AppState.swift`, changed only by two inert
stored-property declarations). The failing test files were last modified by commits far predating this
work. So these are pre-existing and were passing-or-failing independent of item 8.

**The 6 failures (4 suites):**
- `SenderOwnerTests.swift:48` — "ChatEntry displayName with different owner shows Name@Owner":
  `displayName()` returns `"Echo"`, expected `"Echo@Gordon"`. (Suite: F-506/F-509 Sender Owner.)
- `AgentRoutingTests.swift:97-98` — "All-messages agent receives everything": `targets.count` is 0,
  expected 1; `targets.first?.displayName` is nil, expected "watcher".
- `AgentRoutingTests.swift:110-111` — "Mixed trigger modes route correctly": same shape, 0 targets
  where 1 expected, displayName nil where "watcher" expected. (Suite: Agent Message Routing.)
- `AgentConfigTests.swift:324` — "Claude CLI preset resolves non-empty path and has expected args":
  `preset.systemPrompt` is empty, expected non-empty.
- `AgentConfigTests.swift:332` — "Gemini CLI preset has expected shape": `preset.systemPrompt` empty,
  expected non-empty. (Suite: Agent Config.)
- `AppStateTests.swift:129` — "Cannot delete last space": `db.getAllSpaces().count` != 1 after the
  guard should have blocked deleting the last space. (Suite: AppState.)

**Hypothesis (to verify, not diagnosed):** the two CLI-preset failures read an empty `systemPrompt`,
which points at a bundled resource / CLI path that is absent in the local test bundle (env-dependent,
not a logic regression). The routing failures (0 targets) and the Sender Owner / last-space failures
need separate confirmation — could be test data assumptions that drifted with the Spaces / F-506 work,
or genuine regressions from an earlier commit. **Attribute each before fixing:** run the four suites on
successive earlier commits to find where each went red, so a real regression is not mistaken for an
env-only flake.

**Repro:** `swift test --filter "SenderOwnerTests|AgentRoutingTests|AgentConfigTests|AppStateTests"`.

---

## RESOLVED: a test run SIGTERMed the running production app (2026-07-19)

**Incident.** A `swift test --filter "Port"` run killed the production Port42 app mid-session (no
crash report: SIGTERM, not a segfault). The filter matches full test identifiers, which include the
module name `Port42Tests`, so "Port" selected the ENTIRE suite, including the live-API companion
tests and every suite that calls `completeSetup`.

**RCA (two causes, both fixed, gated in `GatewayReclaimSafetyTests`):**
1. `completeSetup` → `configureSyncIfNeeded`: in a test process `GatewayProcess.shared` is never
   running while the real app's gateway holds :4242, so the "stale gateway" reclaim fired
   `killProcessOnPort(4242)` from inside the test run.
2. `killProcessOnPort` ran `lsof -ti tcp:4242` with no state filter — that lists every process
   with ANY socket on the port, so the SIGTERM hit the listener AND its clients: the production
   app itself, its companion processes, and ngrok. The path had been dead code until the
   2026-07-19 lsof-path fix (4904165) armed it; the first full-suite run after that pulled the
   trigger. The kill also tore down the Claude Code session driving the run (exit 137).

**Fixes:**
- `killProcessOnPort` now filters to the listener: `lsof -ti tcp:<port> -sTCP:LISTEN`. Gated
  fail-then-pass with scratch child processes (a listener dies, a connected client survives).
- `AppState.isTestProcess` (process-identity detection: `swiftpm-testing-helper` / `xctest` /
  `.xctest` bundle / XCTest-linked; the SPM helper carries NO test env vars, verified) guards
  `configureSyncIfNeeded` entirely: a test process never spawns a gateway, reclaims a port,
  connects sync, or autostarts ngrok. The gate #requires detection BEFORE touching the dangerous
  path, then proves `completeSetup` leaves sync/gateway untouched. End-to-end: the incident suites
  (`AppStateTests`, `SwimTests`, `CLIIdentityTests`, `SwimUnificationTests`) re-run green with the
  production app up and untouched.

**Process rule going forward:** test filters use exact suite/type names, never substrings that can
match the module name (`Port42Tests` makes bare "Port" a full-suite run).

---

## RESOLVED: the port script "never executes" trap is module scope, not a dead script (2026-07-19)

RCA (probe-verified): both render paths (fence and port.create, `wrapHTML` in PortView +
PortWindowManager) rewrite `<script>` to `<script type="module">` for top-level await — the
documented platform pattern (ports-context's canonical example uses bare top-level `await` +
`addEventListener`). Module scripts DO execute; their top-level declarations are module-scoped, so
inline `onclick="fn()"` attributes resolve against window, find nothing, and fail with "Can't find
variable" — which reads exactly like a script that never ran. This trips any LLM that writes
demo-style inline handlers (the item-6/7 rigs did).

Resolution (behavior unchanged — existing ports depend on module semantics):
- The constraint is now EXPLICIT in ports-context.txt and llms-preamble.txt: never inline
  onclick; use addEventListener or `window.fn = fn`.
- Both wrappers inject a classic-script teaching hint: when the exact failure fires, the console
  explains module scope and the fix instead of a bare ReferenceError.

---

## NOTE: dev-build Screen Recording TCC recovery (2026-07-19)

The Screen Recording grant for `com.port42.dev` can wedge (toggle on, still denied) with no
per-request prompt to recover with, unlike mic/camera. Recovery that worked live:
`tccutil reset ScreenCapture com.port42.dev`, launch, request once (fails), toggle the fresh
System Settings entry, restart the app, request again. (Not a two-bundle clash as first suspected:
`.build` is a SYMLINK to `~/port42-build`, one bundle. Likely a stale grant against an older
signature.) Related build gotcha, hit the same evening: build.sh's kill-before-sign step matches
instances launched via `~/port42-build/...` but not via the repo's `.build/...` symlink path, so a
running app launched through the symlink makes codesign fail with "internal error in Code Signing
subsystem". Quit the dev app before ./build.sh, or widen the kill match to both paths.

---

## BUG: screen.stream glitches the pointer — UNDIAGNOSED, feature NOT stable (2026-07-19)

Live item-6 run: while `screen.stream` is active the mouse pointer JUMPS erratically (not load
stutter — teleporting), recovering the moment the stream stops. Pre-existing behavior of the
streaming pipeline (the item-6 extraction changed ownership/teardown, not capture); the extraction
gates all passed, but the FEATURE cannot be called stable until this is diagnosed.

**Bisect trail (all reproduce the glitch, so all these are exonerated as causes):**
- Headless stream via the gateway, owner nil → no webview delivery at all → still glitches
  (rules out the base64 `evaluateJavaScript` main-thread path).
- fps 2 and fps 10 → same. scale 0.3 and native 1.0 → same.
- Single-WINDOW capture (`desktopIndependentWindow`, no display filter, no cursor compositing)
  → same. (Rules out `showsCursor` and the display content filter.)
- Hoisting the per-frame `CIContext` in both stream delegates (landed) → no perceptible change.
  Kept anyway: a per-frame GPU context was real waste.

**Verdict (2026-07-19, GM):** macOS's own recorder (Cmd+Shift+5) is glitch-free on this machine,
used all the time. So the bug is OURS: something about our SCStream usage. Remaining suspects, in
order: the synchronous heavy work inside the SCStreamOutput handler (CIContext.createCGImage +
NSBitmapImageRep + JPEG + base64 on the sampleHandlerQueue, holding IOSurface-backed buffers and
back-pressuring WindowServer's delivery), default `queueDepth`, `delegate: nil` on the SCStream
(errors invisible). Next diagnostic: a handler that drops every frame immediately (no processing) —
if the pointer is calm, it is the buffer-holding work; move processing off the handler queue and
copy out of the IOSurface fast.

Secondary (still real, now decoupled): per-frame base64 through `evaluateJavaScript` on the main
thread is the delivery cost item for when frames actually flow to a port; off-main serialize or a
binary transport. Design item.

---

## BUG: stale label-identity member row + qualified-name collisions in space membership (2026-07-19)

Found while verifying `space.current` scoping (which is CORRECT — each space returns its own
roster). Two data-level issues in the general space's members:
- **A `remote-http-cal` member row** (type agent, empty owner, the label as id AND name): the
  pre-Phase-3 flattened gateway label persisted as a space member. The constructor class is dead
  (scan-gated), but the fossil row survives in the DB and renders in every member list. Fix: a
  one-time cleanup deleting member/agent rows whose id matches the old label shape; decide whether
  the CURRENT gateway principal (`local-http`) should ever appear as a space member at all.
- **Qualified-name collisions**: the LLM companion `echo` (UUID id) and the CLI agent
  `cli-agent-echo` are distinct members that both resolve to `echo@gordontest`; same for the human
  `gordontest` vs `cli-agent-gordontest`. Distinct rows, legitimate, but `@echo` is ambiguous for
  mention routing. Needs a decision: unique names per space, or disambiguation in qualifiedName.
  Adjacent to the "disallow whitespace in space + companion names" todo.

---

## ~~BUG: a new port created in the CURRENT space peeks instead of just showing up~~ — FIXED 2026-07-20

**Fixed at the peek-decision seam.** `ShellState.handlePortCreated` now gates the peek on
`spaceId != currentSpace` — a port born in the space you're viewing settles straight into the grid
as a tile (via `desktopTilePanels → contextItems`), and the peek is reserved for a port in another
space. The tile already existed the instant the panel was appended (`presentation:"tiled"`); the
peek was only *shadowing* it (peek-wins dedup in `contextItems`), so gating the peek makes it render
as a tile with no new path. This replaced the leaky `userSpawnedPortIds`/`noteUserSpawn` whitelist,
which only suppressed the two dock buttons and missed every other creation path — which is why a CLI
companion spawned from the dock still peeked. The space gate covers all paths (dock, CLI companion,
gateway, JS) with no per-spawn bookkeeping. **Verified:** `PortUnitPeekTests` green (rewritten
`currentSpaceBirthDoesNotPeek`); live in Dev a gateway-created port in the current space tiled while
one created in another space peeked in. Historical write-up below.

## BUG (historical): a new port created in the CURRENT space peeks instead of just showing up (2026-07-20, GM)

**Symptom:** when a port is created in the space you're currently viewing, it comes in as a
*peek* (the transient preview overlay) rather than simply appearing as a tile on the desktop.

**Want:** a peek is for a port that lands in ANOTHER space (a glance at activity elsewhere). A port
created in the space you're in is just yours — it should show up directly (tiled/inline per its
presentation), no peek. So the peek path should be gated on `port.spaceId != currentSpace`.

**Where to look:** the peek trigger on port creation/arrival (ShellState peek logic +
`ShellDesktop`/`AppState.createPort` presentation path). Confirm the space-scoping check exists and
is correct; today it appears to peek regardless of whether the port is in the current space.

---

## ~~TODO (NEXT): output caps live on the shared base — move them to the LLM tool-result path~~ — DONE 2026-07-20

**Done.** The cap moved off the base and onto the LLM tool-result adapter — one generic knob, not two
ad-hoc per-method caps.
- **Removed** the base caps: `ShellExec.maxOutputBytes` (terminal.exec) and the `rest.call` non-JSON
  50KB truncation. Both now return the full body to every caller. Reverted the two description
  truncation notes + the golden + regenerated `llms.txt`.
- **Added** `ToolExecutor.maxToolResultBytes = 200_000` (~50K tokens) and `capForModel(_:max:)`, a pure,
  method-agnostic cap applied only on the in-app LLM tool-result path (`toToolBlocks`). It truncates any
  oversized text block **in-band** ("… (truncated: showing N of M bytes — narrow …)"), leaves small and
  non-text (image) blocks alone, and covers every large result (fs.read, ports.list, getHtml), not just
  the two that had ad-hoc caps. Gateway + port callers are uncapped.
- **Fixed a pre-existing pipe-buffer deadlock in `ShellExec` that the removal exposed:** it drained the
  pipes only after `waitUntilExit`, so any command over ~64KB (the OS pipe buffer) blocked the child on
  write, hung until the timeout, and salvaged a truncated 64KB. Now both pipes drain concurrently with
  the process. Without this the "ports get full output" goal was a lie.
- Verified: `TerminalExecBridgeTests` green — a 300KB command returns whole in 0.055s (was a 30s
  deadlock); `capForModel` caps at 200KB with the marker. Parity / rest / llms.txt gates green.

Historical write-up below.

## TODO (historical): output caps live on the shared base — move them to the LLM tool-result path

**Found while documenting the truncation (0.4).** Two bridge methods truncate their output at 50KB
in the **shared base**, so the cap hits **every** caller identically:
- `terminal.exec` → `ShellExec.maxOutputBytes = 50_000` (`ShellExec.run`, the one shared body).
- `rest.call` → a **non-JSON** response body over 50KB is cut (`BridgeMethods.swift` ~585). A JSON
  body is returned **whole** (parsed, uncapped) — so a 200KB JSON is fine but a 60KB CSV is
  truncated. Arbitrary and inconsistent.

**The problem — it's at the wrong layer.** The cap's only justification is bounding the **model's**
context (every returned byte is tokens the LLM tool-use caller pays for, plus tool-result bloat). But
because it lives in the base, a **port** — plain JS reached via the bridge, NOT token-limited — is
silently truncated at 50KB too. The backlog already caught the symptom: "a port shelling out for JSON
gets `Expected '}'` and no idea why." A limit correct for the model path is wrong for the port path.

**Fix direction (a clean slice of the API/tool-use unification — one base, thin per-caller adapters):**
move the size cap OFF the base and onto the **LLM tool-result adapter**, where the token cost actually
lives. The port and gateway callers receive the full body (or a much larger, opt-out cap); only the
tool-use path truncates, and it does so where it can say so in-band (a `truncated: true` + a pointer to
fetch the rest). Sweep both sites (`ShellExec`, `rest.call` body) and audit for any other base-level
caps that penalize non-model callers. Now that 0.4 documented the caps, this removes the need for the
documentation by removing the surprise. Sequence: with / as a first concrete slice of the unification.

## ~~TODO: publish the generated API reference as a static llms.txt~~ — DONE (found 2026-07-20)

**Already built exactly as planned.** `llms.txt` is committed at the repo root, generated by
`generateAPIReference` (the same renderer `help` serves), with `BridgeDocsExportTests` as both the
exporter (`PORT42_REGEN_DOCS=1`) and the freshness gate (committed == generated, deterministic across
two built worlds). Publish = the committed file (raw GitHub URL). Confirmed green this session when the
terminal.exec/rest.call descriptions changed → regen → gate passes. Historical write-up below.

## TODO (historical): publish the generated API reference as a static llms.txt (2026-07-19)

Since close-out step 4c the reference renders at RUNTIME (`BridgeReference.swift`, served via
`help` + InstructionService); no static llms.txt exists to publish. Wanted (GM): a publishable
artifact. Plan: a small exporter that builds the registry in memory (the parity-world pattern),
renders `generateAPIReference`, and writes `llms.txt` into the repo, plus a freshness gate test
asserting committed == generated so the published file cannot drift (same discipline as the
tool-definitions golden). Publish = the committed file (raw GitHub URL, like the DMG).
`ports-context.txt` stays hand-authored prose; its method claims are already pinned by tests.

---

## ~~TODO: AppleScript / Automation enablement for the test env~~ — RESOLVED 2026-07-20 (a218660)

Took the stub-the-logic option: `resolveTimeout` is now internal and unit-tested directly (default
30s, clamp [1,120]), so the timeout logic is covered without the live NSAppleScript/osascript call.
The real automation path stays live-only; the invalid-script error path still runs live (a compile
error needs no TCC, so it passes headless). The bridge feature itself always worked. Original below.

### (historical) AppleScript / Automation enablement for the test env (2026-07-18)

`AutomationBridgeTests` "timeout defaults to 30s when not specified" fails in the local `swift test`
env: it runs a real AppleScript (`osascript`) that returns neither the expected `"hello"` nor an
`error`, because the test process holds no Automation (Apple Events) TCC grant. A 7th env-only failure
alongside the six above, not a logic regression (the `AutomationBridge` source is untouched, and it was
green after the `ai` service migration on every other suite).

**Enablement options (pick one, verify):**
- Grant the test runner Automation permission (TCC) so the live `osascript` path runs in CI/local.
- Stub `AutomationBridge` behind a protocol so dispatch + arg-parse + `BridgeValue` shaping are
  unit-tested while the real `osascript` call is live-only (the Phase-2 hardware-stub pattern the plan
  already uses for screen/camera/clipboard/audio).
- Mark the live automation test as requiring an entitled/interactive run, so headless runs skip it
  instead of red-failing.

Until then the failure is expected headless.

**Repro:** `swift test --filter "Automation Bridge"`.

---

## BUG: permission prompt lost when a port pops in — re-request never fires (2026-07-17, UNCONFIRMED)

**Symptom (reported by GM, not yet reproduced):** GM responded to a permission prompt, then the prompt
**disappeared as a port popped in** (a peek or a newly-created port taking the overlay's place). GM then
tried to use the port that needed the permission and it **did not prompt again** and the gated action did
not proceed. Net effect: the caller is stuck in a state where the permission is neither granted nor
re-requestable.

**Hypothesis (to verify in code, NOT a diagnosed root cause):** the `PermissionCoordinator` request that
was in flight got resolved/cancelled when the overlay was replaced by the port (focus/z-order or the
overlay view being torn down), so `permissions.request(...)` returned `false` (denied) even though GM had
answered. If a `false` result is then cached or persisted as a decision, the method sees "already
decided" and never re-prompts. Places to look:
- `PermissionCoordinator` queue lifecycle: does replacing the overlay (a port peeking/popping) cancel or
  auto-resolve a pending request? Does a dismissed prompt resolve `false` silently?
- `runBridgeMethod` (`BridgeDispatcher.swift:37`): on a `false` from `request(...)` it throws
  `permissionDenied` but does **not** persist a denial, so a retry *should* re-ask. Confirm nothing
  upstream (the port JS shim, or a per-call cache) is swallowing the retry or memoizing the deny.
- Overlay vs port surface: whether a popping-in port and the permission overlay compete for the same
  presentation slot / focus, so the prompt can be visually replaced mid-decision.

**Repro to attempt:** trigger a gated call (e.g. `screen.capture`) so the prompt appears, then cause a
port to peek/pop in before answering (or while answering), then retry the gated call and observe whether
it re-prompts. Test in Port42Dev (:4243).

**Relationship:** in the same blast radius as the Phase 3 principal work (permission keying). Whatever
Phase 3 does to `Principal`/keying must not entrench this: a lost/denied prompt must always be
re-requestable, never cached as a silent permanent deny.

---

## BUG: ports restore blank — the "blanking bug", root cause found (2026-07-17)

**Symptom:** after an app restart, some web ports come up **blank** (empty `document.body`, `port42`
undefined), while others render fine. Surfaced hard this session by two rebuilds + a Keychain-stalled
startup; recovered by hand with `port.getHtml` → `port.update` (reload the saved HTML into the
webview). The HTML was never lost — `port_panels.html` held the full document for every blank port.

**Root cause (diagnosed in code, not a guess):** `restoreFromDB` → `createPortWebView` calls
`loadHTMLString(wrapHTML(panel.html))` **once, eagerly, on a webview that is not yet in the view
hierarchy** (`PortWindowManager.swift:825`, load at `:884`). A WKWebView load on a detached view,
scheduled while the main thread is stalled at startup (the Keychain block), can silently fail to
complete: blank body, and the `atDocumentStart` bridge script never runs (hence `port42` undefined).
There is **no load-completion check and no reload when the tile finally renders** — so a port that
loses its restore-time load stays blank forever with no recovery.

**Root fix (not the symptom):**
- **Load on attach, not eagerly on restore.** Move the `loadHTMLString` to when the webview enters
  the view hierarchy (`didMoveToWindow` / the representable's first `updateNSView`), so hydration is
  deterministic regardless of startup timing.
- **Verify + self-heal.** The `navigationDelegate` already exists — track `didFinish`/`didFail` and
  reload `panel.html` once if a restored port's initial load didn't complete.
- **Recovery affordance:** a "reload blank ports" command (the `getHtml`→`update` sweep, automated) so
  a user is never recovering ports by hand (relates to the parked "reopen closed ports" item).

**Test:** a restore test asserting every restored web panel ends with non-empty `document.body` and
`typeof port42 === 'object'`. Lives in `PortWindowManager`; independent of the API-unification work.

---

## ~~BUG: background port vanishes on restart~~ — FIXED 2026-07-17 (core); optional hardening remains

**Fixed (the core):** `fetchPortHtml` now falls back to the latest `port_versions` row when there is
no `port_panels` row (`DatabaseService.swift`), so `resolveBackgroundHtml` → `fetchPortHtml` resolves
the background HTML even after the tile was closed. **Verified live:** after a restart, the persisted
background port's `port.getHtml` returns its HTML (was `not_found`) and the background renders with no
manual recovery. Also fixes `port.getHtml` returning `not_found` for panel-less ports generally. Unit
test: `FetchPortHtmlFallbackTests`.

**Optional hardening still open (not required for survival):** stop *deleting* the panel row when a
port becomes background — persist it with `isBackground=true` — so the background is also a live,
listable, editable port (the chrome-is-ports v2 direction), not just a rendered HTML string. Original
write-up below.

---

## BUG: background port vanishes on restart — root cause found (2026-07-17)

**Symptom:** a port set as the shell background (`ShellBackgroundPort` / `setBackgroundPort`, v1) is
gone after a restart — not just un-backgrounded, but **removed from the port list entirely**. Hit this
session: SHADER (the persisted background) disappeared; recovered by pulling its HTML from
`port_versions` and re-creating it.

**Root cause (a chain, confirmed against the DB):**
1. `fetchPortHtml(udid)` reads **only** `port_panels`: `SELECT html FROM port_panels WHERE udid=?`
   (`DatabaseService.swift:1641`).
2. Setting a port as background **closes its tile**, which calls `unpersistPanel` →
   `DELETE FROM port_panels` (`PortWindowManager.swift:296-299`); `port_versions` rows are kept.
   (Confirmed: SHADER had **0** rows in `port_panels`, **17** in `port_versions`.)
3. So a backgrounded port has no panel row → `fetchPortHtml` returns nil → `resolveBackgroundHtml`
   (live-panel → `fetchPortHtml`, `ShellState.swift:86`) returns nil → `restoreBackgroundPort`
   (`ShellView.swift:231`) silently gives up. With no panel row it also isn't restored as a panel, so
   it's *gone*.

**Root fix (not the symptom):**
- **Stop deleting the panel when a port becomes background.** `PersistedPortPanel` already has an
  `isBackground` field and `restoreFromDB` already honors it (`:215`). Set-as-background should
  **persist the panel with `isBackground=true`**, not close+delete it. Then it restores like any panel
  and the background slot re-adopts it by id — no fragile HTML re-resolution.
- **Defense-in-depth:** `fetchPortHtml` should fall back to the latest version when the panel row is
  absent — `... WHERE udid=?` → if nil → `SELECT html FROM port_versions WHERE portUdid=? ORDER BY
  version DESC LIMIT 1`. Also fixes `port.getHtml` returning `not_found` for panel-less ports.
- **Ordering:** ensure `restoreBackgroundPort` runs after `restoreFromDB` so the live panel is found.

**Test:** set-as-background then assert the panel still persists (survives a restore round-trip) and the
background slot re-adopts it. `fetchPortHtml` returns the latest version when no panel row exists.

**Relationship:** both bugs are the same disease — **restore assumes an operation succeeded (webview
loaded / panel persisted) and never verifies or recovers.** Neither is caused by the API-unification
work (both predate it: the restore path and background-as-port v1 are untouched by it); the rebuilds
just forced the restarts that surfaced them. Also connects to the parked "`port_versions` never evicts"
item — the version store is what made recovery possible here.

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

## TODO: launch claude in ANY terminal → auto-create a CLI companion (2026-07-17)

**GM: "when i create a terminal and i launch claude in it, we should create a cli companion — we're
in the injection path."** Correct, and the asset is already there.

**Today:** a CLI companion exists only when you *explicitly spawn a command companion* — the startup
command is `claude`/`gemini`, and `GhosttyTerminalController.isHooksCapable(startupCommand)` detects
it at spawn (`AppState.swift:2495`). If you instead open a plain `bash` terminal port and *type*
`claude`, nothing registers it: it's just a shell running claude, not a member of the space's crew —
no name, no @mention, no turn signals, invisible to routing.

**The asset:** Port42 injects the shim (`ZDOTDIR`) + hooks into **every** terminal, not just
companion ones (`TerminalHooksService`). So claude launched interactively inside a plain terminal
STILL inherits Port42's env, and its Stop hook (`port42-claude-shim notify turnComplete`) can fire.
**We're already in the path — we just don't act on it.**

**The feature:** detect a hooks-capable CLI (`claude`/`gemini`/`codex`) starting in any terminal port
and **auto-register a CLI companion bound to that terminal** — it joins the space crew, gets a name,
becomes @mentionable, and its turns surface (`turnComplete` → member-strip status). This is the GTM
wedge automated: "your agent already lives in a terminal; give it a room" becomes automatic — launch
claude, it's a room member.

**Design questions:**
- **Detection signal:** the shim emits a "claude started" event (cleanest — the shim already runs at
  launch), OR the first `turnComplete` from an unregistered terminal registers it, OR sniff the PTY /
  process. Prefer the shim emitting an explicit launch event: we own the shim.
- **Naming:** auto-name (`claude`, or `claude-2` on collision) vs prompt. Lean auto with a rename
  affordance. Whitespace-in-names rule applies (slugify).
- **Dedup + lifecycle:** don't double-register; and the companion should **end when claude exits or
  the terminal closes** — ties to exhaustive teardown (close() releases everything the port acquired)
  and per-(companion, space) session ids below.
- **Provenance:** a companion born this way is bound to a specific terminal port; killing the port
  ends the companion, and vice versa.

**Relationship:** directly serves the GTM beachhead (`gtm-engineering-teams.md`); pairs with the
per-(companion,space) session-id item below (an auto-registered companion needs a stable session id
too) and the teardown class.

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

## ~~TODO: port.exec async/object marshalling~~ — DONE 2026-07-17

**Fixed.** `PortExecJS.run` swaps `evaluateJavaScript` → `callAsyncJavaScript` (async body,
return-to-yield, `.page` content world), auto-awaits a returned promise, wraps a bare expression as
`return (expr)`, and serializes with `.fragmentsAllowed`; a JS exception/reject → `{error}`, undefined
→ "OK (no return value)". Both `port.exec` sites (`PortBridge`, `ToolExecutor`) route through it. Unit
test on the wrap logic; verified live against the gateway — `port42.ports.list()` (bare, used to be
"unsupported type") now yields the array, a plain object marshals as JSON, `throw` → error, multi-
statement bodies with `return` work. Original write-up kept below.

**Confirmed live this session** while verifying the bridge from inside a port: `port.exec` running
`port42.ports.list()` returned *"unsupported type"* (it handed back the Promise), and a top-level
`await`/`return` form threw *"A JavaScript exception occurred"*. Worked around by stashing the result
to a `window` global and reading it in a second call — the workaround is the tell that the primitive
is broken.

**Root cause:** `port.exec` uses `evaluateJavaScript`, which (a) does **not await promises** (so any
`port42.*` call, which returns a Promise, comes back unresolved) and (b) hands objects back as
`NSDictionary`/`NSArray` that the result serializer rejects (*"unsupported type"*).

**Fix:** swap to **`callAsyncJavaScript`** — it runs the JS as an async function body (so `await` and
`return` work), and pass the **same `contentWorld`** where `port42.*` is injected (else the bridge is
invisible to the exec'd code). Then **`JSONSerialization`** the result with `.fragmentsAllowed`, and
catch non-serializable → `{error}`.

**Edge cases to cover:** a thrown exception / rejected promise → `{error: message}`; `undefined` →
`null`; a `timeout` option (long-running JS); `args` passed into the async body (callAsyncJavaScript
takes an arguments dict). **Acceptance (4):** (1) `return await port42.ports.list()` yields the array
directly; (2) returning a plain object yields JSON, not "unsupported type"; (3) a `throw` yields
`{error}`, not a bare failure; (4) `undefined`/no-return yields `null`.

**Note:** `port.exec` is a **live-only method still on the old path** in the API-unification (not yet
extracted). Do this fix in the old `PortBridge`/`ToolExecutor` `port.exec` now, OR fold it in when
`port.exec` is extracted during the Phase-2 live pass. It reuses the `BridgeValue` serializer (fragments
+ `{error}` on failure) either way.

---

## TODO: storage scope — one shared namespace (PARTLY DONE via the unification, 2026-07-17)

**Original root cause:** the gateway's `storage_*` and a webview's `port42.storage` were **two
non-shared stores** — the gateway used `scope:"tool"` + `creatorId: currentUser`, the webview used
`scope: spaceId` + `creatorId: createdBy` — so a pipeline **written from a port read as untouched from
the gateway** (the `scope.probe` / `review.state` proofs).

**Status — the mechanism half is DONE.** The API-unification storage batch collapsed both into **one
implementation and one scope model**: every surface (gateway / port JS / companion) now routes through
the registry `storage.*` body → the same `db.setPortStorage`, keyed on
`(scope = space|__global__, creator = principal.id | __shared__)`. The `"tool"`-scope fork is gone.
See `plan-api-unification.md` (Phase 1 batch 2, Phase 2).

**What's left — the keying decision.** The unified body keys on the **caller's principal id**, and a
port's principal id ≠ its creator companion's id ≠ a gateway sender id. So cross-surface *sharing* (the
"gateway reads a port's pipeline" behavior GM wants) only lands once the **principal** is settled
(Phase 3): specifically, whether a port's principal resolves to its **creator companion**, giving the
`(companionId, spaceId)` keying this item asks for. Until then storage is unified in mechanism but
still partitioned per-caller.

**Fix (the remainder):** resolve a port's principal to `(companionId, spaceId)` in Phase 3 so a
companion, its ports, and its gateway session share one namespace + the `global` scope option.
Mirror-not-replace if any code needs a synchronous `localStorage` view. **#5 above makes #6's pain
*readable* (you can finally exec a probe and see the value), but #6 is the real fix.**

**Update 2026-07-19 — the companion half landed (Phase 3 item C).** A companion-created port's
principal now resolves to its creator (`PortBridge.portPrincipal`, id = `createdBy ?? messageId`),
so a companion and its ports share one storage namespace per space — gated by
`BridgePrincipalTests/portAndCompanionShareStorage`. Still open: the gateway session is a
DIFFERENT principal (`local-http` / the peer id), so companion-to-gateway sharing needs either the
`shared` opt-in or a future principal-linking decision. Scope shrunk, not closed.

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

## TODO: publish a port as a website (2026-07-17)

**GM:** publish any port as a website easily. Two routes named, and the pieces for the second already
exist: plug in an external host (Vercel/Netlify), **or serve it on the gateway through the reverse
proxy, the way invite sharing already works.**

**A port is already a publishable artifact.** The CSP blocks external loads (`default-src 'none'`,
todo item "CDN loads are silently blocked"), so every port's HTML is **self-contained** with assets
inlined. Its current HTML is one `port.getHtml` away, and versions are retained. So "publish" is
mostly a serving problem, not a packaging one.

**Route 1 (gateway reverse-proxy, the low-lift one, reuses the invite path):**
- The gateway **already serves full HTML pages over the public tunnel**: `/invite` returns a themed
  page with `Content-Type: text/html` (`gateway/main.go:88-152`), reachable at `TunnelService.publicURL`
  (the ngrok origin). Adding `GET /p/<id>` that returns a port's HTML is directly analogous.
- The gateway is a separate Go process and does not hold port HTML (it lives in the app's SQLite). It
  already forwards `/call` RPCs to the app over WS, so `/p/<id>` fetches the HTML via the existing
  `port.getHtml` bridge, wraps it in the port document shell (the CSP + theme wrapper, currently
  **duplicated** in `PortView.swift:245` and `PortWindowManager.swift:947` — unify that as part of
  this, one wrapper), and serves it.
- **Live vs snapshot:** proxying `getHtml` on each request is **live** (the URL always shows the
  current port). A published snapshot (copy at publish time, its own version) is the durable
  alternative. Decide per-publish; live is the natural default for a machine that is online.
- **Cost:** it is *your machine* serving the page, so it is up only while the app + tunnel are up.
  Fine for share-a-thing, not for a durable site. That is what Route 2 is for.

**Route 2 (external static host, durable, off your machine):** push the self-contained HTML to
Vercel/Netlify/Cloudflare Pages via their deploy API, get a URL that lives without Port42 running.
Snapshot by nature; re-push to update. Needs a host integration + a stored deploy token (fits the
existing secrets/`rest.call` model).

**The hard part is the same principal question as everywhere else.** A published port's `port42.*`
bridge calls **do not work off-device** (no gateway on the viewer's side), and if they *did* route
back, they would run with **the author's grants** — the credential-laundering risk the MCP item
(`MCP as a port capability`) already flags, and Anthropic's own reason for forbidding public sharing
of an MCP-declaring page. **Default: a published port is static/visual, zero bridge authority.** Any
future "interactive published port" must execute as the **viewer's** principal, never the author's,
which is exactly the [principal work in #2] (API/tool-use unification). Do not enable bridge-on-
published before that lands.

**Shape:** a `port.publish(id) -> url` / `port.unpublish(id)` verb (the new subscriber on the port's
stream, `membrane/bus-architecture.md`: "rendering is just one subscriber" — a website is another),
a published-state flag + URL surfaced in the port chrome, and a route (`/p/<id>`) or a host push
behind it. Sequence Route 1 first (near-free, rides the invite/tunnel machinery); Route 2 and any
interactivity ride later work. Relates to "a port has a URL" (named in the MCP item), port teleport,
and the native-ports/replication north star (a public HTTP renderer is a read-only subscriber).

---

## TODO: filesystem as a native system service — a permissioned local file route (2026-07-17)

**GM:** make the filesystem a native system service, not a base64 pipe. A **permissioned local gateway
route** (`http://127.0.0.1/files/<path>`), scoped to an **allowed root + a per-file token**, so any
port loads a local asset directly: `<img src="http://127.0.0.1:PORT/files/<token>/photo.jpg">`.
Cleaner than base64, and it **generalizes to every asset** (images, audio, video, fonts, downloads),
not just the one-off `fs.read` → base64 → data-URI dance.

**Why base64 is the wrong primitive:** today a port that wants to show a local image reads it via
`fs.read({encoding:"base64"})` and inlines a `data:` URI. That is heavy (33% size blow-up, whole file
in JS memory, no streaming, no range requests), and it is the *only* option because the port CSP is
`img-src data:` (no file/http origins). A URL the browser fetches natively is streamable, cacheable,
rangeable, and works for `<img>`/`<audio>`/`<video>`/`<link>` uniformly.

**Why it is native/eng, not gateway-only:** the **route** lives on the local gateway, but the
**permission decision cannot**. Which paths a caller may read is the app's FileBridge picked-path /
TCC model (`allowedPaths`), and that authority lives in the Swift app, not the Go gateway. So the app
must vet the path, mint a scoped token, and the gateway serves bytes only for a valid (token, path)
pair under the allowed root. Same shape as the invite/`publish-a-port` routes (gateway serves, app
authorizes), one more surface.

**Design sketch:**
- **Allowed root + per-file (or per-scope) token.** The app grants "this port may serve files under
  <root>" and mints a token; the route rejects anything outside the root or without a live token.
  Token is revocable and scoped to the granting port/principal (this is the **principal** work again:
  a file grant is per-(principal, path-scope), not global).
- **CSP must allow it.** The port document CSP has to add the route's origin to `img-src`/`media-src`/
  `font-src` (e.g. `img-src data: http://127.0.0.1:PORT`), which is the **one shared wrapper** the
  todo already wants deduped (`PortView.swift:245` / `PortWindowManager.swift:947`). Keep it tight:
  only the loopback files origin, only the asset directives.
- **Path safety:** the same sandbox/traversal rules as the unified `fs.*` (no `..` escape, resolve
  under the allowed root) — reuse that resolver.
- **Lifecycle:** a token dies with the port that holds it (ties to exhaustive teardown); a shared
  port must serve files as the *viewer's* principal, never the author's (same rule as MCP-on-a-shared-
  port).

**Relationship:** revises the `fs.*` picture from the API-unification plan — `fs.read`/base64 stays for
"give me the bytes in JS", but **serving an asset to the DOM becomes a URL, not a data-URI**. Sequence
with the principal work (Phase 3): the per-file token *is* a capability grant. Pairs with
"publish a port as a website" (both are app-authorized gateway routes) and the CSP-dedup /
make-failure-visible items.

---

## TODO: ports scoped to space

Ports should belong to a **space**, not float globally. A port created in space X shows when you're
in space X (and is listed with it), rather than the current global pool. Likely: persist a
port's `spaceId` (already on the panel) as the scoping key for what's shown, switch the visible
port set when the active space changes, and decide cross-space behaviour (does a port stay open
when you leave its space — backgrounded? hidden? follow you?). Pairs with the inline cards
(Step 5b) which are already posted into a specific space.

## TODO: port examples catalog → a live "examples gallery" port (2026-07-18)

**GM:** track the types of things you can do with Port42 — the port-creation prompts — as examples,
because these are what people can try and we need getting-started content. Started as
`docs/port-examples.md` (a tracked catalog: each entry is a real port framed as "try asking for
this" + its type + what you get, seeded from `~/.port42/journal/moments.md` and live sessions).

**End state:** the catalog becomes a **live gallery port** that lists the examples and **spawns any of
them in one click** (`port.create` from a card) — getting-started is itself a port you open, browse, and
tap to materialize the example on your desktop. Pairs with "a different dock view of ports" and the
onboarding/GTM content need. Keep the `.md` as the source until the gallery port exists; append an entry
whenever a new port is built.

---

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

## TODO: recency-sorted ⌘K — switch between recent spaces (2026-07-17) (DONE 2026-07-21)

**GM:** a way to more easily switch between *recent* spaces. Today switching has two axes and both
ignore recency:
- **Positional** — `⌘1…9` indexes straight into `workingSpaces`, which is `Space.order(createdAt.asc)`
  (`DatabaseService.swift:742`, `spaces.filter { !isResting }` at `AppState.swift:1776`). Slot 1 is
  the oldest space you made, forever.
- **Search** — `⌘K` empty-query returns `spaceItems` in that same creation order
  (`QuickSwitcher.swift:186-207`).

Neither surfaces "the space I was just in". The **recency signal already exists**: `selectSpace`
stamps `lastReadDates[space.id] = Date()` on every switch (`AppState.swift:1702`), and `restingSpaces`
already sorts by recency (`restedAt` desc, `AppState.swift:1781`) so the pattern is established.

**The change (smallest fit, chosen over a ⌘Tab overlay or a recents rail):** when `⌘K` opens with an
empty query, sort `spaceItems` by most-recently-used instead of creation order. Typing still fuzzy-
searches exactly as today. One method touched (`QuickSwitcher.filteredItems` empty-query branch), the
overlay and keys unchanged.

**Decisions to make:**
- **MRU source + persistence.** `lastReadDates` is in-memory and cleared on lock/sign-out
  (`AppState.swift:2875`), so the order resets across launches. `lastSelectedSpaceId` is persisted but
  is a single id, not a list. For recency to survive a relaunch, either persist `lastReadDates` to
  UserDefaults, or add a `lastVisitedAt` column on `Space` (append migration, next is **v41**). Lean
  toward a persisted timestamp so the first `⌘K` after launch already reads right.
- **Current space placement.** Put the space you're in now first (natural, matches the preview GM
  picked) or drop it from the list (you're already there). Lean first-with-a-"now"-marker.
- **Interaction with drag-reorder (below).** Recency and manual order are two different axes: `⌘K`
  empty-query = recency; the galaxy grid + `⌘1…9` = manual `sortIndex`. Keep them distinct on purpose.

**RESOLVED 2026-07-21 (backlog 0.6), decisions as leaned:**
- **Sort.** `QuickSwitcher.spaceItems` now orders by `AppState.spacesByRecency` (pure, unit-tested):
  most-recently-visited first, unvisited spaces keep their `createdAt` order as a stable tiebreaker.
  The empty-query and `#` branches read right; typing still fuzzy-searches (now over the MRU order).
- **Persistence.** `lastReadDates` persisted to UserDefaults (chosen over a `Space` column + migration,
  since recency is device-local): `markSpaceRead(_:)` is the one write path (selectSpace, enterSpace,
  peek-surface funnel through it), it saves on every visit, `loadInitialState` restores on launch, and
  sign-out clears it. So the first `⌘K` after a relaunch already reads right. Bonus: unread now reads as
  "since last visit" across restart instead of marking everything unread on a cold start.
- **Current-space placement.** It sorts to the top naturally (it is the most recent visit); no separate
  "now" marker glyph added (kept minimal).
- **Left distinct on purpose:** `⌘1…9` and the galaxy grid still use the manual/creation axis, untouched
  (the drag-reorder `sortIndex` item below owns that axis).

---

## TODO: drag-reorder spaces in the galaxy (2026-07-17)

**GM:** click and re-drag the order of a space in the galaxy. Today the order is creation order and
**immutable** — the galaxy grid renders `ForEach(workingSpaces.enumerated())` in `createdAt.asc`
order (`ShellView.swift:411`), and `⌘1…9` indexes the same array (`jumpToSpace(index:)`). There is
**no manual sort field** on `Space` (`Models/Space.swift` — id/name/type/createdAt/accent/restedAt,
nothing positional).

**The missing thing:** a persistent **`sortIndex`** on `Space` (append migration **v41**, never edit
an existing one). Once it exists it drives ordering everywhere the creation order is used today, so
the reorder is real, not cosmetic:
- `workingSpaces` sorts by `sortIndex` (fallback to `createdAt` for null/legacy rows so pre-migration
  spaces keep a stable order).
- **`⌘1…9` follows the manual order** — dragging a space to the front makes it `⌘1`. This is the
  payoff: the positional shortcuts become *yours*.

**The interaction:** a drag gesture on the galaxy `LazyVGrid` worlds (`ShellView.swift` `world(_:index:)`)
that reorders the cards and writes the new `sortIndex` set. `LazyVGrid` has no built-in reorder, so
either a manual drag (`DragGesture` + hit-test the drop slot + animate) or the `.draggable`/`onMove`
route if it composes with the grid. Persist through `db.saveSpace` / a batch reindex; the grid reads
reactively off `spaces`.

**Watch-outs:**
- **`newSpaceCard` is the last grid item** (`ShellView.swift:414`) — exclude it from the drag targets.
- **The resting shelf is separate** and already recency-sorted (`restedAt` desc); manual `sortIndex`
  is a working-set concept only. A space that rests then wakes should keep its `sortIndex`.
- **Accent-by-position is decoupled already** — accents are assigned at creation and kept for life
  (`Space.accent`, `AppState.swift:1737`), so reordering does not recolor anything. Good; leave it.
- Migration backfill: set `sortIndex` from the current `createdAt` order so day-one ordering is
  identical to today, then let drags diverge it.

**Pairs with** recency-sorted `⌘K` above (the two switching axes) and the shell plan's space rail —
if the rail lands, the same `sortIndex` orders it too.

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

## TODO: MCP as a port capability, with the viewer's own credentials (2026-07-16)

**Trigger:** Anthropic shipped view-time MCP for generated pages. A page calls connectors when it is
opened, using the *viewer's* permissions, so two people open the same generated dashboard and see
their own Stripe rows, their own repos, their own queues. Row-level security for throwaway apps.

**Verified against the runtime contract (0.1.12), not the write-ups:**
- A page declares `capabilities: {mcp: {servers: [{server, tools}]}}` and calls `window.claude.mcp`.
- Calls run **with the viewer's credentials and never expose tokens**. The per-viewer property is real.
- Two arms, and the shape is instructive: a section *displaying* data registers
  `watchTool(server, tool, input, handler)` (replays cache, refreshes when stale, polls only via
  `refetchInterval`); an *action* calls `callTool` once.
- **Two constraints the hype drops:** (1) **only claude.ai connectors are valid**; locally-configured
  MCP servers are explicitly not. (2) **A page declaring MCP cannot be shared publicly.**

**The read: it validates the thesis and demonstrates the wall in the same feature.** A generated
surface calling tools with the viewer's permissions *is* the harness, and it is exactly our "one
bridge, permission-gated per asker". The biggest lab in the world independently building it is the
strongest confirmation the model is right. And it works only with their connector registry, on their
site, against their model. A harness that fits one horse (see `one-pager-2026-07.md`).

**What we have:** `port42-mcp.js` is Port42 as an MCP *server* (exposes the bridge to Claude Code,
Gemini CLI, any MCP tool over the gateway WS). It ships in the bundle and **nothing wires it**; you
run it by hand. There is **no MCP client anywhere in the app**: a port or companion cannot consume an
external MCP server today. The direction that matters is the one that doesn't exist.

**Build:**
1. **MCP client as a bridge capability.** `port42.mcp.callTool(server, tool, input)` /
   `watchTool(...)` / `listTools()`, so a PORT can call the user's MCP servers, and a companion
   reaches the same methods as tools (the unified-API invariant: one base, thin calling paths).
2. **Per-server permission, not a blanket `.mcp` bucket.** "This port may call Stripe" is a different
   sentence from "this port may call MCP". The per-asker permission model already fits; this is a new
   scope, not a new mechanism.
3. **Local servers are the differentiator, not a gap.** Port42 runs on your machine. The local MCP
   servers claude.ai *cannot* reach are precisely what a port should be able to call. Same for
   model-agnostic: MCP is a wire, not a vendor, so a Gemini companion or a local model reaches the
   same servers.
4. **`watchTool` is the right shape and worth copying.** Display = watch (cache replay, refresh when
   stale, poll only on an explicit interval); action = call once. That is Subscribe/Notify from
   `membrane/bus-architecture.md`: a port displaying data is a subscriber to a stream. Someone else
   arrived at the same decomposition independently, which is evidence for the model.
5. **The compounding move, and its danger.** MCP + "a port has a URL" + per-viewer identity gives the
   same "two people, same dashboard, different rows" property, except the port is yours, the servers
   can be local, and the page isn't trapped in a tab you don't own. **Note that Anthropic forbids
   public sharing of an MCP-declaring page. That restriction is correct and we need it harder.** A
   shared port that can call connectors is either the best feature in the product or a
   credential-laundering machine, decided entirely by *whose* credentials run the call. **Settle the
   identity model before the transport:** a shared port must execute MCP calls as the VIEWER, never
   as the author, and never as "whoever opened it, using the author's grant".

**Where it lives: the gateway (GM, 2026-07-16).** The MCP client belongs in the Go gateway, not the
Swift app. The gateway is where every caller already converges (port JS, companion tool-use, external
agents over `/call` and `/ws`), it already holds long-lived connections, and Go has the SDK. One MCP
client serving all callers *is* the unified-API principle, enforced by construction rather than
asserted. Putting it in the app would mint a fifth calling path immediately.

**But the permission decision cannot move there yet, and that is the real finding.** GM: *"they could
have diff permissions so that needs to be considered in the p42 protocol layer."* Correct, and it is
worse than it looks: **the protocol already has an authenticated principal and throws it away.**
- `gateway.go` runs a real handshake: challenge nonce, `identify` with `sender_id`, auth, and
  `env.PeerID = peer.ID // authenticated peer identity`.
- `AppState.onCallReceived` receives that `senderId` and immediately flattens it:
  `RemoteToolExecutor(senderId:, senderName: "remote-\(senderId.prefix(8))")` →
  `ToolExecutor(spaceId: nil, createdBy: senderName)`.
- That display string becomes the permission key (`portPerms.<label>.global`).

So permissions are keyed on a **label**, not a principal. The gate asks "what is it called" when it
should ask "who is this". Same root as the `spaceId: nil` bug found the same night.

**The missing concept is a PRINCIPAL in the protocol layer**, and four separate problems are all it:

| Question | The identity it needs |
|---|---|
| Which MCP servers may this caller reach? | the caller's principal |
| Whose credentials run a *shared* port's MCP call? | the **viewer's** principal, never the author's |
| Which port on which instance does this address reach? | the peer's principal (cross-instance address) |
| Who is asking for the microphone right now? | the asker's principal |

`PermissionRequester` (added 2026-07-16 with the permission coordinator) is an accidental first draft
of this: `id` / `displayName` / `spaceId` / `createdBy`. It is a label in an identity's clothes.
Promote it, back it with the gateway's authenticated `peer.ID`, and carry it end to end. Then a
permission is a statement about a principal, an MCP grant is per-(principal, server), and a shared
port executing as the viewer is the default rather than a special case.

**Sequence:** after the API/tool-use unification. MCP is a fourth calling path; do not bolt it beside
three inconsistent ones. The principal work is arguably *part of* the unification, not after it: one
base implementation needs one answer to "who is calling". Related: "adopt agent-comms standards (ACP
+ friends)" above (the parent item), "a port has a URL", "port teleport", and
`membrane/bus-architecture.md` (cross-instance address + per-element right-of-way, which are the same
question again).

---

## NORTH STAR (umbrella): the Port42 protocol — port addressing + P2P ports + shared-URL join (2026-07-22, GM)

The pieces below are scattered across this doc as separate TODOs. GM's framing pulls them under one
program: **a Port42 protocol** that makes a port a first-class, addressable, shareable network object.
Three goals, in dependency order.

**1. Systematic local port addressing.** Every port gets a stable, systematic address so any surface
(JS, gateway, another port, an external viewer) can reference and route to a specific port instead of
passing UDIDs by hand. Today a port is reachable only by UDID/title through `port.*` bridge calls;
there is no address SCHEME. Decide the scheme (candidate: `port://<space>/<id>` or a flat
`port://<id>`), make it resolve locally first (one instance, many ports), and route `port.*` and the
stream bus through it. This is the prerequisite for everything below: you cannot share or peer to a
port you cannot name. Related: the principal work above answers "which port on which instance does this
address reach" (cross-instance address needs the peer's principal).

**2. P2P ports.** A port on one instance connects peer-to-peer to a port (or viewer) on another. Two
transports are already named in this doc: the **gateway relay** (the WS hub + reverse-proxy that
invite sharing already rides, `gateway/main.go`) as the low-lift route, and **true P2P
(libp2p/Iroh)** for a direct link off the relay (`membrane/bus-architecture.md`, the state-replication
notes below). The addressing scheme (goal 1) plus the authenticated `peer.ID` (the principal work) are
the substrate. Sequence: relay first (reuses the tunnel/invite machinery), direct P2P later.

**3. Port sharing — a shared URL someone else opens to JOIN your live port (multiplayer).** GM: "shared
url with someone else and they join your port." This is the user-facing verb over goals 1-2: send a URL,
the other person opens it and lands in your LIVE port, co-present. **Precedent already shipping:** the
SHARED SYNTH port (fundemos space) is a same-instance multiplayer port today (you plus AI players
co-editing one grid). The new axis is CROSS-peer join over a URL. Mechanism is the **state-replication
protocol** already sketched here: `getHtml` = snapshot, `push` = state delta, `patch` = targeted
mutation (see the replication notes near the bottom of this doc + `membrane/bus-architecture.md`). A
join is: resolve the address (1) → open a peer channel (2) → subscribe to the port's replicated state
(rendering is just one more subscriber). "Publish a port as a website" (a read-only HTTP subscriber) is
the degenerate one-way case of this; full join is two-way.

**Not only push/patch — serving the PORT itself to a peer Port42 instance (GM, 2026-07-22).** Beyond
syncing state deltas between two running copies, the protocol should be able to serve the port itself
(its self-contained document + identity + live surface) to a peer's Port42, so the peer instance
instantiates and HOSTS it, not just an HTTP viewer. Open question GM flagged: **is "serve the port to a
peer instance" the same primitive as `getHtml` (snapshot) + `push`/`patch` (live deltas), or a distinct
transfer?** They may collapse (serve = the initial `getHtml` snapshot, then the peer subscribes to
`push`/`patch`), or "serve to a peer instance" may be its own verb closer to **port teleport** (the port
materializes on the peer, addressable there). To work out. This is the difference between a peer
*viewing* your port and a peer *running* your port.

**Building blocks that already exist (validation: partial, in-repo):**
- Authenticated peer identity at the wire: `gateway.go` handshake + `env.PeerID` (thrown away today at
  `AppState.onCallReceived`; the principal item above is exactly promoting it).
- Gateway serves full HTML pages over the public tunnel (`/invite`); a `GET /p/<id>` is directly
  analogous (the publish-a-port item).
- Self-contained port HTML (CSP inlines assets), version store retains every state — so a port is
  already a serializable, replayable artifact.
- Same-instance multiplayer precedent: SHARED SYNTH.

**Open design decisions (unvalidated):**
- Address scheme + resolver (`port://` shape; local resolve vs cross-instance).
- Transport: gateway-relay vs true P2P (libp2p/Iroh); which first.
- Serve-the-port vs replicate-state: is transmitting the port itself to a peer instance (the peer
  instantiates + hosts it) the same primitive as `getHtml` snapshot + `push`/`patch` deltas, or a
  distinct transfer near port teleport? Peer VIEWING your port vs peer RUNNING your port. (GM: to work out.)
- Join semantics: shared replicated state (real co-edit) vs read-only view; conflict handling on
  concurrent `patch`.
- Identity/permissions per joiner: a joiner executes as the **viewer's** principal, never the host's
  (the credential-laundering guard from the MCP / publish items). Bridge authority for a joined port is
  gated on the principal work.
- Live vs snapshot on share (the publish item's live-vs-snapshot decision generalizes here).

**Sequence.** Gated on the **principal work** (identity is the substrate for cross-peer anything). Then:
address scheme → gateway-relay join (reuses invite/tunnel) → state-replication co-edit → true P2P
transport. Subsumes/organizes the scattered items: "a port has a URL", "port teleport", "publish a port
as a website", "MCP as a port capability", "adopt agent-comms standards", and the
`membrane/bus-architecture.md` cross-instance-address + replication work.

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

**Sharpening (GM, 2026-07-20): `ports-context.txt` should carry NO API/tool specifics at all — those
belong ONLY to the generated reference (`llms.txt`/`help`), which is complete and drift-gated.** The
prose today still names methods (e.g. `port42.port.exec(id, js)`), which duplicates the generated
source and is exactly the drift risk — two places to update, one of them ungated. The split should be
clean: **the generated reference owns "what methods exist and their shapes"; `ports-context` owns the
CONCEPTUAL/teaching layer** (what a port IS, ES-module discipline, read-before-patch, the design
system, the failure-visibility rules). That conceptual layer is precisely what a **skill** packages —
so `ports-context` stripped of API specifics IS the `port42-ports` skill's body, and the reference is a
resource the skill points at rather than restates. Do this as part of the migration below: remove
method-specific prose from `ports-context`, point at the generated reference for the API surface, and
package the remaining concepts as the skill.

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

## NORTH STAR: the chrome is ports too — the whole shell is made of what you make (2026-07-17)

**GM: "set your port as your background… that is the ultimate goal. that the sidebar, the app bar,
the entire space is just ports you created/customized."**

The desktop is already live ports. This extends the thesis to its endpoint: **the shell's own chrome —
the background, the top app bar, the dock, the space rail/sidebar — is ports too.** Not native
SwiftUI that hosts ports, but ports all the way down. Your environment stops being an app you use and
becomes a thing you author, in the same grammar as everything inside it.

**Why it's the real endpoint, not a gimmick:**
- **It completes the primitive.** If the chrome itself can be a port, the port is proven universal —
  there is no privileged "app UI" category left. Anything a native panel does, a port can do. That is
  the strongest possible statement of the bus thesis (`membrane/bus-architecture.md`): everything is
  an addressable actor, including the shell's own faculties.
- **It's the ultimate dogfood + the ultimate customization in one.** The app is built from its own
  primitive, AND the user reshapes their whole environment with the same tools they build ports with.
  Your dock is a port you wrote. Your background is a port you set. Your sidebar is yours.
- **It subsumes half the backlog.** "Richer space rows", "a different dock view", ambient activity —
  all become *a port you customize* rather than native features to spec. Pluggable-primitives
  (user-facing primitives are Port42-owned) lands here: the grammar IS the chrome.

**The wedge (shippable, safe): background-as-port first.** Let a port be set as the space background.
Purely visual, least-privileged (no bridge powers needed), and it's the "set your port as your
background" GM named. `ShellBackground` already exists as a layer; swap it for a rendered port
surface. This is the thin end and it de-risks everything above it.

**v1 SHIPPED 2026-07-17** (`ShellBackgroundPort`, `setBackgroundPort`, `port.manage(id,
"background"/"unbackground")`, a "…" overflow menu in the port chrome). Works via curl; the chrome
menu didn't take (likely the header drag gesture eats the Menu interaction — fixable). But live use
surfaced a **v2 redesign that removes the special-casing (GM):**
- **The background is ALWAYS a port — there is no native "regular background".** Today Layer 0 is a
  native Canvas dreamscape OR a port; that split is the problem. Instead: the dreamscape becomes a
  stock "ambient" **port** (the default), and "set as background" just swaps which port occupies the
  Layer-0 slot. "Go back to a regular background" = re-select the default ambient port. One code path,
  no native/port fork.
- **The background port appears in your space as a port** — focus it, edit it, swap it, pull it up.
  It's not hidden chrome; it's a normal port assigned the background slot. This is chrome-is-ports made
  literal for the background.
- **Interactive/AI is a CHOICE, not forced off.** GM: "if i choose an ai-enabled port to be the
  background then fuck yeah i might want it to be AI." Drop the hard `allowsHitTesting(false)`; make
  it a per-background mode (ambient/non-interactive vs live/interactive). An interactive Layer-0 port
  only receives clicks where nothing on the desktop covers it — so it composes, but needs care with
  the desktop's own click-to-deselect. The token/idle work already done is what lets an AI background
  be affordable.
- **v1 makes a fresh instance from HTML** (a webview lives in one place). v2 with background-always-a-
  port dissolves this: the background slot hosts a real port, so "move the live port down" is natural.
- **Fix the chrome menu** (drag-gesture conflict) as part of v2, since the menu is where set/swap/
  clear lives.

**Then, in order of privilege (which is the hard part):**
- **Background** (no powers) → **dock** (needs space-switch + port-launch) → **space rail** (needs the
  space list + selection) → **top app bar** (needs gateway/tunnel/settings state).
- Each step up needs MORE bridge authority, which is exactly the **principal/permission** work: a
  background port must never have the dock's powers. Chrome ports are the case that forces
  capability-scoped ports (a port granted "may switch spaces" is a different principal from a shader).
  So this north star and the API-unification/principal work are the same spine.

**The irreducible kernel (the honest limit):** something native must host the first port and run the
bus — you can't render a port without a port host. So there's a **thin native kernel** (port host +
bus + the bridge), and *everything above it* is ports. The goal isn't "no native code"; it's "no
native *chrome*". Define that line deliberately.

**Load-bearing prerequisite — the work just done matters here.** A chrome port is *always visible and
never closed*, so it must never burn CPU or tokens: the presentation-state, eviction, and the
parked/AI-pause fixes (2026-07-17) are what make an always-on port affordable. A dock that burns a
core is not a dock. Idle-when-static is non-negotiable for chrome ports.

**Relationship:** the natural top of `plan-port42-shell.md` (modes, space rail, dock) — that plan
builds the chrome; this says the chrome should eventually BE ports. Sequence background-as-port as a
near-term proof; the rest rides the principal work.

---

## TODO: multi-display support — place spaces on multiple monitors (2026-07-20, GM)

**Want:** put different spaces on different monitors — space A on monitor 1, space B on monitor 2,
both live at once — so a multi-monitor setup is a multi-space workspace, not one space at a time.

**UX vision (GM 2026-07-20):** the monitors show up in **galaxy view** as targets, and you
**drag-and-drop a space card onto the monitor** you want it on. Direct, physical — the galaxy already
renders spaces as cards, so adding the displays as drop zones is the natural surface.

**Feasibility read (2026-07-20): NOT easy — the UX is the easy 20%, the mechanism under it is the hard
80%.**
- **Easy (the drag-drop UX):** enumerate monitors (have it — `NSScreen.screens` / `screen.displays`),
  render them as galaxy drop targets (moderate SwiftUI), drag a space card onto one (standard drag-drop).
- **Hard (what makes the drop DO something):**
  1. **One shell window per monitor.** Today there is exactly one window; `ShellMode.applyShellWindow`
     pins it to `window.screen ?? NSScreen.main`. A second monitor needs a second borderless-takeover
     window rendering another space — the dedicated `ShellWindow` the shell plan calls "the graduation,"
     anticipated but not built.
  2. **`currentSpace` becomes per-display.** It is a single global today (the whole shell reads
     `AppState.currentSpace`); multi-display shifts the model to "the space on each display" — a
     display→space map, or one `ShellState` per window.
  3. **THE load-bearing risk — port re-parenting across windows without blanking.** A port's webview is
     mounted once in a window's view hierarchy (the mount-once contract that killed the blanking bug).
     Moving a space to another monitor re-parents its ports into the other window. This is the same
     WKWebView re-parent crux the shell plan already **spike-proved** (`prototypes/wkspike`), so there
     is prior art — but it is where this feature lives or dies.

**Recommended path — prove the mechanism before the UX.** Build the smallest thing that renders a space
on a second monitor: a command ("send this space to display 2") that opens a takeover window there with
`currentSpace` per-display, and confirm its ports re-parent cleanly (no blank — point `PortRenderProbe`
at it). That de-risks the multi-window + re-parent core. The galaxy drag-drop is then the UX layer on
top. Building the drag-drop first = a gesture that can't actually move a space yet.

**Current state:** the shell is a **single window on one screen**. Geometry assumes `NSScreen.main`
(e.g. `PortWindowManager` sizes tiles off `NSScreen.main?.visibleFrame`), and the takeover
(`presentationOptions = [.hideDock,.hideMenuBar]` + borderless fullscreen) grabs that one screen.
Port positions (`x/y`) are screen-relative with no notion of *which* screen. The enumeration half
already exists: `screen.displays` / `NSScreen.screens` returns every display's bounds (and the
port-positioning-gap note already flags missing position/display-resolution APIs).

**Design questions to settle before building:**
- **Mapping:** a space is *assigned* to a display (persisted `displayId`/index on `Space`?), or the
  active space fills the focused display while others park on the rest? Lean: a space can be pinned
  to a display, with a sensible default when a display is added/removed.
- **Window model:** one shell window per screen (each a fullscreen takeover on its display), each
  rendering its own space + chrome, sharing the one `AppState`/registry. The port-units contract
  (mount-once) has to span screens without re-mounting on move.
- **Chrome placement:** where do the app bar / dock / space rail live with N screens — per-screen, or
  one primary? Ties into chrome-is-ports.
- **Port geometry across screens:** `x/y` needs a display anchor so a port restores onto the right
  monitor; positions must survive a display being unplugged (clamp back on-screen — related to the
  off-screen-port rescue case in the positioning-gap note).
- **Hotplug:** displays added/removed at runtime (`NSApplication.didChangeScreenParametersNotification`)
  must reflow, not strand a space on a gone monitor.

**Relationship:** a natural extension of the GUI-shell plan below (the shell already owns the screen;
this makes it own *every* screen) and the port-positioning gap (per-display coordinates). Sequence
after the single-screen shell is solid; the enumeration API (`screen.displays`) is the one piece
already in hand.

## TODO: GUI shell — replace the desktop, not the OS (→ `docs/plan-port42-shell.md`) — CORE SHIPPED 2026-07-20

**The headline is done: Port42 IS the desktop.** The shell is the app surface (classic ContentView
retired 2026-07-14), and the **fullscreen takeover** is shipped in `ShellMode.swift` exactly as
planned — `styleMask = [.borderless, .fullSizeContentView]`, `NSApp.presentationOptions =
[.hideDock, .hideMenuBar]`, full-display frame, via `applyShellWindow`. It's an **opt-in toggle**
(`ShellMode.takeoverKey` / the `fullscreenTakeover` setting, default off), so "boots into a desktop of
live ports with no Dock/menu bar" is real today. The ambient surface, the zoom spine
(galaxy ↔ space ↔ focus), port units, peeks, adoption, and ⌘K are all in.

**Still open from the plan (the enhancements, not the core):**
- **Modes (meta-spaces)** — a whole-shell state with its own accent / dock apps / set of spaces /
  default layout. Not built; today `ShellMode` is only the *window presentation* mode
  (takeover vs windowed), not the meta-space concept. This is what would subsume "ports scoped to
  space" + "a different dock view" at the shell level.
- **Boot-into-Port42 tiers beyond the toggle** — launch-at-login (Tier 1) and MDM Autonomous Single
  App Mode (Tier 2, kiosk-grade). The takeover toggle exists; auto-boot / lockdown do not.
- **Multi-display** — see the item above (own every screen, not just one).

Historical write-up below.

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

## BUG: closing a port leaks its mic / speech recognition — forever, unstoppably (2026-07-16) (DONE 2026-07-21)

**Found by sampling a 90%-CPU app at 3am.** The hot stacks were not webviews and not SwiftUI:
```
827  DispatchQueue: SFLocalSpeechRecognitionClient  (serial)
760  DispatchQueue: com.apple.Speech.Task.Internal  (serial)
     + AUScheduledParameterRefresher, caulk::*, coremedia.imagequeue.*
```
A voice port had called `audio.capture({transcribe:true})`. The port was **closed hours earlier**.
The **on-device speech recogniser was still running** — an ML model chewing a core, continuously,
with no port left to show for it. This is the user's "I closed it and it's still going".

**Why it's unstoppable (the real bug):**
- `audio.capture` starts an **app-level** resource (`AudioBridge`: AVAudioEngine + `SFSpeechRecognizer`).
- `audio.stopCapture` is a **bridge method — callable only from the port's own JS**, and is *not*
  exposed on the gateway ("Unknown tool: audio_stopCapture").
- `PortWindowManager.close()` destroys the webview → **the only thing that could ever stop it is gone.**
- Net: **the mic + speech recognition run until the app quits.** No UI, no API, no recovery.

**It's a class, not a one-off.** `close()` currently releases: webview ✓, terminal controller ✓,
hoisted terminal surface ✓, live-cwd file ✓ — and **nothing else the port acquired**. Same shape
almost certainly applies to `camera.stream` / `screen.stream` (both push frames and have `stop*`
methods only reachable from the dead port's JS).

**Fix:**
1. **Port lifecycle teardown must be exhaustive.** `close()` releases *everything the port acquired* —
   audio capture, camera stream, screen stream, timers. Track acquisitions per-`PortBridge` and
   release them in one place, so a new capability can't be added without a teardown.
2. **Never let a resource be stoppable only from the thing that dies.** Any `start` reachable from a
   port needs a `stop` reachable from the *app* (and ideally the gateway), keyed by port id.
3. **Make it visible** — a live mic/camera/screen capture should show an indicator + a kill switch
   (this is also the "always-visible indicator + stop" the computer-use north star already demands).
4. **Test:** open a mic port, close it, assert the recogniser is down (sample/threads or an
   AudioBridge state assert). This is Tier-A-able at the AudioBridge level.

**Severity: high.** Silent, permanent, burns a core, and it's a *privacy* issue as much as a perf one
— **the microphone stays live after the thing that asked for it is gone.**

**RESOLVED 2026-07-21 (commits d009839..8cc4acc), verified live.** Two root causes, both fixed. Spec:
`docs/plan-exhaustive-port-teardown.md`.
- **Root cause A, the retain cycle.** `PortBridge.attach` registered the bridge as the `"port42"`
  `WKScriptMessageHandler`, which `WKUserContentController` retains strongly, and nothing removed it. So
  after `close()` the bridge stayed pinned, its `deinit` never fired, and the deinit-driven stops never
  ran. `destroyWebView` now calls `removeScriptMessageHandler(forName:"port42")` + `removeAllUserScripts`,
  so the bridge deallocs (proven by a weak-ref dealloc test).
- **Root cause B, owner resolution (found in the live pass).** A gateway/companion-created port has
  `createdBy != messageId`, so `portPrincipal.id` is the creator, and owner resolution matched that
  against panel udid/messageId and recorded a **nil owner** — the id-keyed release could never match.
  Fix: `Principal.portId` carries the port's own id (excluded from identity, so P-260 grants are
  unchanged); `owningPortBridge` and `streamPortBridge` resolve on it. Also silently repaired
  transcription/frame/browser event routing to those ports.
- **The exhaustive seam.** `PortOwnedResource` + `AppState.deviceBridges` + `releaseAcquisitions(portId:)`,
  keyed on the stable port id. `close()`/`stop()`/`deinit` funnel through it and it releases audio
  capture, `audio.speak`, `audio.play`, camera stream, screen stream, browser sessions, and the AI loop.
  A fixed-inventory enforcement test fails red if a new start-with-owner bridge skips teardown (item 1).
- **Verified live** on a `createdBy`-set port: close logs `audio.capture stopped` and the sample shows
  `AVAudioEngine` / `com.apple.audio.IOThread.client` / `HALC_ProxyIOContext` / `SFLocalSpeechRecognitionClient`
  all gone; `audio.speak` cuts off instantly on close (by ear).
- **Still open (item 3):** the app/gateway kill switch + always-visible live-capture indicator. The
  `portId` keying is the enabler; the UI is a separate change. Backgrounded-port capture policy is a
  separate follow-up too (background keeps `suspendAI` today; whether it should also idle the mic is a
  policy call).

---

## TODO: the platform hides its failures — make every refusal legible (2026-07-16) — MOSTLY DONE 2026-07-20

**Status 2026-07-20:** parts 1-3 done; part 4 is a skill note.
- **(1) CDN/asset/fetch blocks now surface.** `wrapHTML` (the ONE wrapper — the PortView/PortWindowManager
  duplication was already collapsed) listens for `securitypolicyviolation` on `document` and logs a
  legible `[port42] Blocked by content security policy: <directive> -> <uri>...` through the console
  forwarder. Live-validated: a CDN `<script>` logged `script-src-elem -> unpkg.com/...`, a remote
  `<img>` logged `img-src -> example.com/...` (both previously silent).
- **(2) The bridge rejects** — done in 1635d93 (see its own item above).
- **(3) `terminal.exec` 50KB truncation documented** at the single source — the registry method
  `description` (flows into the generated reference + llms.txt), plus the same for `rest.call`'s 50KB
  response-body cap. Golden + llms.txt regenerated.
- **(4) The frame lies (popover sizing)** — a skill note (`setSize`/fixed-height class), not a code fix.
  Remaining.

Original write-up below.

**One family, three sightings in one session.** Port42 refuses things correctly and then says nothing,
so the author sees a blank rectangle, a frozen picture, or a lie. Every one of these cost a live
debugging round, and each is cheap to fix.

**1. CDN loads are silently blocked (GM: "should be something to add to the list").**
The port document carries a tight, correct CSP:
```
default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:;
```
So `<script src="https://unpkg.com/...">` never loads; so do remote images; and because
`connect-src` falls back to `default-src 'none'`, **all `fetch`/XHR/WebSocket from a port are blocked
too** (which is why `rest.call` exists). The policy is right. **The silence is the bug.**
- **Fix, one line, free:** a CSP violation fires `securitypolicyviolation` on `document`. Nobody
  listens. The wrapper should listen and surface it, the same way a port is told to surface
  `window.onerror`: *"blocked by policy: script-src https://unpkg.com/three.min.js"*. The platform
  must hold itself to the rule it gives authors.
- **Also:** the CSP is **duplicated** in `PortView.swift:245` and `PortWindowManager.swift:947`. Two
  copies of the port document wrapper, primed to drift. One wrapper, one policy.
- **Document the consequence** in the skill: the library must travel inline (three.js min is ~613KB
  against a 2MB payload cap; raw WebGL is ~0KB). Proven 2026-07-16: OPEN WATER carries three.js as a
  631KB inline block, and the cats port was built by lifting that same block out of it.

**2. The JS bridge never rejects** (its own item below): a failed call resolves with `{error}`, so
every `try/catch` in every port is decoration.

**3. `terminal.exec` truncates at 50,000 bytes** (`ShellExec.maxOutputBytes`). It *does* append
`... (truncated)` (credit where due), but the cap is **undocumented in the API reference**, so a port
shelling out for JSON gets `Expected '}'` and no idea why. Document it, and say so in the skill: over
~50KB, **gzip and inflate in the port** (`DecompressionStream('gzip')` works in WKWebView; 190KB of
JSON became 37KB of base64 for the session-history port).

**The through-line:** the skill tells authors "make failure visible — a port that dies silently is
undebuggable." The platform does not follow its own instruction. Fixing that is worth more than any
single one of these bugs, because it is what stops the *next* one costing a debugging round.

**4. The frame lies (a native-chrome sibling, 2026-07-17).** Building the version-history popover: a
`macOS .popover` sizes to its content **once, at present-time, and never grows.** A toggle that
swapped 1 grouped row for 349 saves left the fanned list clipped to the popover's original ~90px —
data correct, query correct, toggle correct, and it still read as "nothing fans out." Fix: a FIXED
content height, not `maxHeight`. Distinct from the others (nothing is hidden or refused) but the same
felt experience: every layer worked and the container betrayed it. Belongs in the skill next to
`setSize(w,h,false)` and `preserveDrawingBuffer` — the class of bug where the frame, not the logic,
is wrong.

---

## ~~BUG: the JS bridge never rejects~~ — FIXED 2026-07-16 (1635d93), confirmed 2026-07-20

**Already fixed in the API unification and confirmed still holding.** `port42._reject` exists
(`PortBridge.rejectCall`); `CallDisposition.disposition(for:)` turns an `{error: String}` envelope
into a JS rejection so the port's `catch` runs, and the streaming path rejects on a thrown
`BridgeError` — `ai.complete`'s old special-case is gone into the base. Pinned by
`PortCallDispositionTests`. Historical write-up below.

## BUG (historical): the JS bridge never rejects — every port fails silently (2026-07-16)

**Found by a voice port that said LISTENING while the mic was refused.** `PortBridge.bridgeJS`:

```js
function call(method, args) {
    return new Promise((resolve) => {   // resolve ONLY. There is no reject, anywhere.
```

Native handlers report failure by **returning** `["error": "..."]`. `call()` resolves that as a
**value**, so the obvious, correct-looking port code cannot see it:

```js
try { await port42.audio.capture({transcribe:true}); }
catch(e) { setMode('idle'); }        // NEVER FIRES. The bridge already said no.
```

**`ai.complete` is the only method that special-cases it** (`if (r && r.error) throw new Error(r.error)`).
Every other method on the surface — `audio.*`, `camera.*`, `screen.*`, `browser.*`, `fs.*`,
`clipboard.*`, `terminal.exec`, `port.*` — fails silently. A port author who writes textbook
`try/catch` gets a lie.

**This is "make failure visible" inverted: the PLATFORM hides the failure**, and no amount of
discipline in the port fixes it. It also means every `.catch()` in every port built this session is
decoration.

**Fix (Track A #2, the unification):** one contract for the return envelope. `call()` rejects when the
handler returns `error`, so `ai.complete`'s special case disappears into the base. A caller must never
need to know that one method throws and forty don't. Audit every port afterwards: code that reads
`r.error` still works if the reject carries the same message.

**Live proof (2026-07-16):** `audio.capture` returned
`{"error":"failed to start audio capture: ... avfaudio error -536870206"}` — CoreAudio refusing the
input because **another app held the mic** (GM was on a Signal call). Correct behaviour by the bridge,
correct error text, and the port displayed "LISTENING" anyway.

**Related, small:** `AudioBridge.capture` should say *why* in human terms. CoreAudio can be asked
directly (`kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input device = the mic is
held), so the error can read "your microphone is in use by another app" instead of a bare OSStatus.
Same for the reverse case in the permission-UX item.

---

## BUG: the app froze mid-demo, every port went grey (2026-07-16) — UNDIAGNOSED

**Reported by GM, live, during a demo.** First two demos fine. On the **third**, it started glitching:
**every port turned grey**, nothing could be interacted with, **LLM calls stopped working**, and the
app had to be killed. No diagnostic was captured.

**Why grey matters:** grey ports + an unclickable UI is the signature of the **main actor being
blocked** (SwiftUI stops compositing, webviews stop painting, clicks aren't serviced). It is also the
signature of the **blanking bug** the port-units mount-once contract was built to kill
(`plan-port-units-render-refactor.md`, I1-I4). Those are different causes with the same face, and
nothing recorded so far separates them.

**Candidates, none confirmed:**
- **A blocked main actor.** Everything on the bridge is `@MainActor`. Any sync wait, or a re-entrant
  bridge call (e.g. `port.exec` running JS that itself calls `port42.*`), could wedge it. Suspected
  the same night but NOT demonstrated: the calls that appeared to prove it were hitting a gateway
  whose app was already dead (see below).
- **The permission hang.** LLM calls stopped, and `.ai` is permission-gated. A gated call with no
  reachable prompt awaits a continuation forever. "Third demo" fits: the first ports' grants were
  cached, a later one asked, and the ask had nowhere to render. This is the known ship-blocker.
- **Accumulation.** Third demo = most ports = most live webviews, none of which idle or evict.

**The diagnostic to run BEFORE killing it next time** (this is the whole ask):
```
sample Port42Dev 5 -file /tmp/p42-hang.txt; open /tmp/p42-hang.txt
```
A blocked main thread names its blocker in the first stack. This is how the mic leak was caught.
Consider shipping a DEBUG watchdog that samples itself when the main thread stalls > 2s, so a demo
freeze is never again unrecoverable evidence.

**Severity: ship-blocking.** It failed in front of an audience, and it is the product's core claim
(the desktop IS live ports) failing under exactly the load the claim implies.

---

## ~~BUG: the gateway outlives the app~~ — FIXED 2026-07-20

**Fixed with the pipe-EOF option (the doc's "preferred" fix).** The app now gives the gateway a
stdin pipe and holds the write end for its whole lifetime (`GatewayProcess.swift`, `parentPipe`),
and the gateway runs a `-watch-parent` goroutine that `io.Copy(io.Discard, os.Stdin)` and exits on
EOF (`main.go`). When the app dies **by any means** the kernel closes the write end, so the gateway
can never orphan on `ppid 1` holding the port. **Live-validated in Port42Dev:** SIGKILL'd the app
(the force-quit path that runs no cleanup on either side) → the gateway exited on its own and `:4243`
freed; the happy path is unchanged (`/health` = ok, bridge calls serve normally with the stdin pipe
present). Gated behind the flag so a manually-run gateway (no pipe) is unaffected. Follow-ups NOT
done (belt-and-braces, lower value now the orphan can't form): reap-on-launch (kill a stale gateway
before binding) and gateway-side fail-fast (a `/call` with no app should error, not hang). Historical
write-up below.

## BUG (historical): the gateway outlives the app (2026-07-16)

**Found while diagnosing the freeze.** After the app is killed, its gateway subprocess **keeps
running and keeps listening**: `Port42Dev.app/Contents/MacOS/port42-gateway -addr :4243`, `ppid 1`,
up 1d04h with no app. Prod's `:4242` gateway was in the same state.

**Consequence:** every `/call` **hangs forever** rather than failing, because the socket accepts and
nothing answers. This wasted real debugging time (calls were read as an app deadlock when the app was
simply gone), and a relaunch would meet a busy port.

**Root cause (found, both sides):** on Unix a child does **not** die with its parent. It is reparented
to launchd (`ppid 1`) and keeps running. macOS has no `PR_SET_PDEATHSIG`, so nothing tells the gateway
its parent is gone. Both mechanisms that could stop it are cooperative and both are skipped by a kill:
- **App side:** `GatewayProcess.swift:79-86` terminates the gateway on
  `NSApplication.willTerminateNotification`; `Port42App.swift:264` calls `stop()`. **A SIGKILL (Force
  Quit, or killing a frozen app) runs neither.** Cleanup code in a dead process is not cleanup.
- **Gateway side:** `main.go:71` handles `os.Interrupt` / `SIGTERM` correctly, but **nobody sends it**,
  and there is **no parent watch at all** (no `getppid`, no pipe, no kqueue).

So it runs away because the only two things that could stop it are a signal nobody sends and a
handler a killed app never reaches.

**Fix — it must live in the CHILD, the only side still alive:**
1. **Pipe EOF (preferred).** The app passes the gateway a pipe (stdin suffices) and holds the write
   end; the gateway reads and exits on EOF. When the app dies **by any means** the kernel closes the
   write end. Survives SIGKILL, no polling, ~5 lines of Go.
2. Alternatives: poll `getppid() == 1` every ~2s (trivial, short orphan window), or kqueue
   `NOTE_EXIT` on the parent pid (immediate, more code).
3. **Reap on launch** — detect a stale gateway on our port and kill it before binding.
4. **Fail fast** — a `/call` with no app behind it must error, never hang. This cost real debugging
   time on 2026-07-16: hung calls were read as an app deadlock when the app was simply gone.

**It is the same class as the mic leak and the never-evicting registry:** nothing releases what it
acquired. Here the leaked thing is the app's own child process, and the lesson generalizes —
**teardown that only runs on the happy path is not teardown.** That matters most for the
standing-intent direction (`plan-standing-intent.md`): unattended work makes every leak permanent.

---

## ~~BUG: parked/backgrounded ports keep running their AI~~ — DONE IN CODE 2026-07-20 (verify with a token-count gate)

**The fix GM remembered is real and wired; the SHADER write-up below predates it.** Both halves
exist: `PortBridge.isSuspended` (`PortBridge.swift:197`) is true when the port is `aiPaused` OR
`panel.isBackground` OR `panel.presentation == "parked"`, and it **gates new** `ai.complete` calls at
both AI stream entry points (`BridgeMethods.swift:73`, `BridgeServiceAI.swift:107`), while
`suspendAI()` (`PortBridge.swift:209`) **cancels the in-flight** stream. Both are called from
`park(id:)` (`PortWindowManager.swift:566`) and the background path (`:669`). So a parked or
backgrounded port can neither start nor continue a generation. Landed as the shell-s1 `suspendAI`
regression fix (05477cc); the SHADER burst (2026-07-17) was captured before it. **Remaining: a live
token-count gate** — park a self-generating port (e.g. SHADER), watch its `port_versions`, assert
zero new saves while parked. Not yet run this session. Historical write-up below.

## BUG (historical): parked/backgrounded ports keep running their AI — burning the subscription (2026-07-17)

**GM, live: subscription limit hit two days running, and this is the likely cause.** A port that
self-generates (SHADER: `ai.complete` → new GLSL → `port.update`, in a loop) **keeps running its loop
while parked or backgrounded** — off the desktop, out of `ports.list`, invisible — and keeps calling
the model. Proof captured 2026-07-17: SHADER, not on the desktop and with a dead webview, still wrote
a **burst of 6 `port.update`s in 9 seconds** (versions 369-374) from its generative loop. Multiply by
days and it eats a subscription with nothing on screen to show for it.

**This is the convergence of three already-filed items, and it now has a dollar cost:**
- Ports are never told their presentation state, so they can't idle (the presentation-state item).
- The webview registry never evicts, so a parked port stays *live* (the eviction item).
- Nothing stops an `ai.complete` loop from the app side (the never-rejecting/no-stop theme).

**Fix — parking MUST pause the port:**
1. **Park = suspend.** When a port is parked (or backgrounded), deliver a presentation event
   (`port42:presentation {state:"parked", visible:false}`) AND, belt-and-braces, have the shell
   throttle/suspend it — pause rAF, and critically **halt outstanding/looping `ai.complete`**. A
   parked port must not be able to call the model.
2. **A generative loop must check visibility before each invoke.** Port-side discipline for the
   skill: never `ai.complete` when `!visible`. But the platform must enforce it too (a port that
   ignores the signal can't be allowed to bill you).
3. **Verify by token count:** park SHADER, watch `port_versions` for it — zero new saves while
   parked is the gate.

**Severity: high — it's costing real money, unattended, twice now.** Same root as the mic leak: a
resource keeps running after the thing that showed it is gone.

---

## TODO: port parking — exact placement + never truly close (2026-07-17)

**Two asks from GM, same lifecycle:**

**1. Place a parked port exactly where you want in the rail.** Dragging a port into the park rail
should let you drop it at a chosen position in the vertical list, and reorder within the rail — not
just append. Today parking appends; make the rail a reorderable list with drop-index targeting (the
drag already tracks a `ParkZone`; add an insertion index + a drop indicator).

**2. Never truly close a port — closing = park/archive, always reopenable.** GM: *"i want to be able
to reopen closed ports. we should never close them."* The version store already keeps every port
forever (proven repeatedly 2026-07-16/17: five ports recovered by hand from `port_versions`, incl.
SHADER, say-it-see-it, four workspaces, PORT WORKBENCH). So "close" should mean **archive, not
destroy**, and there must be a **reopen affordance** — a list/gallery of closed ports (title, last
saved, a preview) that recreates the port from its latest stored HTML. Recreation is trivial and
proven; the only missing piece is the UI.
- Design: `port.manage(id, "close")` → archive (keep the row, drop the live webview to save
  resources — which also serves the eviction item). A "closed / archived ports" view lists them;
  reopen = `port.create` from the latest `port_versions` HTML (or a true un-archive that restores the
  same id).
- **This is the fifth face of the session's theme:** the system remembers every port; nothing exposes
  the reopen. Recovering them by hand tonight was a 2-second read-and-recreate each time.
- Pairs with the eviction item (archived = evicted-but-recoverable) and "ports scoped to space".

---

## TODO: AI-edit a port from its chrome — through the port42 API (2026-07-17)

*Extends into element-targeting: the reference implementation already exists. See "workspace [1B]"
(`1B97BD69`, restored 2026-07-17) — its `✎ shape` button toggles shape-mode: a capture-phase click
SELECTS an element and a "change this →" popover scopes the prompt to that node
(`engine.say(text, target)` where target carries id/type/label). It persists learned utterance→
transform mappings to `port42.storage` ('gi-anneal') so repeated edits get instant + free. GM wants
this promoted from one port into native chrome: an edit icon → a prompt bar drops from the header;
type to change the whole port, OR toggle shape, click an element, and scope the prompt to it. The
element picker is the port-to-port highlighter prototyped in PORT WORKBENCH; the storage-backed
learning cache is the thing worth stealing wholesale. Whole-port edit = full regen; a shaped element =
targeted `port.patch` (which also solves the big-port output-token limit below).*

**Ask (GM):** a button in a web port's chrome opens a small prompt box — pick a companion
(pre-selected default) and type a change; the companion rewrites the port. Sits beside the
refresh/versions icons added the same day.

**The load-bearing constraint (GM): it must go THROUGH the port42 API, not around it.** The tempting
shortcut is `LLMEngine.oneShot` (a native collected-text call), but that bypasses companion identity,
model resolution, context, and permissions — i.e. it mints a parallel calling path, the exact
fragmentation the API-unification item exists to kill. So this feature *forces* a first real slice of
that unification, which is why it earns its own entry rather than being a quick chrome add.

**Why there's no clean native path today:** the bridge's `companions.invoke`
(`handleCompanionInvoke`, PortBridge.swift:1406) resolves the companion, builds an identity +
space-context system prompt, then **streams** via `PortAIHandler` and returns `__deferred__`. Built
for the port-JS path; not reusable as "invoke → get text" from native chrome. `oneShot` is the only
collected path and it skips all the context. Neither is right.

**Plan:**
1. **Extract the shared base (the unification slice).** `AppState.invokeCompanion(id:, prompt:,
   system:?) async -> String?` owns companion + model resolution and runs `LLMEngine.send` (the REAL
   path, not `oneShot`) with a small collecting delegate that accumulates tokens → full text. The
   bridge's `companions.invoke` becomes a thin caller (keeps its own streaming for ports; shares the
   resolution + prompt-building). One base, two callers — the thesis, demonstrated.
2. **Chrome button** (`wand.and.stars`) on web ports → popover: companion picker (LLM companions,
   default = last-used in UserDefaults), prompt field, Update, progress/error state.
3. **Compose the edit from API verbs:** read current HTML → `invokeCompanion(picked, editPrompt)`
   (prompt carries the HTML + the change + "return ONLY the full HTML") → strip code fences → apply
   via `port.update`.
4. **The safety net is already shipped:** a bad AI edit is one more save; the version-history chrome
   restores it in a click. This is what makes destructive AI regeneration safe to offer at all.

**Honest limit:** full-regen needs the model to re-emit the whole document, so it works on small/
medium ports but NOT a 630KB three.js port (exceeds output tokens → truncated, broken HTML). v1 tries
and leans on restore; **targeted-patch mode** (ask the companion for a `search`/`replace` and apply
via `port.patch`) is the follow-up that makes it work on large ports — and it's the honest use of
`patch` as the surgical delta verb (`membrane/bus-architecture.md`).

**Sequence:** it's a natural first slice of the API/tool-use unification — do it as part of that, not
before. Relates to: the never-rejecting-bridge bug (the collecting delegate must surface errors, not
swallow them) and the principal item (the edit's save should be attributed to the picked companion,
which needs the principal work to not flatten to `remote-http-cal`).

---

## TODO: port_versions stamps every update — auto-saves, not checkpoints (2026-07-17)

**Surfaced by the new version-history chrome.** Every `port.update` and `port.patch` calls
`savePortVersion`, so a port driven hard over the gateway accrues hundreds of rows: measured in the
dev DB — SHADER **331**, THE BUS 274, OPEN WATER 264, the cats port 249, one chat port **371**. The
numeric `version` is really an auto-save counter (`v329`), not a version a human chose.

**Two consequences:**
- **The number is meaningless to a person.** The DB already groups by `<meta name="version">`
  (`fetchPortVersionSummaries`), collapsing many saves into one logical version with a `saveCount`.
  The chrome now shows "N versions · M saves" and the `<meta>` label instead of the raw counter — but
  that's a display patch over a data question.
- **It never evicts.** Same bill as the webview registry: prod carries 184 orphaned histories, and a
  busy port keeps every keystroke of its history forever. A chat port at 371 saves is the tell that
  *something re-saves on activity*, not just on human edits — worth finding what.

**Fix direction:** (1) coalesce — don't stamp a new row when the previous save was seconds ago from
the same caller (debounce), or only snapshot on a `<meta>` version bump; (2) a retention policy
(keep every meta-version boundary + the last N saves, evict the middle); (3) investigate the chat
port's 371 — a version per message/render is a leak, not history. Relates to "the webview registry
never evicts" (same never-evicts theme) and the principal item (every gateway save is attributed to
the single label `remote-http-cal`, so history can't tell two agents apart).

---

## TODO: the webview registry never evicts — cost scales with ports-ever-created (2026-07-16)

**Measured, not theorised (2026-07-16):** a dev instance with **101 ports** was running **88 live
WKWebView (WebContent) processes** — Port42Dev at ~90% CPU, prod at ~50%, *with no demos running*.

**Diagnosis, in order:**
- **Not a leak.** Tested directly: create 3 ports → +3 WebContent; close them → back to baseline
  exactly. Webviews die correctly with their port.
- **Not space-scoped.** Closing/leaving spaces frees **nothing** — the registry keeps every port's
  webview alive regardless of the current space. Only closing the **port** frees it.
- **It's the port-units contract working as designed.** *Mount once, never re-mount* is precisely what
  killed the grey-blank bug (`plan-port-units-render-refactor.md`, I1–I4) and makes space-switching
  instant. **The bill: every port ever created stays live forever.** Cost scales with
  ports-ever-created, not with what's on screen.

**The tension to resolve (this is design, not a fix):** mount-once (correct, instant, never blanks)
vs. evict (scales). A busy user hits this at a few dozen ports; a year of building hits 101.
Candidate policy: keep mounted = current space's tiles + adopted + peeks + anything focused recently;
**evict the rest and re-mount on return**, accepting a repaint on a space you haven't visited in a
while. That trade (a repaint on return vs. 88 permanently-live webviews) is almost certainly worth it
— but it must not resurrect the blanking bug, so the eviction path needs the Tier-B probe
(`PortRenderProbe`) pointed at it: an evicted-then-remounted port must come back clean, once.

**Related and compounding:** ports also never idle (see the presentation-state item below) — so it's
not just 88 live surfaces, it's 88 live surfaces *rendering*. Fix both: evict what isn't needed, idle
what's kept. Also relevant: `ports.closed`/reopen (a purge story needs a recovery story) and "ports
scoped to space".

---

## BUG: a generative/stateful port loses its state on restart + on background/pop-out (2026-07-21, GM)

**Symptom (GM):** a shader port we created (a) does not survive a restart — the shader has to be
generated again — and (b) loses its state when backgrounded or popped back out, again forcing a
regenerate.

**RCA (code-level; the definitive port-vs-platform split needs a live repro — see below).** One root
cause, two paths:
- **Root:** the generated shader is **runtime-only state** in the live webview (its GLSL / chosen
  shader). It becomes durable only if the port writes it back — `port.update` DOES persist the latest
  HTML to `port_panels` (`PortWindowManager.updatePort` `:785`), or `port42.storage`. The shader isn't
  doing that, so the persisted HTML is the pre-generation original.
- **Path a (restart):** `restoreFromDB` reloads `panel.html` = the original → regenerates.
- **Path b (background/pop-out):** `minimize(_:)` (`PortWindowManager.swift:664`) sets `isBackground`
  and, per its own comment, **"the unit unmounts"** — the WKWebView is detached from the window. For a
  WebGL shader that triggers **WebGL context loss** (`webglcontextlost`); on remount the context is
  restored EMPTY, so without a `webglcontextlost`/`webglcontextrestored` handler the shader comes back
  blank → regenerates. Same un-persisted state, a second way to lose it.

**Fix direction (mostly port-side, enabled by the platform):**
- **Real fix (port-side, the "stateful-app pattern"):** the shader must persist its generated state
  (`port42.storage` or a `port.update` static snapshot) and rehydrate on load. Then restart AND remount
  both restore the real shader.
- **Platform-side = the presentation-state + eviction items below:** a backgrounded port isn't told it
  is about to unmount, so it can't snapshot first — deliver `port42:presentation {state:"background"}`
  so a well-behaved port persists-before-unmount; and decide whether WebGL-bearing ports stay
  attached-but-idle instead of detaching (context loss is inherent to unmounting).

**Confirm live before fixing:** is this the self-generating SHADER (regenerates by design) or a
generate-once shader whose state simply isn't saved? Open it in Dev, generate, watch the console for
`webglcontextlost` on background, and check whether `port.getHtml` returns the generated shader or the
original. That decides port-fix vs platform-fix. Relates to [[the presentation-state item]], the
webview-eviction item, and the blanking-bug (all "restore assumes state survived; it doesn't").

## TODO: ports must know their presentation state — or the desktop melts (2026-07-16)

**Found the hard way:** four animated ports (three.js scenes + a live WebGL shader) running as tiles
at once **cooked the CPU** and had to be killed. Each ran an unconditional `requestAnimationFrame`
loop at 60fps — *including while peeking at 210px, backgrounded, or ignored*. Nothing throttles.

**The gap:** a port is **never told what it is right now.** The bridge pushes `audio.*`, `browser.*`,
`camera.frame`, `screen.frame` — and nothing about the port's own presentation. So a port literally
cannot idle: it has no signal to idle *on*.

**The sting: the shell already knows.** `panel.isBackground`, `presentation` (tiled/parked/inline),
the peek entry, the zoom rung (`.focus(id)`) — all live in `ShellState`/`PortWindowManager` already.
The information exists; it's simply never delivered to the port. *(Third instance of this exact shape
tonight: the bus remembers every closed port but exposes no reopen; the shell knows visibility but
never tells the port. The system knows; nothing exposes the knowing.)*

**Fix — two halves:**
1. **Tell the port.** `pushEvent("port42:presentation", {state:"focused|tiled|peek|parked|background",
   visible:bool, w,h})` on every state change, consumed as `port42.on('presentation', …)`. Small: the
   state transitions already exist and are already observed.
2. **Defend anyway.** The shell should throttle/suspend backgrounded ports it knows are invisible
   (a port that lies or ignores the signal must not be able to melt the machine). Belt and braces:
   the platform enforces, the port cooperates.

**Why it's load-bearing, not polish:** "the desktop IS live ports" is the shell thesis. It does not
survive each live port burning a core — with the working set + peeks + adopted ports, a busy desktop
is 5–10 live surfaces. Today that's 5–10 × 60fps. This caps how many ports a person can *have*, which
caps the product.

**Port-side discipline** (goes in the `port42-ports` skill): pause the loop when not visible
(`document.hidden` + `IntersectionObserver` today, the presentation event once it exists), drop to
~15-30fps when small/unfocused, cap `devicePixelRatio`, scale particle/geometry counts to tile size.

---

## TODO: a port has a URL — paste it in a browser and you're in it (2026-07-16)

**GM:** *"it would be cool to be able to take a url of a port and paste it into a browser and you're
just in it."* This is the sharing story, and most of it already exists.

**Already there:**
- The gateway is **already an HTTP server serving HTML** — `/` (root page), `/invite` (a real landing
  page with OG tags for link previews), plus `/call` (HTTP bridge) and `/ws` (WebSocket).
- It **already tunnels via ngrok** → it can have a public URL today.
- **Ports are self-describing HTML**, and `port_versions` keeps every version forever (proved
  2026-07-16 — four closed ports restored straight out of the DB).
- **`port42://` deep links already work** in-app (space + agent invites, parsed in `QuickSwitcher`).

**The hop:** `GET /port/<id>` → serve that port's latest HTML from `port_versions`. With the tunnel,
that's a public URL that renders the port in any browser, on any device.

**The interesting part — the bridge (this is the whole design).** A browser-served port has no
WKWebView message handler, so `port42.*` is undefined and any real port breaks instantly. But the
gateway *already* exposes the same methods over `/call` and `/ws`. So the served page gets a
**`port42` shim backed by HTTP/WebSocket** — same method surface, **a third calling path** alongside
the native bridge and LLM tool-use. Which means **this falls out of the API/tool-use unification item
above** ("one base implementation, different calling paths"): do that refactor and the browser path is
nearly free. Don't build a bespoke browser API — make the browser a third caller of the one base.

**Copy vs. co-presence (same distinction as port teleport).** Serving the HTML gives a *dead copy*.
Serving the HTML **+ a live WS bridge back to the bus** gives **the same port, in a browser** —
addressable, subscribed, live. Send someone a link and they are *in your port*, not looking at a
photocopy of it. That's the sharing primitive Port42 has never had.

**LOAD-BEARING SAFETY — do not skip.** A public URL to a live port that can call the bridge is
**remote code execution on your Mac**. The browser shim must be **capability-scoped by construction**,
not by policy:
- A **share token** per link (revocable, expiring, per-port — never a session key).
- A **strict subset** of the bridge: the port's own data + its own stream. **Never** `fs.*`,
  `terminal.exec`, `automation.*`, `clipboard.*`, `rest.call`.
- **Read-only vs interactive** as an explicit choice at share time.
- The permission model here is the *product*, not a nice-to-have — this is the one feature where
  getting it wrong hands a stranger your machine.

**Why it's worth it:** it makes a port shareable with anyone who has a browser — no install, no
account. That's the demo you send Dom; that's how a port escapes the app. Related: "port teleport"
(below), cross-instance addressing in `membrane/bus-architecture.md` (the keystone), and the
`ports.list`/tool-use unification item.

---

## TODO: port teleport — moving a port between instances must be IN the protocol (2026-07-16)

**Proved by accident, 2026-07-16.** Four live ports (OPEN WATER, ATELIER 3D, SHADER, THE BUS) were
copied from the dev instance into the production instance — different bundle id, different gateway,
different database — with one `port.create` each. **They arrived alive and ran.** Ports teleport
trivially *because they are self-describing*: a port's whole being is HTML + state, so there is
nothing to export. That half is free.

**What did NOT travel — and this is the whole lesson: the addresses.** Each port had *dev* companion
UUIDs baked into its JS (`onthekeys`, `sonnet`, `echo`). Those are meaningful **only in the instance
that minted them**. Copied as-is, every `companions.invoke` would fail silently. It only worked
because a human hand-remapped them (`onthekeys→sage`, `sonnet→muse`, `echo→echo`) — i.e. **a person
stood in as the resolution layer**. That is exactly the keystone gap in
[`membrane/bus-architecture.md`](membrane/bus-architecture.md) (cross-instance Address), seen from
the other direction.

**So the protocol must carry:**
1. **Transfer as a first-class operation** — `port.send(id, to:<instance>)` / `port.fork`, not
   "re-create it by hand". The port's **state travels with it** (`port42.storage` contents — the
   sculpture's forms, the marks), not just its HTML.
2. **References must be ADDRESSES, not raw local UUIDs.** A port referring to a companion should say
   `port42://agent/<id>` (resolvable) or a **role/capability** reference ("a fast companion", "the
   one that makes music") — never a bare UUID that only one instance can resolve. Otherwise every
   teleport needs a human translator.
3. **Rebinding on arrival** — when a port lands in a new instance, its references resolve: by
   address, by name, or by an explicit binding step ("this port wants a Haiku companion → bind to
   sage"). Unresolvable references should surface *loudly*, not fail silently (they failed silently
   in the hand-copy; only foreknowledge caught it).
4. **Provenance** — a teleported port should know where it came from (its origin address), which is
   what later lets the two copies find each other.

**Copy vs. co-presence (the real prize).** Tonight was a *copy* — two independent ports that now
drift apart. With addressing done properly it stops being a copy: **the same port, reachable from
both instances, subscribed to each other.** You wouldn't remap echo — echo would simply be
*reachable*. That is the difference between "I sent you a file" and "we're in the room together",
and it's the same Address work the media plane needs. Do addressing once; teleport, multiplayer, and
subscription all fall out of it.

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
