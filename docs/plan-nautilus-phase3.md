# Nautilus Phase 3: the pipe

Detailed plan for Phase 3 of `plan-shell-only.md`. Scenario served: 3. Rewritten 2026-09-26 against
`nautilus` at `140bd30` for GM's review.

**Status (2026-09-26): built.** The Antigravity producer moved to the roadmap (GM). 3.0 to 3.3, 3.5, 3.6 and 3.7 are built
and verified live on Dev4; 3.4 moved to the roadmap (decision 5). The harness passes five of five
with scenario 3's three rows, and all eight companion combinations (claude and codex, in a port and
hidden, listening to a space and watching a port) pass. Suite 1228 green.

## Goal

One port feeds another with no glue, including when the middle stage has no tile, when the receiver
is not on screen, and when the receiver is a companion rather than a port.

## What changes, for a person and for an agent

- **Any port can run headless.** A port can be hidden: it runs, keeps its storage, chat and
  subscriptions, and has no tile. A web port hidden is a background process written in HTML and JS (a
  transform stage, a poller, a scheduler). A terminal port hidden is a background shell job, and a
  terminal running Claude Code or Codex hidden is a headless agent, driven through its chat exactly as
  a visible one is. A hidden port can be shown for debugging and hidden again.
- **Ports keep working off screen.** A port in another space, parked or hidden still receives and
  sends events at full rate.
- **An agent can watch a port.** Today an agent wakes only when someone @mentions it. A watch makes
  an event on a port wake it: "fix this port when its console throws", "review every edit to this
  port", "tell me when the scraper finds something". Its answer goes to that port's chat.

## Decisions for GM

1. **Which events wake a watcher: the watch says (decided, GM 2026-09-25).** A watch names the event
   kinds it wakes on. Default: the port's own published events (`port.*`). Can be asked for: `state`
   (an edit to the port), `console` (a log line or error), `chat` (every post in the port's chat, not
   only mentions, which already wake). Never: `terminal.output`, which fires on every keystroke.
2. **A burst of events becomes one turn (decided, GM 2026-09-26).** A wake is one full model turn, which
   takes seconds to minutes and costs tokens. A port can emit events far faster than that. If each
   event started a turn, five events in a second would type five messages into the agent while it is
   still answering the first. Recommended: each companion has at most one turn running. Events that
   arrive while it runs are held, and when the turn ends they are delivered together as one message
   ("5 events on port 'x' since your last turn", then each). The first event of a quiet period waits
   one second before waking the agent, so a burst that arrives together is one turn, not one turn and
   then a batch.
3. **A watch has no default floor, and a ceiling against runaway (decided, GM 2026-09-26: start at 60 wakes an hour).** There is no
   right minimum gap between wakes in general: "review every edit" wants each one, "tell me when the
   scraper finds something" does not care. So the watch sets its own floor (`every`, seconds) and has
   none by default; decision 2 already keeps it to one turn at a time. The ceiling guards the one
   failure the floor was for, a port that emits forever keeping its watcher in back-to-back turns: past
   a set number of wakes in an hour the watch pauses and says so in the port's chat, and anyone can
   resume it. The number is a guess made visible rather than a measured value; 3.5 logs wakes per hour
   and it is revisited from that.
4. **A person can always see what is running hidden (decided, GM 2026-09-26).** ⌘K lists hidden ports in
   their own section with show, close and delete, and the space's chrome shows a count ("3 hidden")
   when there are any. Nothing runs where the person cannot find it.
5. **`terminal.exec` in a port moves to the roadmap (decided, GM 2026-09-26).** The master plan wanted
   every shell command to run in a port with an identity. No scenario needs it, and running a command
   in a real terminal to capture its output and exit code is fragile (prompts, TUIs, sentinels), while
   today's exec already requires the caller's own grant. Hidden terminal ports give a caller a
   background shell whenever it wants one. Recommended: 3.4 is not built in this phase.

## What is measured

- **The pipe works for live, visible ports.** Scenario 3 passes: produce, transform and render as
  three web ports, produce to render in single-digit milliseconds.
- **One channel for durable and live.** A port's chat is durable and is also published on the port's
  own topic as a `chat` event.
- **Off-screen web views leave the window.** A port in a resting space or parked is unmounted from
  the desktop, and its `WKWebView` is kept but sits in no window (`ShellPortHost`). WebKit throttles
  pages it considers hidden (timers, animation frames, possibly more). Whether a port off screen still
  publishes and receives at full rate is **unmeasured**. The previous draft said "web ports do not
  sleep"; that was an inference, not a measurement.
- **A companion wakes only on chat.** A mention wakes it (a closed terminal is respawned first), and
  since 2026-09-26 a plain post reaches the companions that are members of that chat. It cannot watch
  a port.
- **"Headless companion" today means an NDJSON program**, a command speaking Port42's agent protocol
  over stdio (`CommandAgentHandler`), not Claude Code or Codex. Claude Code and Codex run only in
  terminal ports.
- **A turn has a start and an end the app can see.** A terminal companion's turn starts when a
  message is injected (`inject + armed`) and ends at its Stop hook (`turnComplete`), which is how every
  reply is posted today. This is the busy signal decision 2 needs.
- **Errors reach port JS, and there is no token carve-out** (verified 2026-09-25). The bridge rejects
  with the whole envelope, so `e.code` and `e.current` are set in a port's catch.
- **`terminal.exec` runs as a raw child of the app**, attributed to its caller only by the grant it
  needed.
- **There is no tile-less port.** Every port is tiled, parked or the wallpaper; the presentation value
  appears as a string literal in about 30 places.

## Before this phase: agents in a room (GM's multi-agent test, 2026-09-25)

Two Claude companions and a Codex companion tried to work on one port through its chat. Found and
fixed, each with tests calibrated by removing the fix:

- **Every reply is posted.** A turn typed into the terminal was never posted, so its @mention
  hand-off went nowhere. Replies go to the chat that asked, else the terminal's own chat, whose
  @mentions then route. Companions must @mention each other there, so two cannot loop.
- **Messages arrive whole.** A long or multi-line message goes in as one paste with an Enter that
  waits for it; typed as keys, one lost about 1,100 characters and its Enter. An unsent first-run
  prefill is cleared before the next message.
- **Codex can take part.** Its sandbox blocked the network, loopback included, so it concluded Port42
  was not running; this session's config now allows it. Its instructions keyed on an env var that did
  not reach its shell; they key on the token file now. A terminal that starts codex is registered as
  codex, not claude (the session-start hook names its CLI).
- **Agents know where they are.** A new `whoami` answers, from the caller's credential, its name,
  space, terminal port and chat, and who else is here. Claude's prompt and Codex's AGENTS.md teach the
  chats from one source (`CompanionProtocol.chats`): whoami first, a message names the chat it came
  from, a port's work belongs in that port's chat (`chat.read`, `chat.post`), @mention to reach
  someone. A port's chat is named with its id. Replies are "delivered back to the chat it came from".

Open from the same test: a person's plain post in a web port's chat reaches nobody (who counts as in
that chat is 3.3's watch), and the MIC ON button GM reported missing in the mic shader port.

## Steps

Each step is its own commit: suite green, harness five of five, plans updated. 3.0 comes first
because its answer decides part of 3.2.

### 3.0 Measure ports off screen

A web port that publishes a counter every 100 ms and counts its own animation frames, with a second
port subscribed to it, measured on Dev3 in four places: tiled on the current desktop, tiled in a
resting space, parked, and (after 3.2) hidden. For each: events published per second, events received
per second, produce-to-receive latency, animation frames per second, and whether anything stops after
several minutes. The figures go in this plan.

If off-screen ports are throttled, the fix is chosen from what the measurement shows, for example
keeping off-screen views in an invisible host window so WebKit treats them as visible, while their
presentation still tells the page it is not seen so it can stop drawing. No fix is designed before
the numbers exist.

*Gates:* the measurement table, recorded here. If a fix lands, a harness check that an off-screen
producer still delivers at its own rate.

**Measured 2026-09-26 on Dev4** (a producer publishing every 100 ms and counting animation frames, a
second port subscribed to it, 10 s per row):

| Where | Published/s | Received/s | Latency median | Frames/s (producer / consumer) |
|---|---|---|---|---|
| Both visible | 10 | 10 | 1 ms | 59 / 59 |
| Producer docked (hidden) | 1 | 1 | 2 ms | 0 / 31 to 60 |
| Consumer docked (hidden) | 10 | 10 | 1 ms | 59 / 0 |
| Both in a resting space | 1 | 1 | 2 ms | 0 / 0 |
| Both in a resting space, after 3 min | 1 | not remeasured after the fix | | 0 / 0 |
| Back on screen | 10 | 10 | 1 ms | 59 / 59 |

- **Events reach a port off screen at full rate**, with the same latency. The pipe's event-driven
  stages (a transform reacting to what it hears) are unaffected.
- **A port's own timers slow to once a second off screen, and animation frames stop.** WebKit's
  hidden-page throttling. A producer that polls on a timer runs at 1 Hz while not seen. Nothing
  further stops after 3 minutes.
- **The whole app counts as unseen when its window is covered.** One run read 1/s and 0 frames for
  "both visible" with the Dev4 window behind others.
- **Bug found and fixed: a parked port lost its subscriptions for good.** Parking cancels a port's
  AI generations to stop the spend, and the same call cancelled every stream on the port, including
  `port.subscribe`, without telling the page. The first run showed a consumer receiving nothing
  after it had been parked once, even back on screen. Parking now stops only finite streams;
  closing still stops all (`ParkedSubscriptionTests`, a real web view, calibrated).

**Decided and built 2026-09-26: hidden ports run their timers at full rate.** A hidden port opts out
of WebKit's clamp on unseen pages (its own `_setHiddenPageDOMTimerThrottlingEnabled` and process
suppression preferences, set only when the running WebKit has them); animation frames still stop;
parked and resting ports keep the clamp. `HiddenTimerTests` in a real web view: a 50 ms timer ticked
at most 6 times in 2 s clamped and 23 hidden, and the clamp returns when the port is shown
(calibrated by not setting the preference). The port manual now says when to make a port hidden and
what runs off screen.

### 3.1 Errors reach port JS: already true

Verified 2026-09-25, nothing to build. A refused write from a port principal carries `code` and
`current` in the envelope the page receives; a gate for that is added with 3.2.

### 3.2 Hidden ports

- **Create and move.** `port.create({..., presentation: "hidden"})` makes any type of port hidden.
  `port.manage(id, "show")` tiles it on its home desktop at a free spot; `port.manage(id, "hide")`
  hides a tiled or parked port. The presentation is stored like any other (`port_panels.presentation`).
- **Where it is not.** No desktop, no rail, no dock, no exposé. Every place that decides which ports a
  surface shows reads one predicate, so a hidden port cannot leak into a view that forgot it.
- **Where it is.** `ports.list` lists it with status `hidden`. ⌘K lists it under "Hidden" (decision 4)
  with show, close and delete, and the chrome shows the count. Closing archives it like any port, and
  reopening brings it back hidden. It survives a restart hidden.
- **What it runs.** A web port gets its web view and bridge as today; its presentation reports
  `hidden`, not visible, so it can pause drawing while its logic runs (subject to 3.0). A terminal
  port gets its terminal surface as a parked terminal does. Its chat, storage, subscriptions,
  console and driver chip work as for any port.
- **Headless agents.** `port.create({type: "terminal", command: "claude", presentation: "hidden"})`
  is a headless Claude Code companion: it registers, is @mentioned and replies through its chat, and
  can be shown to watch it work. Same for Codex.
- **Permission.** A hidden terminal needs the same terminal grant as a visible one. Hiding is not a
  way around any gate.

*Gates:* a hidden port is in no desktop, rail or dock set (one predicate, source-scanned so a new
surface cannot skip it); a hidden producer's events reach a visible subscriber and a hidden
subscriber receives a visible producer's; show then hide round-trips its presentation and position;
it survives a restart and a close and reopen hidden; `ports.list` reports it hidden; a hidden
terminal companion answers a mention in its chat; a refused write from a port carries `code` and
`current` (3.1).

**Built 2026-09-26.** A hidden port already existed as "docked" (`isBackground`, from `port.manage
minimize`): running, persisted, on no desktop and in no rail, and listed by no view, so it ran where
nobody could find it. It is now the hidden port. `port.create` takes `presentation: "hidden"` for
every type (terminal and browser ignored `presentation` before); `port.manage` takes `hide` and `show`
(the old names still work); `ports.list` says `hidden`; a hidden port reports the state `hidden` to
its page (it reported `background`, the wallpaper's state). ⌘K lists hidden ports after spaces,
searchable, and selecting one shows it on its home desktop; the chrome shows "N hidden" as a menu
when the current space has any. Gates in `HiddenPortTests` (created hidden, hide and show through
the API keeping the spot, persisted, and a source scan that fails any tile filter letting a hidden
port through), each calibrated; `PortPresentationTests` covers the new state. Verified live on Dev4:
a `claude` terminal created hidden registered as `witty-fox`, was listed hidden, and answered a
mention in its space's chat as itself. Open: the timer decision in 3.0.

### 3.3 Companions watch ports

- **API.** `companions.watch {port, kinds?, every?, companion?}`, `companions.unwatch {port,
  companion?}`, `companions.watches {companion?}`. `companion` defaults to the caller, so an agent
  watches for itself. A person or a client with a grant on the port can set a watch for a companion.
  `every` is the watch's floor in seconds (decision 3).
- **Stored.** A new table, `companion_watches` (companion id, port udid, kinds, floor, paused, created),
  in a new migration. Watches are restored at launch; deleting the port or the companion deletes its
  watches; closing the port pauses them until it is reopened.
- **Delivery.** Each watch subscribes to the port's topic on the NotifyBus. An event of a watched kind
  goes to that companion's wake queue, which applies decision 2 (one turn at a time, a burst is one
  batch, a quiet-period event waits one second) and decision 3 (floor and ceiling). The queue is a pure
  state machine with its own tests; the app only feeds it events and turn boundaries.
- **What the agent receives.** One message, in the same form as a chat message so it knows where it
  came from and where its answer goes: `[port 'render' (id X): 3 events since your last turn]` and
  one line per event, kind then payload, each payload cut to a fixed length with the total said.
- **Where the answer goes.** The watched port's chat, through the reply routing that already posts
  every turn. @mentions in it route as any chat post does.
- **No self-wake.** An event caused by the watcher's own write does not wake it: while its turn runs,
  events on a port whose token it moved in that turn are dropped. Without this, an agent that fixes a
  port on `console` would wake on the log line its own fix produced, and loop.
- **Which companions.** A terminal companion (a closed terminal is respawned first, as a mention
  does). A headless NDJSON companion is launched with the message. A hidden terminal companion (3.2)
  is the ordinary case for a watcher nobody needs to see.

*Gates:* the wake queue in isolation: idle then one event wakes once after the one-second gather; a
burst of five during a turn becomes one batched message at turn end; the floor holds; the ceiling
pauses and reports; a paused watch resumes. In the app: a watched port's `port.*` event wakes its
watcher and the reply lands in that port's chat; `terminal.output` never wakes; a kind not named does
not wake; the watcher's own write does not wake it; unwatch stops it; a watch survives a restart;
deleting the port removes it.

### 3.7 The new-companion card (GM's review, 2026-09-26)

Making a companion is where a person chooses what the agent is, where it listens and whether it is
seen, so it carries this phase's ideas (hidden ports, watches) to people. Reviewed against the code
(`ShellNewCompanionView`, and the settings card, which shares its fields):

| Field today | Finding | Change |
|---|---|---|
| TYPE presets (echo, architect, compiler, operator) | Pre-canned constitutions. | Removed (GM). The prompt is the person's. |
| "Advanced" collapsed | Hides the choices that matter. | The full card is the default (GM). |
| TRIGGER: mention-only / all messages | **Stored and never read.** No routing path checks it; every companion behaves as mention-only plus chat membership. | Replaced by LISTENS TO (below). |
| CLI: claude / gemini / codex / custom | **gemini has no hook producer**, so a Gemini companion never registers and its replies are never posted. | claude / codex / antigravity / custom. Antigravity's `agy` is installed here; whether it runs as an interactive terminal agent with turn hooks is a spike before it is offered. |
| COMMAND and ARGS, custom only | A CLI companion cannot be given flags. | ARGS for every CLI, passed as on a bare command line (GM). |
| "runs headless (NDJSON)" for custom | Today's only headless path, a program speaking Port42's stdio protocol. | RUNS: a tile, or hidden (3.2), for every CLI. This is where "headless" is chosen. |
| WORKING DIR, SYSTEM PROMPT | Fine. | Kept. |
| SECRETS | Named Keychain secrets a companion may use in `rest.call` without seeing the value. **The restriction only applies to callers of kind companion; a terminal companion calls as a peer, so it is not restricted at all** (with the REST grant it can use any secret). | Kept. **Gate fixed 2026-09-26:** it keys on the companion a caller acts as, looking through a terminal's credential to its companion (`AppState.companion(actingAs:)`); `SecretScopeTests`, calibrated. Ports and plain terminals are still unscoped; a per-caller secret grant belongs with Phase 4's read scoping. |
| OR ADD EXISTING | Fine. | Kept. |

**LISTENS TO** replaces TRIGGER and says what a companion is subscribed to: this space (it hears
@mentions and, once mentioned, plain posts in the space's chat, as today), or one live port picked
from a list, with the event kinds that wake it (a watch, 3.3). A companion made for a port is placed
beside that port's work rather than in the space's crew.

*Gates:* no pre-canned type remains; no field is stored that nothing reads (a source scan pairing each
card field with its reader); a companion made hidden is created with a hidden terminal (3.2); a
companion made for a port starts with that watch; the secrets gate refuses a terminal companion a
secret it was not given (calibrated by removing the gate).

**Built 2026-09-26.** `CompanionWatch.swift`: the watch model, `WatchKinds` (the default "port" is
every `port.*` event; `terminal.output` and the frame streams can never wake), the pure `WakeQueue`,
and `CompanionWatchService`, which subscribes each watch to its port's topic and feeds the queue.
Stored in `companion_watches` (migration v53), restored at launch, removed with the port (delete
forever) or the companion. API: `companions.watch`, `companions.unwatch`, `companions.watches`; the
caller is the watcher unless it names `companion`. Delivery reuses the mention path
(`deliverToTerminalCompanion`, extracted from `routeMentionsToTerminals`), so a closed terminal is
reopened first and the reply goes to the watched port's chat; a mention's turn also holds watch
events. The turn ends at the terminal's Stop hook; a turn that never reports its end times out and
releases what it held (found writing the tests: without it, held events waited forever behind a
closed terminal). The companion prompt and Codex's AGENTS.md teach `port42 companions.watch`.
Gates: `WakeQueueTests` (11, calibrated by removing the gather, the hold and the ceiling) and
`CompanionWatchTests` (5, through the API and the real bus, calibrated by removing the self-wake
guard and the delete cleanup). Verified live on Dev4: a hidden Claude companion watching a port
answered one published event in the port's chat 9 s later, and a further event followed by five
more fired during its turn gave exactly two more replies, the second reading "Alerts #3 to #7 came
in as a burst, all within 47 ms".

**3.7 built 2026-09-26** (card and settings), except Antigravity, which waits on its spike. The card
shows every field with no "Advanced": AGENT (claude, codex, custom), ARGS for every CLI, RUNS (in a
tile or hidden, stored as the companion's `runsHidden`, migration v54, so a reopened terminal comes
back hidden), LISTENS TO (this space, or a port picked from the space with the events that wake it,
which creates the watch), working dir, prompt and secrets. The presets and their four constitution
files are gone. The settings card's TRIGGER became RUNS, which hides or shows the live terminal.
Gates in `NewCompanionCardTests`, calibrated. Not yet looked at by GM.

**GM's review of the card, and testing every combination (2026-09-26).** Wording is "in a port" /
"hidden", never "tile"; secrets moved to the companion's settings (an agent CLI calls APIs from its
own shell); "bring one from another space" lists companions under the space each is in now, and
joins the same companion to this space (its terminal stays where it runs). The card and a new
`companions.create` share one path (`AppState.createCompanion`), so the harness proves what the card
does. Running all eight combinations (claude and codex × in a port and hidden × this space and a
port) on Dev4 found and fixed, each with a calibrated test:

- **The missing Enter** (GM saw it live). A message typed before Claude was ready sat unsent as
  typeahead. Messages now wait for the CLI's SessionStart and a quiet screen; after the CLI exits
  they are held rather than run in the bare shell; and Claude now reports a submitted prompt
  (UserPromptSubmit), so an unconfirmed message gets Enter again, up to three times. Verified: two of
  four Claude companions needed the second Enter and then answered.
- **A hidden companion put back on the desktop** when woken while its terminal started.
- **The app froze.** AVKit's `AVPlayerView` (lock screen and boot videos) deadlocked the main thread
  with a media thread; the videos are drawn with a bare `AVPlayerLayer`.
- **Calls timed out under load.** The main thread re-scanned every terminal's output buffer with
  freshly compiled regexes on every chunk, and cleaned output nobody reads; and it committed a
  client's last-seen to disk on every gateway call. Both fixed.

Result: all eight combinations PASS. Open: with the disk busy (Dropbox's file provider at 112% CPU
while this repo was being committed and built), the harness's own polling still saw one 30 s call,
sampled as the main thread blocked in a synchronous write to its log file. The app still logs and
commits to SQLite on the main thread; moving that I/O off it is the remaining fix.

**Fixed the same day.** The database runs in WAL mode with `synchronous = NORMAL`, so a commit is a
sequential append rather than a rollback journal and two syncs; every log line goes through
`p42log`, formatted where it is logged and written in order by a background queue (all 158 `NSLog`
calls in the library). Gates in `MainThreadIOTests` (journal mode, a slow log sink not blocking its
caller, no `NSLog` left), calibrated. Re-run on Dev4: all eight combinations PASS, every companion
answering within 16 s of the ask, and the slowest call of the run 0.11 s where calls had timed out
at 30 s.

**Antigravity spike (2026-09-26).** `agy` (installed at `~/.local/bin/agy`) is an interactive terminal
agent with a print mode (`-p`), resume (`--conversation`, `--continue`) and plugins. It has lifecycle
hooks, among them SessionStart, Stop, Pre/PostInvocation and PostTool, loaded from a plugin's
`plugins/<name>/hooks.json` (run with the plugin's directory as cwd), and the hook payload carries a
`transcriptPath`. So the path is a Port42 plugin for `agy` whose SessionStart and Stop hooks call the
same notifier (`port42-claude-shim notify …`) Claude's and Codex's do, plus a producer that installs it
per session. Not built; it is a step of its own (a third `CLIHookProducer`, the plugin, and a live check
that an `agy` companion registers and its replies post), after which the card offers it.

### 3.4 `terminal.exec` runs in a port (moved to the roadmap, decision 5)

What it would be: each caller that runs `terminal.exec` gets one hidden terminal port of its own,
created on first use and reused, and the command runs there with its output captured and returned as
today. Not built in this phase unless GM decides otherwise.

### 3.5 Scenario 3, extended

The harness's scenario 3 gains, in its own space:

- the transform stage as a hidden port, with produce and render visible;
- the render port moved to a resting space, still receiving at full rate (3.0);
- a hidden Claude Code companion watching the render port for one kind, woken by one published
  event and replying in the render port's chat;
- a burst of five events while it is answering, which arrives as one batched turn, so the render
  port's chat holds two replies, not six.

**Built 2026-09-26.** Scenario 3 reports three rows: the original pipe; "hidden, off screen" (the
transform stage created hidden, the render port in another space, `harness-elsewhere`); and "a
watching agent" (a hidden Claude companion watching an alarm port: one event answered in its chat,
then one event and a burst of five during its turn giving exactly two more replies). First run on
Dev4: all three PASS; 8 events in 6 s at 4 ms median, the same 8 off screen, the watcher answering
in 15 s and the burst arriving as one turn. The watching row costs about three agent turns.

### 3.6 Port42 as a command, not curl (built 2026-09-26)

Companions reached Port42 by curl, so every call was a quoted shell line (and HTML went through jq),
and Codex asked for approval on each. GM chose the CLI over MCP: `port42 <method> key=value` calls
any registry method as the calling session (`$PORT42_TOKEN_FILE`, `$PORT42_GATEWAY_PORT`), with
`key:=json` for values, `key=@file` for a file's contents (HTML never passes through quoting), and
`port42 help api` / `port42 help ports` from the live app, so a new method needs no CLI change. A
refusal prints `{error, code, current}` and exits 1. Each terminal gets its own instance's CLI first
on PATH, after the user's startup files too, since `~/.local/bin/port42` belongs to whichever
instance installed last. The companion prompt, Codex's AGENTS.md and the instruction block teach
`port42`, with curl as a one-line fallback.

*Gates:* Go tests for the argument forms and the rule that a session calls as itself; a real-zsh
test that a terminal runs its own CLI in interactive and login shells when the user's rc puts a
decoy first; the chat guidance names the CLI calls. Each calibrated by removing its fix. Verified live
2026-09-26: on Dev3 a Claude and a Codex companion each patched one port with `port42 port.patch`
from files in 20 s, Codex retrying a stale write with the refusal's `current`; on Dev4 Codex ran
`port42 whoami` as itself, from `/tmp/port42-shim-…/bin/port42`, while `~/.local/bin/port42` was
still prod's older CLI. Open: a restarted Codex terminal waits on a risk dialog GM has to accept.

**Fixed 2026-09-26: instances shared the instruction files.** Every instance rewrote the Port42 block in
the user's `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` at launch with its own gateway port, so the
last instance launched decided where every session's calls went (Dev3's 4245 reached prod's
sessions). The block now names the port as `${PORT42_GATEWAY_PORT:-4242}`, every terminal Port42
starts carries its own instance's port in that variable, and each instance's Codex home has its own
AGENTS.md (the user's file plus the block) instead of a link to the user's. The Settings install
buttons are gone: Port42's sessions get what they need per session, and an already-installed block
is still refreshed at launch, now identical from every instance. Gates in
`MultiInstanceInstructionsTests`, each calibrated by removing its fix. Verified live 2026-09-26 with prod
(4242), Dev3 (4245) and Dev4 (4246) running: Dev4's launch left both global files byte-identical,
Dev4's Codex home holds its own AGENTS.md, and a Codex session in Dev4 answered `whoami` through the
file's curl as its own companion in its own space.

**Done 2026-09-26: a write reloads a port only when it must.** `port.update`, `port.patch` and
`port.restore` all reloaded, even for identical HTML, throwing away a paused animation or a drawn
canvas. Now identical HTML does nothing (no reload, no version); a change confined to `<style>` is
applied in place; any other change is sent to the page as a cancelable `port42:update` event with
the new HTML, and a page that applies it itself (`preventDefault()`) keeps its state; otherwise it
reloads. Each write returns `applied` (unchanged, styles, handledByPage, reloaded), and the port
manual teaches the event. Gates in `PortLiveUpdateTests`, in a real web view, calibrated both ways
(every write reloading, no write reloading).

**Future optimization (GM, 2026-09-25): HTML from a shared buffer.** Agents now always write a port's
HTML to a file and build the request from it with `jq`, which removes shell quoting but still sends
the HTML through JSON. A write that names a local file or a shared buffer Port42 reads directly
(`port.update {id, html_file}`) would skip the encoding, the copy and the size limits.

## Test plan

Three layers, as in every phase: automated gates run by every build, the harness against a live
instance, and what GM checks by hand. Every automated gate is calibrated by breaking the code it
guards and watching it fail.

| Step | Automated (Swift and Go, every build) | Harness (live, Dev3) | GM by hand |
|---|---|---|---|
| 3.0 | none; it is a measurement | the off-screen table: rate, latency, frames, tiled vs resting space vs parked vs hidden | nothing |
| 3.2 | hidden in no desktop, rail or dock set (source scan); show and hide round-trip; restart and reopen keep it hidden; `ports.list` says hidden; a refused port write carries `code` and `current` | a hidden transform stage in scenario 3 | finds hidden ports in ⌘K and the count; shows then hides one |
| 3.3 | the wake queue alone: one event wakes once after the gather; five during a turn arrive as one; a set floor holds; the ceiling pauses and reports; resume works. In the app: a watched kind wakes, `terminal.output` and unnamed kinds do not, the watcher's own write does not, unwatch stops, a watch survives restart, deleting the port removes it | a hidden companion woken by one event and answering in the port's chat; a burst of five giving two replies, not six; wakes per hour logged | watches an agent react to a port's event in that port's chat |
| 3.7 | no preset left; no stored field without a reader (source scan); hidden and port-scoped companions created as chosen; the secrets gate refuses a terminal companion a secret it was not given | a companion created hidden and one created for a port, each answering | creates companions from the card with each choice |
| all | suite green | five of five, with scenario 3 extended | the verify below |

## Verify, live on Dev3

The harness passes five of five with the extended scenario 3. GM watches a hidden agent react to a
port's event in that port's chat, finds the hidden ports in ⌘K, and shows then hides one.

## Not in this phase

- Remote subscribers and remote watches (Phase 4).
- REST reaching the gateway from a port, the field report's containment finding, which belongs with
  Phase 4's read scoping.
- Bridge proxies firing phantom calls when coerced to a string (a small fix, taken whenever the
  bridge is next touched).
- Retiring the NDJSON headless companion. Once a hidden terminal companion covers headless agents
  (3.2), the separate stdio protocol serves no scenario and is a candidate for removal.
- The Codex risk dialog after a rebuild: a restarted Codex companion waits on it and swallows every
  message until someone accepts. To identify and fix alongside 3.2, since hidden companions cannot
  show a dialog to anyone.
