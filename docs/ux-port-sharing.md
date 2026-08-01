# Sharing a port: the flow, and what actually crosses

**Opened 2026-07-31** (GM). Mapped before building, because two things in it are not obvious from
the sentence and both change what milestone B has to provide.

## The flow, as described

1. I share a link to a port with a friend
2. They click it, and a port pops open in their space
3. That port shows content served from my machine
4. They click something in it, and they are driving my machine
5. I am watching the same port, seeing what they do, and can interact too

## What actually crosses the wire

This is the part that decides everything else, and the slice's own design already answers it: B does
**not** receive pixels. B receives `getHtml` (a snapshot) and then `patch` / `push` deltas, and
renders them in its own webview.

**So the port's JavaScript runs on the FRIEND'S machine, not mine.** A shared calculator is computed
entirely on their side. Nothing of mine is touched by a click that only moves the port's own UI.

"Driving my machine" is therefore a narrower and more interesting act than it sounds: it happens when
the port's JS calls a `window.port42` method that must execute on the host — reading my files,
running a command, capturing my screen. Some ports never do this. Some do it on every click.

**Two classes of shared port fall out, and they feel completely different:**

| | what a click does | what the host risks |
|---|---|---|
| **self-contained** (a calculator, a chart, a form) | runs on the guest's machine only | nothing |
| **host-reaching** (a terminal, a file browser, anything calling a device API) | executes on the host | exactly what the permission card says |

## Finding 1 · CR1 does not hold for a shared port

CR1 says: *"Ports calling `window.port42` are unaffected. They reach the bridge in-process and never
traverse the gateway."* That is true of every port today and is why ports were exempt from the whole
authentication story.

A shared port breaks it. The JS is on B, the bridge call has to reach A, and it therefore **does**
traverse a transport. `PortBridge` is in-process by construction, so a shared port needs its
`window.port42` calls routed to the host instead — and once they leave the process they are a caller
like any other, which means they must carry an identity and be subject to grants.

That is not a defect, it is a requirement nobody has written down yet: **a shared port's bridge calls
are remote calls, and the guest is the actor making them.**

## Finding 2 · shareability is a property of how the port is WRITTEN

Both sides converge only on state that flows through the bridge. A port that keeps state in local JS
variables and mutates its own DOM will diverge silently: the guest sees their click, the host sees
nothing, and neither is told.

So a port is shareable to the degree that its state changes go through `patch` / `push` / `update`
rather than through direct DOM mutation. That is a real authoring constraint and it belongs in the
port-authoring manual, not discovered per port.

**Open: do we detect it or document it?** A port that diverges looks like a bug in sharing rather
than a bug in the port.

## The consent moments

There are four, and only one of them exists today.

| # | moment | who decides | exists? |
|---|---|---|---|
| 1 | the friend accepts the link | friend | the deep-link accept path exists (`TransitionRoot`) |
| 2 | the friend's instance enrols as a peer of mine | both, implicitly by sharing and accepting | no. Slice-02 step 2 |
| 3 | the friend's first host-reaching action | **me**, at my machine, via the permission card | the card exists; it names a client, not a peer on another machine |
| 4 | I stop it | me, revoke the peer or the grant | revoke exists per client and per capability |

**Moment 3 is the one to get right**, and it is the permission-at-a-distance question in the primary
flow rather than at the edges. My friend clicks a button; my card appears on my screen; their click
hangs until I notice. If I am not at my desk, they wait and then time out with no idea why.

## The hard cases

**I go offline.** Their tile is showing my port. It should say so rather than freeze: a port whose
host is unreachable is a state, not an error, and `host_offline` already exists as a code.

**We both interact at once.** State writes are CAS: whoever composed against the current token wins,
the other is refused with `current` and retries. The driver chip names whoever moved it last, on both
screens. Appends (see `design-append-writes.md`) do not contend at all.

**They restart, or reopen the app.** Does the shared tile come back? It should — it is an adopted
port like any other — but it is a proxy whose content lives elsewhere, so "restore" means reconnect
rather than reload from the local database.

**They share it onward.** Not addressed anywhere. A guest forwarding my link would be enrolling a
third party against my machine without me acting. The link must therefore be bound to the invitee, or
sharing onward has to fail.

## Open for GM

1. **Where does the tile land on their side?** Their current space, a new one, or a "shared with me"
   space? A space is a zone, so a port from another machine sitting inside a zone of theirs is
   coherent, but it needs a name.
2. **Do they see whose machine it is, always?** A tile serving my content in their space should
   probably carry my name permanently, not only at accept time.
3. **Moment 3's behavior:** block until I click, or refuse fast and tell them to ask me? My
   recommendation is refuse fast, because a hang is indistinguishable from a broken link.
4. **Is the link bound to one invitee?** If not, anyone it is forwarded to can enrol against my
   machine.
5. **Self-contained versus host-reaching:** should the two look different to the guest? They feel
   completely different and currently would not be distinguishable.
