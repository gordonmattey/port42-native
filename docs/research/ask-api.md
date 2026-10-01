# Spec: Ask, the API and the substrate

**Ticket** #241. **Base** main at 4d204efb. **Branch** spike/ask-api. **Date** 2026-10-01.
**Replaces** `docs/spec-ask.md` at d7550429 (branch echo/friction-log, drafted by echo), on Gordon's
instruction that Ask be decoupled from the UX: API and substrate only. Nothing here is built.

## Question

What is the smallest durable record, API and event stream that lets one party ask another for something,
keep it open until it is answered or withdrawn, and wake the asker on the answer, so that any surface
(a shell list, the board, a notification, a script) can be built on it without the substrate knowing
about any of them?

The answer settles it when each method, field, state change, permission and failure is stated, and the
list of what a surface must build for itself is explicit.

## Decision needed

**Recommendation.** Build the record, four methods plus one stream, the events, and the permission rule
below as one feature. Every surface in the old spec (the list and count, the rail dot, the notification, the
board change, the catalog entry) becomes a consumer with its own card, built on this and not inside it.

**The one blocker.** The app side is Swift in main and needs an owner (the dev lead's column).

**Needs Gordon.**
1. Is a new right needed for acting as the person (section 4), or should it ride an existing permission?
2. The limits and retention in section 6 (25 open asks per asker, 2,000 characters, closed asks kept 30 days).
3. Confirm the principle in section 3: nothing closes an ask except `ask.answer` or `ask.withdraw`. A reply in
   a chat does not.

## What changed from the first spec

| Old spec | This one |
|---|---|
| Part 3, one place with a count, ⌘K, the folded rail's dot | Not here. A surface calls `ask.list` and `ask.subscribe`. |
| Part 4, a macOS notification | Not here. A surface subscribes and notifies. |
| Part 5, the board replaces `waitingOnYou()` | Not here. The board is a consumer. |
| Part 6 and the catalog section (element entry, recipes, site counts) | Not here. Skills text and catalog belong to their owners. |
| `ask.list(to: person)` also returns live rows from presence | Not here. Presence is its own substrate. A surface may join the two. |
| Four methods | Four methods, a stream, events, a permission rule, limits, retention and error codes |

## 1. The record

A new table through `DatabaseService`, with an append-only migration taking the next free version on current
main when main is merged in (v69 is the latest today).

| Field | Meaning |
|---|---|
| `id` | Stable identifier, assigned on create |
| `from` | The asker, taken from the caller's principal and never from an argument: `{id, name, kind}` |
| `to` | The addressee: `person` (the signed-in person on this Mac) or a companion, stored by id and by the name it had |
| `kind` | A word the asker picks, `[a-z0-9-]` up to 24 characters. Conventions are the consumer's: the board uses `answer`, `decide`, `try`, `read` |
| `text` | What is asked, and why. Up to 2,000 characters |
| `ref` | An opaque string for what it is about, up to 200 characters. Suggested forms: `port:<id>`, `chat:<id>`, `card:#241`. The substrate stores it and never parses it |
| `space` | The space the ask was made in |
| `chat` | Where the answer is posted (section 3). Defaults to the chat the caller is replying in |
| `since` | Created at |
| `updatedAt`, `repeats` | Set when a repeat updates an open ask (below) |
| `status` | `open`, `answered`, `withdrawn` |
| `answer`, `answeredBy`, `answeredAt` | Set on answer |

**One open ask per (from, to, ref, kind).** `ask.create` for a key that is already open updates `text`,
sets `updatedAt`, increments `repeats` and keeps `since`, and returns the existing ask with
`created: false`. A key whose earlier ask was answered or withdrawn creates a new one.

## 2. The API

Declared once in the `BridgeRegistry`, so the tool schemas, `llms.txt`, the skills' references and the
guest's method table generate from it and the stale-file tests apply. Each method needs a row in
`SkillCatalog` naming the skill that teaches it.

| Method | Arguments | Returns | Who |
|---|---|---|---|
| `ask.create` | `to`, `text`, `kind?`, `ref?`, `chat?` | `{ask, created}` | Any local caller |
| `ask.get` | `id` | `{ask}` | The asker, the addressee, or a holder of the right in section 4 |
| `ask.list` | `status?` (default `open`; `answered`, `withdrawn`, `all`), `to?`, `from?`, `space?`, `ref?`, `limit?` | `{asks, count}`, oldest first | See section 4 |
| `ask.answer` | `id`, `text?` | `{ask}` | The addressee, or a holder of the right in section 4 when the addressee is the person |
| `ask.withdraw` | `id` | `{ask}` | The asker only |
| `ask.subscribe` | the same filters as `ask.list` | a stream of `{event, ask}` | As `ask.list` |

`ask.subscribe` is an endless stream method like `port.subscribe`, so it is refused on a request and response
door with the message that names the door that works. `event` is `created`, `updated` (a repeat), `answered`
or `withdrawn`. A subscriber that wants the current state calls `ask.list` first, then subscribes; the
substrate does not replay.

`count` in `ask.list` is the number of asks that match the filter before `limit`, so a surface can show a
count without fetching every row.

**Errors.** `not_found` (no such ask, or a companion that does not exist), `permission_denied` (the caller may
not do this to this ask), `wrong_state` (answering or withdrawing a closed ask), `bad_arg` (empty text, an
ask to oneself, a kind or field outside the limits), `limit` (section 6). A remote caller is refused on every
method and on the stream, as `notify.send` is: add the rows to the `RemoteAccess` table as never.

## 3. Closing, and waking the asker

**Only `ask.answer` and `ask.withdraw` close an ask.** A reply in a chat does not. The board's current rule,
dropping a card once the person's reply is the newest message, is one way requests go missing, and the
substrate does not copy it.

**Answering wakes a companion asker through the existing wake.** When the asker is a companion, `ask.answer`
posts into the ask's `chat` a message that **begins with the asker's mention** and then the answer:
`@asker  Your ask <kind> on <ref>: <answer>` (the answer text, or `done` when none). The message starts with the
mention so that it is addressed to the asker under the to and copy rule in `docs/research/mention-to-cc.md`;
today every mention wakes, and starting the message this way is correct under both. The post goes through
`postToChat` as the answerer, so the usual routing, membership and reply paths apply.

When the asker is not a companion (a person, a port or a script) no chat message is posted. The `answered`
event is the delivery, and a surface decides what to show.

**An ask to a companion** is answered by that companion with `ask.answer`, and the answer wakes the asker the
same way. The substrate does not wake the addressee on create: the asker mentions or messages it in the chat as
today, and the ask is the durable record of the request. (A wake on create to a companion is a follow-up if a
surface wants it.)

## 4. Who may do what

- **Any local caller** (a companion, a port, a script on the gateway, the person) may create an ask, read the
  asks it sent or received, withdraw its own, and answer one addressed to it.
- **Acting as the person.** The person's own principal (the shell, `Principal.Kind.human`) may list and answer
  every ask addressed to the person. Another caller may do that only with a grant, **`asks`**: see and answer
  the asks addressed to the person, asked through the shared permission card
  (`docs/plan-permission-card.md`) with a see right and a use right, each ticked. A companion never has it by
  default. This is what lets the board, as a port, show and answer Gordon's asks on his behalf, and it is
  the one place this feature adds to the permission model.
- **Not the cross-space question.** `ask.list` with no `space` returns the caller's own space. A caller with
  `asks` may name any space or omit it for all.
- **A companion cannot answer** an ask addressed to the person, and a port cannot withdraw another's ask.

## 5. Substrate behavior to state in the tests

- Persists across a restart; closed asks are kept for the retention period and pruned after.
- The dedup key is one open ask; a repeat is cheap and emits `updated`.
- An answer on a closed ask is `wrong_state`; an answer by the wrong caller is `permission_denied` and changes nothing.
- `ask.subscribe` receives each event once, in order, and stops when cancelled or when the caller loses the grant.
- A companion that is removed or renamed keeps its asks: `to` and `from` hold the id and the name as it was.

## 6. Limits and retention

- `text` 2,000 characters, `ref` 200, `kind` 24.
- At most **25 open asks per asker**. A further create is refused with `limit`, naming the count. This replaces
  the old spec's "who may ask the person" question: with eleven companions in a space, volume is the risk,
  and a per-asker cap bounds it without ranking the askers.
- Closed asks are kept **30 days**, then deleted. `status: all` lists them until then.

## Compatibility

Additive. No existing method changes. The new methods regenerate `llms.txt`, the skills' references and the
guest's method table, and the stale-file tests must pass; the `BridgeParamConsistencyTests` method count and
the tool-definition golden file move with them. The migration is appended and no existing one is touched.

## Acceptance

1. `ask.create` then `ask.list` returns the ask with `since`, and it survives an app restart.
2. A second create with the same (from, to, ref, kind) returns `created: false`, one open ask, the first
   `since`, the latest `text`, `repeats` 2, and one `updated` event.
3. `ask.answer` by the addressee closes it, and a message that starts with the asker's mention and carries the
   answer lands in the ask's chat when the asker is a companion.
4. A companion calling `ask.answer` on an ask addressed to the person gets `permission_denied`.
5. A caller with the `asks` grant lists and answers the person's asks; without it, it sees only its own.
6. A reply in a chat leaves the ask open.
7. A remote caller is refused on all five methods.
8. The 26th open ask from one asker is refused with `limit`.
9. `ask.subscribe` yields `created`, `updated`, `answered` and `withdrawn` for the matching asks, and nothing
   for asks outside its filter.
10. A closed ask older than 30 days is gone.

Tests use Swift Testing with `DatabaseService(inMemory: true)` and `makeParityWorld()`, calibrated by breaking
each rule and watching the test fail.

## What a surface builds for itself

Each is a consumer with its own card, built on the API above and not part of this spec.

- **A list and a count** where the person is (the shell, ⌘K, the folded rail's dot): `ask.list` and `ask.subscribe`.
- **A notification** when an ask to the person arrives and the app is not frontmost: a subscriber, with its
  own setting.
- **The board**: replace `waitingOnYou()` with `ask.list` for the person, and the "answered" button with
  `ask.answer`; it needs the `asks` grant.
- **The skill rule**: "when you need the person to answer, decide, try or read something, create an ask". The
  methods' reference text generates from the registry; the guidance on when to use them is the skills
  owner's.
- **The catalog entry** and its recipes, which are growth's.
- **Presence**: a surface that wants "a terminal is waiting on you" beside the open asks joins `presence` and
  `ask.list` itself.

## Not verified

- **Nothing was built or run.** The migration version, the principal kinds, `postToChat`, the stream-method and
  remote tables were read from main (4d204efb).
- **The wake wording** assumes the to and copy rule is adopted; under today's router the leading mention wakes
  the asker as before.
- **The `asks` right** is a proposal. Whether it fits the permission card's vocabulary was not checked with the
  card's table, which is not built yet.
- **The numbers** (25, 2,000, 30 days) are starting values, not measured.
- **Whether a missing-asks problem is caused by inference rules** is the first spec's hypothesis and was not
  tested here.
