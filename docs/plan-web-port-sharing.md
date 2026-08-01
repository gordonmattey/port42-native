# Web port sharing: implementation plan

**Opened 2026-08-01.** Sequencing decided in `browser-guest.md`: prove the sharing MODEL over the
transport that exists, then swap the transport (D-a's seam). So this plan uses the gateway, ngrok and
`/ws`, and no libp2p.

**What it proves when it works.** A browser on any machine renders a live port hosted on mine,
drives it, and both of us see the same thing. No install on the guest side.

---

## What already exists, verified in the source

| the guest needs | how | verified |
|---|---|---|
| reach the host | `/call` (HTTP) and `/ws`, public via ngrok | shipped |
| authenticate | `Authorization: Bearer <token>` on `/call`; `credential` on the `/ws` envelope | `resolveGatewayCaller`, live-verified 2026-07-31 |
| the port's HTML | `port.getHtml { id }` | `BridgeMethods.swift:1454` |
| live events | `port.subscribe { id }` as a `call` envelope on `/ws`; events arrive as `stream` frames on the same `call_id`. **WS only** — refused on `/call` with `unsupported`, because a subscription there could only hang | `BridgeMethods.swift:48`, live-verified 2026-07-30 |
| drive it | `port.push { id, text, token }`, `port.exec { id, js }` | shipped |
| an actor that does not pool | the compound `<peerGuest>/<portX>` | proven by `SharedPortActorSpikeTests` |

---

## Three gaps found while planning, before writing code

### G1 · A subscriber is never told the state changed — and this is a LIVE gap, not a sharing one

`PortEventKind` has sixteen cases — `console`, `push`, `presentation`, `driver`, `filedrop`,
`terminal.output`, `browser.*`, `screen.frame`, `camera.frame`, `audio.*`, `message`,
`companion.activity` — and **not one means "this port's state was replaced"**.

**Worse, checked in the dispatcher (2026-08-01): a state write publishes NOTHING unless the driver
changed.** The only publish on that path is `broadcastDriverChange`, and it returns early for a
refresh, deliberately: *"publishing per keystroke would drown the topic in non-news"*
(`BridgeDispatcher.swift:446`). So a host patching their own port twice in a row emits one driver
event at most, and possibly none.

**That kills the cheap workaround.** An earlier draft of this plan proposed "re-fetch when an event's
token runs ahead of the one you hold". There is no event to carry the advanced token. A subscriber
cannot detect a state change by any means available today.

**And it is not a sharing gap.** `port.subscribe` exists so that something can WATCH a port. Today a
watcher — an agent, the CLI, another instance — sees console output, pushes, driver changes and
device frames, and cannot see the port's content change. That undercuts the reason OUTPUT was built,
which §10c records as *"an agent cannot watch a port was a hole in the product regardless of
libp2p"*. **So fix it generally, in `NotifyBus` and `PortEventKind`, and sharing inherits it.**

**Shape:** a `state` kind published on every state write, carrying the port's new token. Whether it
carries the new HTML, a patch, or only the token is the open question — the token alone is enough for
a subscriber to know it must re-read, and is the smallest honest version. Suppression must NOT be
inherited from the driver rule: a refresh is non-news for a driver chip and is exactly the news for a
subscriber.

### G2 · The guest's `window.port42` has to go somewhere

The port's HTML expects `window.port42` in-process. In a browser guest there is no in-process bridge.
The guest page must render the port inside an **iframe** and inject a shim that forwards every
`window.port42.<method>(args)` call to `/call` over HTTP with the guest's token.

This is CR1's change made concrete: **a shared port's bridge calls are remote calls**. The shim is
where a port's JS stops being local.

*It also sandboxes.* An iframe with `srcdoc` keeps the guest's page and the host's port HTML apart,
so the port cannot read the guest's token directly — it asks the shim, which holds it.

### G3 · The token has to be threaded, and the guest starts without one

Every write carries the port's token. `port.getHtml` returns the HTML; the guest needs `current` too.
`ports.list` and `port.create` return one, and every write returns the next. The cheapest phase-0
answer is to take the token from the first event that arrives, and otherwise let the first write be
refused with `token_required` carrying `current` — the designed self-correcting path, which costs one
extra round trip exactly once.

---

## Phase 0 · the loop, with NO app changes

The point is to learn whether this feels right before touching Swift.

**Setup:** add a client by hand in Settings → Access (exists), copy its token, create a web port in
Dev3, note its id.

**Build:** one static HTML file, opened from the filesystem or served locally.

1. `POST /call` with the bearer token, `{"method":"port.getHtml","args":{"id":"<portId>"}}`
2. render the returned HTML into an `<iframe srcdoc>`
3. inject the `window.port42` shim into the iframe, forwarding to `/call` with the same token
4. open `/ws`, send `identify` carrying `credential`, then a `call` envelope for
   `port.subscribe { id }`
5. on each `stream` frame: apply `push` events to the iframe, and on a `state` event re-read
   `getHtml`. **G1 has to be built first** — there is no event today that says the state moved
6. a button that calls `port.push` back to the host

**Done when:** the browser shows the live port, a change made on the host appears in the browser, and
a click in the browser appears on the host.

**Verify:** in a browser tab on this machine first, then over a VPN or from a phone browser against
the ngrok URL, which is the same code path with a different address.

---

## Phase 1 · the guest is a real principal

**Now the Swift side.** Everything phase 0 does is authenticated as a hand-made client, which is a
person, not a guest.

- `clients.kind` gains `guest`, distinct from `peer`: **ephemeral, session-scoped**
- the compound actor `<guest>/<portId>` is what the host authorizes, per the spike
- **grants for a guest do not persist.** A guest gets a fresh identity per visit, so persisting them
  fills the manager with rows that can never fire — the 135-dead-grants disease with a generator
  attached
- the permission card names the guest AND the port: "Ada's Pricing Calculator wants filesystem
  access", not a port name with no hint that a person elsewhere is asking

**Verify:** two browser tabs are two guests. A grant to one gives the other nothing. Neither survives
a restart.

## Phase 2 · the invite carries it

- `port42://port?` (per `invite-taxonomy.md`): host address, port id, a one-time token
- **one-time use** (GM): the link burns on acceptance, so a forwarded link enrols nobody
- two modes: Port42 installed opens in the app as YOU; not installed opens the browser page as a
  guest
- the landing page hosts the phase-0 page rather than a download prompt

**Verify:** a link works once and fails the second time, with a message that says why.

## Phase 3 · both drivers

- the driver chip names whoever moved the token last, on both screens
- a stale write is refused with `current` and one retry lands
- appends (`design-append-writes.md`) do not contend at all

**Verify:** two browsers and the host, all pushing. Nothing is lost and nothing double-applies.

## Phase 4 · make it not stall

- async permission (D-d), which is not a blocker for building or demoing — a blocking prompt is fine
  when the host is present — but is what makes it work when they are not
- host offline reads as dormant rather than broken (`host_offline` exists)

---

## The boundary (GM, 2026-08-01): "the goal is to access a port, that's it"

**The browser page shows ONE shared port and nothing else.** No space, no chat, no second port, no
navigation, no persistence. Written down because it is currently true by accident — phase 0 built
only what phase 0 needed — and phase 2 is where it stops being accidental.

**Phase 2 is exactly where the pressure arrives.** A landing page is a place someone arrives, and
"while they are here, show them the space too" is a reasonable-sounding next step. A space is a chat
port, so that step is the doorway to a second client, and a second client doubles the product.

**What keeps it cheap is the shim, not restraint.** The page knows nothing about port types, port
internals, or the bridge's method list; it forwards whatever the port's own JS calls. A terminal, a
browser tile and a chart all work unmodified. That property holds exactly as long as the page's job
stays "show me the one thing I was sent".

**And the two-mode link is what makes the limit affordable:** if Port42 is installed the link opens
the real app, so the browser only ever has to serve the person who has nothing.

## Open decisions

1. ~~G1: `state` event kind now, or token-driven re-fetch first?~~ **CLOSED 2026-08-01: the event
   kind is required.** A state write publishes nothing today, so there is no event to carry an
   advanced token and nothing to re-fetch against. It is also a live product gap rather than a
   sharing prerequisite, so it lands in `NotifyBus` first and sharing inherits it. Open within it:
   does the event carry the new HTML, a patch, or only the token?
2. **What does a guest persist?** Nothing, per the ephemeral rule. Then a refresh is a new guest, and
   any grant is asked again. Acceptable for a demo, possibly annoying in use.
3. **Does the shim expose every bridge method, or a subset?** Everything a port can call locally is a
   remote call for a guest, including device APIs. The permission model covers it, but the blast
   radius is worth a deliberate decision rather than a default.
