# Design note: how a port feeds other ports

**Ticket** #246. **Base** main at 4d204efb. **Branch** spike/port-subscriptions. **Date** 2026-09-30.
A design note and a recommendation, not an implementation. The dev lead's guidance on the card is adopted:
a cross-space subscription is a **see** grant on the publisher, asked once through the shared permission
card (`docs/plan-permission-card.md`); a command back is **use**, a change is **edit**, each with its own tick;
the grant limits what a reader can see and not the topic; kind filtering and the last event per kind are
properties of the subscription, which the grant leaves unchanged; question 4 stays open until #244 reports.

Gordon's intent: one port holds the data and publishes it, and other ports in any space show as much or as
little of it as they need.

## Decision needed

| Question | Answer |
|---|---|
| 1. Can a subscriber ask for kinds? | No today. It should: a `kinds` option on the subscription, filtered in the bus before anything is encoded or sent. |
| 2. A pattern for summary plus content | A small `summary` kind (retained) and a heavy `content` kind (not retained); readers subscribe to one or both; a late full reader gets the retained summary and fetches the content. |
| 3. Late subscribers | Yes: keep the last event per kind, only for kinds the publisher marks `retain`, delivered first on request (`replay`). In memory first. |
| 4. Off-screen publishers | **Open until #244.** What this design needs from the answer is below. |
| 5. Writes back | A reader's command is a separate verb with the **use** right; subscription is **see**. No change to the grant model. |

**Recommendation.** Build kinds, retained last-per-kind and a payload cap as one change to the bus and the
`port.subscribe` method, behind the cross-space grant. It is the same change at the relay: a mirror
subscribes through the same method.

**The one blocker.** None for the design. One ordering fact: `port.subscribe` has no read-scope check today
(`BridgeTargetScopeTests` lists it as "read scope OPEN: APP-10"), which is why the Launch desk feed works
across spaces. When the cross-space grant lands (#238) that stops, and the Launch desk's small view will
ask at its first subscribe.

**Needs Gordon.** A cap on one published event (section 2 suggests 256 KB). Today there is none.

## 1. How it works today

- **A topic per port** (`port:<id>`). `NotifyBus.publish` sends every event to every subscriber of the topic
  (`NotifyBus.swift`). A subscriber gets the whole envelope: `topic`, `kind`, `payload`, `token`.
- **A subscription is `port.subscribe(id)`** and takes no options (`BridgeMethods.swift:54`). In a page,
  `port42.port.subscribe(id, onEvent)` returns a handle with `cancel()`.
- **A publisher** calls `port.publish(kind, payload)`. The kind is namespaced to `port.<kind>` so a port cannot
  forge a system kind. There is no size limit on the payload.
- **What else is on the topic.** The system kinds (`console`, `chat`, `push`, `state`, `storage`, `driver`,
  `terminal.output` and so on) travel on the same topic, so a subscriber with `see` today also receives
  what was pushed into the publisher and what its chat says. Filtering by kind is also how a reader asks for
  less than everything.
- **A late subscriber sees nothing** until the next publish. The bus keeps no state. The Launch desk
  republishes every minute for this reason.
- **Mirrors already do the late-subscriber dance.** A tile of a port on another machine subscribes through
  the relay (`startMirror`, `RemoteTile.swift`) and re-reads the port on every (re)connect before relying on
  events (`refreshMirror`). That is the pattern the retained value replaces for ports.

## 2. Delivery costs, measured

A published event is encoded once and then, per subscriber, escaped in full, embedded in a JavaScript
string and evaluated in that subscriber's page (`PortBridge.pushToken`, `escapeJSString`, all on the main
thread, because `NotifyBus` is main-actor). `spikes/port-subscriptions/bench.swift` reproduces that path
with the real escape function and real web views (macOS 15.6.1, one machine, 20 deliveries, medians).

| Event size | 1 subscriber | 3 subscribers | 10 subscribers |
|---|---|---|---|
| 1 KB (a summary) | 0.2 ms | 0.5 ms | 1.2 ms |
| 20 KB | 1.3 ms | 3.7 ms | 22 ms |
| 200 KB (a draft) | 18.5 ms | 40 ms | 140 ms |
| 1 MB | 72 ms | 200 ms | 673 ms |

The main thread is busy for most of that: 124 ms of the 140 ms for 200 KB to 10 subscribers. About half of each
200 KB delivery is the escape (6.4 ms), done again for every subscriber on the same string.

Reading it: a 200 KB event once a minute to a handful of readers is a small cost. The same event once a second
to ten readers is 12% of the main thread, and a reader that wanted a one-line summary pays it too. A filter in
the bus removes the cost for readers that did not ask. A payload cap bounds the worst case. Escaping once and
reusing the result for every subscriber would halve the rest; it is independent and small.

## 3. The design

### Question 1 and 2: kinds on the subscription

`port.subscribe(id, onEvent, opts)` with `opts.kinds`, a list, default all. A kind matches exactly, or `port.*`
for every kind the publisher named. The page may write the short name (`summary`) or the full one
(`port.summary`). The filter runs in `NotifyBus.publish` before the envelope is encoded for that subscriber,
so a heavy payload is never escaped, sent or parsed for a reader that did not name its kind. At a mirror the
filter travels in the remote `port.subscribe` arguments, so the relay carries only what the reader asked for.

**The pattern.** A publisher emits two kinds from one revision counter:

- `summary`, a few hundred bytes: a title, counts, a state, `rev`. Published on every change. Retained.
- `content`, the heavy body (full draft text), with the same `rev`. Published when the content changes. Not
  retained, or retained only if the publisher says so and the size is under the cap.

A small view subscribes to `['summary']`. A reader that wants everything subscribes to both. A full reader
that opens late gets the retained `summary`, sees `rev`, and asks the publisher for `content` with a command
(`port.push`, the **use** right). The publisher answers by publishing `content`. A very large body is a
sequence of `content` events with `seq` and `of` fields, never one event over the cap.

### Question 3: the last event per kind

`NotifyBus` keeps, per topic and kind, the last event the publisher marked retained
(`port.publish(kind, payload, { retain: true })`). A subscription with `replay: 'last'` receives those first,
each marked `retained: true` and carrying its original time, then live events. Bounds: only the publisher
chooses, one event per kind, within the cap, dropped when the port closes.

In memory first. A retained event does not survive a relaunch, and the publisher republishes when its page
loads. If publishers become dormant until needed (the not-started state in `docs/research/boot-order.md`), a
persisted retained set is what lets a reader see the last summary of a port that has not started. That is a
later step and a small table.

### The payload cap

`port.publish` refuses an event whose payload encodes larger than a limit, with a message that says to publish
a summary and send the content as pieces. The table above supports 256 KB: under 20 ms per subscriber, and
about 70 ms of main thread for ten. Today there is no limit.

### The envelope

Add `at` (the publish time) to the envelope. A retained event replayed to a late reader then says how old it
is, which is also how a reader shows that a feed has gone stale (question 4).

## 4. Question 4: keeping a feed live (open)

The dev lead measured that timers stop for every port while Port42 is not frontmost, not only for ports in
other spaces, and #244 is on it. Whatever the cause is, this design needs three things from the answer:

1. **Whether a page's timers can be kept running** while a port has timers and subscribers. If yes, nothing
   changes here.
2. **Whether the page can be woken by the platform.** A subscribe to a dormant or throttled publisher could
   wake it. That is the same wake the not-started state in the boot-order note needs.
3. **If a page cannot run on a schedule**, a publisher needs a schedule the platform runs for it, outside the
   page. That is a larger change and would be its own design.

Independent of the answer: retained events with `at` make a stopped feed visible as old, not as current.

## 5. Question 5: how this relates to #238

The grant is made once, at the first `port.subscribe` across spaces, as a **see** grant on the publisher. The
card names both ports. Everything in section 3 is a property of a subscription made under that grant:

- **Kinds** narrow what the reader receives. They can never widen it.
- **Replay** hands the reader an event it would have been allowed to see live.
- **A command back** (a request for content, a control) is a different method with its own right: `port.push` is
  **use**, a change to the publisher is **edit**. The card shows each with its own tick, so a reader that only
  subscribes is never asked for use.
- **A revoke** ends the subscription, and a retained event is not replayed to a reader without the grant.

The grant does not name a kind. A reader with **see** may subscribe to any kind. A publisher that has events
only some readers should see (a draft in progress, say) needs a finer right than this design gives, and the
design does not add one.

## Costs and risks

- **Existing readers keep working.** `kinds` and `replay` default to today's behavior (all kinds, no replay).
- **The bus holds state** for the first time. Bounded by the cap and by one event per retained kind per port.
- **Kind names become an interface.** A publisher that renames `summary` breaks its readers. The generated
  port documentation should say so, and `ports.list` could expose the kinds a port publishes.
- **The cap breaks a publisher** that sends more than 256 KB today. None is known; the Launch desk was not
  measured.
- **The grant timing.** Subscribers that work today because the read is open will ask once #238 lands.

## Not verified

- **Nothing was built or run in the app.** The benchmark is a standalone WebKit program using the real escape
  function and the same evaluate-and-parse shape as `pushToken`, not the app's bus, and not through a port's
  bridge. Dev9 was not used.
- **The Launch desk** and its small view were not examined, so its real event sizes and rate are unknown.
- **Relay cost.** The saving from filtering at a mirror is by reasoning, not measured.
- **Memory** of a retained set across many ports, and the 256 KB figure, are suggestions from the table above.
- **Question 4**, by instruction.
- **Binary payloads** (base64 frames) were not considered; `screen.frame` and `camera.frame` are not meant for
  this path.

## Work items (to file once Gordon passes this)

1. **Feature, dev lead:** kinds, replay and retained last-per-kind on `port.subscribe` and `port.publish`, the
   `at` field, the payload cap, and the same arguments through the remote subscribe.
2. **Issue, throttle:** escape a published event once for all subscribers, not once per subscriber
   (`PortBridge.pushToken`, `NotifyBus.publish`).
3. **Issue, scribe:** the publisher and reader pattern (summary and content) in the ports manual, generated from
   the type like the envelope.

## Reproduce

    swiftc -swift-version 5 -O spikes/port-subscriptions/bench.swift -o /tmp/bench && /tmp/bench
