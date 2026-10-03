# Research spike: Claude Code mods as Port42's integration with Claude

**Ticket** #255. **Base** main at 3d008238. **Branch** spike/claude-mods. **Date** 2026-10-03.
Sources: the Claude Code mods documentation (code.claude.com/docs/en/plugins/mods: overview, api, reference),
the TypeScript declarations the engine wrote for this build (Claude Code 2.1.288), Port42's code on main, and
the measurements in `spikes/claude-mods/`.

## Question

A mod is a plugin whose JavaScript runs inside Claude Code and can watch, change or take over events: tool
calls, prompts, turns, commands and what the interface draws. Could Port42 integrate with Claude better through
one than it does today?

The answer settles it when it says, per thing Port42 needs from Claude, what it does now, what a mod would do,
what was observed to work, and what it costs.

## Decision needed

**Recommendation.** Yes, adopt it in steps, as a mod added beside today's settings hooks and the shim, behind a
version check, with today's path kept as the fallback. Order of value:

1. **Delivery of chat messages** with `$.prompt.submit` instead of typing into the terminal.
2. **Presence and the final reply** from `turn.start`, `turn.complete` (which carries the answer text) and
   `tool.check`, instead of one spawned process per hook.
3. **A live brief** through `prompt.compose`, so a change to the companion rules reaches running sessions.
4. Native tools (`$.tool.register`) for posting, asking and publishing, instead of shelling out to `port42`.

Do not build panes or a UI inside Claude for now. Port42's shell already is the surface.

**The one blocker.** Not technical. A mod is unsandboxed code that runs with the person's permissions and can
approve tool calls, so shipping one is a trust decision, and an organization can switch mods off.

**Needs Gordon.**
1. Is it acceptable to ship code that runs inside Claude Code with the person's permissions (Port42's own mod,
   in the app bundle), with the settings-hook path kept for anyone whose Claude is older than 2.1.287 or whose
   organization blocks mods?
2. Order: delivery first (largest effect on reliability), or presence first (smallest change)?

## 1. What a mod is

- **A plugin directory** with `.claude-plugin/plugin.json`, `hooks/hooks.json` naming one hooks module, and the
  module, which exports `register(on, options)` and adds handlers with `on(event, matcher?, hook)`. A handler is
  `($, e, next)`: observe, rewrite with `next({...e})`, or answer without `next`.
- **Loaded** by installing the plugin, or for one session with `--plugin-dir`. Port42 already passes
  `--plugin-dir` for its skills (`shim/main.go:169`), and that directory already has a
  `.claude-plugin/plugin.json` (`Sources/Port42Lib/Skills/port42-skills/`), so a mod needs two more files there,
  not a new mechanism.
- **Needs Claude Code 2.1.287 or later**, on by default. Runs in the CLI and the Desktop app's Code tab, and
  its hooks also run under `claude -p` and the Agent SDK, without drawing.
- **Events** (reference page): `tool.call`, `tool.check`, `prompt.submit`, `prompt.compose`, `prompt.section`,
  `turn.start`, `turn.step`, `turn.complete`, `session.start`, `session.end`, `session.receive`, `session.send`,
  `command.run`, `ui.render` (with sites such as `AskUserQuestion`, `Spinner`, `AbovePrompt`, `Pane`), and
  every existing settings hook as `classic.<Event>`, for example `classic.Notification`.
- **The `$` API:** `$.prompt.submit`, `$.http.fetch`, `$.process.run` and `spawn` (streamed output),
  `$.fs`, `$.env.get`, `$.store`, `$.clock.every` and `after`, `$.tool.register`, `$.command.register`,
  `$.model.complete`, `$.session.send`, `$.ui.*`, `$.mcp`.
- **Trust and control.** Mods run with the person's permissions, can read files and secrets, see every prompt and
  tool call, rewrite them, approve a tool call before the person is asked, and spend their usage. They are not
  sandboxed. `claude plugin validate` lists every event a mod handles and every `$` call it makes before it runs.
  Off switches: `/plugin` per mod, `--safe-mode`, `"disableAllHooks"`, and for an organization
  `allowManagedModsOnly`. The built-in table also implies Anthropic can turn installed mods off remotely.

## 2. How Port42 integrates with Claude today

| Need | Mechanism now | Evidence in the tree |
|---|---|---|
| Start Claude with Port42's wiring | A `claude` shell function (zsh through ZDOTDIR) and a PATH symlink call `port42-claude-shim`, which execs the real `claude` | `CLIHookProducerClaude.swift`, `shim/main.go` |
| Events from Claude | `--settings <json>` registers 8 settings hooks (`SessionStart`, `SessionEnd`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop`, `StopFailure`, `UserPromptSubmit`). Each one spawns `port42-claude-shim notify <event>`, which writes a normalized line to a unix socket | observed in a running Dev9 session's command line |
| The final reply | The `Stop` payload; the shim prefers `last_assistant_message` and falls back to polling the transcript file | `runNotify`, `lastAssistantTextWithRetry` |
| Messages to a companion | Typed into the terminal as keystrokes or one bracketed paste, held until the screen is quiet, with Enter timing | `TerminalWrite`, `heldUntilRunning`, `enterDelay`, `keysLimit` (15 references in all); defect 6 in `docs/defects-triage.md`: a wake typed 1.2 s after a turn ended was lost |
| Telling an injected line from the person's typing | A text rule: a `[@` prefix and `]: `, plus a list of the CLI's own tags | `ChatRouting.isInjectedLine`, `isCLIOwnLine` |
| "Waiting on the person" | The `Notification` hook, filtered for the idle nudge | `ChatPresence.isRealAsk` |
| The brief | `--append-system-prompt`, baked once per launch | `shim/main.go:200`, `AppState.bakeCompanionPrompt` |
| Calling Port42 from Claude | The `port42` command through Bash, with a token file | skills and brief |
| Resume | `--session-id` or `--resume` pinned by the shim | `sessionIDArgs` |

## 3. What a mod would do for each

| Need | With a mod | Basis |
|---|---|---|
| Messages in | `$.prompt.submit({ text, asUser })` waits until Claude is idle and starts the turn, so the quiet-screen and Enter timing logic is not needed. Its origin is `plugin`, so the text rule for injected lines goes. By default Claude prefixes "The `<mod>` plugin sent a message:"; `asUser: true` sends the text as it is. | Observed (section 4) that a timer submit starts a turn 62 ms later in the interactive UI. Not observed: a completed turn. |
| Final reply | `turn.complete` carries `answer`, `reason` (`answer`, `aborted`, `refusal`, `error`), duration and usage with the model. No transcript read. | Observed in `claude -p` |
| Presence | `turn.start` (with `turnId`), `tool.call` (the tool), `tool.check` (the decision, `ask` means a permission prompt is coming), `turn.complete`. In-process, so no spawned process. | Events observed except `tool.check` and `tool.call`, which were not exercised |
| Waiting on the person | `tool.check` deciding `ask`, the `AskUserQuestion` render site, `classic.Notification`: signals from the engine, not a filter over a nudge | Documented, not exercised |
| Live brief | `prompt.compose` and `prompt.section` rewrite the system prompt each request, so a change reaches a running session. Today a session keeps the brief it started with, for days (found in #245) | Documented |
| Tools | `$.tool.register` gives Claude `mcp__port42__post`, `ask`, `publish` with a schema and a direct result, instead of Bash and a CLI | Documented |
| Resume, session ids | Unchanged; these are launch flags | |
| Codex | No change. Mods are Claude only | |

## 4. What I measured

**The settings hook, per event.** One `port42-claude-shim notify toolStarting` run against a listening socket, 200 times
in a row: median 4.8 ms, 95th percentile 8.1 ms, worst 75 ms. Forty at once: 89 ms wall, 9 ms median each. The
machine's load average was 224. Every tool call raises two hooks (`PreToolUse` waits for it). **So the per-event
process cost is small and is not, by itself, a reason to move.**

**A probe mod** (`spikes/claude-mods/p42-mod/`) reporting events to a local server:
- `claude plugin validate` passes and prints `hooks:` and `calls:` lines. One rule matters for how a mod is
  written: `$` may be passed only to functions declared at the top level of the file. A helper defined inside
  `register` is refused.
- Loaded with `--plugin-dir` under `claude -p`, no prompt for approval appeared. Events arrived in order:
  `session.start`, `prompt.submit` (origin `sdk`), `turn.start`, `turn.complete` (`answer: "OK"`, reason
  `answer`, 1,717 ms, usage with the model), `session.end`.
- `$.http.fetch` to `127.0.0.1` returned in 2 to 12 ms. A hook's total time, fetch included, was 21 ms for
  `session.start` and 40 ms for `prompt.submit`. Hooks on the tool path block the tool until they return, so they
  have to stay small.
- **In the interactive UI** (a pty running `claude --plugin-dir`), a timer fired `$.prompt.submit` at +4,050 ms.
  A turn started 62 ms later with the text `The p42-probe plugin sent a message:` followed by the prompt, and the UI
  showed "Prompt from the p42-probe plugin". The turn then failed with "Login expired": my test harness has no
  interactive login, so **no completed turn from a submitted prompt was seen**. The `prompt.submit` hook did not
  fire for the plugin's own submission in that run.

## 5. Costs and risks

- **Version floor.** 2.1.287 or later, and Claude updates itself. A companion on an older Claude needs the
  settings-hook path, so both stay.
- **A second code path.** Two sources of the same events must not both write presence, or the roster flickers.
  The mod would be the source when it loads, and the settings hooks the source when it does not.
- **Policy and switches.** `allowManagedModsOnly`, `disableAllHooks`, `--safe-mode`, `--bare`, a per-mod disable in
  `/plugin`, and apparently a remote switch. Port42's mod can be off without Port42 knowing, unless the mod
  announces itself at `session.start` (the probe's first event shows it can).
- **Trust.** The mod runs with the person's permissions and could approve tool calls. Port42's must do none of
  that, and `claude plugin validate`'s `calls:` list is the review: it should name only `http.fetch`, `clock`,
  `prompt.submit`, `fs.read` and the like. A test can hold that list.
- **Authoring limits.** One hooks module file, `$` only through top-level functions, a 10 second limit per hook
  (not counting `next`), no Node and no timers of its own. A mod this size is a few hundred lines in one file.
- **Delivery needs a channel in.** A mod cannot listen. It would poll Port42's gateway with `$.clock.every` and
  `$.http.fetch`, or `$.process.spawn` a streaming command. Either needs the companion's token, read with
  `$.env.get` and `$.fs.read`. Neither was built.
- **Drift.** The documentation says the TypeScript declarations are the complete reference and the GitHub copy can
  lag the installed version. The version Port42 targets should be pinned in a test.
- **A hosted terminal.** Mods draw in the terminal surface, which is where Port42's Ghostty tile shows Claude, so a
  pane would appear there. Not recommended, since the shell already shows presence and chat.

## 6. Options

| | Option | Gain | Cost |
|---|---|---|---|
| A | Keep the shim and settings hooks | Nothing to build | Typed delivery stays fragile; briefs stay old for days; heuristics stay |
| B | Mod beside them, in steps (recommended) | Delivery, a live brief and exact presence, with a fallback | A second path, a version check, a trust decision |
| C | Replace the settings hooks entirely | One path | Breaks older Claude, blocked mods and any session where the mod fails to load |

## 7. Not verified

- **A completed turn from `$.prompt.submit` in the interactive UI** (blocked by login in my harness), and whether
  typed delivery or submit is more reliable under load. That comparison is the first thing a build spike runs.
- **`tool.check`, `tool.call` and `classic.Notification`** were registered and loaded but not triggered, because the
  one permitted test run had no tools.
- **What the person sees** when a mod loads for the first time in a fresh interactive session. No dialog appeared in
  the `-p` run.
- **Whether a mod can import another file.** The validator named one hooks module.
- **The remote switch** is inferred from one table row in the documentation, not confirmed.
- **Resume with a mod**, an organization's managed settings, and Claude's Desktop app were not tried.
- **Dev9 was not used.** Nothing in the app changed; the work was in `claude` directly. Port42's code was read, not
  built or run.

## Work items (to file once Gordon passes this)

1. **Feature, dev lead:** a Port42 mod in the skills plugin directory that reports `session.start`, `turn.start`,
   `turn.complete` (with `answer`) and `tool.check` to the app, with the settings hooks kept as the fallback and a
   version check.
2. **Feature, dev lead:** deliver chat messages with `$.prompt.submit` when the mod is loaded, typing as the fallback.
3. **Issue, tracer:** measure typed delivery against `$.prompt.submit` over a hundred wakes on Dev9, loaded and idle,
   with a real login.
4. **Issue, scribe:** the companion brief and the `port42` skill say how a session is told which path delivered a
   message, once item 2 lands.

## Reproduce

    claude plugin validate spikes/claude-mods/p42-mod
    python3 spikes/claude-mods/logger.py &            # collects the events
    cd /tmp && claude -p --plugin-dir <repo>/spikes/claude-mods/p42-mod --setting-sources "" --tools "" "Reply with the single word OK."
    python3 spikes/claude-mods/shimcost.py             # the settings-hook cost
    python3 spikes/claude-mods/pty_run.py 40           # the interactive submit; needs a real login to finish a turn
