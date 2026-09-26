# Golden eval set

A fixed set of agent tasks, run the same way every time, so two versions of Port42 (two briefs, two
builds, two sets of skills) can be compared on outcome and cost. Created 2026-09-26 (GM). Not yet run.

## Why

A one-off comparison of two team runs on 2026-09-26 gave three different token answers in an hour,
each one wrong in a new way: the runs did different amounts of work (4 versions against 11), and the
Codex accounting double-counted a linked folder and counted other agents' sessions that mentioned the
engineer's name. The eval set removes both: the work is fixed per task, and the accounting is one
tested module.

## What it measures

Per run: whether every check passed, wall time from the ask to the end condition, versions of the
port, and tokens per agent (fresh input, cache read, cache write, output, model calls, session
files). `compare.py` reports per task and CLI the pass rate and the medians of wall time, total
tokens and tokens per version, B against A.

Tokens are a count, not a cost: most input is cache reads, which are billed at a fraction of fresh
input.

## The tasks (`scripts/evals/golden.json`)

| Task | Agents | Fixed work | Checks |
|---|---|---|---|
| make-counter | one, claude or codex | one small web port, one version | exists, 1 or 2 versions, console clean, has the button |
| patch-heading | one | one minimal edit to a given port | 2 or 3 versions, new text present, old gone, paragraph untouched, console clean |
| fix-error | one | fix a given port that throws | console clean, says "ready", at most 4 versions |
| pipe | one | three ports, the middle one hidden | source exists, middle hidden, view shows a multiple of ten, console clean |
| watch-fix | one | watch a port, fix it when it breaks | watching, console clean after the break, content intact |
| duo-review | claude maker, codex reviewer | v1 and exactly one improvement | 2 or 3 versions, console clean, both spoke in the port's chat |
| team-three | claude lead, claude and codex engineers | exactly three versions | 3 or 4 versions, console clean, all three spoke, one port |
| imagine | the team `imagine.start` makes | a fixed line, budget of three versions | 1 to 3 versions, console clean, all three spoke, one port |

Solo tasks run once per CLI (claude and codex); mixed ones as written: 13 variants in all. Agents are
made hidden with `companions.create` in a space of their own, and asked in the space's chat as a person
would ask them. The `imagine` task is the exception: `imagine.start` makes the space, the visible team
and the brief, exactly as ⌘I does, and the run reads the names and title it returns.

## How to run it (not yet run)

On a dev instance only (port 4242 is refused), with a client token for that instance:

    scripts/evals/run_evals.py                                  # the plan; touches nothing
    P42_TOKEN_FILE=~/.port42/port42dev4/tokens/nautilus-prime \
        scripts/evals/run_evals.py --port 4246 --label skills --repeat 3 --run
    scripts/evals/compare.py scripts/evals/results/A.jsonl scripts/evals/results/B.jsonl

`--task` and `--cli` narrow it. Each run leaves its space and ports in place to inspect. Results go to
`scripts/evals/results/` (not committed).

To compare against the brief before Phase 5 (label `old-brief`), build a dev instance from a commit
before `8da4704` and run the same set against it.

Three repetitions per variant is the least that makes a median mean anything; the full set at three
repetitions is 39 runs of real agent work.

## The accounting (`scripts/evals/usage.py`)

An agent's own session files come from the instance's log, where the app records the transcript path
at the end of every turn, tagged with the agent's name; paths are resolved through links and counted
once. Claude: the sum of `usage` over every assistant record. Codex: each resumed session is a new
file with its own running total, so the last total of each file, summed. `test_usage.py` pins all of
it, calibrated against both mistakes above (`python3 -m unittest scripts/evals/test_usage.py`).

The log is a dev instance's (`~/port42-build/<instance>.log`); prod does not write one, which is one
more reason evals run on a dev instance.
