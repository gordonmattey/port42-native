# Plan: bring running sessions into Port42 in one click

Asked by GM on 2026-09-26: at first run, where the person picks the agent, offer to bring every
running Claude Code and Codex session into Port42 in one click, choosing which sessions share a
space. Draft for GM's review; nothing is built. Product idea; demand unvalidated.

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
- Each goes into a space named after its project by default, so sessions in the same repository
  land together. A row's space can be changed to any other row's space or to a new name, which is
  how the person groups them.
- One button brings the ticked ones in: each becomes a terminal port in its space, resuming its
  session as a fork, and a companion named after its project and branch, so it can be @mentioned.
- The originals are left alone. A line says they can be closed.
- The same list is a ⌘K action, "Bring in running sessions", for after first run.

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
2. **Group:** the default space per session and regrouping, pure, tested.
3. **Bring in:** one method, `sessions.import {sessions: [{id, cli, cwd, space}]}`, that makes the
   spaces, the terminal ports resuming as forks, and the companions. Tested headless (the fork
   command each port starts, the spaces, the companions); one live import on a dev instance.
4. **The first-run step** and the ⌘K action, both calling step 3.

## Not in this plan

Sessions on another machine, sessions of other CLIs, and moving (quitting the original).
