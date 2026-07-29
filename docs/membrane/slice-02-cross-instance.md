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

| seam | what the local half builds | what libp2p adds | why it then slots in |
|---|---|---|---|
| **ADDRESS** | `PortRef.key`, one definition. **Port 0 is the machine itself** | a `<peerID>/` prefix | `port42://<peerID>/space/<id>/<portId>` already assumed. Port 0 makes `<peerID>/0` mean *that machine*, so a peer can name a machine and not only a tile |
| **ACTOR** | `principal_id`, stamped ONLY by a verifier, written peer-qualified from day one | a third verifier: PeerID → principal | libp2p authenticates a peer cryptographically. Today that authenticated peer is flattened to a string and thrown away (`Principal.swift`'s own header says so). The seam is where it lands instead |
| **TOKEN** | `<epoch>:<seq>`, CAS, peer- and epoch-qualified | nothing | already transport-independent by construction. Done |
| **OBJECT** | the grant key gains its missing slot: `<grantee> × <port> [× zone]`, both sides peer-qualifiable | peers on both sides | "peer B may act on my port 0's clipboard" becomes expressible with no new concept. Without the slot, adding it later is a migration across two instances rather than one |
| **OUTPUT** | one publish door with a typed kind | a gossipsub topic per port | ten publish sites today, two of which accept a caller-supplied kind. Gossipsub needs ONE payload definition, so the seam has to exist first |
| **LEGIBILITY** | the permission manager: every grant visible, revocable, grouped by grantee | remote peers are grantees too | a grant to a peer you cannot see is the local invisibility problem with a network attached |
| **ERRORS** | typed codes, app and gateway | the same codes on the wire | a remote caller acts on `stale_write` / `token_required` exactly as a local one does |

**The test for each row:** adding libp2p should mean writing a verifier and a transport, and touching
nothing above the seam. Anything that would force a change above the seam belongs in the local half.

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
| FR5 | A caller with no credential can do exactly one thing: request pairing |
| FR6 | A pairing request is approved or denied by the user, who is shown the requested name |
| FR7 | Children the app spawns are registered with no prompt, and keep a stable identity across respawns |
| FR8 | Permission grants key on the client, so one caller's grant is never inherited by another |
| FR9 | The user can see every enrolled client and revoke any of them |
| FR10 | Every refusal states how to fix it |
| FR11 | No permission reaches a caller without passing through its principal and the permission request path. No blanket pre-grant exists (see D12) |
| FR12 | Every permission names its OBJECT, and the object is always a port. Machine capabilities (clipboard, filesystem, automation, notify, rest, screen, camera) are port 0's (see §4) |
| FR13 | A zone qualifies the ACTOR on a grant. It is never an object, and never the only thing a key names |

**Behavioral**

| | requirement |
|---|---|
| BR1 | Channel and message traffic is unaffected by authentication. Sharing does not regress |
| BR2 | A gateway with no secret serves channel routing only, and refuses `call` and `is_host` |
| BR3 | The app is host only of a gateway it spawned itself |
| BR4 | At most one pairing request is pending at a time, and a pending request expires |
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
| CR3 | On upgrade, no client exists, so every gateway caller is refused until it pairs. This is a deliberate break, and FR10 is what makes it survivable |
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

```
  ClientRegistry (app)        the only place a token is minted, named or revoked
        │ root secret, over the gateway's stdin at spawn
        ▼
  Verifier (gateway)          credential → principal id, or nothing. Stateless.
        │ principal_id
        ▼
  Router (gateway)            envelopes, addressing, host routing
        │
        ▼
  Authorizer (app)            principal → enrolled? → grants → allow / prompt / deny
```

| interface | invariant |
|---|---|
| registry → gateway | the gateway holds one secret and no table, and never reads the filesystem |
| caller → verifier | a credential is the only way to acquire a principal |
| verifier → app | `principal_id` is written ONLY by the verifier, and is unconditionally overwritten on every inbound envelope |
| router | `sender_id` addresses. It never authorizes. It stays caller-supplied and untrusted |
| authorizer | `Principal.peer` is constructed only from `principal_id`. `sender_id` never reaches it |

The last one is greppable and testable, and it is the gate. `Principal.peer` has exactly two
production construction sites, both in `ToolExecutor.swift`, both currently taking `senderId`.

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
  kind        TEXT NOT NULL       paired | child | manual
  createdAt   DATETIME NOT NULL
  lastSeenAt  DATETIME            updated on each accepted call
  revokedAt   DATETIME            null means active
```

`id` is a slug rather than a UUID because it is also the token file's name, and the documented client
flow is "read a known path, pair only if it is missing". A UUID would make the path unknowable before
the first pairing, which is the inconsistency that has to be avoided.

**The grant key gains its missing object. DONE 2026-07-29** (§10a). Was
`portPerms.<grantee>.<spaceId ?? "global">`; now `portGrant.<grantee>.<object>.<zone>`, naming
grantee, object port, and the zone that qualified the actor (§4). The old keys are REAPED, not
translated (CR5, superseded). `grants(grantee:on:zone:)` / `saveGrants(…)` are the one read/write
pair, so the permission manager (D13) and this share a store.

**A child's id is derived, not random**, so a companion terminal keeps its grants across respawns:
`child-<companionId>-<spaceId>`, slugged. Re-pairing an existing slug re-issues onto the same row,
so a user who deletes a token file gets a new credential and keeps their grants.

**The host is not a row.** It is ephemeral and holds no grants, so it never enters this table.

**D2. Secrets, and how they reach the gateway**

| secret | where it lives | lifetime |
|---|---|---|
| root | Keychain, service `Port42-credentials`, account `gateway-root-<instance>` | until rotated |
| host | app memory only, never written anywhere | one gateway spawn |

Both are 32 random bytes. The root secret is created on first launch if absent, and is the only thing
that can mint a client token. The host secret is regenerated on every gateway spawn, which is what
makes `is_host` unforgeable by anything on disk.

**Both reach the gateway on stdin, not in its environment**, for the reason measured in §1: `ps -E`
publishes a subprocess environment to every process running as the user. The app already holds the
write end of the gateway's stdin for the EOF-on-death watch and never writes to it, so it writes two
lines at startup and then leaves the pipe open exactly as before.

**The read is gated on `-watch-parent`**, the flag that already distinguishes an app-spawned gateway
from a manually launched one. A relay started by hand has an interactive stdin, and a blocking read
there would hang it.

**D3. Token format and verification**

```
p42_<id>_<mac>          mac = base64url-unpadded( HMAC-SHA256(secret, id) )
```

`id` is constrained to `[a-z0-9-]`, so splitting on `_` always yields exactly three parts. The
gateway recomputes the MAC and compares in constant time (NFR1). On success it stamps
`principal_id = id`. It consults no table and stores nothing, which is what keeps NFR5 true and makes
the verifier survive its own restart.

The host credential is the same construction over the host secret with `id = host`, so one routine
covers both and they differ only in which secret is used.

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

Two new envelope types carry pairing between the gateway and the app: `pair_request` (gateway to
host) and `pair_result` (host to gateway).

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

The pairing protocol:

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

1. The credential arrives, in a header or in `identify`.
2. **Gateway** verifies it and stamps `principal_id`, or refuses with `auth_required` / `auth_invalid`.
3. **Router** forwards to the host as it does today, keyed on `CallID`.
4. **App** refuses a call carrying no `principal_id`.
5. **App** looks the client up. Missing or revoked gives `auth_revoked`. Otherwise `lastSeenAt` is
   updated.
6. `Principal.peer(id: principal_id, displayName: client.name)`.
7. The existing permission coordinator runs unchanged: grant lookup, prompt if needed, dispatch.

**Steps 2 and 5 are deliberately in different components.** The gateway proves the token was minted
here. The app decides whether that client still exists. That split is what makes revocation instant
without the gateway holding state or needing a restart (FR4, NFR5).

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
| user deletes a token file | that client can no longer authenticate and pairs again. The row survives, so re-pairing the same slug re-issues onto it and the grants are kept |

**D9. What happens to an existing install on upgrade**

On first launch after the upgrade the root secret is minted and the client table is empty, so every
gateway caller is refused until it pairs. That is the deliberate break in CR3, and FR10 is what makes
it survivable rather than a wall.

`InstructionService.refreshInstalled()` already rewrites the instruction block at every boot, so a
new Claude Code, Gemini or Codex session reads the new flow. **A session already running holds the
old block in its context and will not**, which is exactly why the refusal has to carry the fix.

The orphaned `portPerms.local-http.*` grants become unreachable the moment `localGatewayID` is
deleted, so they are inert. Whether to park or delete them is open (§13).

**D10. Errors, and the refusal that carries its own fix**

| code | meaning |
|---|---|
| `auth_required` | no credential presented |
| `auth_invalid` | malformed token, or a MAC that does not verify |
| `auth_revoked` | verified, but the client no longer exists |
| `pair_busy` | a pairing request is already pending |
| `pair_disabled` | the user turned pairing off |
| `pair_expired` | the request outlived its TTL |
| `no_host`, `host_offline`, `timeout`, `bad_request` | the gateway's own failures, previously uncoded |

The last row closes the register §5 item that was parked for "the next thing to touch that file".

`auth_required` names the header, the token path and the pairing verb, in the same shape as
`stale_write` carrying `current`. A stale caller self-corrects in one retry, and a caller that was
never enrolled is walked into pairing by the error itself, so one mechanism does both jobs. No error
body ever echoes a token (NFR2).

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

| what | where | design |
|---|---|---|
| `ClientRegistry`, the only minting site | new file | D1, D3, D5 |
| `clients` table, new migration | `DatabaseService.swift` | D1 |
| root secret, per instance | `AgentAuth.swift` (`Port42AuthStore`) | D2 |
| host secret, generated per spawn, and both secrets written to stdin | `GatewayProcess.swift` | D2 |
| token file write and removal | `ClientRegistry` | D5, D7 |
| the pairing prompt and its approval path | new view, `AppState` | D5, D11 |
| refuse a call with no `principal_id`, and refuse a revoked client | `AppState.onCallReceived` (:1364) | D6 |
| two `Principal.peer` sites take `principal_id` | `ToolExecutor.swift` (:150, :175) | D0, D6 |
| children registered at spawn | `TerminalHooksService.swift` (:218), `AgentProcess.swift` | D1, D5 |
| `isSharedIdentity` and `localGatewayID` deleted, not gated | `Principal.swift` (:110, :178) | D9 |
| the permission manager: grants grouped by grantee, revoke per row and per grantee, clients as a grantee kind, add by hand | `SignOutSheet.swift`, new screen | D11, D13 |
| delete the dead `PortPermissionOverlay` (no call site) | `PortWindowManager.swift:1657` | §4 touchpoint 2 |
| the three `remoteAllow*` flags and their Remote Access toggles deleted | `SignOutSheet.swift` (:25-27, :659-661), `ToolExecutor.swift` (:140-144) | D12 |

**Gateway**

| what | where | design |
|---|---|---|
| read two secrets from stdin when `-watch-parent` is set, then keep the EOF watch | `main.go` | D2 |
| verify a credential and stamp `principal_id`, constant-time | `gateway.go` | D3, D4 |
| strip and re-stamp `principal_id` on every inbound envelope | the read loop, `gateway.go` (:340) | D4 |
| `Authorization: Bearer` on `/call` | `HandleHTTPCall` (:802) | D4 |
| `token` in `identify`, and refuse `call` from an unauthenticated peer | `routeCall` (:907) | D4, D6 |
| `is_host` honored only for the host credential | identify (:283) | D2, D8 |
| `POST /pair`, `GET /pair/<id>`, rate limited, in-memory state | `main.go`, `gateway.go` | D5 |
| the gateway's own error codes | `gateway.go` | D10 |
| never log a secret or a token | throughout | NFR2 |

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
2. **The permission manager** (D13). Grants grouped by grantee, revoke per row and per grantee. This
   is the first time in the product's life that a granted permission can be seen, and it is what
   makes step 1's migration verifiable rather than trusted.
3. **The card names its object.** "Claude Code wants to read the clipboard in Port42." Delete the
   dead `PortPermissionOverlay`, and delete the `remoteAllow*` pre-grant (D12) now that every
   capability has a place to be granted and revoked per grantee.

**Half two: the credential.** Every step here has the manager from step 2 to make it legible.

4. **Store and mint.** Root secret, derived tokens, the token file, minting from the acts that
   already exist (connect a tool, spawn a child, add by hand). Clients appear in the manager as a
   grantee kind. Nothing enforces yet.
5. **Seam and verifier together.** `principal_id` exists, is written only by the verifier, and a
   call without one is refused. `local-http` is deleted rather than preserved: carrying a transport
   label through a transition step would seed the new field with exactly the kind of value it
   exists to eliminate.
6. **Children.** Per-child registration at spawn, which is where the pooled bucket actually dies.

Step 5 is the only one with a blast radius, and by then every caller has a token, the refusal teaches
the fix, and the manager shows what happened.

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

**Concrete input for step 2: the store cannot be enumerated.** `grants(grantee:on:zone:)` is a point
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
3. Whether anything stops the store re-accumulating. The reap emptied it once, but nothing expires or
   reaps a grant, so it grows again from zero. Related to the expiry question D13 puts out of scope.
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
| **Actor (A)** | a call with no verified `principal_id` is refused on BOTH doors; a caller cannot name itself; `local-http` is gone | a caller still picks its own identity on either door |
| **Object (A)** | ✅ **2026-07-29.** every grant names the port it is about; port 0 exists; the 144 objectless grants were reaped, so none survives to be inherited | a grant still names a grantee and a space and no object |
| **Legibility (A)** | every grant is visible and revocable in one screen, grouped by grantee | a grant is still invisible after the moment it is given |
| **Address** | `port42://<peerID>/…` reaches the remote port; the same verb path works local and remote | remote needs a different API than local |
| **Query in** | B's `patch`/`getHtml` executes on A's port via A's existing bridge | remote writes bypass A's local bridge/authority |
| **Stream out** | a delta on A appears on B within one round-trip; multiple subscribers get it from one publish | B must poll; or fan-out needs bespoke per-subscriber code |
| **Right-of-way** | a write composed against stale state is REFUSED with `current`, and one retry lands; presence names whoever wrote last, on both ends; no double-apply under contention | a stale write is applied and A's state diverges from B's view; or a caller is blocked outright, which is the lease failure again |
| **Traversal (B)** | direct connection via DCUtR where NAT allows, clean relay fallback otherwise; success rate recorded | connection only works same-LAN; or fails silently behind NAT |

**Slice-level acceptance:** on two instances across two networks — B addresses A's port, reads its
state and token, patches it carrying that token, both UIs converge on the new state and show B as the
driver; A then writes with a token it read BEFORE B's patch and is refused `stale_write` with
`current`; A retries once and lands. Location-transparent; the same verbs, and the same refusal, as
local.

**The measured number (the falsifier):** hole-punch **direct-connection success rate** across ≥4 real
network settings (home, café, corporate, tethered mobile). ≥~80% direct + clean relay fallback →
p2p-as-sovereignty is viable. Mostly-relayed → the moat thins; know it now, not later.

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
