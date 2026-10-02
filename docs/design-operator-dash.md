# Design: the operator dash

Agreed, 2026-09-28 (GM: go build it). GM asked for one place to steer Port42 at a high level: dev and growth, with the
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

**Everything runs through the issues board; features are the dev lead's.** (GM, 2026-09-29; before
this, features stayed off the board.) The squad's playbooks are built for issues, so the squad keeps
issues. Features go on the board as cards assigned to the dev lead, with auto-dispatch off: one is
picked up when GM chooses it, planned, built after GM's go, and moved to resolved with its commits. A
bug the dev lead fixes outside the squad is filed there as resolved too, in a batch at each release.
The dash still shows what needs GM; the board is the full record.

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
| `options` | For an item waiting on GM: the choices, each a few words ("Hold until measured"). Each is a button on the dash |
| `open` | Optional: the id or title of the port where the work lives (the Drafts desk), for an "open" button |
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

Items are kept on the machine-wide shared board (`storage.set` with `scope: "global", shared: true`),
one key per item, `dash:item:<id>`, with an `owner` field holding the lead's @mention. The machine-wide
board lets growth's working-space companions write their own items too. It is readable by anything on
this Mac (APP-20); these are plans, not secrets. (The operator space's own bucket was the first choice;
a companion's terminal cannot write it until APP-15 binds its calls to its space: `release-1.0.2.md`.)

Built 2026-09-28: the `operator` port in `port42-app` reads the board every 20 seconds.

**Shared, the dash shows a snapshot.** A copy on another machine (a shared tile, a browser guest)
reaches only the port's own storage, never the machine-wide board, by design (`RemoteAccess`). So the
dash on this Mac writes the board it read to its own key `dash:snapshot` on every refresh, and a copy
that cannot read the board reads that, marked "as of" its time. It is only as fresh as the dash last
open on this Mac. The decide and discuss buttons post to the operator space's chat, which a guest of
the port alone cannot reach.

**Hand-offs across areas are told, not assumed.** When one area finishes something another depends
on, its lead posts to the other lead in the operator space: a dev release to growth (its Releases entry
and site sync), a launch date to dev (a build to have out by then). The standing case, a release, is
in the release steps in `CLAUDE.md`.

## What the dash shows

1. **Needs you.** Every item waiting on GM, soonest `due` first, then oldest: the ask, the options, which lead owns it.
   This is the top of the page and the reason to open it.
2. **Deliberate.** Features and moments by state, dev and growth side by side: what is proposed,
   being discussed, decided, being built.
3. **Autopilot.** One line per lane: running, stalled or idle, and its progress. A stalled lane moves
   up to "needs you" only if its lead sets `waitingOn: gm`.
4. **Shipped lately.** The last few items shipped, with their `result` once known.

Each "needs you" item has up to three actions:
- **An option button** per choice in `options`. Clicking one posts GM's decision in the operator space's
  chat with an @mention of the owning lead ("Gordon decided on dev-relay-cap: Hold until measured"). The
  lead acts on it and records it on the item, which then leaves "needs you". Deciding is one click; the
  lead still keeps the record.
- **Open**, when the item names a port in `open`: the dash focuses it. A port in another space may be
  out of the dash's reach; the dash then says where it is.
- **Discuss**, the fallback: an @mention of the lead with the item's id, to talk it through in chat.

## Starting data

- **Dev deliberate:** every open item of the later list (`plan-shell-only.md`), each as a `dev-*` item
  (Gordon, 2026-10-02: the dash is the whole list, not only "Next up"). A new later-list item goes on the
  dash when it is written down.
- **Dev autopilot:** the squad's 1.0.2 batch, from `port42-issues`.
- **Dev waiting on GM today:** nothing. The relay rate cap (#122) is deferred (Gordon, 2026-09-30).
- **Growth** (lucky-ibis, 2026-09-28). Autopilot lanes: content (the Drafts desk in `port42-growth`),
  publishing, the site following releases, moments, desk upkeep. Deliberate: the Product Hunt launch
  (Tuesday 2026-09-29, 12:01am PT), the flagged Show HN, the protocol RFC, auto-publish on approval,
  retiring the old Drafts in `port42-app`, the horizon essay. The Download-latest item is resolved:
  the relay workflow marks its releases `--latest=false`, and v1.0.1 is Latest.

## Not in this version

- The dash reading working spaces directly.
- Areas beyond dev and growth. The record takes any `area`, so one can be added.

## For GM to confirm

1. The two levels and the two modes as described.
2. That leads update the dash (not the dash scraping sources).
3. The four sections, with "needs you" at the top.
4. The growth side: lucky-ibis has read it, and its four changes are in (a count for streams of
   approvals, `due`, `result`, free-text `waitingOn` with `blockedBy`).
