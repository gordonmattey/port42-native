# /imagine: one line to a briefed team

Detailed plan for `/imagine`, moved from the roadmap into the release's scope (GM, 2026-09-26). Draft
for GM's review, written against `nautilus` at `0ce34a5`; approved by GM with the recommended defaults.
Product idea; whether people want it is unvalidated.

**Status:** Done (GM, 2026-09-26). I.1 to I.5 built and verified live on Dev4: run 5 passed all twelve checks, and run 6 moved the work into the port's chat. GM is trying it by hand.

## Goal

A person types one line, "/imagine a shader that reacts to music", and gets a space with a small team
of agents that builds it: a lead who sets the vision and two engineers who build it in rounds, in the
port's chat, until the lead reports DONE. The person watches and talks to the team in the same chats;
the team is ordinary companions from the start.

## What changes, for a person

- **⌘I opens a quick imagine box** (like ⌘K): type the line, Enter, and the team starts. In a chat,
  a line starting `/imagine` does the same. Both run one path.
- **A new space appears**, named from the line, with its team in it and a first post from Port42
  saying what it asked for. The port shows up as soon as the first version exists.
- **You follow it in the space's chat** (the lead's one-line updates) and the port's chat (the work),
  and can join in by @mentioning any of them.
- **It stops on its own** at DONE or at its version budget. There is no stop command: the team is
  ordinary companions, and its terminals are never closed by /imagine.

## What exists today (measured)

Everything except the trigger and the brief. `companions.create` makes a Claude or Codex companion,
hidden or in a port, in a space; a chat post with @mentions starts it; messages wait for its CLI to be
ready; replies land in the chat they came from; the team skill teaches hand-offs, exact names and one
port per title; `scripts/scenarios/team.py` has run a lead and two engineers to DONE several times
(a starfield, a shader: 4 to 11 versions, 6 to 14 minutes). Two team runs on 2026-09-26 measured about
1.1 to 1.3 million tokens per version shipped, and without a version limit a lead kept improving (11
versions where the baseline stopped at 4).

## Decisions for GM

1. **Port42 writes no brief with a model (recommended).** The kernel runs no model (D9). The brief is a
   fixed template around the person's line, and the lead, which is a model, turns the line into a
   vision as its first job. The template carries what the team runs taught: the roles, one port, work
   in its chat, check each version, the version budget, DONE.
2. **The team: a lead and two engineers, one of them Codex when Codex is installed (recommended).**
   Lead Claude, engineer Claude, engineer Codex, as in every team run so far; Claude alone when Codex
   is not installed. Named with codenames, like any companion.
3. **A version budget, not rounds (5, raised to 10 by GM on 2026-09-26).** Rounds let a lead decide how much a round holds;
   a budget of versions bounds the work, and so the tokens, whatever the lead decides. The lead is told
   the number and reports DONE by it. `/imagine` takes an optional `--versions N`.
4. **The agents run visible (decided, GM 2026-09-26).** Three terminals on the new space's desktop,
   so each can be watched and typed into.
5. **After DONE the team stays, idle.** You can keep asking it for changes in the port's chat.
   **Changed (GM, 2026-09-26): /imagine is a bootstrap, and there is no stop.** It makes the space, the
   companions and the brief and gets out of the way; the team is then ordinary companions, managed
   like any other. Nothing in /imagine closes a terminal or removes a companion, ever. The version
   budget stays, as the one guard on token spend.
6. **Where it is typed: ⌘I and any chat (decided, GM 2026-09-26).** ⌘I opens a quick imagine box,
   like ⌘K. In any chat input, `/imagine` is a slash command, parsed before posting, so the line never
   reaches other agents as a message.
7. **Roles live in each agent's own system prompt (recommended).** Given with `companions.create`'s
   `prompt`, so a role holds for the whole session, not only the first message; the brief starts the
   work. Drafts below.

## The texts (drafts)

**Lead's role:** You lead an imagine team. You own the vision and the version budget. You do not build:
you set the vision, split the work between your engineers so they never edit the same part, check each
version works (its console and DOM), and decide the next step. Work in the port's chat; answer the
person in the space's chat in one line. Stop at DONE.

**Engineer's role:** You are an engineer on an imagine team led by @{lead}. Build what the lead gives
you in the port, only your part. Check it works before you say so, then report in the port's chat to
@{lead}: what you changed and what you checked.

**The brief** (to the lead, in the space's chat):

> @{lead} /imagine from {person}: "{line}"
> You lead @{eng1} and @{eng2}. Make one web port titled '{title}' that realizes this, in at most {N}
> versions.
> 1. Reply here in one line saying what you are going for, then write the vision in 3 to 5 lines in
>    the port's chat.
> 2. Have @{eng1} make v1. For each later version, give both engineers concrete, non-overlapping next
>    steps toward the vision, check the result, and push further.
> 3. When the vision is met or the budget is spent, post in the port's chat a message that starts
>    with DONE and says what the port now is, and one line here.

The title is taken from the line, so the space and the port share a name; the line itself is passed
through verbatim.

## Steps

Each step is its own commit: suite green, harness five of five, plans updated.

### I.1 The brief

`Imagine.brief(line:names:versions:)`, pure: the template around the line, naming the lead and the
engineers by their generated names. Written from `team.py`'s brief and what the runs taught.

*Gates:* the brief names every agent with an @mention, states the budget, asks for DONE in the port's
chat and a one-line answer in the space's; a source scan keeps the line verbatim (never rewritten).

### I.2 Start a team

`imagine.start {line, versions?}` (and the slash command's parser): a space named from the line, the
team made with `companions.create` (visible, each with its role as its prompt, Codex only if installed), a Port42 post of what was asked,
then the brief to the lead. Returns the space, the names and the budget.

*Gates:* the space and the three companions exist and belong to it; without Codex installed the team
is Claude only; the first post is the person's line; the lead is asked once.

*Done.* `AppState.startImagine` (Imagine.swift) and `imagine.start`, homed in the `port42-team` skill.
The brief is posted as the person, so the space's first post carries their line verbatim and asks the
lead once. The team is saved in `imagine_teams` (migration v55) for the budget.

### I.3 The budget (stop removed)

The version budget is enforced by the app, not only asked for: past it, the lead is told the budget is
spent and the team's further writes to the port are refused with a clear error.

*Gates:* a write past the budget is refused with its own code; the lead is told; nothing in /imagine
closes a terminal or removes a companion.

*Done, then stop removed.* `imagine.stop` was built and then taken out when /imagine became a
bootstrap (decision 5); a test now holds that /imagine never closes a terminal or removes a
companion, and a bare `/imagine stop` is plain text. The budget counts versions of the port being
written: a `port.update` or `port.patch` by a member of the team, to a port in its space that
already has `versions` versions, is refused with `budget_spent` before its token moves. When the
team's write that reaches the budget lands, Port42 tells the lead in the port's chat. The person's
own writes are never refused.

Added beyond the plan: `imagine.budget {space, versions}` (and `/imagine --versions N` with no line),
because decision 5 keeps the team for later changes and a spent budget would otherwise refuse them.

Known flake, not from this step: "stuck: the person is told..." (StartupPromptTests) failed once in
three full-suite runs (the stuck notice never came in 20s) and passed in isolation and alongside the
delivery tests six times. Not root-caused yet.

### I.4 ⌘I and the slash command

⌘I opens a quick imagine box (a line and Enter, like ⌘K). `/imagine <line>`, `/imagine --versions N
<line>` and `/imagine --versions N` typed into any chat run the same methods instead of posting. Anything else
starting with `/` still posts as text.

*Gates:* the parser (line, budget, stop, and text that only looks like a command); the input runs the
command and posts nothing to agents.

*Done.* ⌘I is a shell-global chord (and a menu item under File) that opens `ImagineBox`, which takes a
bare line or a whole `/imagine` command through the same parser. Every chat input (the space's chat
and each port's) sends through `AppState.submitChatInput`, which runs `/imagine`, `/imagine --versions
N` instead of posting (and a bare `/imagine stop`, since stop was removed, posts as text); the budget acts on the chat's space (a port's chat
belongs to its port's space). A command that fails leaves the text in the input with the error.

### I.5 Verify

The harness gains `imagine`: `/imagine` with a fixed line and `--versions 3`, to DONE; the golden eval
set gains it as a task. GM tries it from the space's chat.

*Gates:* the harness run reaches DONE within the budget with one port, no console errors, and every
agent speaking; five of five.

*Built.* `scripts/scenarios/imagine.py` (calls `imagine.start`, watches to DONE, checks the budget, one
port, every agent, the console and the lead's answer, then stops the team and checks the port stays)
and the `imagine` task in the golden eval set (`run_evals.py` reads the team from `imagine.start`).
The run tag goes first in the fixed line, since the title keeps 60 characters.

*What the live runs on Dev4 found, all fixed with tests:*

- The brief @mentioned both engineers, so all three received it and the Codex engineer, first to
  start, wrote the vision. The brief now @mentions only the lead and names the engineers plainly.
  This changes the approved template's wording in two places.
- Port42's own notices (a CLI at a startup prompt) reached every member of the chat. They now reach
  only whom they @mention; the budget notice still reaches the lead.
- A stopped team came back through a teammate's @mention. Moot now: there is no stop.
- A v1 passed on a clean console and a full DOM while its canvas drew nothing (a NaN in its steering,
  from a pointer move over a zero-size tile; reproduced). The lead's role now checks pixels, and an
  engineer ends every turn with a report to the lead, after a team waited on one whose turn ended
  with "will patch" and no report. The lead asks after a silent engineer.
- The lock screen's video froze the app at a switch between clips (`bfb1053`).
- The app went deaf to every call after a NaN was serialized on the main thread (`2afbe1c`).

Run 4 reached DONE in 372 s within its budget of 3, with the lead checking pixels, and exposed three
things, all addressed (GM, 2026-09-26):

- The team talked in the lead's terminal chat: the Codex engineer spoke first, unasked, by posting
  into the lead's terminal chat, and a reply goes to the chat that asked last. The skill, the roles
  and the brief now say to coordinate in the space's chat, use a port's chat when working on it
  together, and never post into another companion's terminal chat; the test script fails a run that
  does.
- Versions count writes, so v1 and two engineers' patches spent a budget of 3. The default is now 10.
- The startup-stuck detector fired for every slow-starting CLI, quoting spinner garbage. Removed.

Run 5 (budget 10) passed all twelve checks: DONE in 807 s, 10 versions, one port, a clean console,
every agent speaking, nobody in another's terminal chat, and the lead checking pixels. But every
exchange stayed in the space's chat: the port and its chat did not exist until v1, and replies go back
to the chat that asked. So **/imagine now makes the port at bootstrap** (a placeholder page titled from
the line, migration v56 records it), the brief names it by id and runs the versions in its chat
(`port42 chat.post port=<id>`), the vision and a line per version stay in the space's chat, and the
placeholder does not count against the budget. The test script checks that the engineers worked in
the port's chat.

Still to watch: messages typed into a starting Claude not submitted after three Enters (run 2 only).

## Test plan

| Step | Automated (every build) | Harness (live, Dev4) | GM by hand |
|---|---|---|---|
| I.1 | brief contents; line verbatim | none | reads a brief |
| I.2 | space, team and first post; Claude-only fallback | a team starts | none |
| I.3 | stop leaves port and chats; budget refused past N | stop mid-run | none |
| I.4 | parser; command posts nothing | none | types `/imagine` in a chat |
| I.5 | suite green | `imagine` to DONE in budget; five of five | watches one, stops one |

## Not in this plan

Choosing agents per role from the line, teams larger than three, and a team spanning machines (Phase 4
territory).
