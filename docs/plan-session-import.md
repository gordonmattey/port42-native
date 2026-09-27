# Plan: bring running sessions into Port42 in one click

Asked by GM on 2026-09-26: at first run, where the person picks the agent, offer to bring every
running Claude Code and Codex session into Port42 in one click, choosing which sessions share a
space. Approved by GM (2026-09-26). **Built** (steps 1 to 4); live import not yet run. Product idea; demand unvalidated.

## What exists

- `port42 teleport` brings one Claude Code session in: run from its directory, it finds the newest
  session there and opens a Port42 terminal that resumes it (`docs/plan-teleport.md`). Claude only.
- It resumes as a **fork**: a new session that starts with a copy of the transcript. The original
  keeps its own session file, so the outside terminal can stay open and the two never write the same
  file.
- Codex has the same two verbs: `codex resume <id>` and `codex fork <id>` (checked on this machine).
- The first-run agent step (`SetupView`) already finds which CLIs are installed and asks which one
  Echo runs on.

## What changes, for a person

At the agent step, under the CLI choice:

> **Bring your sessions in.** Port42 found 5 running sessions.
> ☑ claude · port42-native (nautilus) · "fix the gateway stall" · 3 min ago → space **port42-native**
> ☑ claude · port42-native (phase4) · "relay and invites" · 1 min ago → space **port42-native**
> ☑ codex · kynee-release · "release notes" · 12 min ago → space **kynee-release**
> ☐ claude · ~/scratch · 2 h ago → space **scratch**
> **[ Bring 3 sessions in ]**

- Each row is one running session: which CLI, the project (directory and branch), the session's own
  title or first request, and when it was last active.
- They are **grouped automatically**: one space per project (sessions in the same repository land
  together), shown as groups. The person **drags a session to another group** to move it, or onto
  "new space" to start one, and can rename a group (GM, 2026-09-26).
- One button brings the ticked ones in: each becomes a terminal port in its space, resuming its
  session as a fork, and a companion named after its project and branch, so it can be @mentioned.
- **It says it forks, before and after** (GM). Before: "Port42 opens a copy of each session with
  the whole conversation so far. Your original terminals are not touched." After: "N sessions are in
  Port42. Their originals are still open and will fall behind: close them now," with the list of
  originals (project, branch, CLI) to close. Port42 does not close them itself.
- The same list is a ⌘K action, "Bring in running sessions", for after first run.

## The screen (agreed with GM, 2026-09-26)

A step in the first-run setup terminal, right after the agent choice; no galaxy. The terminal widens
for it (520 to about 760).

```
> looking for agents already running on this Mac…
> found 5 sessions: 3 claude code, 2 codex

  # port42-native                                    ✎
    [x] claude   nautilus   "fix the gateway stall"      3m
    [x] claude   phase4     "relay and invites"          1m
  # kynee-release                                    ✎
    [x] codex    main       "release notes"             12m
  + new space  (drop a session here)
  ▸ older (2)

  port42 opens a copy of each, with the whole conversation.
  your terminals aren't touched.

  [ bring 3 in ↵ ]   skip
```

Drag a row onto a `#` heading to move it, onto `+ new space` to start one; ✎ renames. Sessions
active in the last day are ticked; older ones are collapsed and unticked. No sessions: no step.
After Enter each prints as it lands (`✓ port42-native  claude nautilus → @port42-native-nautilus`),
then "close the originals now, they'll fall behind" with each original's terminal app and path, and
`continue ↵` lands on echo in genesis, as a first run always does (GM, 2026-09-26); the imported sessions wait in their spaces. ⌘K "bring in running
sessions" opens the same list in a command box.

## What a fork is

Both CLIs have it. Claude: `claude --resume <id> --fork-session` (teleport already uses it,
`cli/main.go`); Codex: `codex fork <id>`. Each starts a new session, with a new id, that begins with
a copy of the whole conversation: every message and tool result, so the agent knows what it knew.
The original session's file is untouched. From then on the two diverge: work continues in Port42's
copy, and the original, if kept open, is out of date. Hence closing it.

## How it finds them

- **Running processes** of `claude` and `codex`, with each one's working directory.
- **Not Port42's own:** a process Port42 started carries its hooks (`--settings` naming a
  `port42-claude-shim`, or a `CODEX_HOME` inside a Port42 data directory) and is skipped.
- **Which session** each is running: an explicit `--resume`/`--session-id` in its arguments, else the
  newest transcript recorded for its directory (Claude's `~/.claude/projects`, read by `cwd` as
  teleport does; Codex's `~/.codex/sessions` by the `cwd` in each session's first record).
- **Title:** Claude's transcript records an `ai-title`; otherwise the first request, cut short.

## Decisions for GM

1. **Fork, not move (recommended).** The original keeps running and nothing it has is touched.
   Moving would mean quitting the person's terminals for them, which Port42 should not do.
2. **One space per project by default (recommended),** regrouped by picking a row's space.
3. **Imported sessions become companions (recommended),** so they can be @mentioned and join teams.
   Teleport today does not do this (`plan-teleport.md` §8); import should.
4. **Codex included from the start (recommended),** through `codex fork`. Its resume and fork
   behavior under Port42's Codex home has not been exercised yet; step 1 checks it.

## Steps

1. **Find:** a pure function from a process list and the two transcript folders to a list of
   sessions (CLI, directory, branch, session id, title, last active), skipping Port42's own. Tests on
   fake process lists and fake `~/.claude` and `~/.codex` trees. A one-off live check that
   `codex fork <id>` works under Port42's Codex home.
2. **Group:** the default space per session, moving a session between groups (what a drag does),
   renaming a group; pure, tested.
3. **Bring in:** one method, `sessions.import {sessions: [{id, cli, cwd, space}]}`, that makes the
   spaces, the terminal ports resuming as forks, and the companions. Tested headless (the fork
   command each port starts, the spaces, the companions); one live import on a dev instance.
4. **The first-run step** and the ⌘K action, both calling step 3: grouped rows with drag between
   groups, the fork note, and the "close these originals" list after import.

## Not in this plan

Sessions on another machine, sessions of other CLIs, and moving (quitting the original).

## Built (2026-09-26)

- **Find:** `SessionImport.find` over `ps`/`lsof` and the session logs; Port42's own sessions and CLI
  helpers skipped; checked read-only on GM's Mac (24 sessions).
- **Group:** `SessionImport.Selection` (one space per project, the last day ticked, move, new space,
  rename).
- **Bring in:** `AppState.importSessions`, `sessions.find` and `sessions.import` (terminal permission).
  Claude forks through the shim: `PORT42_FORK_FROM` forks the original INTO the terminal's pinned
  session on its first launch (`--resume <orig> --fork-session --session-id <pin>`, checked against the
  real CLI), and every later launch resumes the pin, so a restart never forks the original again. Codex
  runs `codex fork <id>` with the briefing as its first prompt (which is also what makes it report
  SessionStart); when it reports its new session, the companion and its stored terminal switch to
  `codex resume <new id>`. A companion's saved environment now reaches its terminal.
- **Screens:** the step in the setup terminal (widened to 780) after the agent choice, with the grouped
  list, drag between groups and onto "new space", rename, the fork note, then what came in and the
  originals to close, landing on the first imported session; the ⌘K action "bring in running sessions"
  with the same list in a command box.
- **Not yet:** window titles through AppleScript (matched on tty) for the close list; a live import.

