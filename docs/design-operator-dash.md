# Design: the operator dash

Draft, 2026-09-28. GM asked for one place to steer Port42 at a high level: dev and growth, with the
routine running itself and the new or major work getting reasoned through. This is the design to
agree before building. Status: draft; the growth side is to be confirmed with lucky-ibis.

## The two levels

| Level | Dev | Growth |
|---|---|---|
| **Operator** (this space, `port42-app`): where GM steers | The dev lead (this session): features, releases, priorities, decisions | The growth lead (lucky-ibis): growth direction, moments such as a launch |
| **Working spaces**: where the detailed work runs | `port42-issues`: the squad fixes issues on a playbook | The growth space: content production on a cadence |

The dash is a port in the operator space. It shows both areas at a high level. The working spaces carry
on as they are.

## Two modes of work

- **Autopilot.** Work with a playbook: the squad's issue fixes, growth's content production. It runs
  without GM. The dash reports it, and raises it only when it stalls or needs a call.
- **Deliberate.** New things and major changes: features, a launch moment. These need reasoning, a
  plan and GM's decision before anyone builds, and they are discussed in chat, not run from a playbook.

**Features never go to the issues board.** The squad's board and playbooks are built for issues and
cannot handle new features (GM). A feature is discussed and decided at the operator level, then built
by the dev lead or by a session or team spun up for it; the squad takes the bugs it produces later, as
issues.

Discussion happens where it already happens: dev in the dev lead's chat, growth in lucky-ibis's. There
is no chat per item. When GM wants to drive several things in tandem, an item can be spun out to its own
session, and the item records where it went. That is the exception.

## Items

Each deliberate item, and each autopilot lane's summary, is one record:

| Field | Meaning |
|---|---|
| `id` | Short and stable, e.g. `dev-pairing`, `growth-tuesday-launch` |
| `area` | `dev` or `growth` |
| `mode` | `deliberate` or `autopilot` |
| `title` | One line |
| `state` | Deliberate: `proposed`, `discussing`, `decided`, `building`, `shipped`, `dropped`. Autopilot: `running`, `stalled`, `idle` |
| `waitingOn` | Free text: who or what it waits on (a lead, the HN moderators, Product Hunt), with `gm` as the special value that puts it in "needs you" |
| `blockedBy` | Another item's `id`, for a wait across areas (a growth item waiting on a dev change) |
| `due` | When it must happen, for anything with a date (a launch) |
| `ask` | When `waitingOn` is `gm`: the decision needed, in one sentence, with the options |
| `decision` | Once decided: what, and when |
| `where` | Where it is discussed or run: a chat, a spun-out session, a working space |
| `next` | The next concrete step |
| `result` | After `shipped`, what came of it (rank, signups, downloads): for growth, shipping is not the end |
| `updated` | When the record last changed |

For an autopilot lane, `title` is the lane ("Issues: 1.0.2 batch", "Content: weekly posts"), `next` is
its progress in one line ("APP-05 verified, NAU-02 in progress"), and `waitingOn` is set only when it
needs GM. A lane with a stream of small approvals says so with a count ("3 posts waiting on the desk")
rather than one item per approval: the approvals stay on the growth desk, and "needs you" gets one line.

## Who writes what

Each lead keeps its own area current. The dash writes nothing on its own. A lead updates an item when
its state changes, when a decision is made (wherever it was discussed), and at the end of a working
session. The squad and the growth space are summarized by their lead, not read raw, so the dash stays
high level.

Items are kept in the operator space's shared storage (`storage.set` with `shared: true`), one key
per item (`item:<id>`). The dash port and both leads live in that space and can read them. That
bucket is readable by anything in the space (APP-20); these are plans, not secrets.

## What the dash shows

1. **Needs you.** Every item waiting on GM, soonest `due` first, then oldest: the ask, the options, which lead owns it.
   This is the top of the page and the reason to open it.
2. **Deliberate.** Features and moments by state, dev and growth side by side: what is proposed,
   being discussed, decided, being built.
3. **Autopilot.** One line per lane: running, stalled or idle, and its progress. A stalled lane moves
   up to "needs you" only if its lead sets `waitingOn: gm`.
4. **Shipped lately.** The last few items shipped, with their `result` once known.

Clicking an item's owner posts in the operator space's chat with an @mention of that lead and the
item's id, so "let's talk about this" is one click and the conversation stays where it belongs.

## Starting data

- **Dev deliberate:** the "Next up" group of the later list (`plan-shell-only.md`): sessions surviving a
  restart, pairing and scoped tokens, Codex tools, the relay rate cap, and so on. The rest of the
  later list stays in the doc until one is picked up.
- **Dev autopilot:** the squad's 1.0.2 batch, from `port42-issues`.
- **Dev waiting on GM today:** the relay rate cap (#122).
- **Growth** (lucky-ibis, 2026-09-28). Autopilot lanes: content (the Drafts desk in `port42-growth`),
  publishing, the site following releases, moments, desk upkeep. Deliberate: the Product Hunt launch
  (Tuesday 2026-09-29, 12:01am PT), the flagged Show HN, the protocol RFC, auto-publish on approval,
  retiring the old Drafts in `port42-app`, the horizon essay. The Download-latest item is resolved:
  the relay workflow marks its releases `--latest=false`, and v1.0.1 is Latest.

## Not in this version

- The dash reading working spaces directly.
- Decisions made by buttons on the dash. Decisions are made in chat, and recorded by the lead.
- Areas beyond dev and growth. The record takes any `area`, so one can be added.

## For GM to confirm

1. The two levels and the two modes as described.
2. That leads update the dash (not the dash scraping sources).
3. The four sections, with "needs you" at the top.
4. The growth side: lucky-ibis has read it, and its four changes are in (a count for streams of
   approvals, `due`, `result`, free-text `waitingOn` with `blockedBy`).
