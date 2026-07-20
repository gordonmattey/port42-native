# Plan: per-space working directory + unique command-companion sessions

*2026-07-20, branch shell-s1. Status: DECISIONS LOCKED (GM), no code. Fixes the `.command` companion
reply-post bug (root cause + evidence in `summer2026-todo.md`: all command companions default to
cwd `/Users/gordon`, claude 2.x keys its transcript on project=cwd, so they share one stale
transcript; the reply on screen is never in the file the Stop hook reports). Test in Port42Dev
only. Gate discipline: an item is not touched until its gate test exists and is recorded failing.*

## The bug in one line

`.command` companions share a transcript because they share a cwd (home); the shim reads the wrong
file and posts empty or stale. `.llm` companions have no cwd/transcript and are unaffected.

## Decisions locked (GM, 2026-07-20)

1. **Working directory is USER-PICKED per space.** The space carries a working dir the user chooses;
   it is not auto-located under a convention. Sub-decision for step 1: when unset, command
   companions fall back to today's behavior (home) but the UI nudges the user to pick one — no
   silent auto-dir.
2. **A command companion's cwd defaults to the space dir** (the port-level `cwd` override on
   `port.create` stays as the escape hatch). One change: the default in `spawnNativeTerminalPort`
   stops being home.
3. **Unique claude session id per command port** ("yes probably" — do it, pending the step-0
   blocker). This is what isolates two companions that SHARE the space dir (the intended model:
   companions collaborate on the same files, but each has its own conversation). Injected via the
   shim's `claude()` shell-function.
4. **Nothing for `.llm` companions.** No cwd, no transcript, no change.

## The model

Space dir = the shared workspace (companions work on the same files). Session id = what isolates
each companion's conversation. This beats per-port subdirs, which would stop companions
collaborating. Confirmed tonight: distinct DIRS give distinct transcripts. NOT yet confirmed:
distinct SESSION IDS in the SAME dir give distinct transcripts — that is the blocker.

## The matrix

| # | Item | Gate (recorded failing before code) | Notes |
|---|---|---|---|
| 0 | **BLOCKER — verify session-id isolation.** Two `claude` terminals in the SAME cwd, each pinned a distinct `--session-id` via the shim, must get DISTINCT transcript paths (read the instrument: `[hooks] turnComplete: transcript=… sid=…`). | Manual live probe in Dev, documented result. If distinct → the shared-space-dir + session-id model holds. If NOT → fall back to per-port subdir isolation (revisit decision 3/model). | No commit; a spike. Uses tonight's shim instrument. Everything downstream depends on the answer. |
| 1 | **Space carries a user-picked working dir.** `Space` gets an optional `workingDirectory`; a Settings affordance to pick it (NSOpenPanel, directory). Unset = home fallback + a nudge. | `SpaceModelTests` / a new suite: a space round-trips its workingDirectory through the DB; unset resolves to the home fallback. Recorded failing (field absent). | New migration (append-only). |
| 2 | **Command companion cwd defaults to the space dir.** `spawnNativeTerminalPort` resolves cwd = explicit override ?? space.workingDirectory ?? home. | Unit on the resolution helper: override wins; else space dir; else home. Recorded failing. | The port-level `cwd` override already exists. |
| 3 | **Unique session id per command port** (gated on step 0 = yes). The shim pins a per-port session id so same-dir companions don't collapse. | Live: two command companions in one space (shared dir) get distinct transcripts + both post their own reply. Plus a unit on the id-derivation if any lands app-side. | Depends on step 0. |
| 4 | **Live acceptance + close-out.** | Two command companions in one space, driven from chat, each replies correctly (no empty, no stale, no cross-talk). The join-instructions name collision is gone (cwd ≠ home → `basename $PWD` ≠ "gordon"). Docs updated. | Closes the summer-todo bug + the join-prompt collision. |

## Sequencing

0 (blocker spike) → then 1 → 2 → 3 → 4. Step 0 decides whether 3 is "pin a session id" or "per-port
subdir." Do NOT build 1–3 before step 0 answers.

## Files (expected)

`Sources/Port42Lib/Models/Space.swift` (+ field), `DatabaseService.swift` (+ migration),
`AppState.swift` (`spawnNativeTerminalPort` cwd resolution), the shim launch path / `claude()`
shell-function (session-id pin), a Settings view for the picker. Tests as above.

## Out of scope (separate todo items, do not fold in)

- Auto-registering an ad-hoc `claude` terminal port as a space companion (depends on this landing).
- The join-instructions generator itself (external tool, not in this repo) — this fix removes the
  name collision at the source (cwd), but the prompt text lives elsewhere.
