# One-pager — working notes

*Backing material for `one-pager-2026-07.md`. Not part of the document; this is the audit trail so
every claim in the narrative can be traced, cut, or defended.*

---

## The thesis (GM, 2026-07-16)

> "Every company is going to want their own harness, that's my belief, and port42 is that harness.
> For whatever vertical you are working on, or horizontal work (developers)."

This replaces the "reality compiler" frame. The old pitch sold **artifacts** (intent → tool; value =
tool count: 84 tools, 244→84 context switches). The harness frame sells **the place the work
happens** — which is what the product actually became when the shell replaced the desktop.

Why the harness frame is stronger for an investor:
- It names a buyer ("every company") and a budget line, where "personal computing" named a feeling.
- It's defensible: the harness is the customer's context, which no model vendor can ship and no
  customer wants to rent. That's a moat argument that doesn't depend on out-engineering OpenAI.
- It survives model progress. Better models make the harness *more* valuable, not less — the
  strongest possible position to hold while the models keep improving.
- It explains the architecture instead of being decorated by it: one bridge / two callers *is* a
  harness; permissions *are* the leash.

## The horse-collar analogy — check before use

Historically sound and worth keeping precise:
- The throat-and-girth harness compressed the horse's windpipe under load, limiting sustained draft.
- The rigid padded collar (China, ~5th c.; widespread in Europe by the 10th–12th c.) moved the load
  to the shoulders, greatly increasing usable draft power and letting horses displace oxen on the
  plough in northern soils.
- **The load-bearing point, and the reason it fits: the animal didn't change. The harness did.**
- Don't over-quantify it in the doc. Figures for the improvement vary by source; the qualitative
  claim is safe, a specific multiplier is not.

Second meaning worth having in the back pocket (don't force it into the doc): in engineering a
*harness* is what holds a component and wires it to everything else so it can be exercised — a test
harness, a wiring harness. The pun runs the same direction as the metaphor, which is rare.

## Metaphor bench

*A menu, not a recommendation. Pick, don't accept.*

| Metaphor | What it buys | Where it breaks |
|---|---|---|
| **The horse collar.** Everyone has the horse; nobody has the collar. The animal didn't change — the harness did. | **Now the spine of the doc.** It's GM's own word, it names the buyer's actual problem, and it survives model progress. Historically true and checkable. | Agricultural metaphors can read as quaint. And it implies a single simple part, where the harness here is a platform. |
| **Chat already proves it.** Nobody screen-shares a chat window — you sync messages and each end renders natively. | **Strongest technical claim available.** Not an analogy — an existence proof *inside the product*. Pre-empts "sounds hard" with "you already use it." | Chat is append-only text; a 3D shader port is not. Understates how much harder arbitrary state is. |
| **MIDI, not audio.** Streaming a port as video is bouncing to WAV; sending queries is sending MIDI. | Explains query-vs-pixel in one beat to anyone who's touched music software. **Predicted the design**: the avatar plan (stream pose+visemes, render locally) *is* MIDI. | MIDI needs an agreed instrument at both ends. "The far end has the same synth" is exactly the unsolved rebinding problem. |
| **"Actor" is a pun and both halves are load-bearing.** Hewitt/Erlang actor (mailbox, location-transparent) *and* stage actor (enters, says its line, exits). | Free rigor + free poetry. Makes "a port is a sentence, not a document" a consequence rather than a separate idea. | Cute to engineers, jargon to everyone else. We have no supervision trees — don't invite an Erlang purist to audit it. |
| **The fax machine of collaboration.** Screen-sharing works and throws away everything that made the thing a thing. | Used in the doc, one line. Blunt, and correctly scoped — it concedes the honest exception (surfaces you don't own). | It's a negation; tells you what we're not. |
| **A phone number, not a photograph.** Screen-share gives a photo of the room; an address gives a way in. | Cleanly names the teleport gap: ports have photographs, not phone numbers. | Phone numbers reach people, not objects. Strains on "the same port in two places." |
| **The web did this to documents; nobody did it to the desktop.** Everything on the web has had an address since 1991; nothing on your desktop does. | Enormous, instantly legible, literally the `GET /port/<id>` plan. | HTTP is stateless and document-shaped; ports are stateful actors. Invites "so it's a web app?" |
| **Figma didn't win by streaming Photoshop's pixels.** | Commercially validated, one sentence, investors already believe it. | Figma is *one* document type; we claim the whole desktop — a far bigger promise to defend. |
| **The gateway is a supernode** (Napster → FastTrack → Skype). | Real lineage; makes p2p sound engineered, not ideological. | **Handle with care.** Microsoft centralized Skype's supernodes in ~2012 — the metaphor's own history argues against us. And an ngrok'd gateway is *not* UDP-reachable, so it isn't a supernode today. |
| **X11 tried this in 1984 and lost to pixels.** | Disarms "surely someone did this" by answering it first. | **A cautionary tale.** Only use if you can say why latency + a fixed drawing model killed X11 and why a self-describing actor isn't that. |
| **Two hands on the same clay.** | Best emotional frame for co-holding; makes per-element right-of-way feel obvious. | Clay implies one artifact; a desktop of ports isn't one lump. |

## Ships today (verified against code, CLAUDE.md, git log)

- **The shell is the app.** Zoom spine (galaxy ↔ space ↔ focus), tiled port units, peeks, park rail,
  dock, ⌘K switcher, working set (rest/wake), ⌘\` cycling. No OS windows. Classic mode deleted
  2026-07-14 (`60fc1d7`) — deleted, not deprecated.
- **Ports, two types, one primitive.** `port.create({type:"web"|"terminal"})`. Web = companion-authored
  HTML; terminal = native Ghostty. Both addressable and driveable.
- **The unified bridge.** ~40 methods (clipboard, screen, files, terminal, audio, camera, browser,
  automation, notify, AI, REST, storage, relationship state) reachable identically from port JS and
  companion tool-use. Permission-gated per category.
- **Companions.** LLM and command (CLI) agents, mentions/routing, invite links, relationship memory.
- **Spaces + sync.** Local-first SQLite; Go gateway; WebSocket sync; per-channel AES-256-GCM E2E;
  ngrok tunneling.
- **Versioning.** Every port version retained; four closed ports restored from the DB, 2026-07-16.
- **Notarized DMG.** macOS 14+.

## Direction — written, not built (never demo as working)

| | Status |
|---|---|
| **Cross-instance address** | The keystone. Designed (`slice-02-cross-instance.md`). Transport decided: go-libp2p (Circuit-Relay v2 + DCUtR). **No code.** |
| **A port has a URL** (`GET /port/<id>`) | Concept. No route. Gated on a capability-scoped share token — a public URL to a live bridge is RCE on your Mac. |
| **Port teleport as protocol** (`port.send`/`fork`) | Proved *by accident, as a hand-copy*. No API. |
| **Standing intent** | CONCEPT (2026-07-16). No code. |
| **Live media plane** (WebRTC, agents as tracks, 3D presence) | North star. Audio + screen + avatars; camera dropped. |
| **Pluggable primitives** | Thesis + four docs. |
| **Computer use** (`computer.act`) | Plan. Pieces exist; composition doesn't. |

## Known open problems (they bound the claim)

The desktop-is-live-ports thesis owes a bill: the webview registry never evicts (101 ports → **88
live WebContent processes**, measured 2026-07-16), and ports are never told their presentation state,
so they can't idle. Also: **closing a port leaks its mic + on-device speech recognizer permanently**
(`68706b0`) — privacy bug as much as perf, and a hard blocker on anything unattended. Being paid down
now. Included in the narrative in one honest paragraph; cut it only if the audience can't hold it.

## What could not be verified

- **Every figure in the Oct-2025 PDF.** 100+ installs / 44 registered users / 84 tools (35 in 72h) /
  244→84 context switches / 0–58 in 72h / "$0 acquisition cost, 2 posts" / "2 months of solo work in
  4 hours for $60" / $20–200 per tool per month / 500M scale / the $1M-9mo and $10M-12mo asks. None
  reproducible from this repo. **Not reused. Must be refreshed before external use** — a harness
  pitch needs harness evidence (who ran an agent on real work, and what changed), not tool counts.
- **UERP / `port42-rfc.txt`** — **RESOLVED 2026-07-16.** The memo exists, outside the workspace:
  `~/Dropbox/Working Files/port42-rfc.txt` (333 lines, Dec 2024, standards-track mock memo). An
  earlier note that it "does not exist" was a scoped-search error. **But the substance stands, more
  precisely:** §5 specifies payload formats for **Query and Response only**. There is no Update
  payload anywhere — so the entire write path (`push`/`patch`/`exec`/`update`) has no wire format.
  UERP as written is a *resolution* protocol (DNS-for-entities), not a protocol for driving an actor.
  `bus-architecture.md`'s "written, not open — needs wiring, not inventing" **overclaims**; the
  supportable sentence is that the vocabulary and addressing shape are written and four of six facets
  run in the bridge.
- **An unresolved fork the docs currently answer two different ways.** `bus-architecture.md` open item
  #1 says *extend the address to carry the instance* (`port42://<peerID>/...`, matching
  `slice-02-cross-instance.md`). The RFC has **no instance component by design** — §1 names
  "addressing equals location" as the thing it exists to reject, and instead returns a **location
  list** in the Response (§5.3). Instance-in-address is dialable today but pins a port to a machine
  and breaks every reference when it moves — the exact failure the teleport already demonstrated.
  Resolve-to-locations survives movement but needs the resolution layer first. **This is the keystone
  decision and it should be made deliberately, not by whichever doc a session opens first.**
- **"Four of six facets shipped."** The *verbs* exist and are documented; not exercised end-to-end.
- **`bash.tv` / Dom Hofmann** (cited as validation) — from `bus-architecture.md`, not independently
  checked. A competitive scan run 2026-07-16 rated it ADJACENT and flagged low confidence.
- **Team bio claims** (Ticketmaster VP Mobile, Yahoo Senior Director, etc.) — outside this repo,
  unchecked. Carried over from the old PDF only if GM confirms.
- **The harness thesis itself is a belief, not evidence.** GM states it as belief. Nothing in this
  repo demonstrates that companies want their own harness — that's the claim an investor will test,
  and the one place the doc most needs outside proof (design partners, a pilot, someone else's
  vertical).
