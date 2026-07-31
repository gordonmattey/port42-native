# Slice 02 · Cross-Instance — one slice, local seams through libp2p

> **RESCOPED 2026-07-28 (GM): this is now ONE slice, and everything in flight lives here.** The
> gateway-auth work, port 0 and the permission object, and the permission manager are not a phase
> before the slice. They are the slice's local half, and they are here so the wire half slots in
> rather than lands on a refactor. `plan-gateway-auth-tls.md` keeps P0 (shipped), the ngrok note, and
> the TLS phases; its P1 section now points here.
>
> **The old concurrency mechanism in the wire half is OBSOLETE and the rest still stands.** The
> sections below were written 2026-07-15 against a per-port **lease**: one holder, a write requires
> it, no lease means rejection. That mechanism was built locally and then deleted. The local protocol
> thread replaced it with three nouns, ADDRESS · ACTOR · TOKEN, and the replacement is a different
> answer rather than a refinement:
>
> | this doc used to say | what actually exists |
> |---|---|
> | a lease grants the right to write | **a TOKEN says what you composed against**; a stale one is refused with `stale_write` + `current`, an untokened write with `token_required` (R5) |
> | one holder per port, others rejected | **nobody is ever blocked.** Refusing a caller who declined to declare state is not refusing a caller who lost a race |
> | the holder is broadcast so both UIs show the pen | **presence is DERIVED** from whoever moved the token last. It shows; it refuses nothing |
> | request → grant/deny → handoff | **no verbs.** `release` and `handoff` were deleted as lease-era code with no callers |
>
> **Why the lease died, and why it matters MORE across the wire.** A lease is a lock with a TTL, a TTL
> has no principled value, and it depends on clocks agreeing between peers, which they do not. A
> vanished holder leaves a port stuck. Every one of those is sharper at a distance. **The token is
> correct whether the writer thought for 3ms or 3 hours, and identical locally and remotely**, which is
> why it was built peer-qualified (`ActorRef` is `<peerID>/<principal>`) and epoch-qualified
> (`<epoch>:<seq>`) from day one.
>
> **O-1 is void** (no grant, so no authority to locate). **O-4 survives in a better form**: a late
> delta carries a token the port has moved past, so CAS refuses it by construction; what remains open
> is Notify ordering for DISPLAY, not for correctness.
>
> **Read `plan-port42-protocol-local-bus.md` §A before building from this file.**

## The slice in one line

> A port lives on **instance A**. From **instance B** you address it, send it a query, and see its
> stream, as if it were local. Every caller on both ends is a **named actor** acting on a **named
> object**, and you can see and revoke what each one may do. When B writes, A sees B driving, and
> neither overwrites the other. Location is transparent; the wire is libp2p.

---

## Part 0 · The seams libp2p slots into

**This is the whole reason the local half is in this document.** Each row is a seam built locally,
in a shape where the wire is an addition rather than a rewrite. If a row is skipped, libp2p arrives
as a migration instead of a plug.

| seam | state | what the local half builds | what libp2p adds | why it then slots in |
|---|---|---|---|---|
| **ADDRESS** | ✅ | `PortRef.key`, one definition. **Port 0 is the machine itself** | a `<peerID>/` prefix | `port42://<peerID>/space/<id>/<portId>` already assumed. Port 0 makes `<peerID>/0` mean *that machine*, so a peer can name a machine and not only a tile |
| **ACTOR** | ✅ | a verified caller identity, established ONLY by presenting a credential, written peer-qualified from day one | a second verifier: PeerID → principal | libp2p authenticates a peer cryptographically. Before half two that authenticated peer was flattened to a string and thrown away. The seam is where it lands instead |
| **TOKEN** | ✅ | `<epoch>:<seq>`, CAS, peer- and epoch-qualified | nothing | already transport-independent by construction. Done |
| **OBJECT** | ✅ | the grant key gains its missing slot: `<grantee> × <port> [× zone]`, both sides peer-qualifiable | peers on both sides | "peer B may act on my port 0's clipboard" becomes expressible with no new concept. Without the slot, adding it later is a migration across two instances rather than one |
| **OUTPUT** | ✅ **2026-07-30** | one publish door with a typed kind and a typed payload, and a way OUT of the process | a gossipsub topic per port | payload is `BridgeValue`, every envelope carries the port's token, and a subscriber outside the app now receives events as `stream` frames. Gossipsub becomes a second subscriber to a stream that already exists |
| **LEGIBILITY** | ✅ | the permission manager: every grant visible, revocable, grouped by grantee | remote peers are grantees too | a grant to a peer you cannot see is the local invisibility problem with a network attached |
| **ERRORS** | ✅ **2026-07-30** | typed codes, app and gateway, from ONE list | the same codes on the wire | a remote caller acts on `stale_write` / `token_required` as a local one does, and on `no_host` / `host_offline` before it reaches the app at all |

**The test for each row:** adding libp2p should mean writing a verifier and a transport, and touching
nothing above the seam. Anything that would force a change above the seam belongs in the local half.

### Part 0's state, stated exactly (2026-07-30)

Five of the seven rows are built and live-verified. **Two are not, and the earlier claim that the
local half had built every row it owns was wrong.** Both gaps land on milestone B rather than beside
it.

**OUTPUT is built (§10c, §10d).** The payload is `BridgeValue` rather than `Any`, every envelope
carries the emitting port's token, and events now leave the process as `stream` frames. Two defects
surfaced on the way, both shipping at HEAD and neither visible from either end alone:

- **`PortBridge` interpolated an OPTIONAL into its topic**, publishing to `port:Optional("abc")`
  while subscribers listen on `port:abc`. Every event on that path had never reached the bus:
  `browser.*`, `screen.frame`, `camera.frame`, `audio.*`, `presentation`. The compiler had been
  warning on that line the whole time.
- **The gateway threw every streamed event away.** `RemoteToolExecutor` served streaming methods with
  `yield: { _ in }`, and no `stream` frame existed to carry one anyway. So nothing outside the app
  could ever watch a port.

**Sizing it made it smaller, and this is the reusable part.** "Ten publish sites" was the number in
the register; the real surface was one funnel plus five direct calls, because eleven `pushEvent`
callers all route through a single private method. Measuring before designing changed the shape of
the work here exactly as the grant census did at step 1.

**ERRORS is built (§10e).** The app side has been typed since 2026-07-28; the gateway's own failures
were bare English until 2026-07-30 (`"no host available"`, `"host is offline"`, `"failed to reach
host"`), which a caller cannot branch on and which a REMOTE caller meets before anything the app
says. They are now `no_host`, `host_offline`, `transport_failed`, `timed_out`, `missing_arg` and
`unknown_method`, declared in the app's `BridgeErrorCode` and mirrored in Go behind a gate that fails
if the gateway spells a code the app has never heard of.

**Deliberately still uncoded: the channel and message path.** Rate limits, channel membership and
token-count failures are the MESSAGING protocol, which BR1 leaves untouched and which no bridge
caller meets. Typing them would mean inventing codes, or bending messaging failures into names built
for the RPC surface. The line is what a CALLER can act on, which is what this row is about.

**ALL SEVEN PART 0 ROWS ARE NOW BUILT.**

---

# The local half

*Everything from here to "The wire half" was `plan-gateway-auth-tls.md` §P1, moved here 2026-07-28 so
the slice has one home. Section numbering is that document's.*

#### 1. What is true today (measured 2026-07-28, Dev3 and GM's live defaults)

**There are two doors into the same bridge, and the second one is weaker than the one the design
named.** `/call` (HTTP) stamps a constant identity. `/ws` copies an identity off the wire. A local
WebSocket client that names itself in `identify` is that principal:

```
identify as sender_id=local-http, no credential   → accepted
ports.list                                        → returned the user's real port list
automation.runAppleScript                         → ran, no prompt
```

Both were run against Dev3. The second inherited a standing grant, so this is the full escalation
and not merely an identity defect.

**The standing grants are wider than the earlier note recorded.** Production holds
`portPerms.local-http.global = ai, screen, filesystem, terminal`. Dev holds
`filesystem, automation, rest, microphone, browser, ai, terminal, screen, clipboard`.

**`is_host` is unchecked** (`gateway.go:283`, established from source, not measured, because testing
it live would wedge the instance's routing). Any peer claiming `is_host: true` becomes
`globalHostID`, which is the peer every `/call` is routed to.

**Two facts recorded 2026-07-27, still accurate.** `gateway.go` sets `SenderID: localPrincipalID`
with no check of `r.RemoteAddr`; the constant's name was load-bearing for a security property that
only P0's bind actually provided.

**A THIRD authorization path exists that never consults a principal at all, and it is ON in
production.** `ToolExecutor.swift:140` builds a `pregrant` set from three UserDefaults flags and
unions it into the permissions for every gateway call, before the principal is constructed:

```
remoteAllowTerminal   remoteAllowFS   remoteAllowScreen
```

Measured on GM's installs: production has **all three set to 1**; Dev has `remoteAllowTerminal = 0`
and the others unset; Dev3 has none set. This is the "Remote Access" pre-approval the generated
CLAUDE.md block already points at.

**This is independent of the `local-http` grants and survives everything above it.** Naming and
authenticating every caller does not touch it: with these flags on, an enrolled client still
receives terminal, filesystem and screen with no prompt and no per-client scoping, which is FR8
violated by construction. It was found by the caller sweep (spike D), not by reading the design,
and the decision about it belongs in this phase rather than after it.

**The environment is not a private channel.** `ps -E` against a same-user process returns its full
environment, so handing the gateway a secret at spawn publishes it to every process running as the
user. The decided design said "the gateway takes it from its environment at spawn"; that part does
not hold. The app already holds the gateway's stdin pipe open for the EOF-on-death watch and never
writes to it, so the secret goes over stdin as one line at startup and appears in no process table.

### 2. The root cause, stated once

Authentication, addressing and authorization are smeared across three components and none of them
owns any of it. The gateway, a transport, decides identity. `sender_id` is simultaneously a routing
address for channel messages and a permission key for calls. The app trusts whatever arrives.

This is the same conflation the protocol thread already fixed twice: `PortRef.key` (one address,
three definitions) and `createdBy` (provenance doing authorization's job). Here an ADDRESS is doing
an ACTOR's job on the wire, while the app side of the same noun was resolved at I1.

### 3. Requirements

Numbered so a test can name the one it covers. "Caller" means anything reaching the app through the
gateway, by either door.

**Functional**

| | requirement |
|---|---|
| FR1 | No bridge method is invocable without a verified principal, on either door |
| FR2 | A principal is acquired only by presenting a credential minted by THIS instance |
| FR3 | Every credential names exactly one client, and every client carries a human-legible label fixed at mint time |
| FR4 | A client is revocable individually, effective on its next call, with no gateway restart |
| FR5 | ~~A caller with no credential can do exactly one thing: request pairing.~~ **VOID 2026-07-30** — pairing was dropped as the only genuinely new machinery. A caller with no credential can do NOTHING; it is enrolled by a named act instead (spawn, install, or by hand). This is stronger, not weaker: there is no unauthenticated verb at all |
| FR6 | ~~A pairing request is approved or denied by the user, who is shown the requested name.~~ **VOID 2026-07-30** with FR5. Consent moved to the enrolling ACT, and the name is no longer a caller's claim under review — the user types it, or Port42 already knows it |
| FR7 | Children the app spawns are registered with no prompt, and keep a stable identity across respawns |
| FR8 | Permission grants key on the client, so one caller's grant is never inherited by another |
| FR9 | ✅ **2026-07-29** for grants (Settings → Access, per capability and per grantee). Clients themselves arrive with half two |
| FR10 | Every refusal states how to fix it |
| FR11 | ✅ **2026-07-29.** No permission reaches a caller without passing through its principal and the permission request path. No blanket pre-grant exists (D12, deleted at A.3) |
| FR12 | ✅ **2026-07-29.** Every permission names its OBJECT, and the object is always a port. Machine capabilities (clipboard, filesystem, automation, notify, rest, screen, camera) are port 0's (see §4) |
| FR13 | ✅ **2026-07-29.** A zone qualifies the ACTOR on a grant. It is never an object, and never the only thing a key names |

**Behavioral**

| | requirement |
|---|---|
| BR1 | Channel and message traffic is unaffected by authentication. Sharing does not regress |
| BR2 | ⚠️ **REWRITTEN 2026-07-30, because the code deliberately does the opposite and is right.** Was: "a gateway with no secret serves channel routing only, and refuses `call` and `is_host`." A gateway with no host credential is the HAND-LAUNCHED RELAY, which has no stdin pipe to receive one. Refusing `is_host` there breaks the relay case rather than closing a hole, so `gateway.go` honors the claim when nothing is configured and checks it when something is (`hostCredentialConfigured() && !matches` → refuse). `call` is likewise not refused at the transport. **The enforcement moved rather than vanished:** a credential is verified by the APP on both doors, so an unauthenticated call is refused wherever the gateway came from. The requirement now reads: an APP-SPAWNED gateway refuses an unproven `is_host`, and no gateway of any provenance can produce a call the app will serve without a credential |
| BR3 | The app is host only of a gateway it spawned itself |
| BR4 | ~~At most one pairing request is pending at a time, and a pending request expires.~~ **VOID 2026-07-30** — no request exists to be pending. The state machine, its TTL and its one-at-a-time rule all went with pairing |
| BR5 | Revoking a client removes its token file |
| BR6 | Rotating the root secret invalidates every client at once, and is the only thing that does |

**Non-functional**

| | requirement |
|---|---|
| NFR1 | Credential comparison is constant-time |
| NFR2 | Secrets and tokens are never logged, never placed in an error body, never sent to analytics |
| NFR3 | Verification adds no round trip to a call |
| NFR4 | Instances are separated by their secrets, not by a path check |
| NFR5 | The gateway holds no client table and touches no filesystem |

**Compatibility**

| | requirement |
|---|---|
| CR1 | Ports calling `window.port42` are unaffected. They reach the bridge in-process and never traverse the gateway |
| CR2 | Remote peers and the ngrok tunnel are unaffected |
| CR3 | **REWRITTEN 2026-07-30**, because it promised a verb that was deleted. On upgrade no client exists, but MOST CALLERS ENROL THEMSELVES: a child at spawn, the CLI at install, while ports and the hooks shim never traverse this door at all. What is left is the caller nobody installs — a script, cron, a curl — which is added by hand in Settings. FR10 is what makes the refusal survivable |
| CR4 | A caller with no human present (cron, a background script) cannot pair, and needs a token made by hand in Settings. Stated regression |
| CR5 | ~~The existing `portPerms.*` grants migrate without widening.~~ **SUPERSEDED 2026-07-29 (GM): nothing migrates.** The objectless store is REAPED and every grant is asked for again. Only 9 of its 144 keys could ever have fired, so a faithful migration would have preserved nothing. The replacement requirement: no grant survives the reap, and no caller inherits one |

### 4. The model, and the user-facing surface (UX down)

**GM, 2026-07-28: "the DESKTOP IS A PORT. PORT 0."** Clipboard, filesystem, automation, notify, rest,
screen and camera are not portless capabilities sitting outside the model. They are port 0's. So
`caller → port → action → permission` holds with no exceptions.

**ONE primitive: a port.**

| | |
|---|---|
| **port 0** | the Port42 window itself. Its title is already its name, so the user-facing word is "Port42", not an invented one like "desktop" |
| **ports** | tiles, terminals, browsers, chat. Done: address, actor and token are each single-definition |
| **zones** | a grouping OVER ports, a space being the first one. On top of the primitive, never a kind of object (GM, 2026-07-28) |

**The measurement that settles it.** Production holds 144 grants (re-measured 2026-07-29; it was
143 on 07-28, and the extra one is a `terminal` grant). What they grant:

```
121 terminal    18 screen      8 clipboard     2 microphone
 21 rest        18 filesystem  6 automation    1 notification
                12 ai
```

Every one is a port 0 capability, and 141 of the 144 keys are space-scoped. So the current key,
`portPerms.<grantee>.<spaceId ?? "global">`, holds a grantee and a space and **no object at all**.
The object was always the machine; it simply had no name, so the space slid into the slot where the
object belonged and has been impersonating it. That is why the model read as muddled.

```
today     <grantee> × <space>             the object is implicit and unnamed
after     <grantee> × <port>  [× zone]    the object is named; the zone qualifies the ACTOR
```

**A space was never scoping what is acted on. It was scoping the context the actor acted in.** Two
different questions sharing one key. Naming port 0 separates them, and it is also why a zone
qualifying a subject is not doing a primitive's job.

**Nothing migrates. The store is reaped** (GM, 2026-07-29), for the reason in the next paragraph:
the grants that would have been carried forward were almost entirely unreachable, so preserving them
faithfully would have been preserving nothing.

**What the same measurement says about the store itself, and it is worse than the count suggests
(2026-07-29).** Only **9 of the 144 grants point at anything that still exists**: 6 are qualified by
a live space and 3 are `global`. The other **135 name a space that has been deleted** (18 of them
carrying the legacy `swim-<uuid>` form). On the other axis, **43 of the 58 grantees match no live
agent** — agent ids are UUIDs now, and 10 of the 15 UUID-shaped grantees are live companions, while
the named ones are `echo`, `forge`, `claude`, `claude1` … `claude101`, `claudeSat1`, `"Claude Code"`,
`"Claude Codetest"` and `"Gemini CLI"`. **Those last three are §1's weaker door showing up in the
data**: a caller that named itself in `identify` became that principal, and now holds standing
capability that nobody can see or revoke. Nothing reaps any of it, which is why the count went
119 (07-27) → 143 (07-28) → 144 (07-29).

**So the store is reaped and the model starts from an empty one** (GM, 2026-07-29). The deciding
number is that **only 9 of the 144 could ever fire again**: a grant is read with the caller's LIVE
zone, so 135 keys naming a deleted space were unreachable rather than merely untidy. Carrying them
forward would have preserved nothing and opened the permission manager on 135 rows describing a
world that no longer exists. What it costs is one more ask per companion per capability per space,
which is the same shape as D12 and lands in the same release. What it discards is the record above,
which is why the census is written down here and the raw store was dumped beside the production
database before the reap ran.

This section is mapped UX first, deliberately. The protocol serves these surfaces; the surfaces are
not a rendering of the protocol.

**Every touchpoint, and its state**

| # | touchpoint | where | state |
|---|---|---|---|
| 1 | the permission card | `ShellPermissionOverlay.swift` | exists. Says "Local (gateway)". Must name the caller and the port it wants to act on |
| 2 | a second, dead permission overlay | `PortWindowManager.swift:1657` | `PortPermissionOverlay` has no call site. Retired with the window mode. Delete |
| 3 | who is connected, and revoke | Settings | does not exist. **IS the permission manager** (`summer2026-todo.md`, 2026-07-27), not a second screen beside it. See D13 |
| 4 | connect a tool | Settings, the instruction-block buttons | exists as "install instructions". Becomes the enrollment act that mints a token |
| 5 | Remote Access pre-approval | Settings → Remote | three blanket toggles, all ON in production. DELETED (D12) |
| 6 | the driver chip | tile header | exists. Names whoever last moved a port's token. Extends to port 0 for free |
| 7 | port 0, the Port42 window | `ShellDesktop.swift` | exists as a view with no identity. Port 0 is what gives it one |
| 8 | a zone (a space) | `NewSpaceSheet`, the galaxy | exists. Becomes an actor qualifier on a grant, not an object |
| 9 | ⌘K switcher | `QuickSwitcher.swift` | exists. Lists port 0 once it has an identity |
| 10 | the generated instruction block | `InstructionService` | a touchpoint for the agent AND for GM reading it. Loses the Remote Access line, gains the header |
| 11 | onboarding | `SetupView` → shell | never mentions callers or grants. Open question whether it should |

**What the card should say.** Uniform, because the model is uniform:

```
Claude Code wants to read the clipboard in Port42
Allow for Claude Code in Port42. Revoke it any time in Settings.
```

```
Echo wants filesystem access in Port42, while working in #port42-app
```

The second names the object (port 0), the actor (Echo) and the zone that qualifies it, which is
exactly the three parts of the key above.

**The consequence to be honest about.** The grant key gains an object and the space becomes a
qualifier. That is a change to the permission model, not only to the gateway, and every existing
`portPerms.*` key is discarded by it rather than translated (§4). It is the reason this phase grew:
P1 began as authenticating a socket and is now also where authorization gets its missing noun.

### 5. Design

**D0. The decomposition, and the invariant on each interface**

**AS BUILT (corrected 2026-07-30).** The design put the verifier on the transport. It ended up in the
app, and the diagram below is what exists:

```
  ClientRegistry (app)        the only place a token is minted, named or revoked
        │ host secret only, over the gateway's stdin at spawn
        ▼                     (the ROOT secret never leaves the app)
  Router (gateway)            envelopes, addressing, host routing.
        │                     Carries `credential` OPAQUELY: parses nothing, verifies nothing
        │ credential
        ▼
  Verifier (app)              credential → client id, or a refusal. Stateless.
        │
        ▼
  Authorizer (app)            client → enrolled? → grants → allow / prompt / deny
```

| interface | invariant |
|---|---|
| registry → gateway | the gateway holds one secret (the host one), no table, and never reads the filesystem |
| caller → verifier | a credential is the only way to acquire a principal |
| verifier → authorizer | a caller identity is produced ONLY by `resolveGatewayCaller`, from a credential, on the app side of the boundary |
| router | `sender_id` addresses. It never authorizes. It stays caller-supplied and untrusted |
| authorizer | `Principal.peer` is constructed only from a verified client id. `sender_id` never reaches it |

The last one is greppable and testable, and it is the gate. `Principal.peer` has exactly two
production construction sites, both in `ToolExecutor.swift`, and both now receive the verified id
that `AppState.onCallReceived` resolved.

**Why the verifier moved, and it is the better answer.** Splitting mint from verify across two
languages gives the token format two implementations that can drift, and it requires the root secret
to cross a process boundary in order to be useful on the far side. Keeping both in the app means the
format has one implementation, the root secret never leaves, and the gateway's job shrinks to
carrying an opaque string. **What the original split bought was instant revocation without gateway
state, and that survives intact.** The app was always going to be the one deciding whether a client
still exists.

**Under this decomposition there is no "HTTP work" and no "WS work".** Both doors reduce to "produce
a verified `principal_id` or don't", so neither can be fixed while the other is forgotten. That is
the structural answer to the failure mode this session kept repeating: a fix verified on one caller
path and assumed to hold on the others.

It is also what makes slice-02 cheap. libp2p adds a verifier that maps a PeerID to a principal, and
nothing above the seam changes.

**D1. The data model**

One new GRDB table, added as a new migration (never edit an existing one).

```
clients
  id          TEXT PRIMARY KEY    slug, [a-z0-9-]+, stable for the life of the client
  name        TEXT NOT NULL       the label shown on permission cards
  kind        TEXT NOT NULL       child | installed | manual   (paired is unreachable, below)
  createdAt   DATETIME NOT NULL
  lastSeenAt  DATETIME            updated on each accepted call
  revokedAt   DATETIME            null means active
```

**`kind` as built.** `installed` was added (GM, 2026-07-29) for a first-party tool Port42 installs,
enrolled at install time: installing is itself a named act with the user present, which is the same
argument that lets a spawned child enrol with no prompt. It is distinct from `manual` because the
user did not NAME this one, Port42 knows what it is. **`paired` survives in the enum with no
production construction site**, since pairing was dropped (FR5). It is reachable only from tests.
Left rather than deleted so a stored row from an early build still decodes; nothing new can be
written with it.

`id` is a slug rather than a UUID because it is also the token file's name, and the documented client
flow is "read a known path, pair only if it is missing". A UUID would make the path unknowable before
the first enrolment, which is the inconsistency that has to be avoided.

**The grant key gains its missing object. DONE 2026-07-29** (§10a). Was
`portPerms.<grantee>.<spaceId ?? "global">`; now `portGrant.<grantee>.<object>.<zone>`, naming
grantee, object port, and the zone that qualified the actor (§4). The old keys are REAPED, not
translated (CR5, superseded). `grants(grantee:on:zone:)` / `saveGrants(…)` are the one read/write
pair, so the permission manager (D13) and this share a store.

**A child's id is derived, not random**, so a companion terminal keeps its grants across respawns:
`child-<companionId>-<spaceId>`, slugged. Re-registering an existing slug re-issues onto the same row,
so a user who deletes a token file gets a new credential and keeps their grants.

**The host is not a row.** It is ephemeral and holds no grants, so it never enters this table.

**D2. Secrets, and how they reach the gateway**

| secret | where it lives | lifetime |
|---|---|---|
| root | Keychain, service `Port42-credentials`, account `gateway-root-<instance>` | until rotated |
| host | app memory only, never written anywhere | one gateway spawn |

Both are 32 random bytes. The root secret is created lazily, on the first mint rather than at launch,
so a build that never enrols anything never writes to the Keychain. It is the only thing that can
mint a client token. The host secret is regenerated on every gateway spawn, which is what makes
`is_host` unforgeable by anything on disk.

**AS BUILT, ONE secret reaches the gateway and it is the host one** (corrected 2026-07-30; this
section planned two). The root secret never leaves the app, because the gateway was given nothing to
verify: a client credential rides through it OPAQUELY and the app both mints and checks it (D4). That
is strictly better than the design and it is worth naming as the reason. **A secret that never
crosses a process boundary cannot be leaked by the process on the other side**, and the token format
ends up with exactly one implementation instead of one per language.

**The host secret reaches the gateway on stdin, not in its environment**, for the reason measured in
§1: `ps -E` publishes a subprocess environment to every process running as the user. The app already
holds the write end of the gateway's stdin for the EOF-on-death watch and never writes to it, so it
writes one line **after `run()`** (the read end does not exist until the child does) and then leaves
the pipe open exactly as before.

**The read is gated on `-watch-parent`**, the flag that already distinguishes an app-spawned gateway
from a manually launched one. A relay started by hand has an interactive stdin, and a blocking read
there would hang it.

**D3. Token format and verification**

```
p42_<id>_<mac>          mac = base64url-unpadded( HMAC-SHA256(secret, id) )
```

`id` is constrained to `[a-z0-9-]`, so splitting on `_` always yields exactly three parts. **The MAC
covers the id**, so a token cannot be replayed as another client. The slug constraint is also what
stops a caller-supplied name smuggling a path separator into the token FILE's name: the name is a
claim, and slugging is what makes it safe as both a filename and a key.

**AS BUILT, the APP recomputes the MAC, not the gateway** (corrected 2026-07-30; this section put the
verifier on the transport). `ClientRegistry.verify` compares in constant time (NFR1) and
`AppState.resolveGatewayCaller` then decides whether that client still exists. The gateway consults
no table, stores nothing and parses nothing, which keeps NFR5 true more completely than the original
design did.

**NFR1's gate is STRUCTURAL, because the behavioral one was a lie.** A test named "constant-time"
that only asserts a near-miss fails is satisfied by plain `==`, and when the naive comparison was
substituted that test stayed green. The real gate scans `verify`'s body: it must route through
`constantTimeEquals` and must not compare a MAC with `==`. Timing is not unit-testable, so the
guarantee has to be structural.

The host credential is the same construction over the host secret, so one routine covers both and
they differ only in which secret is used.

**D4. The wire**

| door | where the credential rides |
|---|---|
| HTTP `/call` | `Authorization: Bearer <token>` |
| WS `/ws` | a `token` field in the `identify` envelope |

The WebSocket API cannot set request headers, so `identify` is the only place available on that door.
It is already the auth point the Apple verifier uses.

The envelope gains one field:

```
principal_id   string, omitempty
```

It is **stripped and re-stamped on every inbound envelope in the gateway's read loop, before
dispatch**. Unconditional overwrite is the mechanism, not a check, so a caller-supplied value cannot
survive by any path. `sender_id` is untouched and keeps its routing meaning.

~~Two new envelope types carry pairing between the gateway and the app.~~ **DROPPED with pairing.**
The envelope gained `credential` instead — a client's token, carried OPAQUELY, because the app both
mints and verifies it. Note what is deliberately absent: no inbound `principal_id`. This section
originally planned to strip and re-stamp one on every envelope; carrying a credential means there is
nothing to forge and nothing to remember to overwrite.

**D5. Enrollment: a token is minted by a named act, never picked up**

**There is no root token and no ambient token file.** An unconsented enrollment is the same hole one
level out: anything that can read a shared file becomes a legitimate principal with no human in the
loop, and a caller that enrolled itself has no name anyone gave it, which is what produces today's
anonymous permission card.

Every token is minted by `ClientRegistry` at a moment that already carries consent:

1. **Pairing**, for a caller Port42 did not spawn. One unauthenticated verb whose only power is to
   ask.
2. **Spawn**, for children (companion terminals, command agents). Registered directly with no
   prompt, because the user spawning them is the consent and the app is both parties.
3. **By hand**, in Settings, for the user's own scripts and for any caller with no human present.

**THE PAIRING PROTOCOL BELOW WAS DESIGNED AND THEN DROPPED** (GM), and is kept only as the record of
what was considered. It is not built and nothing calls it. What replaced it: enrolment by a named act
— a child at spawn, the CLI at install, anything else by hand in Settings → Access.

Why it went, beyond "one less thing": it required an UNAUTHENTICATED verb, the one door that must stay
open for anything to get in, plus a pending-request state machine, a TTL, and a one-at-a-time rule. It
also let any local process raise a dialog at any moment showing a name IT chose — the doc's own words,
"a claim under review". Enrolment by a named act has no network surface, and the name is either typed
by the user or already known to Port42, so there is no claim to review.

The dropped design:

```
POST /pair            {"name": "Claude Code"}
  202  {"request_id": "...", "expires_in": 120}
  429  pair_busy       a request is already pending
  503  no_host         Port42 is not running
  403  pair_disabled   the user turned pairing off

GET /pair/<request_id>
  {"status": "pending"}
  {"status": "denied"}
  {"status": "expired"}
  {"status": "approved", "token": "p42_...", "path": "~/.port42/<instance>/tokens/claude-code"}
```

State machine: `pending → approved | denied | expired`. TTL 120 seconds, one pending request at a
time (BR4), held in gateway memory only. An approved result is handed to the polling client once and
then forgotten, so the gateway never retains a token.

Port42 writes the approved token to `~/.port42/<instance>/tokens/<id>` at 0600 inside a 0700
directory. The app owns the file, so revoking removes it.

The requested name is caller-asserted. It is shown to the user at the moment of approval, so it is a
claim under review rather than a trusted fact, which is the same contract every pairing UX makes.

**Instance separation falls out of the secret**, not out of a path check: prod, Dev and Dev3 hold
different root secrets, so a token minted by one fails another's verification.

**D6. What happens on a call, in order**

**AS BUILT (corrected 2026-07-30).** Steps 2 and 4 planned a gateway-side verifier and a
`principal_id` field. Neither exists. The order is:

1. The credential arrives, in `Authorization: Bearer` on `/call` or in the envelope on `/ws`.
2. **Router** forwards it to the host untouched, keyed on `CallID`. It does not parse it and cannot
   refuse it.
3. **App** (`AppState.onCallReceived` → `resolveGatewayCaller`) refuses a call carrying no
   credential, with `auth_required`.
4. **App** recomputes the MAC in constant time. A token that does not verify is refused with
   `auth_required`, whose message says it may belong to a different instance, which is the one
   failure a caller cannot diagnose from the outside.
5. **App** looks the client up. Missing or revoked gives `auth_revoked`. Otherwise `lastSeenAt` is
   updated.
6. `Principal.peer(id: <verified client id>, displayName: client.name)`.
7. The existing permission coordinator runs unchanged: grant lookup, prompt if needed, dispatch.

**BOTH DOORS REDUCE TO THE SAME FUNCTION, and that is the structural answer** to the failure mode
this scope was built on. There is no HTTP path and no WS path to verify separately: the two doors
differ in where the credential sits and in nothing else, and they meet at one `onCallReceived`.

**There is no `auth_invalid`.** D10 listed it; a bad MAC returns `auth_required` instead, deliberately,
because the caller's fix is the same in both cases and a second code would only ask them to tell apart
two states they cannot observe.

**D7. Revocation and rotation**

**Revoke** sets `revokedAt`, deletes the token file, and closes any live WS peer holding that
credential. It takes effect on the client's next call. The gateway is not involved and is not
restarted.

**Rotate** replaces the root secret, deletes every token file, and restarts the gateway. Every client
must pair again. It is the panic button, and it is the only thing that invalidates everything at once
(BR6).

**D8. Startup, restart, and degraded modes**

A gateway's lifetime is contained by the app's, through the `willTerminate` observer plus the
`-watch-parent` EOF watch. So a new app launch always means a new gateway and a new host secret, and
there is no path where an old host credential outlives the app that minted it.

| situation | behavior |
|---|---|
| gateway spawned by the app | receives both secrets on stdin, full function |
| gateway launched by hand, or a remote `gatewayURL` | no secrets, so it serves channel routing only and refuses `call` and `is_host` (BR2). The app cannot be its host (BR3) |
| gateway restarts mid-pair | the pending request is lost, the client polls and sees `expired`, and retries |
| app restarts mid-pair | same |
| user deletes a token file | that client can no longer authenticate and is enrolled again — automatically for a child or the CLI, by hand otherwise. The row survives, so re-issuing the same slug lands on it and the grants are kept |

**D9. What happens to an existing install on upgrade**

On first launch after the upgrade the root secret is minted and the client table is empty. **CR3 used
to say every gateway caller is then refused until it PAIRS — and pairing was dropped, so that sentence
promised a verb nobody could call.** Worse, it made the break sound total when it is not.

What actually happens, measured against what now exists:

| caller | on upgrade |
|---|---|
| a companion terminal | enrols itself at spawn. Nothing to do |
| the `port42` CLI | enrols itself at install, which the app performs at every boot. Nothing to do |
| a port's `window.port42` | unaffected — in-process, never traverses the gateway (CR1) |
| the hooks shim | unaffected — it uses its own unix socket, not `/call` |
| a script, cron, a bare `curl` | **refused until added by hand** in Settings → Access |

So the deliberate break is real but narrow: it lands on callers nobody installs, which is exactly the
set that has no named act to hang enrolment on. That is CR4's stated regression, and add-by-hand is
its answer. FR10 is what makes the refusal survivable rather than a wall.

`InstructionService.refreshInstalled()` already rewrites the instruction block at every boot, so a
new Claude Code, Gemini or Codex session reads the new flow. **A session already running holds the
old block in its context and will not**, which is exactly why the refusal has to carry the fix.

The orphaned `portPerms.local-http.*` grants become unreachable the moment `localGatewayID` is
deleted, so they are inert. Whether to park or delete them is open (§13).

**D10. Errors, and the refusal that carries its own fix**

**REWRITTEN 2026-07-30 against the enum, which is the only honest source.** Codes are values in
`BridgeErrorCode.swift` and the published docs render from it, so this table names what exists rather
than restating it:

| code | state | meaning |
|---|---|---|
| `auth_required` | ✅ built | no credential presented, OR a MAC that does not verify |
| `auth_revoked` | ✅ built | verified, but the client no longer exists or was withdrawn |
| ~~`auth_invalid`~~ | ❌ never built | folded into `auth_required` (D6): same fix, and the caller cannot tell the two states apart anyway |
| ~~`pair_busy`~~, ~~`pair_disabled`~~, ~~`pair_expired`~~ | ❌ void | went with pairing (FR5/FR6) |
| `no_host`, `host_offline`, `timeout`, `bad_request` | ❌ **STILL OPEN** | the gateway's own failures are still bare strings: `"no host available"`, `"no host available in channel"`, `"host is offline"`, `"failed to reach host"`, `"timeout waiting for host response"` |

**The last row does NOT close the register §5 item, and this doc claimed it did.** It is the ERRORS
row of Part 0, half built: the app side is typed and the transport side is not. A remote caller
reaching a peer through a relay meets the untyped strings first, which is why it belongs with
milestone B rather than after it.

`auth_required` names the header, the token path and where to add a client, in the same shape as
`stale_write` carrying `current`. A stale caller self-corrects in one retry, and a caller that was
never enrolled is walked into enrolment by the error itself, so one mechanism does both jobs.
`isRetryableWithCurrentState` is pinned to exactly `stale_write` + `token_required`, so neither auth
code invites a retry that cannot work. No error body ever echoes a token (NFR2).

**D11. User-facing surfaces**

- **The pairing prompt.** Shows the requested name, marked as the caller's own claim, and states that
  the request arrived on loopback, which is the only thing we actually know about it. Allow or Deny,
  and dismissing means Deny.
- **Settings, secrets tab.** The client list with name, kind, created, last seen, and Revoke. Add by
  hand for a caller that cannot pair.
- **The permission card.** Named by the client, so it reads "Echo's terminal in #port42-app wants
  filesystem access" rather than "Local (gateway)".

**D12. The blanket pre-grant (`remoteAllow*`) is REMOVED (GM, 2026-07-28)**

Three UserDefaults flags union terminal, filesystem and screen into every gateway call before the
principal exists (§1). They are the one thing in the system that can hand out authority without
naming anybody.

**Decision: delete them. Every capability goes through the permission request path.** GM: "has to go
through permission request path... it does seem unnecessary."

The mechanism made sense while callers were anonymous, because there were only two options and both
were bad: prompt on every single call, or trust everything. There was nothing to attach a grant to.
Per-client grants are that missing third thing, so the flags become redundant rather than merely
unsafe. Grants already persist per principal (`portPerms.<id>.<space|global>`), which is why the
pooled `local-http` bucket accumulated one in the first place. So the flags were never buying
standing access, only skipping the FIRST prompt per capability per client.

What it costs, stated because it is what a user feels: after upgrading, a client asks once for
terminal, once for filesystem, once for screen, and then never again.

**The existing production values are not migrated**, for the same reason the `local-http` grants are
not: they were granted to "anything that calls", which is not a client, so there is no client to
attach them to without inventing a consent that was never given.

Five sites, and the flags are gone from the codebase rather than defaulted off:
`SignOutSheet.swift:25-27` (the `@AppStorage` declarations), `:659-661` (the Remote Access toggles),
and `ToolExecutor.swift:140-144` (the `pregrant` construction). The generated instruction block's
line "Pre-approval lives in Port42 Settings → Remote Access" goes with them.

**D13. The permission manager is IN SCOPE, and it is touchpoint 3**

The backlog already carries it (`summer2026-todo.md`, 2026-07-27: "you cannot see or revoke what you
granted"). It is in P1 rather than after it because P1 cannot satisfy FR9 without it, and because
building a client list first would produce a second screen answering the same question.

**Measured 2026-07-28, re-measured 07-29:** production held **144 grant keys** (143 the day before,
119 on 07-27), dev 41, Dev3 2. Nothing in `Sources/Port42Lib/Views/` reads a grant, so no UI has ever
displayed one. **The count question is answered: the store was growing, not the counts differing.**
It was never reaped, which was the actual defect, and §4 has the shape of it: 135 of the 144 were
qualified by a space that no longer exists, and 43 of the 58 grantees matched nothing live.

**Step 1 reaped all of it, so the manager now opens on an empty store** and fills only with grants a
human actually gives. That is a better first screen than 144 rows of archaeology, and it means the
manager's job is legibility and revocation rather than cleanup. **What it does NOT fix is the cause:
nothing expires or reaps a grant, so the same accumulation starts again from zero.** Expiry stays out
of scope (below), but the reaping question is now a live one for the manager rather than a historical
one.

**One screen, grouped by grantee**, which is the backlog's own sketch. A client is a grantee kind
beside companion, port and peer, so "who is connected" and "what did I grant" are one list:

```
Claude Code                        connected · revoke client
  desktop        clipboard, filesystem            revoke
  #port42-app    terminal                         revoke

Echo                               companion
  #port42-app    filesystem, ai                   revoke
```

`Principal.scopeDescription` already generates the sentence a row needs, and the screen reads and
writes the existing `grants` / `saveGrants` pair, so it adds no storage.

**It is also the only way the rest of P1 is verifiable by the person it protects.** The object slot
and revocation both happen inside a store nobody can see, and every grant it will hold from now on
was given by a human who was never shown it again. The backlog item makes this point about itself and
it applies doubly here.

**Out of scope within it, and stated so it does not creep:** whether grants expire. Everything is
permanent today, which is what makes an invisible grant serious, but expiry is a policy decision and
this phase is about legibility and revocation.

**D14. Alternatives rejected, and why**

| rejected | reason |
|---|---|
| a root token in a shared file | enrollment with no human in it, and it is what produces the anonymous card |
| dropping the Keychain for a plain file | the only motivation was a dev-instance launch prompt, and release builds do not have it |
| handing the gateway its secret in the environment | `ps -E` publishes it to every process running as the user |
| minting inside `InstructionService` | gives a documentation writer a second job, fires on the wrong event, and does not generalize past the three tools that have instruction files |
| a token that carries capabilities | bootstrapping goes circular, and per-actor grants stop being expressible |
| the gateway holding a client table | needs a push channel and state that survives its own restart, for no gain over HMAC plus an app-side enrollment check |
| gating `/call` only | the WS door is the weaker one, and lets a caller pick its own principal |
| a soft-enforcement window | a door left open behind a doc that says it is closed, which is the P0 lesson |

### 6. What this buys, in the user's terms

The visible payoff is naming, not encryption. Today a prompt is anonymous and pooled:

```
Local (gateway) wants filesystem access
```

Allowing it once grants it to every local process, forever. After P1:

```
Echo's terminal in #port42-app wants filesystem access
```

The grant lands on that caller alone, and it can be revoked by itself.
`Principal.gatewayDisplayName(for:)` is the single site that changes.

### 7. Deliverables

Where the design above lands in the tree. The design says what it is; this says what changes.

**App**

**Marked against the tree, 2026-07-30.** Line numbers are the ones that were true when the row was
written and are not maintained.

| what | state | where | design |
|---|---|---|---|
| `ClientRegistry`, the only minting site | ✅ | `Services/ClientRegistry.swift` | D1, D3, D5 |
| `clients` table, new migration | ✅ | `DatabaseService.swift`, `v44-clients` | D1 |
| root secret, per instance | ✅ | `AgentAuth.swift`, account `gateway-root-<instance>` | D2 |
| host secret per spawn, written to stdin | ✅ **one secret, not two** | `GatewayProcess.swift` | D2 |
| token file write and removal | ✅ 0600 in a 0700 dir | `ClientRegistry` | D5, D7 |
| ~~the pairing prompt and its approval path~~ | ❌ **void** | n/a | dropped with FR5 |
| refuse a call with no credential, and refuse a revoked client | ✅ | `AppState.onCallReceived` → `resolveGatewayCaller` | D6 |
| two `Principal.peer` sites take the verified id | ✅ | `ToolExecutor.swift` | D0, D6 |
| children registered at spawn | ✅ | `AppState`, `TerminalHooksService.swift` | D1, D5 |
| the `port42` CLI enrolled at install | ✅ **added, not in the original list** | `CLIInstallService.swift` | D1 |
| `localGatewayID` deleted, `isSharedIdentity` kept returning false | ✅ | `Principal.swift` | D9 |
| the permission manager: grants grouped by grantee, revoke per row and per grantee, clients as a grantee kind, add by hand | `SignOutSheet.swift`, new screen | D11, D13 |
| delete the dead `PortPermissionOverlay` (no call site) | `PortWindowManager.swift:1657` | §4 touchpoint 2 |
| the three `remoteAllow*` flags and their Remote Access toggles deleted | `SignOutSheet.swift` (:25-27, :659-661), `ToolExecutor.swift` (:140-144) | D12 |

**Gateway**

| what | state | where | design |
|---|---|---|---|
| read the host secret from stdin when `-watch-parent` is set, then resume the EOF watch from the SAME buffered reader | ✅ **one secret** | `main.go`, `credentials.go` | D2 |
| ~~verify a credential and stamp `principal_id`~~ | ❌ **moved to the app** | n/a | D0, D3 |
| ~~strip and re-stamp `principal_id` on every inbound envelope~~ | ❌ **void** | n/a | the field does not exist; there is nothing to forge and nothing to remember to overwrite |
| carry `credential` OPAQUELY on the envelope | ✅ | `gateway.go` | D4 |
| `Authorization: Bearer` on `/call` | ✅ | `HandleHTTPCall` | D4 |
| `is_host` proven by the host credential when one is configured | ✅ | identify | D2, D8, BR2 |
| ~~`POST /pair`, `GET /pair/<id>`~~ | ❌ **void** | n/a | dropped with FR5 |
| the gateway's own error codes | ❌ **STILL OPEN** | `gateway.go` | D10, Part 0 ERRORS |
| never log a secret or a token | ✅ | throughout | NFR2 |

**Two rows in this table are the wire half's inbox, not oversights.** The gateway's own failures are
still untyped strings (D10), and `sender_id` is still stamped `local-http` on the HTTP door as a
ROUTING address. The second is harmless by construction, because nothing authorizes on `sender_id`
any more, but it is a value the rest of the tree describes as deleted and it will read as a live
identity to whoever meets it next.

**Docs and generated artifacts**

| what | where |
|---|---|
| curl examples gain the header; the block documents read-the-file-then-pair, mints nothing, contains no token; the "Pre-approval lives in Settings → Remote Access" line is dropped | `InstructionService.buildMarkdown` |
| the same header on every example | `llms-preamble.txt`, `README.md` |
| the auth codes beside the existing taxonomy | `ports-context.txt` |

`llms.txt` and `Tests/Fixtures/tool-definitions-golden.json` are generated. Regenerate through their
existing paths and read the diff.

### 8. Out of scope, deliberately

- **HTTPS.** The gateway is on loopback. TLS there protects against nothing an attacker on the
  machine cannot bypass, and costs a certificate story that is unpleasant locally. It becomes
  necessary when the door stops being loopback, and stays scoped to the tunnel and the relay. P2.
- **Relay auth (F-511)** and remote peer identity. Channel traffic is untouched.
- **Per-program identity.** That is the permission-manager thread.
- **Resistance to a process running as the user.** See limits.

### 9. Stated limits

- This does not defeat a process running as the user, and no local-socket design will. A token file
  is readable by anything with the user's uid. What P1 buys is that every caller is named, enrolled
  by a deliberate act, and individually revocable.
- A leaked token stays valid until it is revoked or the root secret is rotated.
- The name a pairing client supplies is its own claim, reviewed by a human at approval.

### 10. Build order

Two halves, in this order, because the naming half is meaningful on its own and the credential half
is not meaningful without it. Each step leaves the app shippable.

**Half one: the object, and making consent visible.** Nothing here authenticates anything, and
nothing here can strand a caller.

1. **Port 0 exists. DONE 2026-07-29, live-verified in Dev3.** The grant key gained its object slot:
   grantee × port [× zone]. The objectless store is REAPED rather than migrated (CR5, superseded),
   so the model starts from an empty one. See "Step 1 as built" below.
2. **The permission manager** (D13). **DONE 2026-07-29, live-verified in Dev3.** Grants moved to a
   table, grouped by grantee, revocable per capability and per grantee. The first time in the
   product's life that a granted permission can be seen. See "Step 2 as built" below.
3. **The card names its object. DONE 2026-07-29, live-verified in Dev3.** `scopeDescription` reads
   "Allow for Claude Code in Port42, everywhere. Take it back any time in Settings → Access." The
   dead `PortPermissionOverlay` and the `remoteAllow*` pre-grant are both deleted. See "Step 3 as
   built" below. **Half one is complete.**

**Half two: the credential.** Every step here has the manager from step 2 to make it legible.

4. **Store and mint. DONE 2026-07-29.** Root secret, derived tokens, the token file, the `clients`
   table, and clients in the manager as a grantee kind. Nothing enforces yet. See "Step 4 as built".
5. **Seam and verifier together. DONE 2026-07-29/30, in two parts.** **5a**: a caller's identity comes
   from its CREDENTIAL, never from `sender_id`. **5b**: an unnamed caller is REFUSED, and
   `local-http` is deleted as an identity rather than preserved. Carrying a transport label through
   a transition step would have seeded the new field with exactly the kind of value it exists to
   eliminate. See "Step 5 as built" below.
6. **Children. BUILT 2026-07-29** (taken BEFORE step 5, see below). Per-child registration at
   spawn, which is where the pooled bucket actually dies. A companion terminal is enrolled as a
   `child` client with a DERIVED id, and its process is handed `PORT42_CLIENT_ID` and
   `PORT42_TOKEN_FILE` — **the id and the path, never the token**, because `ps -E` publishes a
   subprocess environment to every process running as the user. Ad-hoc terminals (no companion) get
   no identity rather than sharing one. Unit-tested; the live spawn path is not yet verified.

**5 AND 6 ARE SWAPPED (2026-07-29).** The doc ordered them 5 then 6, justifying step 5 as safe
"because by then every caller has a token" — which is only true once 6 has run. Doing 5 first would
strand every running companion in the gap between enforcement and enrolment. Same end state, no
window where the user's own companions are locked out.

Step 5 is the only one with a blast radius, and by then every caller has a token, the refusal teaches
the fix, and the manager shows what happened.

**ALL SIX STEPS ARE DONE, and so are the two Part 0 rows this list never contained.** OUTPUT (§10c,
§10d) and ERRORS (§10e) were both built on 2026-07-30, after an audit found the document claiming the
local half was complete on the strength of a fully ticked build order that did not mention them.
**Worth keeping as a process note: a checklist can only report on its own rows.**

**If you want to ship less:** half one is a coherent release by itself. It names the primitive, makes
144 invisible grants visible and revocable, and removes the blanket pre-grant, without touching
authentication at all.

### 10a. Step 1 as built (2026-07-29)

`PortObject` (new, `Sources/Port42Lib/Services/PortObject.swift`) is the object a grant is about:
`PortObject.machine` is port 0, and an object is peer-qualified by construction
(`<peerID>/0`, `<peerID>/<portKey>`), in the same grammar as the address, so the wire half adds a
peer and no concept. `PortGrantKey` beside it owns the key `portGrant.<grantee>.<object>.<zone>`.

`AppState.companionPermissions(createdBy:spaceId:)` and its save pair became
`grants(grantee:on:zone:)` / `saveGrants(_:grantee:on:zone:)`. **Three parameters because the key has
three parts**, so a caller cannot read or write a grant without naming its object. Five production
sites, all passing port 0: both dispatchers, `PortBridge`, `ToolExecutor`, and the DEBUG actor probe.

**Reap, once** (GM, 2026-07-29). `PortGrantKey.reapGrantStore` deletes every `portPerms.*` key at
launch and carries nothing forward, so the grant store starts empty. Both prefixes go, because
neither the new key nor the copy-forward migration it replaced ever shipped: after this a
`portGrant.*` key can only mean a grant a human actually gave. The once-only flag is load-bearing
rather than an optimization, since a reap on every launch would delete grants continuously and the
store could never accumulate the consent it exists to remember.

**Why reap rather than migrate**, which reversed the first decision of the day: only 9 of the 144
grants could ever fire again (§4). A grant is read with the caller's live zone, so the 135 naming a
deleted space were unreachable, and migrating them faithfully would have been preserving nothing
while opening the manager on 135 dead rows.

**Honest about what the slot can prove today.** Every `PortPermission` case is a machine capability,
so no production path can name an object other than port 0, and a migration that only ever writes `0`
is indistinguishable from a key rename. The tests therefore exercise a non-zero object deliberately:
a tile key and a peer-qualified object, each isolated from port 0 in both directions.

`PortObjectGrantTests`, 11 tests, suite **1183 green**. Four gates, every one calibrated by breaking
it: dropping the object from the key was caught by the separation tests (a tile grant leaked onto
port 0); a hand-built key planted in `ToolExecutor` was caught by the tree-wide scan that permits a
grant key nowhere but `PortObject.swift`; a reap matching on the bare prefix ate a
prefix-adjacent default; and a reap with no once-only guard ate a grant given after it ran.

**Live-verified in Dev3**, which is what "done" means here. All five of its keys (two `portPerms.*`,
two `portGrant.*` from the retired migration, and that migration's flag) were gone after launch, with
only the reap flag left. `automation.runAppleScript` over the gateway had returned `{"result":"42"}`
silently before the reap; after it, the same call blocks on a permission prompt. That is the whole
user-visible consequence, measured rather than asserted.

### 10a2. Step 2 as built (2026-07-29)

**The store is a table** (GM, 2026-07-29), migration `v43-grants`, taken deliberately because step 2
is the first thing that reads the whole store and the window was free: the store was empty after the
reap, and that window closes the moment real grants accumulate.

```
grants(grantee, object, zone, permission, grantedAt, lastUsedAt)
  PRIMARY KEY (grantee, object, zone, permission)
```

**One row per permission**, which is the point: revoking a single capability is a DELETE, where the
comma-joined defaults key made the smallest withdrawable unit *everything*. `zone` is NOT NULL with
`""` for unzoned rather than nullable, because SQLite treats NULLs as DISTINCT and a nullable column
in a primary key would not enforce uniqueness. Nothing migrated in; the table starts empty.

**`lastUsedAt` is in from the start**, throttled to one write per key per minute. The read side is
every gated dispatch, so an unthrottled touch would turn a permission CHECK into a database WRITE per
call. It is the only honest basis for reaping later (open question 3) and it cannot be backfilled:
the old store grew 119 → 144 in three days precisely because nothing observed use.

**The hot path needed a cache**, and this is the one thing the swap could have broken silently.
`grants()` used to read `UserDefaults`, an in-memory dictionary; the table is not, so without a cache
on `AppState` the swap would have put a SQLite read in front of every permission check. Revocation
drops the cache wholesale rather than surgically, because a stale entry there means a capability the
user just withdrew still answering yes, which is the one error this store must not make.

**The sweep became unconditional**, and losing its once-only flag is the point. While grants lived in
defaults the flag was load-bearing; with the table authoritative there is nothing there left to
protect, so it was a piece of subtle reasoning guarding nothing.

**The manager** is the Access tab in `SignOutSheet.swift`, grouped by grantee, one revocable chip per
capability, `lastUsedAt` rendered as "used 3 days ago" / "never used".

**The dead-zone rule is pure and tested** (`PortGrantDisplay.zoneLabel`), not asserted by a view, in
the same shape as `RootScreen.decide`. A zone renders by SPACE NAME, and says "in a space that no
longer exists" when it is gone, with a test asserting the uuid never reaches the screen. **That one
rule is the manager's actual job**: 135 of the 144 old grants were qualified by a deleted space, and
a uuid on screen would have hidden that exactly as well as having no screen did.

**Calibration caught a weak TEST, not just weak code, and that is the lesson.** Breaking `saveGrants`
to reset a grant's age on every re-save left the test passing: two `Date()` values written
microseconds apart land in the same stored millisecond, so a `grantedAt` comparison proves nothing.
Rewritten to assert on `lastUsedAt`, which is nil-or-not and therefore unambiguous, it caught the
break. **A gate that has never been broken is not known to be a gate**, and this one would have
shipped looking like a guarantee.

Suite **1204 green**. **Live-verified in Dev3** end to end: the table was created and the defaults
swept clean at launch; a gateway call raised a prompt; approving it wrote
`local-http | 0 | zone="" | automation` — the object slot holding port 0 through the real permission
path; a second call ran with no prompt and `lastUsedAt` was recorded 24 seconds later.

### 10a3. Step 3 as built (2026-07-29) — HALF ONE IS COMPLETE

**The card names its object.** `Principal.scopeDescription` now reads "Allow for Claude Code **in
Port42**, everywhere. Take it back any time in Settings → Access." Two things it could not say
before: what the grant is ABOUT (until step 1 the object had no name), and how to undo it (until
step 2 there was nowhere to go, and a grant was permanent and invisible from the moment it was
given).

**The blanket pre-grant is deleted** (D12). `remoteAllow*` is gone from the source tree rather than
defaulted off: the `@AppStorage` declarations, the three Remote Access toggles, and the `pregrant`
construction in `RemoteToolExecutor`. **Live-verified by falsification, which is the only way to
prove a bypass is dead:** with `remoteAllowFS` written back to `1` on Dev3, a gateway `fs.read`
BLOCKED on a permission prompt for a full 12 seconds instead of returning the file instantly. A grep
gate over the whole tree keeps it from coming back, calibrated by re-adding a flag read and watching
it fail.

**The dead second overlay is deleted.** `PortPermissionOverlay` had no call site — it was the
pre-shell window mode's prompt and retired with that mode, while the live card is
`ShellPermissionOverlay`. A second implementation of a consent prompt is exactly the kind of thing
that gets edited by mistake and then believed.

**Both generated docs lost the pre-approval line.** `InstructionService.buildMarkdown` and
`llms-preamble.txt` now say a grant is per caller and revocable under Settings → Access.
`llms.txt` regenerated through `PORT42_REGEN_DOCS=1`; the diff was the one line.

Suite **1206 green**.

**What half one delivers, with no authentication anywhere in it:** every permission names its object,
port 0 exists, 144 invisible grants are gone, every grant that exists from now on can be seen and
withdrawn per capability, and the one mechanism that could hand out authority without naming anybody
is deleted.

**One process note.** A full-suite run failed a streaming-cancel test on a 60s time limit, taking
445s. It passes alone in 0.4s; the cause was contention from concurrent builds, not the change. Worth
knowing that suite is load-sensitive before treating it as a real failure.

### 10a4. Step 4 as built (2026-07-29) — half two begins, and enforces nothing

`ClientRegistry` is the only place a token is minted, named or revoked. `clients` table
(migration `v44-clients`): id (slug), name, kind (paired | child | manual), createdAt, lastSeenAt,
revokedAt. The root secret is 32 random bytes in the Keychain, **instance-qualified** as
`gateway-root-<instance>` off `PORT42_DATA_DIR`, so instance separation falls out of the secret
rather than a path check (NFR4) — and a Dev3 token simply fails production's verification.

Token is `p42_<id>_<mac>`, mac = base64url-unpadded HMAC-SHA256 over the **id**, so a token cannot be
replayed as another client. `id` is constrained to `[a-z0-9-]`, which is also what stops a
caller-supplied name smuggling a path separator into the token FILE's name — the name is a claim, and
slugging is what makes it safe to use as a filename and a key. Files land at 0600 inside a 0700
directory; revoking deletes the file (BR5).

A child's id is DERIVED (`child-<companionId>-<spaceId>`), so a companion terminal keeps its grants
across respawns. Re-registering an existing slug re-issues onto the same row and clears `revokedAt`,
because re-enrolling is a deliberate act by the same user.

**Nothing enforces.** Tokens exist and clients show in the manager under CONNECTED; no call is
refused for lacking one. That is step 5, by which point every caller has a token and the refusal can
teach the fix.

**NFR1 got a STRUCTURAL gate, because the behavioral one was a lie.** A test named "constant-time"
that only asserts a near-miss fails is satisfied by plain `==` — and when the naive comparison was
substituted, that test stayed green. The real gate scans `verify`'s body: it must route through
`constantTimeEquals` and must not compare a MAC with `==`. **Timing is not unit-testable, so the
guarantee has to be structural.** This is the second time in two days that calibration caught a weak
TEST rather than weak code (§10a2), and both were tests whose NAME claimed more than their body
checked.

Also calibrated by breaking: a MAC that stops binding the id (caught — a token replayed as another
client), and a slug that lets `/` and `.` through (caught — `../../etc/passwd` survived).

Suite **1219 green**.

### 10a5. Steps 5 and 6 as built (2026-07-29/30). HALF TWO IS COMPLETE

*Written 2026-07-30. This section was missing: the code shipped and the build order above still read
"step 5" as pending, so the document understated itself by a whole step.*

**Step 6 first, deliberately** (the swap above). A companion terminal is enrolled as a `child` client
with a DERIVED id (`child-<companionId>-<spaceId>`), so a respawn keeps its grants. Its process is
handed `PORT42_CLIENT_ID` and `PORT42_TOKEN_FILE`, **the id and the PATH, never the token**, because
`ps -E` publishes a subprocess environment to every process running as the user. An ad-hoc terminal
with no companion gets no identity rather than sharing one. The `port42` CLI enrols at install
(`CLIInstallService`), which the app performs at every boot, so it is idempotent onto the same row and
the same file. That closed the last route: **every caller now has a named act to hang enrolment on,
except the one nobody installs.**

**5a: the credential decides, `sender_id` never does.** `AppState.onCallReceived` resolves the caller
through `resolveGatewayCaller(credential:)`. `sender_id` keeps its routing meaning and loses every
other one. That is the line that ends the escalation §1 measured: `"Claude Code"`, `"Gemini CLI"` and
`claude1`…`claude101` held standing capability precisely because naming yourself in `identify` made
you that principal.

**5b: an unnamed caller is REFUSED, and `local-http` is gone as an identity.** `localGatewayID` and
`gatewayDisplayName` are deleted. `isSharedIdentity` is KEPT, returning `false`, not as a gate but
because rung 1 of `forPortBridge` asks a real question ("is this creator an actual author"), and a
future shared id should have to answer it in one place rather than be rediscovered at a call site.

**The refusal carries the fix (FR10)**, in three messages that differ by what the caller can actually
do: no credential says add a client in Settings → Access and send `Authorization: Bearer`; a MAC that
does not verify says it may belong to a DIFFERENT INSTANCE, which is the one failure invisible from
outside; a revoked client is told to ask the human and not to retry. **This matters more than a
generic 401 because a session already running holds the old instruction block in its context and will
never re-read it.** The error is the only thing that teaches.

**Both doors reduce to one function, which is the whole structural claim of D0.** There was no HTTP
fix and no WS fix to verify separately, because there is no second place a caller identity can be
formed. That is the answer to the failure mode this scope was built on: a fix verified on one caller
path and assumed to hold on the others, three times in one session.

**`is_host` stopped being believed.** It is now proven by a credential the app generates per gateway
spawn, hands over on stdin, and stores nowhere, so nothing on disk can forge it and a stale one
cannot outlive the app that minted it. A hand-launched relay, which has no pipe, still honors the
claim; see the rewritten BR2 for why that is the relay case and not a hole.

**What 5b did NOT delete, and it should be said plainly.** The gateway still stamps
`SenderID: "local-http"` on the HTTP door as a routing address, and its comment still claims nothing
enforces yet. The value is inert, because nothing authorizes on `sender_id`. The comment is false.

**VERIFICATION STATUS, stated honestly (2026-07-30 audit).** Suite **1256 green** in 145 suites, plus
the `gateway/` and `cli/` Go suites, all re-run at the audit. The code paths were read end to end and
the enforcement is structurally sound. **The §11 live matrix has NOT been re-run at this HEAD**: Dev3
was not running at audit time, and the recorded live checks belong to the session that built the
step. Under this thread's own rule (*done means live-verified, not committed*), half two's live
column is inherited rather than confirmed, and §11 is the thing to run first at milestone B, on a
freshly built Dev3, per door and per caller.

### 10c. The OUTPUT payload as built (2026-07-30)

**`PortNotify` is what leaves a port**: `{ topic, kind, payload, token }`, one definition, one
encoder. `NotifyBus.publish` takes `BridgeValue` and will not accept `Any`.

**The payload type is `BridgeValue`, deliberately not a new one.** It is already the single result
shape every bridge method returns, it already round-trips JSON both ways, it already crosses the
gateway, and `.data(base64:mime:)` already carries binary, which matters because `screen.frame` and
`camera.frame` push frames. A purpose-built Notify type would have solved all of that a second time
and could then disagree with the request side. Requests were typed and responses were typed; events
were the third of the system that was not.

**The envelope carries the token, and the BUS resolves it.** A Notify used to say what changed but
not what state it left the port in, so a subscriber that wanted to write next had to call `getHtml`
first, which is the second round trip the "Stream out" acceptance row forbids. `AppState` injects
`notifyBus.tokenForTopic`, so no publish site passes a token and a site added tomorrow carries one by
construction. **It also closes O-4's remaining half**: the token is `<epoch>:<seq>`, monotonic per
port, so it IS the display ordering key and no sequence field was needed.

**DEFECT FOUND BY TYPING IT, and it had been shipping.** `PortBridge.pushEvent` built its topic as
`"port:\(messageId)"` with `messageId` an OPTIONAL, so it published to `port:Optional("abc")` while
every subscriber listens on `port:abc`. **Every event on that path missed the bus entirely**: all
three `browser.*`, `screen.frame`, `camera.frame`, both `audio.*` and `presentation`. The port's own
JS was unaffected, because `port42._emit` needs no topic, which is exactly why nobody noticed.
`console`, `terminal.output`, `push` and `driver` publish elsewhere with an unwrapped key and always
worked, so the paths in daily use were the working ones.

**The compiler had been reporting it the whole time**, as a string-interpolation warning on that
line. Worth stating plainly: a warning nobody reads is a test nobody wrote.

**The gate is structural and calibrated against that exact defect.** No source file may build a port
topic by hand; every one goes through `PortNotify.topic(forPortKey:)` / `portKey(fromTopic:)`.
Calibrated by reinstating the original interpolation, watching the gate fail naming the file and
line, and restoring. **The gate immediately found the other half of the same disagreement**: three
SUBSCRIBE sites (`port.subscribe`, and two in `ShellState`) were hand-building topics too. No unit
test of either end alone could have caught this, because each end was internally consistent; only a
rule about the string itself reaches it.

`NotifyBusTests` +6, suite **1262 green**. Dev3 rebuilt clean and the auth matrix re-run on it.

**What is NOT proven live, and why:** that a `pushEvent` event now reaches a remote subscriber. It
cannot be, because the stream has no way out of the app (the section under Part 0). The fix is
covered by the round-trip test, the calibrated gate, and the disappearance of the compiler warning.

### 10d. The exit as built (2026-07-30)

**A `stream` frame is a response that does not end the call.** The gateway gained one envelope type,
routed to `TargetID` like a response but deliberately NOT consulted against `httpCallbacks`: `/call`
is request/response and must be completed by exactly one `response`, so a stream frame resolving that
callback would truncate the call at its first event. Pinned by a Go test that asserts the callback
survives.

**`Streamable` is set by the GATEWAY, on the WS door only**, never taken from the caller: a client
must not be able to claim it can receive streams on a transport that cannot carry them.

**A method now declares whether it ENDS.** `BridgeStreamMethod.endless` separates a subscription from
a completion, which is the distinction a one-shot transport needs. `ai.complete` finishes, so
collect-into-final gives an HTTP caller the whole answer; `port.subscribe` does not, so the same
treatment gave them a hang and then a timeout. Declared rather than inferred from the name, so the
refusal cannot drift from behavior. Both one-shot surfaces refuse an endless method up front now, the
gateway's HTTP door and tool use, the latter because a companion calling one would wedge its own turn.

**The refusal names the door that works** (FR10), the same contract as `stale_write` carrying
`current`. Measured: 36ms to refuse, against 30 seconds of hanging before.

**`acceptingExpect()` had to carry `endless` too.** It rebuilds the struct, and a rebuild that omits
a declared property turns it off silently. This struct has now lost two fields that way, so the
comment beside `needsLiveSurface` gained a third case.

**A THIRD instance of the same class of bug, found live.** `SyncEnvelope` has explicit `CodingKeys`,
so the new `streamable` property compiled, ran, and was never decoded: always nil, turning every WS
caller into an HTTP one and refusing the subscription on the door that supports it. Explicit coding
keys make an added field silently absent, exactly as an interpolated optional makes a topic silently
wrong.

**CALIBRATION, and it caught the TEST rather than the code, again.** Removing `endless: true` did not
fail the gate: it HUNG it, because the un-refused method runs until cancelled, which is the very
behavior being replaced. A gate that hangs on a regression is worse than one that fails, since a
wedged suite reads as an environment problem. Rewritten to a bounded race where losing IS the
assertion; the same break now fails in seconds naming the cause. **The first bound, 3 seconds, then
flaked under full-suite load** (passes alone in 0.18s, lost the race at 18.8s in a full run, the same
MainActor contention §10a3 recorded). Widened to 60s, which costs nothing on the passing path because
the group returns the moment the call does.

**Live-verified in Dev3, which is what closed it.** A WS subscriber received `driver` and two `push`
frames while a port was driven from a separate HTTP caller, each carrying the port's token and the
token advancing per event. The same test returned zero frames in ten seconds before the fix.

`NotifyBusTests` +9 and three Go tests; suite **1265 green** plus both Go suites.

### 10e. The gateway's error codes (2026-07-30), Part 0's last row

**The app has owned the code list since 2026-07-28 and the gateway did not use it.** A caller could
branch on every error the app raised and none of the ones the transport raised. That is the wrong way
round for slice-02, because a remote peer meets the transport first.

Now `no_host`, `host_offline`, `transport_failed`, `timed_out`, `missing_arg` and `unknown_method`, on
both doors, in the WS envelope (a new `code` field) and in the HTTP body.

**Kept apart only where the repair differs**, the register's own rule. `no_host` means Port42 is not
running, so go start it; `host_offline` means it was there and its connection dropped, so retry. Two
codes for two next actions, not for two internal states.

**The new repair group carries the sentence that actually helps:** *your call never reached Port42, so
nothing was executed and nothing changed. Retrying is always safe.* It belongs to the group rather
than being repeated per code. Explicitly NOT `isRetryableWithCurrentState`, which is CAS and means
something else: these never reached a port at all.

**One list, two languages, and a gate between them.** `BridgeErrorCode` declares, `gateway/errorcodes.go`
mirrors, and a Swift test scans the Go file and fails if it spells a code the enum lacks. Calibrated
by adding `totally_made_up` to the Go and watching it fail by name. Without it the second language is
free to invent, and the published docs (which render from the enum) would silently stop describing
what the gateway sends.

**The agent-facing docs moved with it.** `llms.txt` gained the THE GATEWAY group, regenerated from the
enum with the diff read. More importantly, both `llms.txt` and `ports-context.txt` had been
documenting the Notify envelope as `{ topic, kind, payload }`, with no `token` and no mention that the
gateway serves the stream on `/ws` only. A port author reading the old text would not have known the
token was there, which is the one thing that lets them write back without a read first.

Suite **1267 green**.

### 10f. Why the docs went stale, and the rule that stops it (2026-07-30)

**GM's question, and it is the right one: why was this not automatic?** The agent-facing docs went
stale the moment the Notify envelope gained a field, and a human had to notice.

**The gate that existed checks the wrong property.** `BridgeDocsExportTests` asserts
`llms.txt == what the registry generates`. That is CONSISTENCY: it proves the artifact was
regenerated. It cannot know the registry's own `description` string is wrong, so generated-from-wrong
passes it byte for byte. `ports-context.txt` had no gate at all beyond the one rendered block.

**The mechanism to fix it already existed and had been used once.** `{{ERROR_CODES}}` is substituted
at load from `BridgeErrorCode`, so the codes cannot be restated wrongly because they are not restated
at all. That was built 2026-07-28 and then not applied to anything else.

**THE RULE, stated once: a fact about a code structure is RENDERED from that structure, never typed
into prose.** `PublishedDocs.render` is the single place every renderer is applied, so adding one is
one line. Two more now exist:

- `{{NOTIFY_ENVELOPE}}` from `PortNotify`. Add a field to the struct and both documents gain it.
- `{{EVENT_KINDS}}` from `PortEventKind.allCases`. The hand-written list named four kinds; there are
  sixteen, so it was not merely stale, it had always been wrong.

**The gate is that no marker survives into served text.** Calibrated twice: an unwired `{{FOO}}` in a
document is caught, and deleting a renderer from `render` is caught, both naming the marker. That is
what catches the next one, because the failure mode is writing a marker and forgetting to wire it.

**Two findings about the existing gates, from making this one pass.**

`PortEventKindTests.coversWhatIsEmitted` kept a HAND-WRITTEN list of the enum's non-case members, and
it broke the moment the enum grew legitimate API (`publish`, `docsMarker`). A gate that fails because
the type gained a method is a gate people edit rather than read. Its exclusion list is now derived
from the type's own source.

**That same test is largely redundant with the compiler and weaker than it looks.** It scans for the
spelling `PortEventKind.<case>`, which only 4 of the 16 kinds use; every other emit site uses
leading-dot inference and is invisible to it. What it claims to catch (a case deleted while a caller
names it) is a COMPILE ERROR in Swift, for both spellings, always. Its sibling gate, no bare string
literal at a publish site, catches something the compiler cannot and is the one carrying the weight.
Left in place rather than removed, and recorded here so the next reader knows which of the two is
load-bearing.

### 10b. What step 1 learned, and what it changes for steps 2 and 3

**Measure whether the data is worth migrating before designing the migration.** The day began on a
copy-forward migration with a careful verification story, and it was correct and pointless. One
census killed it: 135 of 144 grants named a deleted space, so they could never fire. The recorded
measurement (a count and a permission breakdown) was accurate and told us nothing that mattered. The
question that decided the design was **how many can still fire**, which needed a join against the
live `spaces` table and had not been asked. A count is not a census.

**A slot with one possible value is indistinguishable from a rename.** Every `PortPermission` case is
a machine capability, so nothing in production can name an object other than port 0. The tests
therefore had to use a tile key and a peer-qualified object deliberately. **This recurs at the wire
half**, where `principal_id` will have exactly one verifier until libp2p adds the second: the same
discipline applies, or the seam is asserted rather than tested.

**The escalation in §1 is not theoretical, and the store is the evidence.** 43 of the 58 grantees
matched nothing live, and among them are `"Claude Code"`, `"Gemini CLI"` and `claude1`…`claude101` —
callers that chose their own `sender_id` over the WS door and accumulated standing capability. That
is the case for half two written in production data rather than in a spike.

**A failed build leaves a bundle that runs and lies.** A `./build.sh` run that reported a codesign
error and `Operation not permitted` on a resource copy still produced a launchable app, in which the
dreamscape and cinematic videos rendered black. That cost real time and read exactly like a
regression: assets, bundle resolution, signature, gating and layering were each checked and cleared.
A clean rebuild fixed it. **Rule: if a build reports a signing or copy failure, the bundle is not
evidence. Rebuild before debugging any behavior in it.**

**Concrete input for step 2, and it was acted on: the store could not be enumerated.** Resolved in
§10a2 by moving to a table rather than by parsing keys. The rest of this note is kept as the record
of why the question came up.

**Original note: the store cannot be enumerated.** `grants(grantee:on:zone:)` is a point
lookup, and the only walk over the store lives inside the reap. The manager needs an enumeration that
parses `portGrant.<grantee>.<object>.<zone>` back into its three parts, **splitting from the RIGHT**:
zone last, object second to last, grantee everything before. That is sound because an object segment
uses `/` and never `.`, and a zone is a space id or `global`, neither of which contains a dot; a
grantee may contain anything, including spaces, as the production keys show. Whether to keep this in
`UserDefaults` or move it to a table is a step 2 decision, and worth taking deliberately now that
something will finally read the whole store.

**The reap emptied the store but did not touch the cause.** Nothing expires or reaps a grant, so it
accumulates again from zero. Open question 3.

### 11. Verification

Live, per door and per caller, rather than once. The lesson this scope is built on is that a fix
verified on one caller path was assumed to hold on the others, three times in one session.

| | `/call` (HTTP) | `/ws` (envelope) |
|---|---|---|
| typed curl | with token, without token, with a revoked token | n/a |
| the app's children | a companion terminal's own token | n/a |
| the gateway subprocess | n/a | host credential accepted, forged `is_host` refused |
| a port's `window.port42` | goes via the bridge, not the gateway. Confirm it is unaffected | |

Plus: the probe above re-run and refused, an unauthenticated `ports.list` over `/ws` refused, channel
messages still routing with no credential, and a revoke taking effect without a gateway restart.

`gateway_httpcall_test.go` already exercises `/call` end to end. Calibrate every new gate by breaking
it before trusting it.

### 12. Spikes run, 2026-07-28

Four, run before building, in the session's own discipline: measure first, and calibrate every gate
by breaking it.

**A. Does a NEW RELEASE prompt on the Keychain?** No. **The store choice is validated.**

A signed probe created an item and read it back, then a second build with the same identifier and
the same Developer ID certificate but a different cdhash read it silently (`OSStatus=0`), with user
interaction disabled so a would-be dialog returns an error code instead of blocking.

Calibrated by breaking it three ways, all correctly refused with `errSecAuthFailed`: a different
bundle id, a different certificate, and ad-hoc signing. The control kept working throughout.

**The first run of this spike was wrong and the harness was the reason.** `codesign` derives the
identifier from the filename, so the two builds had different identifiers and the refusal proved
nothing about a release. The ACL binds to (identifier, signing certificate), not to the exact binary.

That also explains the dev-instance prompt exactly, and it is two causes at once rather than one: a
dev build has a different bundle id **and** a different certificate from the app that created the
shared `Port42-credentials` items. Instance-qualifying the account fixes it, and is not P1.

**B. Is the pairing refusal followable by a real Claude Code session?** Yes, first attempt, no
hand-holding. **D5 and D10 are validated.**

A stub gateway served the proposed 401 body and the pairing endpoints, approving after a delay to
stand in for a human clicking Allow. A headless session was given the proposed instruction block and
one task. Its trace:

```
POST /call  method=help        NO TOKEN  -> 401 auth_required
POST /call  method=space.list  NO TOKEN  -> 401 auth_required
POST /pair  name='claude-code'           -> 202
GET  /pair/<id>                          -> APPROVED, token written
POST /call  method=space.list  AUTHENTICATED -> 200
```

It read the hint, enrolled under a sensible name, waited, retried, and then told the user the
response looked like a stub. The file landed at `0600` in a `0700` directory.

**Not measured, and worth a follow-up:** the approval came back on the client's first poll, so the
`pending` branch was never exercised. How patiently a session polls while a human takes a minute to
reach the dialog is still unknown, and it is the realistic case.

**C. The stdin handover.** Works, both ways. **D2 is validated.**

A faithful stand-in for `GatewayProcess` (Process plus a Pipe on `standardInput`, write end held)
and for `main.go`'s watch-parent: both secrets arrived intact, and after a `kill -9` of the parent,
which runs no cleanup on either side, the child still exited on EOF. A hand-launched instance with
no `-watch-parent` skipped the read and did not block, which is the relay case.

One detail that has to survive into the real code: resume `io.Copy` from the **same buffered
reader**, not from `os.Stdin`, or anything already pulled into the buffer is lost.

**D. Who else treats `sender_id` as authority?** This found the `remoteAllow*` pre-grant in §1,
which is the finding that changed the design. Confirmed alongside it: `Principal.peer` has exactly
two production sites, both in `ToolExecutor.swift`, and two `senderId == localGatewayID` comparisons
beside them in `#if DEBUG` probe blocks that retire with the constant.

### 13. Open for GM

1. The wording on the pairing prompt and on a hand-made client's permission card.
2. Whether add-by-hand in Settings ships in step 1 or waits.
3. ~~Whether anything stops the store re-accumulating.~~ **CLOSED 2026-07-29 (GM): grants are
   PERMANENT.** No expiry and no auto-reap; revocation is manual, in the manager. `lastUsedAt` keeps
   recording use (throttled) because it cannot be backfilled if that ever changes, but nothing
   consumes it — it is informational, not load-bearing.
4. Whether pairing can be switched off entirely in Settings, for a machine that wants no new clients.

**Closed:** the `remoteAllow*` pre-grant, removed outright (D12, GM 2026-07-28). Park or delete the
orphaned grants — **delete, all of them** (GM, 2026-07-29): the objectless store is reaped at launch
and nothing carries forward, so every caller asks once more and the model starts from an empty store.
Only 9 of the 144 could ever have fired, which is what made a faithful migration pointless.


---

# The wire half

## Why this slice (what it validates)

1. **It proves keystone #1 — address across instances.** The single foundational decision in
   [`bus-architecture.md`](bus-architecture.md): extend `port42://space/<id>/<portId>` to carry the
   instance, so a query reaches a remote port the same way it reaches a local one.
2. **It proves a coarse keystone #2 — right-of-way across the wire.** Per-*port* ownership (not yet
   per-element): two drivers on two instances never double-write.
3. **It cashes out the hardest sentence.** My own earlier critique flagged the Synchronizer's real-time
   surface as the deepest unsolved piece stated as one bullet. This is where it meets code.
4. **It measures the honest falsifier.** Hole-punch success rate under real networks — the number that
   decides whether "p2p = sovereignty" is viable or whether relay dominates in practice.

## Scope — jobs this slice touches

| Job | What the slice exercises | Kept thin by… |
|---|---|---|
| **J8** working on the same thing together | co-hold one port across two instances | one port, per-port right-of-way (not per-element) |
| **J16** working with other people | A's surface driveable by B (another person) | two peers, no teams / no fan-out to N |
| **J13** wherever & whenever I am | the same port reachable from another instance/device | no mobile; two desktop gateways |

## Scope — roles this slice cuts

*Build **only** the one thing named.*

| Role (ID) | Build only this | Skip |
|---|---|---|
| **Synchronizer** (F2) | remote address + query-in/stream-out + per-port right-of-way over libp2p | per-element right-of-way; unified 4-way subscription; CRDT/OT merge |
| **Controller** (S3) | who-may-write across the wire — CAS on the port's token (was: the ownership lease) | full delegation matrix |
| **Gatekeeper** (S2) | **IN as of the rescope.** every caller named and enrolled, one verifier per door, the permission object (port 0), and the permission manager | per-program identity; expiring grants |
| **Coordinator** (R1) | two peers discover + connect | N-peer swarm, conflict detection among agents |

**Not in this slice:** Keeper, Sensor, Guard, Librarian, Presenter-beyond-terminal, agents writing to
the remote port. Human-driven both ends first. **The Gatekeeper moved IN** with the 2026-07-28
rescope: without it the actor arriving over the wire is asserted rather than verified, which is the
one thing libp2p cannot fix from outside the seam.

---

## The reference implementation — extend the local bridge over the wire

The bus already exists **locally**: the port bridge ships `getHtml` (snapshot), `patch` (delta), `push`,
`update`, `history`/`restore`, and a local event stream (P-400, Mar 2026). The slice is **not** a new
system — it is: *make those same verbs cross a libp2p stream to a port on another instance, and add a
token so a write composed against stale state is refused rather than applied.* (Same move as Slice 01 naming git as the Guard's substrate:
here the substrate is the existing bridge + libp2p.)

### The shape

```
   INSTANCE A (owns port P)                         INSTANCE B (remote driver)
   ┌───────────────────────┐                        ┌───────────────────────┐
   │  port P (actor)        │                        │  proxy handle → P      │
   │   state · stream       │                        │   renders P's stream   │
   └─────────┬─────────────┘                        └──────────┬────────────┘
             │ gossipsub topic: port42/<space>/<P>  (Notify deltas)          │
             │◀───────────────────────────────────────────────────────────▶ │
             │ libp2p stream /port42/uerp/1.0.0     (Query / Update in)      │
             │◀───────────────────────────────────────────────────────────▶ │
        Circuit-Relay v2 ─── DCUtR hole-punch ──▶ direct conn (or stay relayed)

   ADDRESS   port42://<peerID>/space/<space>/<portId>     ← instance = PeerID
   WRITE     B reads P's token → B patches, carrying it → A applies, or refuses `stale_write`
             with `current` → B retries once → Notify to both (see the re-head note: no lease)
```

### The contract, made concrete

- **Address (F2).** `port42://<peerID>/space/<id>/<portId>`. Resolve `<peerID>` → live multiaddr via
  mDNS (milestone A) or DHT/rendezvous (milestone B). A local port keeps its short address; the instance
  segment is what's new.
- **Query in (F2).** B opens a `/port42/uerp/1.0.0` stream to A and sends a UERP-framed `Update`
  (`patch`/`push`) or `Query` (`getHtml`, incl. as-of). A executes it **through its existing local
  bridge** — the remote caller is just another origin.
- **Stream out (F2).** A publishes every port delta to gossipsub topic `port42/<space>/<portId>`;
  B (and any subscriber) receives `Notify`. One publish, many subscribers — the unified-subscription
  shape, minimally.
- **Right-of-way (S3) — the TOKEN, not a lease.** *(Rewritten 2026-07-28; the original paragraph
  specified a lease and is quoted in the re-head note.)* Every write carries the token it was composed
  against. A writes it through its own local bridge, which either applies it or refuses `stale_write`
  carrying `current`, so B self-corrects in one retry with no extra round trip. An untokened write is
  refused with `token_required`, also carrying `current`. **Nobody is blocked and nothing is granted.**
  Presence is derived from whoever moved the token last and is broadcast on the Notify topic as
  `kind: "driver"`, so both UIs show who is driving — a display fact that refuses nothing.
  *(The deliberate concurrency choice: optimistic CAS on a per-port monotonic counter, not pessimistic
  ownership and not CRDT/OT. A lock cannot cross the wire, because clocks do not agree between peers.)*

### Milestones (isolate the seams from the contract from traversal)

- **A · the local seams.** Part 0's rows, on one machine: port 0 and the grant object, the permission
  manager, then the credential and the `principal_id` seam. No wire at all. Shippable on its own, and
  it is where the falsifier is cheapest: if a seam needs changing above the line, find that here.
- **B · same-LAN (mDNS).** Prove the *contract* — address, query, stream, token — with traversal taken
  out of the equation. If this doesn't feel instant on a LAN, nothing else matters.
- **C · cross-NAT (relay + DCUtR).** Prove *traversal* — two instances on different networks. Instrument
  the hole-punch: record direct-vs-relayed, and the success rate.

---

## Acceptance — pass/fail per seam

| Seam | PASS | FAIL |
|---|---|---|
| **Actor (A)** | ✅ **2026-07-30 (code; live matrix owed).** a call with no verified credential is refused on BOTH doors, and there is only one function that can form a caller identity; a caller cannot name itself; `local-http` is gone as an identity, surviving only as a routing address | a caller still picks its own identity on either door |
| **Object (A)** | ✅ **2026-07-29.** every grant names the port it is about; port 0 exists; the 144 objectless grants were reaped, so none survives to be inherited | a grant still names a grantee and a space and no object |
| **Legibility (A)** | ✅ **2026-07-29.** every grant is visible and revocable in one screen, grouped by grantee, per capability; a zone whose space is gone says so | a grant is still invisible after the moment it is given |
| **Address (B)** | `port42://<peerID>/…` reaches the remote port; the same verb path works local and remote | remote needs a different API than local |
| **Query in (B)** | B's `patch`/`getHtml` executes on A's port via A's existing bridge | remote writes bypass A's local bridge/authority |
| **Stream out (A local, B wire)** | ✅ **locally, 2026-07-30.** a subscriber outside the app receives every event as a `stream` frame carrying the port's token, so it can write next with no extra read. Live-verified over the WS door. The wire half adds a transport, not a mechanism | B must poll; or fan-out needs bespoke per-subscriber code |
| **Right-of-way (B)** | a write composed against stale state is REFUSED with `current`, and one retry lands; presence names whoever wrote last, on both ends; no double-apply under contention | a stale write is applied and A's state diverges from B's view; or a caller is blocked outright, which is the lease failure again |
| **Traversal (C)** | direct connection via DCUtR where NAT allows, clean relay fallback otherwise; success rate recorded | connection only works same-LAN; or fails silently behind NAT |

**The milestone tag was wrong on one row and is corrected here (2026-07-30).** Traversal read `(B)`
while the milestone list gives B the contract and C the traversal, and the slice-level acceptance
below is a C run. B's exit criteria are the four rows tagged `(B)`, on one LAN.

**Slice-level acceptance:** on two instances across two networks — B addresses A's port, reads its
state and token, patches it carrying that token, both UIs converge on the new state and show B as the
driver; A then writes with a token it read BEFORE B's patch and is refused `stale_write` with
`current`; A retries once and lands. Location-transparent; the same verbs, and the same refusal, as
local.

**The measured number (the falsifier):** hole-punch **direct-connection success rate** across ≥4 real
network settings (home, café, corporate, tethered mobile). ≥~80% direct + clean relay fallback →
p2p-as-sovereignty is viable. Mostly-relayed → the moat thins; know it now, not later.

---

## Milestone B · implementation scope, derived from the acceptance rows (2026-07-30)

*Written after the milestone A audit. The local half had three things this half did not: a build
order where every step leaves the app shippable (§10), a live matrix per door and per caller (§11),
and a gate calibrated by breaking it. Milestone A's quality came from those rather than from the
design, so B gets the same three before it gets code.*

### What B must deliver, and nothing more

Four acceptance rows: **Address**, **Query in**, **Stream out over the wire**, **Right-of-way**. On
one LAN, two machines, mDNS. Traversal, the hole-punch rate and the cross-network run are milestone C
and are not evidence for B.

### What B inherits, so it is not rebuilt

| inherited | from | what it means for B |
|---|---|---|
| the TOKEN, `<epoch>:<seq>`, CAS, peer- and epoch-qualified | A | right-of-way is plumbing, not design. No new mechanism |
| a stream that leaves the process, carrying the port's token | §10d | gossipsub subscribes to an exit that exists |
| `BridgeStreamMethod.endless` | §10d | a subscription and a completion are already distinguishable, which a one-shot remote door needs |
| typed error codes on both sides of the transport | §10e | a remote caller meets a code it can branch on, at the layer it meets first |
| the object slot, peer-qualifiable (`PortObject.remotePort`) | §10a | "peer B may act on my port 0" is expressible with no new concept |
| one function that forms a caller identity (`resolveGatewayCaller`) | §10a5 | there is exactly one place the second verifier can land |

### The three things that are NOT inherited, and they set the step order

1. **`PortAddress` has no instance segment.** Part 0 ticks ADDRESS on the strength of `PortObject`,
   which is peer-qualified, and `PortObject` is the GRANT object. The resolver's grammar is a
   different type: `PortAddress.parse` requires exactly two path segments and returns nil for a
   third, and `canonical` renders the local form only. Small delta, wrongly ticked.
2. **A peer has no enrolment act.** FR5 killed pairing, and a remote peer is precisely the caller
   nobody installs, so CR3's fallback is add-by-hand, which is a poor first run for the thing the
   slice exists to show. See the decision below.
3. **A peer identity is authenticated in the GATEWAY.** libp2p proves the peer cryptographically, and
   the app is the only verifier. If the PeerID reaches the app as a plain envelope field, the
   transport is deciding identity again, which is the exact conflation §2 records as the root cause.
   Spike E is the test of it.

### Step 0 · two spikes, before any code

Both are gates on the design, in the discipline of §12: measure first, calibrate by breaking.

**Spike E · the peer principal seam.** Two gateways on one machine, a stub stream standing in for
libp2p. Prove a call arriving from an authenticated peer produces a `Principal` in the app WITHOUT the
app trusting an unverified gateway-supplied field, and that its grants key on `<peerID>/0`. Calibrate
by forging the peer field from a hand-launched gateway holding no host credential and watching it be
refused. **Falsifier:** if the only available path is "believe the field", D0's last invariant breaks
and the seam is redesigned before libp2p is in the build rather than after.

**Spike F · go-libp2p inside the shipped bundle.** Not whether go-libp2p works. What it costs in a
signed, hardened-runtime, notarized `port42-gateway`: binary size delta, launch time, idle CPU, and
whether the macOS local network privacy prompt fires for mDNS, what it names, and whether it survives
notarization. **Falsifier:** the local-network prompt blocks or confuses discovery in a release build,
or idle cost regresses, either of which changes B's shape before a line of contract code.

Spike E can change the design. Spike F can change the milestone.

### Step 0 as run (2026-07-30). BOTH SPIKES GREEN, neither falsifier triggered

**Spike F · go-libp2p in the gateway.** `go-libp2p v0.49.0` and `go-libp2p-pubsub v0.17.0`, linked
into a copy of the REAL gateway sources and reachable from `main` so the linker cannot drop them.

| measured | baseline | with libp2p |
|---|---|---|
| gateway binary | 14,779,986 bytes | 36,950,610 bytes (**+22.2 MB, 2.5x**) |
| host start | n/a | 4 to 5 ms |
| idle CPU, no peers | n/a | 0.06 s CPU over 30 s wall, about 0.2% |
| mDNS discovery | n/a | 4.0 s with both hosts starting together; 2 ms to 668 ms when one was already advertising |
| connect | n/a | 34 to 39 ms |
| `/port42/uerp/1.0.0` round trip | n/a | 291 to 466 µs |
| gossipsub | n/a | every message delivered, both directions, at a 2 s cadence |

**The size is the only real cost, and it is a decision rather than a blocker.** It lands in the app
bundle and in the LFS-tracked DMG. Launch time and idle CPU are noise, which matters given the
dreamscape idle-burn history.

**The identity question is answered, and it settles the keypair count.**
`crypto.ECDSAKeyPairFromKey` accepts a P-256 key, which is the curve `AppUser` already uses for the
signing key. The PeerID derived from a stored key file was byte-identical across separate launches,
and a second key file produced a different one. **So the PeerID rides the identity Port42 already
holds. It is not a fourth keypair**, and `summer2026-todo.md:1024`'s "three keypairs for one job"
does not become four.

**DERIVED, not handed over** (GM, 2026-07-30). The spike proved the raw P-256 key works, and using it
directly would mean handing the user's long-lived SIGNING identity to the gateway process. D2's
argument for keeping the root secret in the app applies with more force here: the host secret is safe
to hand over because it is per-spawn and worthless afterwards, and an identity key is neither. So the
libp2p key is an Ed25519 seed from a domain-separated HKDF over the identity key
(`info = "port42-libp2p-identity-v1"`), and only that derived key crosses to the gateway. The PeerID
is still your identity, stable and reproducible; the signing key stays in one process; and the
libp2p key can be rotated on its own. Ed25519 rather than P-256 because libp2p handles it natively
and the PeerIDs are compact.

**Two properties this makes into requirements rather than luck.** `AppUser.id` is a fresh UUID per
install (`AppUser.swift:50`), so the key is per-INSTALL, which is what a PeerID needs. It is named
and described as the USER identity, the person. **If remote identity ever converges one person across
two Macs onto one key, both machines derive the same PeerID and addressing breaks outright**, so the
derivation must stay per-instance even where the person is not. Second, the grant key carries
`<peerID>` and grants are permanent, so **a rotation orphans every peer grant**, which is the 135
dead grants with a new cause. Neither bites today: there is one creation site (`SetupView.swift:939`)
and nothing deletes the key.

**The hardened runtime does not block any of it.** The harness was wrapped in a minimal app bundle
(`com.port42.spike`), signed with the Developer ID certificate and `--options runtime`, and
discovery, the UERP stream and gossipsub all worked from inside it.

**One part of F is NOT closed, and it is narrow.** This machine is macOS 15.6.1, where local network
privacy is live, and `Info.plist` carries neither `NSLocalNetworkUsageDescription` nor
`NSBonjourServices`. The probe was launched from Terminal, so responsibility attributes to Terminal
rather than to a Port42 bundle, which means the case that matters (Port42.app spawns a gateway that
sends multicast) is still unmeasured. Two consequences: the Info.plist keys are a required addition,
and the prompt is a live check at step 3, on the machine pair, not before.

**Spike E · the peer principal seam. D0's invariant survives, using only mechanisms that exist at
HEAD.** Two factors, both verified by the APP:

1. **The credential**, verified against the ROOT secret. This is `ClientRegistry.verify` unchanged,
   and it is what makes a peer a client like any other (kind `peer`).
2. **An attestation of the libp2p peer identity**, produced by A's own gateway with the HOST secret
   the app minted for that spawn and handed over on stdin, and verified by the app with the same
   secret. It MACs `<peerID>|<clientID>`, so it binds the peer to the client rather than naming a
   caller on its own. A hand-launched relay holds no host secret and cannot produce one at all.

Nine cases pass, and the ones that matter are the refusals: a peer id asserted with no attestation,
an attestation minted with a secret this app never issued, a valid attestation replayed onto a
different claimed peer, peer B's credential presented over peer C's connection, and a revoked peer
that attests correctly. Local clients are untouched and cannot acquire a peer object by claiming one.

**Calibrated by breaking each gate on both sides, which is what shows they do different jobs.**
Removing the attestation check lets the "believe the field" case through, so that gate is what
catches a gateway naming a peer it never authenticated. Removing the client row's peer comparison
lets a stolen peer token replayed from another peer through, so that gate is what catches theft.
Two gates, two failures, neither redundant.

**The first calibration attempt was wrong, and it is the same lesson as §10a2 and §10a4.** It broke
the attestation PRODUCER and left the verifier intact, so all it proved was that two constructions
disagreed. **A gate broken on one side only is not calibrated.**

**The residual, stated rather than buried:** the app trusts its own gateway's word about which peer
the libp2p handshake authenticated. That exact trust already exists for `is_host`, it is bounded by a
secret that is per-spawn and written nowhere, and removing it would mean moving the transport into
the app. What the spike rules out is the app trusting an UNVERIFIED field, which is the thing §2
names as the root cause.

**Consequence for the build order:** step 3 gains the attestation, and no step gains a new secret.

### Build order, each step shippable, each step naming its own live check

| # | step | live check that closes it |
|---|---|---|
| 1 | **The address gains its instance segment.** `PortAddress` parses and renders `port42://<peerID>/space/<id>/<portId>`; the local two-segment form is unchanged and still round-trips; an address carrying THIS instance's own peerID resolves locally. A tree-wide gate: no site builds a port address by hand, the same rule `PortNotify.topic` already carries | ⌘K, `port.subscribe` and the resolver behave identically on Dev3 with a peer-qualified self-address |
| 2 | **The peer identity is DERIVED, and a peer is a grantee kind.** The libp2p key is an Ed25519 seed from a domain-separated HKDF over the existing `AppUser` P-256 key (`info = "port42-libp2p-identity-v1"`), and only the DERIVED key reaches the gateway. `clients.kind` gains `peer`. Enrolment by the act decided below. Nothing connects yet | two instances hold each other's peer rows; the PeerID is unchanged across an app restart on both machines, and BOTH sides keep their grants |
| 3 | **The transport.** go-libp2p host in the gateway, mDNS discovery, a `/port42/uerp/1.0.0` stream. A remote call arrives as a `call` envelope carrying an ATTESTED peer identity in the shape spike E validated, and is refused if that peer is not enrolled | B's `space.current` against A is refused as unenrolled, then served after enrolment; a forged peer identity is refused; a revoked peer is refused on its next call with no restart |
| 4 | **Query in.** B addresses A's port and executes `getHtml` / `patch` / `push` through A's existing local bridge. The permission-at-a-distance behavior is decided and built here (see the assumption below) | per direction and per caller: the matrix under "Verification" |
| 5 | **Stream out over the wire.** A gossipsub topic per port, publishing the `PortNotify` that already exists. Gap detection off the monotonic token, resync via `getHtml` | B renders A's port live; B's subscriber is killed and restarted and resyncs with no manual step; a dropped delta is detected rather than silently missed |
| 6 | **Right-of-way over the wire.** Nothing new to build if the token holds. A stale write refused with `current`, one retry lands, the driver chip names the far end on both machines | the slice-level acceptance run, minus traversal, on the LAN |

**If you want to ship less:** steps 1 and 2 are coherent alone and add no network surface. They are the
two rows Part 0 got wrong, fixed, with nothing connected.

### Verification · the §11 equivalent for the wire

Live, per direction and per instance, rather than once. Same reason as §11: the failure mode this
scope is built on is a fix verified on one path and assumed to hold on the others.

| | A → B | B → A |
|---|---|---|
| an enrolled peer | query, patch, subscribe | query, patch, subscribe |
| a peer that was never enrolled | refused, naming the fix | refused, naming the fix |
| a peer revoked mid-session | refused on the next call, no restart either side | same |
| a forged peer identity | refused | refused |
| a local caller, unchanged | `window.port42`, the CLI and a companion terminal all behave as before | same |

Plus, per lifecycle: the far app restarts, the far gateway restarts, the peer vanishes mid-stream, and
both machines sleep and wake. Each of these either resyncs or refuses with a code, and never hangs.

### Decided

**The transport is libp2p** (GM, 2026-07-30). Nostr was weighed and set aside for this slice: it is
client-to-relay over WebSocket with no direct peer connection, so it concedes the thing milestone C
exists to measure. Its relay-based group model (NIP-29) is a real answer for TEAMS, which this slice
does not touch, and it stays on the table for that. **The key approach is settled by spike F**: the
libp2p PeerID is derived from the P-256 identity Port42 already holds, so the count stays at three
keypairs rather than four, and it is DERIVED from that identity by HKDF rather than handed to the
gateway, so the signing key never leaves the app.

### Decisions needed from GM

1. **Peer enrolment.** Recommended: a peer invite reusing `ChannelInvite.swift`, which is already a
   named act with consent at both ends and a token that crosses machines. It keeps FR5 intact (no
   unauthenticated verb, no pairing state machine) and gives the demo a first run better than
   add-by-hand in Settings. The alternative is add-by-hand, which is CR3's existing fallback and
   costs nothing to build.
2. **The second machine.** "Done" in this thread means live-verified, and mDNS between two instances
   on one Mac does not test milestone B. Which second Mac, and does it run a Dev3-flavored build.
3. **Permission at a distance** (assumption 2 below), if the recommendation there is not taken.

### Assumptions to validate, ranked by what they cost if wrong

1. ~~**The PeerID is stable across launches.**~~ **ANSWERED by spike F, and it is now a requirement
   rather than an assumption.** The PeerID is deterministic from the key, so stability is entirely a
   question of persisting one. The grant key will carry `<peerID>` and grants are permanent (open
   question 3, closed 2026-07-29), so an identity regenerated per launch silently orphans every peer
   grant, which is the 135-dead-space-grants failure with a new cause. Nothing in the tree persists a
   libp2p identity today. Step 2 builds it, DERIVED from the identity key that already exists rather
   than stored as a new one, so there is nothing extra to persist and nothing extra to lose.
2. **"A remote caller is just another origin."** A's bridge prompts a HUMAN. §10a3 measured a gateway
   `fs.read` blocking on a prompt for 12 seconds. So B's first patch against an ungranted capability
   blocks B until someone at A clicks, and then meets `timed_out`. Recommended: refuse fast with a
   code that says a human at the other end must grant it, rather than block. Decided here, not
   discovered at step 4.
3. **"The wire half adds a transport, not a mechanism"** for Stream out. The local exit is ordered and
   reliable; gossipsub is neither. O-4 is answered for CORRECTNESS by CAS, but delivery gaps are a new
   question that loopback could not raise. The monotonic token gives gap detection for free and
   `getHtml` is the resync, so the answer is probably cheap. It is still a mechanism.
4. **"One retry lands."** True by construction against a single competing writer. Under two live
   drivers with real LAN latency it is a claim about contention rate. Measure it at step 6, where
   measuring is cheap, rather than assume it into milestone C.
5. **Part 0's thesis**, that libp2p means writing a verifier and a transport and touching nothing
   above the seam. Spike E tests it, and assumption 1 plus the address gap already show two things
   above the seam that move.

### Not in milestone B

Traversal, relay, DCUtR and the hole-punch rate (C). Per-element right-of-way, agents as remote
drivers, N>2 peers, mobile, host-offline persistence and TLS, all already out for the slice.

## What a green slice means — and doesn't

- **Means:** the bus is real across instances on libp2p; `port42://` is a working protocol, not a paper
  one; the sovereignty thesis (direct peer connections, no central node holding state) has a walking
  skeleton.
- **Does *not* mean:** per-element co-editing works (that's the next slice), agents drive remote ports,
  N-peer rooms scale, or the traversal rate holds at population scale.

## Explicitly out of scope

Per-element right-of-way (CRDT/OT vs. finer locks); agents as remote drivers; N>2 swarms; mobile;
persistence when the owning instance goes offline (room outlives host); TLS on any transport
(`plan-gateway-auth-tls.md` P2); per-program identity and expiring grants; the Keeper/epistemic layer
entirely (a Keeper, if present, is *a gossipsub subscriber* like persist —
not part of this contract).

## Open questions (marked — not asserted)

- **O-1 · ~~Lease authority~~ · VOID (2026-07-28).** There is no grant, so there is no authority to
  locate. Kept for the record: the question was — the owning instance grants the lease, so what happens
  when the *owner* is the one who should yield, or when owner and requester disagree? A single-owner lease is the thin start; a
  neutral arbiter is deferred.
- **O-2 · Availability when the host leaves.** If A goes offline, P is gone. Multiplayer usually wants
  the room to persist. Pure p2p vs. a designated always-on node is unresolved — and bears on the
  sovereignty story.
- **O-3 · Discovery trust.** DHT/rendezvous tells B where A is; what stops a hostile peer from answering
  for A's address? Out of scope here, real later.
- **O-4 · ~~Causality under lease churn~~ · ANSWERED for correctness (2026-07-28).** A late delta from
  a prior writer carries a token the port has already moved past, so CAS refuses it BY CONSTRUCTION.
  What remains is Notify ordering for DISPLAY, which is a rendering question, not a correctness one.
  The original: rapid lease handoffs + in-flight deltas need ordering
  (sequence/causal tag on Notify) so a late delta from the prior holder isn't misapplied.
- **O-5 · Per-element, later.** Per-port locking is coarse; real co-holding wants per-element. Whether
  that stays locking or moves to CRDT/OT is the next slice's central decision, explicitly deferred.

## Risk — what this slice retires vs. leaves

- **Retires:** that every caller on both ends is a named actor acting on a named object, and that a
  grant can be seen and withdrawn; cross-instance addressing correctness (keystone #1); that the local
  verb set replicates over the wire unchanged; that libp2p traversal is viable *for this workload* (the measured rate).
- **Early signal on:** the p2p-as-sovereignty bet — the direct-connection rate is the first real evidence
  it holds under real networks.
- **Leaves untouched (by design):** per-element concurrency (CRDT/OT vs. locks), host-offline
  persistence, N-peer scale, agent-driven remote writes, and the entire epistemic/Keeper layer.
