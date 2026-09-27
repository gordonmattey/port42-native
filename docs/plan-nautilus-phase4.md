# Nautilus Phase 4: the remote pipe

Detailed plan for Phase 4 of `plan-shell-only.md`. Scenario served: 4. Written 2026-09-26 against
`nautilus` at `638e1c2` on branch `nautilus-phase4`, and reviewed with Gordon the same day. Nothing
is built. **The architecture is specified in `design-phase4-relay.md`**; the peer-to-peer research
that led to it is in `research-phase4-transport.md`. Other sources: `membrane/slice-02-cross-instance.md`
(spike E), `browser-guest.md`, `plan-web-port-sharing.md`, `invite-taxonomy.md`, and three notes on
the `research` branch (`design-invite-over-libp2p.md`, `research-host-mesh.md`,
`research/security-bridge-authorization.md`).

Testing is on Dev2 (`./build.sh --dev2`, gateway 4244) and on further instances Gordon allowed for
this phase (Dev6, Dev7 and on). Dev3, Dev4 and prod are never built, launched or called.

## Goal

Someone on another machine sees and drives one of my ports, from Port42 or from a plain browser, and
reaches nothing else. No token crosses the internet, nothing on the Mac listens beyond loopback, the
relay carries only ciphertext, and a guest that asks for anything beyond its grant is refused.

## What changes, for a person and for an agent

- **Share a port with a link.** One link per port, on `port42.ai/invite.html`. Opened where Port42 is
  installed, the port appears as a tile on the other person's desktop. Opened anywhere else, it runs
  in the browser tab. Both people drive it, both driver chips agree, and a stale write is refused
  with `current`. It works from any network, including cafés, offices and phones.
- **Opening a link is one click.** The guest types a name and presses Join, and is in; you get a
  notification with a one-tap Remove. For a sensitive share, tick "require a code" and send the
  six-digit code another way. Link previews and mail scanners, which load pages but press nothing,
  get nothing.
- **Access lists who has what.** Each person or browser you shared with appears in Settings → Access
  with the ports they hold and the rights on each, and revoking takes effect on their next call.
- **Agents on both machines can work together.** A companion on the other machine drives the shared
  port with the same verbs it uses locally (`port42 port.push id=port42://<peer>/<port>`), and, if the
  invite allows it, messages your companions in that port's chat.
- **A guest reaches one port**, and never learns your IP address.

## Decisions

All decided with Gordon on 2026-09-26 except where marked open.

1. **Address: `port42://<peer>/<portId>`.** The peer is the lowercase base32 of the instance's
   Ed25519 public key (8). No space segment: a port id is a UUID, unique on its machine and in
   practice everywhere, and the resolver already finds a port by id alone (a nil space means any,
   `PortResolution.swift`). A space is where a port sits, which can change, and naming it would hand
   a guest the id of a space it was not given. Lowercase because many URL parsers and linkifiers
   lowercase a host. The local form `port42://space/<s>/<p>` keeps parsing; the unused remote form in
   `PortAddress.swift` is replaced.
2. **Relay first.** Every remote connection goes through a relay over a secure WebSocket on 443,
   encrypted end to end with Noise IK between the two instances' keys. It connects from every network
   on day one, hides each side's IP from the other, and removes the unknowns of peer-to-peer (NAT
   traversal, port mapping, IPv6 firewalls, public Nostr relays refusing traffic, the macOS local
   network prompt, a listening socket on the Mac). A direct path is a later upgrade per session behind
   the same four-verb seam (listen, dial, peer id, stream), as Tailscale upgrades from its relays.
   Considered: WebRTC with public introductions, libp2p, Iroh, Tailscale (`research-phase4-transport.md`).
3. **Port42 runs a default relay; anyone can run their own.** One small Go program in `relay/`, no
   database, stateless beyond who is connected. It needs TLS on 443 and WebSockets and no UDP, so any
   host fits. It learns who connects to whom, from which IPs, when and how much; never content. The
   invite lists the host's relays, so a self-hosted relay is a Settings entry. **Hosted on Railway**
   (Gordon's account), under `relay1.port42.ai`; Railway terminates TLS on 443 at its edge and the
   Noise session inside is unaffected. Port 443 is a choice, not a requirement: office, hotel and
   café networks commonly allow only web ports outbound, so the default relay uses 443, and a
   self-hosted relay may use any port.
4. **The per-port invite, both lanes.** An invite names one port and grants that port only (D10).
   Port 0 and spaces are never invitable; a second port is a second invite.
   - **One link, on the page that exists:** `https://port42.ai/invite.html#<coupon>`. The coupon
     (host key, relays, port id, rights, a one-time nonce, an expiry, display names) is in the
     fragment, which never reaches a server.
   - **The page never acts on load**, because link previews (iMessage on the sender's own phone,
     LinkedIn, Instagram) and mail scanners are reported to run a page's scripts. It clears the
     fragment and offers "Open in Port42" or "Open here".
   - **Redeeming is one click (Gordon).** The page shows "Gordon shared 'chart' with you", a name
     field and Join. After Join, the page (or the guest's Port42) opens a session to the host through
     the relay and presents the nonce and the typed name. The host checks the nonce is live, burns
     it, enrols the guest's key as a `peer` client under that name, grants the port with those rights,
     and notifies: "Ada joined 'chart'", with Remove. Nothing waits on the host. What remains is a
     forwarded link used before the intended guest: the host sees it and removes them, and the used
     link refuses everyone after.
   - **"Require a code", per invite (Gordon).** The invite dialog shows a six-digit code beside the
     link, to send another way. The guest types it before Join. The host's gateway checks it, never
     the relay; five wrong tries and the invite is dead. A forwarded link without the code grants
     nothing.
   - A guest who already holds a grant reconnects straight in.
   - **A browser guest keeps its key** in that browser, so a refresh is the same guest. Safari clears
     it after seven days without a visit; the guest then needs a new invite. Guests unused for a
     period Gordon sets are reaped from Access.
   - **Default rights: view and drive**, which are `see` and `use` below.
   - **The page loads no third-party script** (today's loads PostHog, which could read the coupon),
     sets a strict CSP limiting connections to the listed relays, sends no referrer, and pins its own
     script with subresource integrity. Its source is outside this repo and is to be found. The app
     recognizes a pasted invite link again (the old recognition went with `fbee08d`).
5. **Remote callers are locked down; local callers are unchanged in this phase.** Denied by default:
   every registry method declares what it acts on (a port argument, a listing, the machine, or
   nothing), and a remote principal may call only port methods, only on ports it holds a grant for,
   within the grant's rights. A listing returns only its granted ports. Machine capabilities, spaces,
   companions, `port.create`, `port.exec` (it runs inside the host's page as that port's own
   principal), `terminal.exec`, `rest.call`, `fs.*` and secrets are refused with a new code,
   `not_granted`. Nothing a remote caller does raises a permission card. Remote access grows into its
   own permission system, a port being something like a VM (Gordon). **Its first rights (confirmed
   by Gordon):**
   - **`see`**: source, rendered page, console and live events (`getHtml`, `history`, `getDom`,
     `info`, `console`, `subscribe`). A browser guest receives the source, so `see` cannot prevent a
     copy.
   - **`use`**: input and chat (`push`, `publish`, `chat.read`, `chat.post`). Every write carries CAS,
     so scenario 4's stale-write refusal needs only this.
   - **`edit`**: change the port itself (`update`, `patch`, `restore`, `rename`, `setTitle`). Off by
     default.
   - **`wake agents`**: the guest's posts and events wake the host's companions (@mentions, Phase 3
     watches). Gordon wants remote agents at least to message the host's agents, so it is grantable,
     off by default, and a woken companion is told the message came from a remote peer. A companion
     runs with the host's terminal, so this puts a remote party's text in front of an agent with a
     shell, and each wake spends the host's model tokens.

   **The shared port's own grants are disclosed (Gordon).** The host's copy of the port keeps its
   machine grants (clipboard, REST), and a guest's input can make it use them. The invite dialog lists
   them ("This port can use your clipboard and make web requests. Anyone you let in can make it do
   so.") before the link is made.

   **Named secrets get a per-caller grant.** A companion's ticked secrets write grants for it; any
   other local caller (a port, a plain terminal, a manual client) is asked by a card naming the
   secret; a remote caller never.
6. **The guest page is `port42.ai/invite.html`,** static on Netlify. It carries one bundled script:
   the relay client, a Noise IK implementation on the audited `@noble` libraries, the envelope
   client and the bridge shim. It renders the port's source in a sandboxed iframe, as today's spike
   does. The gateway's `/port` route stays for loopback testing until step 4.7.
7. **The Signal Protocol is not in this phase.** Noise encrypts every session end to end with forward
   secrecy, and nothing is stored and forwarded. When a chat port is mirrored to offline peers, MLS
   (RFC 9420) is evaluated beside Signal, since a chat port has many subscribers.
8. **Each instance has one Ed25519 key.** Generated at first need, kept in the Keychain under the
   instance name (`Port42AuthStore`), handed to the gateway on stdin at spawn. Its public key is the
   peer id; the Noise static key converts from it, so there is one identity per instance. Per
   instance, never per person. Rotating it orphans every grant keyed on it, so nothing rotates it in
   this phase.
9. **A peer is authenticated by its key, and the app never trusts an unverified peer field.** The
   relay admits a host only after it signs a challenge. Noise IK authenticates both ends: the guest
   knows the host's key from the invite, and the host checks that the guest's Noise key converts from
   the peer id it claims. The gateway forwards each call with that peer id and a MAC over it; the app
   checks the MAC before forming a principal in `resolveGatewayCaller`. **The MAC key is a second
   per-spawn secret that only travels on stdin**: the host credential cannot serve, because the app
   sends it over the socket in `identify` (`GatewayDoor.swift:154`).
10. **Instances.** Dev2 plus Dev6, Dev7 and on, on this Mac, cover both lanes against a relay, local
    or deployed; `build.sh` gains the flags. A second machine or a phone on cellular checks the
    deployed relay from another network; no traversal measurement is needed.

## What is measured

Against `638e1c2` unless a date says otherwise.

- **Nothing is reachable from off this machine.** The gateway listens on `127.0.0.1`
  (`GatewayProcess.swift:95`); its only dependency is a WebSocket library (`gateway/go.mod`).
- **The address can name another instance and resolves none.** `PortAddress` parses
  `port42://<peer>/space/<s>/<p>`, and the resolver refuses any peer that is not this one
  (`PortResolution.swift:130`), where this one is always nil because no instance has a key.
- **There is no key.** `AppUser` carries no key material since v48. `Principal.peer`'s comments still
  describe an authenticated `peer.ID` flattened to a label (`Principal.swift:4-8`, `:22-24`).
- **Callers are clients with stateless tokens.** `p42_<id>_<mac>`, verified by recomputing an HMAC
  over the instance's root secret, with no expiry and no one-time form. Kinds are `paired`, `child`,
  `manual` and `installed` (`ClientRegistry.swift`). Revocation is effective on the next call.
- **The envelope already uses the name `peer_id`**, for the WebSocket connection id (`gateway.go:39`).
- **Authorization is by capability, never by object.** In `BridgeMethods.swift`, 41 methods declare
  `permission: nil` and 28 name one. The grant object is hardcoded to port 0 wherever a grant is read
  or written (`BridgeDispatcher.swift:45`, `:112`, `:117`, `:524`; `PortBridge.swift:76`).
  `ports.list` lists every space's ports (`BridgeMethods.swift:1346`). Any enrolled client can read,
  write, execute JS in and subscribe to any port.
- **Secrets are scoped for companions only** (`BridgeMethods.swift:853`).
- **The invite's door survived and its payload did not.** The `port42://` handler reaches
  `TransitionRoot.handleDeepLink` (`TransitionRoot.swift:283`), which accepts nothing. The gateway's
  `/invite` builds `port42://channel?…` for the deleted hub (`gateway/main.go:142`). The live
  `port42.ai/invite.html` reads `gateway`, `id`, `name`, `key` and `token` from its query string and
  loads PostHog.
- **The guest page is a working spike on loopback** (`gateway/main.go:53`, `guestpage.go`): a client
  token in the query string, the port's source in a sandboxed iframe, bridge calls forwarded.
- **Events leave the process with tokens.** `port.subscribe` over `/ws` delivers `stream` frames
  carrying the port's token, and a write that replaces state publishes `state`
  (`BridgeDispatcher.swift:65`, `:91`).
- **This Mac's network, 2026-09-26:** T-Mobile Home Internet, IPv4 behind carrier NAT
  (`172.59.124.208`), IPv6 untranslated. Irrelevant to a relay, which is reached outward on 443, and
  the reason a direct path would have been hard here.
- **Not yet measured:** the relay round trip from this Mac and from a phone on cellular, Noise in the
  browser, a 3 MB port through the relay, and whether link previews load the invite page.

## Steps

Each step is its own commit: merged from `nautilus` first, suite and Go suites green, harness five
of five on Dev2, this plan and `plan-shell-only.md` updated. Every gate is calibrated by breaking the
code it guards, on the side that enforces it, and watching it fail. 4.1 comes before any wire, so a
remote principal is scoped before one can arrive.

### 4.0 Measure what the design assumes

Spike code in a scratch directory, not the product tree.

- **The relay round trip.** A throwaway relay on the chosen host; this Mac to it and back, and a phone
  on cellular to this Mac through it: connect time, round trip, throughput, and a 3 MB message in
  64 KiB chunks.
- **Noise in the browser.** The IK handshake and transport on `@noble` in Chrome, Safari (macOS and
  iPhone) and Firefox: time and bundle size.
- **Link previews.** A test link pasted into iMessage, WhatsApp, Slack, Teams, LinkedIn and Gmail,
  logging every page load and whether any runs the script.

*Gates:* the figures, recorded here.

### 4.1 Remote callers see only what they were granted

Local, no wire. A remote principal can be built in a test without one.

- **Every method declares its object**, a new required field on `BridgeMethod` and
  `BridgeStreamMethod`: `.port(param)`, `.listing`, `.machine` or `.none`. A gate checks it agrees
  with `writesTarget` and `permission`.
- **`Principal.remote(peer:actor:displayName:)`**. The grantee is the peer; the actor it reports is
  display only.
- **Port grants** with the rights of decision 5, the grant object's first non-zero use.
- **The gate**, in the dispatcher before the permission gate: `not_granted` for a method that is not
  `.port`, a port without a grant, or a missing right; listings filtered; `port.exec` refused; a
  remote post or event wakes a companion only with `wake agents`.
- **Per-caller secret grants**, and the stale comments on `Principal.peer` and `local-http` fixed.

*Gates:* every registry method declares an object (source scan; calibrated by deleting one). A remote
principal with `see` on P reads and subscribes to P, is refused writes and `exec` on P, is refused Q,
and sees only P in `ports.list`. With `use` it pushes to P with CAS; without `edit` it cannot update
P. It is refused every `.machine` and `.none` method, `rest.call` and `port.create`. Its @mention wakes
nobody without `wake agents` and the named companion with it. A plain terminal and a port are refused
a secret they hold no grant for and served one they do. Local callers pass the existing suite
unchanged. Each calibrated by removing the check it pins.

**Built 2026-09-26.** As planned, with four choices made in the code:

- **One table, not a field per method.** `RemoteAccess.table` (`RemoteAccess.swift`) classifies every
  registry method as `.port(param, right)`, `.listing` or `.never`, so the whole remote surface reads
  in one screen, and a method missing from it is `.never`. A gate fails until a new method is
  classified.
- **A port acting on itself is never remote.** `port.publish`, `setTitle`, `setCapabilities`,
  `info` and `presentation` are refused: a guest running a copy of a port in its browser is not that
  port, and the host's copy publishes and describes itself.
- **Storage is never remote yet.** It keys on the caller, so a guest would read its own empty bucket
  rather than the port's; settled with the browser lane (4.7).
- **Rights share the `grants` table** (the port's key as object, the right as permission, no zone), so
  no migration. Secret grants use the object `secret:<name>` with `rest`; a companion's secrets stay
  the ones ticked on its card. The card names the secret (`PermissionRequest.detail`), and two
  secrets are two cards.
- A remote listing omits space, creator, directory and position. A refusal reads the same whether
  the port exists or not, and a port is named by exact id only.

Gates: `RemoteAccessTests`, 11 tests, each calibrated by breaking its check (the one-shot gate, the
streaming gate, the listing filter, the wake check, the secret check, one table entry, exact-id
matching); each break failed its own test and no other. Suite 1248 green, Go green. Harness on Dev2
(client `nautilus-harness`, space `phase4-harness`): five of five, including scenario 3's hidden
stage and watching agent, once the harness client held the terminal grant.

### 4.2 The instance key, and the address that names it

- The Ed25519 key (decision 8), handed to the gateway on stdin with the host credential and the MAC
  key (decision 9). The gateway derives the peer id and tells the app, so its encoding has one
  implementation.
- `PortAddress` takes the form of decision 1. `clients.kind` gains `peer`, with a `peer_key` column
  (new migration).

*Gates:* the remote form round-trips with a foreign peer kept distinct from ours both ways; our own
peer resolves locally; the local form unchanged; the key reaches the gateway only on stdin (tree
scan, calibrated by passing it in the environment); the peer id survives a Dev2 restart.

**Built 2026-09-26.** The seed is 32 random bytes in the Keychain (`peer-key-<instance>`, in memory
under tests, `InstanceKey.swift`). The stdin handover is two lines, the host credential then the
seed, so the credential and the death-watch are unchanged (`GatewayProcess.handover`,
`gateway/peer.go`). The gateway derives the peer id, lowercase base32 without padding (52
characters), logs it, and sends it only in the proven host's `welcome` (`self_peer`); the app keeps it
as `AppState.localPeerID` and the resolver uses it. `PortAddress` parses `port42://<peer>/<portId>`,
accepts an uppercased peer, and no longer parses the old form with a space. Migration v56 adds
`clients.peerKey`, unique when set, and the `peer` kind.

Gates: `InstanceIdentityTests` (6) and the rewritten remote cases in `PortAddressTests` and
`PortResolutionTests`; `peer_test.go` (4) with RFC 8032's key as a vector checked against a second
base32 implementation. Each calibrated: wrong alphabet, the peer id sent to any peer, no key read
from the handover, the resolver not given the peer id, the welcome not wired, a second place reading
the key, no lowercasing, a non-unique peer key, a hand-built remote address. The one-address-builder
gate now also catches an interpolated `port42://` host. Suite 1270 green (one run hit a timing flake
in nautilus's `StartupPromptTests`, green alone and on rerun), Go green. Live on Dev2: peer id
`56dvfh4ylpfgpyvn2rygu5bttdop5bxjuchgdlv5wg2g34tc7mxa`, the same across a restart; an address
naming it reaches its own port, and the same port id under another peer is refused. Harness five of five
on Dev2.

### 4.3 The door over a seam, proven with a fake transport

Go. No relay yet.

- `transport.go`: the four verbs as an interface, and an in-memory implementation.
- A session carries the door's envelopes with chunking (`design-phase4-relay.md`, "Inside the
  session"). The gateway adds `remote_peer` and `remote_attest` and forwards to the app as it does a
  `/ws` call; both fields are stripped from `/ws` and `/call`.
- The app verifies the MAC, finds the `peer` row and forms `Principal.remote`.

*Gates:* the door works over the fake transport (the seam is pluggable); a 3 MB response chunks and
reassembles, and an 8 MiB-plus message is refused; spike E's refusals as a Go and Swift pair (no MAC,
a key this app never issued, a MAC replayed onto another peer, a revoked peer, a local caller claiming
a peer). Calibrated on both sides.

**Built 2026-09-26.** `gateway/transport.go` is the seam (`Accept`, `Dial`, `PeerID`, and a
`Session` of whole messages) with an in-memory network for tests; `gateway/chunk.go` splits a message
into frames with a one-byte header and refuses one past 8 MiB; `gateway/remote.go` serves sessions.
A remote call reaches the host as a `/ws` call does, addressed to its session, with no credential,
the transport's peer id in `remote_peer` and an HMAC over it in `remote_attest`. The attestation key
is a third stdin line, fresh per spawn (`GatewayProcess.attestKey`); with none, no remote caller is
served. `/ws` frames have both fields stripped. In the app, a call carrying `remote_peer` goes only
to `GatewayDoor.onRemoteCallReceived`, and `AppState.resolveRemoteCaller` checks the HMAC in
constant time, then the `peer` client row and its revocation, before forming `Principal.remote`
keyed on the peer id; `RemoteToolExecutor` runs as that principal.

**Found and fixed on the way:** the gateway rate-limited the app's own host connection, so a burst
of more than 30 replies or stream frames a second was dropped without a word. It happened in the
4.2 harness run on Dev2 ("peer AADCB05E rate limited"). The proven host is now exempt; callers are
still limited (`TestTheHostIsNotRateLimited`, calibrated).

Gates: `remote_test.go` (7, including one HMAC vector computed outside both languages and checked by
both) and `RemoteCallerTests` (6). Calibrated: the `/ws` strip removed, the guest's own peer claim
believed, no key check, a credential let through, no size cap, replies not routed back, the app's
HMAC check removed, revocation ignored, remote calls sent to the local handler, the executor
dropping the remote principal, the HMAC label drifted. Each failed its own test. Suite 1276 green,
Go green. Harness five of five on Dev2.

### 4.4 The relay and Noise

- `relay/`: the protocol and limits of the spec, a Dockerfile, a self-hosting note.
- The gateway: the relay link (register, reconnect after drops and sleep, link state to the app) and
  Noise IK sessions implementing the seam, inbound and outbound.
- A Go test peer in `gateway/cmd/` with its own key. A harness tool, not a product.

*Gates:* in process: a host and a guest through a relay round-trip a call and a subscription, and the
door sees the verified key; a `hello` with a bad signature is refused; a guest cannot open a session
to a key that is not registered; a relay that tampers with a frame breaks the session instead of
changing a call (calibrated by disabling the MAC check in the test cipher); each relay limit refuses
with its code. *Live, this Mac:* the test peer through a local relay against Dev2 reads a granted
port, is refused an ungranted one, keeps a subscription through a host write, and is refused on its
next call after revoke with no restart. Then the same through the deployed relay.

**Built 2026-09-26.** The relay lives in the gateway module, so the protocol has one implementation:
`gateway/relay` (server, client, Noise), `gateway/cmd/port42-relay` (the program), `relay.Dockerfile`
(Railway), and `gateway/transport` now holds the seam, the framing and the peer id encoding (moved
out of the gateway's main package so the relay client can implement the seam). Noise is
`flynn/noise`; the X25519 key is derived from the Ed25519 key (`filippo.io/edwards25519`), and a
test checks both derivations agree. Dependencies are pinned to versions that build with Go 1.24.
The gateway registers on the relays in its `-relay` argument, which the app fills from the
instance's `PORT42_RELAYS` default (none unless set, until invites exist). The test peer is
`gateway/cmd/p42peer`.

**Deployed:** the relay runs on Railway (project `port42-relay`, service `relay`), live at
`wss://relay-production-beea.up.railway.app/v1`. `relay1.port42.ai` is attached and its DNS record is
in Cloudflare (DNS only, propagated); Railway was still validating ownership for its certificate at
the time of writing, so Dev2 uses the Railway address for now.

**Live, Dev2 through the deployed relay:** the test peer, on its own key, dialled Dev2 by peer id
across the internet, completed the Noise handshake, and was refused by Dev2's app as not enrolled
("does not know you. Ask its owner for an invite"); an unregistered peer id is `host_offline` at
once. Timing from this Mac: a call round trip on an open session about 270 ms (the path crosses the
relay twice each way, since both ends are here); a fresh dial with TLS, registration, pairing and the
handshake 1 to 4 s, so a guest keeps its session open. The enrolled half of this step's live check
(read a granted port, subscribe, revoke) needs enrolment, so it moves to 4.5.

**Found on the way:** a reply sent down a remote session carried `peer_id`, the gateway's id for the
host connection, which is the host's local user id; it is now removed before anything reaches a
guest (calibrated).

Not built from the spec: the per-session throughput cap (1 MB/s). The other limits are in.

Gates: `relay_test.go` (10: the key derivations agree; both ends authenticated and a 3 MB message
whole; a wrong host key reaches nobody; a caller naming someone else's key refused; an altered frame
refused as unauthentic; the relay pairs guest and host; an unregistered key is offline; a host claim
signed by another key refused; a signature for another relay refused; a client refuses a relay that
names itself differently; the per-guest session limit) and `relay_e2e_test.go` (the door serves a
remote call through a relay, attested). Each calibrated by breaking its check, and the whole Go suite
passes under `-race`. Swift suite 1279 green. Harness five of five on Dev2, with Dev2 registered on
the deployed relay.

### 4.5 The per-port invite

- `invite.create {port, rights, expires, requireCode}` returns the link (and the code when
  required); `invite.list`, `invite.revoke`. Refused for port 0 and a space. The dialog discloses what
  the port can do on this machine.
- `invite.redeem {nonce, name, code?}`: enrolment, the grant, and the "joined" notification with
  Remove.
- Settings → Access shows peers with their ports and rights and the invites outstanding, each
  revocable, and the relays in use with a place to add one.
- The deep link accepts `port42://invite#…`, ⌘K accepts a pasted invite link, and the gateway's
  `/invite` channel page is deleted.

*Gates:* a link redeems once and a second redemption is refused with a reason; an expired link is
refused; a required code is enforced, a wrong one refused, and the fifth wrong one kills the invite;
redemption notifies the host and Remove revokes; port 0 and a space cannot be invited; revoking one
grant leaves the peer's others. Calibrated by removing the burn and the code check.

**Built 2026-09-26.** `Invites.swift`: `invite.create`, `invite.list`, `invite.revoke`, and
redemption at the remote door, which runs after the gateway's attestation is verified and before
enrolment is required, since redeeming is how a peer becomes known. Migration v57 adds `invites`,
holding only hashes of the nonce and the code. Refusals carry a new code, `invite_invalid`, with a
`reason` (unknown, used, expired, revoked, wrong_code, locked, gone). An agent or client creating an
invite is asked by a new `share` permission card; the person is not asked on their own behalf. A
join posts a system line in the port's chat that wakes nobody. Settings → Access gains "Shared with
other machines": each guest's ports and rights with "stop sharing", and unused invites with
"withdraw". The gateway's old `/invite` channel page is gone. The coupon format and the page's
behavior, for whoever rebuilds `invite.html`, are in `design-phase4-relay.md` ("For the website").
Moved to 4.6: the app accepting `port42://invite#…` and a pasted link, which needs outbound calls.

Keep-alive, found while testing: `relay1.port42.ai` is proxied by Cloudflare, which closes a
WebSocket after about 100 seconds of silence, and the 20-second pings in the spec had not been built.
The relay client now pings every 20 seconds and closes a connection whose ping goes unanswered
(calibrated).

**Live on Dev2, through `relay1.port42.ai`** (Dev2 registered there; the test peer, a separate
process with its own key, on this Mac; so the path is real and the machine is the same): an invite
was created (after the share card), redeemed in 252 ms, and the port read in 222 ms; the same link
from another key was refused as used; a port not shared was refused `not_granted`; the guest's
listing held only the shared port; a subscription received the host's pushes and its rename live.

**Found:** a call that times out at the gateway while its permission card waits keeps running in
the app, and completes when the card is answered. Four retries of `invite.create` during the wait
became four extra open invites once it was allowed; they were withdrawn. The same holds for any
gated method (asynchronous permission, D-d, is not in this phase).

**Open, seen twice in about thirty runs:** a guest's `ports.list` through the door returned its one
port twice, and never an ungranted one. Not reproduced when instrumented; the tests compare the set
of ids, which still fails if an ungranted port appears. To find.

Gates: `InviteTests` (10). Calibrated: no burn, no code check, no try limit, no expiry, no withdrawal
check, agents not asked, a space shareable, redemption not handled before enrolment; each failed its
own test. The registry and tool golden, `llms.txt`, and the ports skill (a new "Share one" section)
regenerated. Suite 1289 green, Go green under `-race`, harness five of five on Dev2.

### 4.6 The Port42 lane: a shared port on the other desktop

- **Outbound calls.** The app asks its gateway to call a method on a remote address; the resolver
  forwards any address naming another peer, so `window.port42`, the `port42` CLI and companions on the
  guest's machine reach a remote port with the same verbs.
- **The remote tile.** A web port whose HTML comes from the host and whose bridge calls go to it,
  subscribing for `state` and pushes, resuming after a drop, and showing the host offline rather than
  broken (`host_offline`).
- **Driver chips.** The host's names `<peer>/<actor>`; the guest's names the host's actor.

*Gates:* a foreign address is forwarded and never falls through to a local port with the same id;
the outbound path over the fake transport. *Live:* Dev2 and Dev6: scenario 4 in Port42 on a chart and
a chat port, and a companion on each side messaging the other with `wake agents` granted.

**4.6a built 2026-09-26: this instance calling a port on another.** The app sends a `remote_call`
(`to_peer`, `relays`, and an ordinary call) on its host connection; the gateway dials that peer
through those relays as a guest with this instance's key, keeps one session per peer, and hands each
`response`, `stream` and `error` back on the app's call id, failing any still waiting when a session
ends (`gateway/outbound.go`). Only the proven host may ask. In the app, `GatewayDoor.remoteCall`
awaits the reply and passes stream events on; `invite.accept {link, code?}` redeems as this instance
under the person's name and records the port and its relays (migration v58, `remote_ports`); and the
dispatcher forwards any call whose port argument names another instance, replacing the address with
the port's own id, so `window.port42`, the `port42` CLI and companions reach a remote port with the
same verbs. The other instance's rights decide; a remote caller's call is never forwarded on.
`build.sh` gains `--dev6` (gateway 4248) and `--dev7` (4249).

Gates: `outbound_test.go` (3: two instances through one relay, a stream event and the response
routed back on the caller's id, the session reused; an unreachable peer is `host_offline` at once;
only the host may call out) and `RemotePortTests` (5). Calibrated: any caller calling out, no session
reuse, the offline code collapsed, replies dropped, no forwarding, a remote caller forwarded on, the
port id not substituted, a refusal taken as success, the accepted port not recorded. A calibration of
the Swift side hung once because the test's scripted gateway answered an unexpected call with
silence; it now answers with an error, so a broken gate fails instead of hanging. Suite 1294 green,
Go green under `-race`.

**Live, Dev2 and Dev6 on this Mac, both registered on `relay1.port42.ai`:** Dev2 made an invite for
a port; Dev6 accepted it with `invite.accept` (after its share card) and Dev2 recorded it used within
five seconds. Dev6 then drove Dev2's port by `port42://<Dev2>/<port>`, about 300 ms a call: it read
the port; a push with no token was refused with Dev2's current token, one retry with it landed, and a
write on the old token was refused `stale_write` with the new current; a Dev2 port it was not given
and an edit it lacks the right for were refused `not_granted`. Dev2's port chat shows the join line.

**Found in that run, fixed:** a refusal forwarded back from the other instance kept only its code and
message, so `current` was lost and the one-retry recovery could not work between instances. The door
now carries every field of the refusal (`RemotePortTests`, calibrated).

**The link scheme, open:** every Port42 instance registers `port42://`, so a clicked
`port42://invite#…` opens whichever instance macOS picks. The live test uses `invite.accept`; the
click and ⌘K accept path (4.6b) needs an answer to this.

**4.6b built so far, 2026-09-26: a port on another instance as a tile, live between two Port42s.**
Accepting an invite opens a tile on this desktop that runs the host's own HTML. Everything that page
asks of `window.port42` goes to the host, as this instance, with the host's port id in place of the
tile's, so the host's rights decide; `presentation`, a fact about this desktop, stays here. The tile
subscribes to the port: a `state` event fetches the HTML again, and a push reaches the tile's page as
it reaches the host's, a `port42:data` event, so both copies see the same input. A host that cannot
be reached shows as offline in the tile's chrome, and the tile retries. Mirrors resume after a
restart. Settings: the AI tab is gone, and Remote shows this instance's peer id and its relays, each
with whether this instance is registered there (`relay_state` from the gateway), with add and remove.
Sharing asks an agent or client for each port it shares or opens (`share:<port>` grants), never the
person on their own behalf.

**Live on Dev2 and Dev6 through `relay1.port42.ai`, with Gordon at both screens:** a counter port on
Dev2, clicked on either desktop, counts on both, each log naming the copy the click came from; one
push reaches Dev6 in about half a second and a burst of 20 in under a second, nothing lost. Then a
WebGL shader on Dev2 with four sliders: each machine renders it on its own GPU, and a slider moved on
either desktop moves the other. Gordon: "shader test you made works great."

**Found live, fixed:**
- The tile's page got a push as a `push` bus event while the host's page gets `port42:data`, so a
  page written for its host missed every push in the tile. One definition now
  (`PortBridge.dataEventScript`) serves both (`RemoteTileTests`, calibrated).
- A click on a port in the Port42 window that was not in front only brought the window forward:
  the click lands on the web view, and WebKit accepts a first click only where a drag or scroll could
  start. With two instances side by side every switch lost a click. The port's web view now accepts
  it (`PortFirstClickTests`, calibrated). This was true of every port, not only shared ones.

Gates: `RemoteTileTests` (6), `PortFirstClickTests` (1), `InviteTests` per-port sharing, and the
relay-state frame in `RemotePortTests`; each calibrated by breaking what it guards. Harness five of
five on Dev2. The harness now works in a space of its own and switches the person back afterwards
(Gordon: tests never touch a space in use).

Still in 4.6b: the Share button and dialog in the port chrome (rights, code, copy link), fork and
move, and accepting by clicked link or ⌘K paste.

**Found before the Share button, fixed 2026-09-26: only a web port can be shared.** Invites did not
refuse a terminal or a browser port. `use` on a shared terminal would type into this machine's shell
and `see` would read everything it prints; a browser port is signed in as this person. Nothing had
shared one, but a Share button would have made it one click. `createInvite` and the redeem both refuse
anything but a web port (`AppState.shareable`); gate in `InviteTests`, calibrated. Decided (Gordon, 2026-09-27): terminals
and browser ports are never shared in Phase 4. A shared web port sends a page the other side runs;
a terminal or browser port is a live session on this Mac, so sharing one means streaming it and
taking input into it, which is remote access. Companions on terminals collaborate across machines
through a shared port's chat instead (4.6c). A watch-only terminal (output streamed, no input) is a
possible later feature, with its own design.

**The sharing pill and the Share box, built 2026-09-27 (Gordon chose the pill over a share icon or
the overflow).** One pill in a tile's chrome, left of presence: "shared · 2" (or "invite sent") on a
port of this instance, "Ada's" or "Ada's · offline" on a tile of someone else's, and nothing on a port
nobody shares. It opens one panel. On your port: each machine it is shared with, its use, edit and
wake as chips that toggle (see stays, since it is what sharing is), stop sharing, the invites not used
yet with withdraw, and "+ invite someone". On theirs: whose it is, what you can do, remote wake, and
leave (closes the tile and forgets the port here). "Share…" under "…" on a web port of this instance
opens the Share box: use, edit, remote wake (on by default) and a code, then the link with copy, the
code, and what the port can do on this Mac. The pill reads a cached `sharing` state rebuilt on every
rights or invite change, so a render never reads the database. Gates: `SharePillTests` (labels; the
pill follows an invite, a join, a right, stop sharing and a withdrawal; a tile says whose and leaving
forgets it), calibrated by five breaks. Suite 1339 green.

**Accepting, built 2026-09-27.** An invite link, clicked (`port42://invite#…`, through the existing
deep-link door) or pasted into ⌘K (the web page's link or Port42's own), opens the accept box: whose
port, what it lets you do, remote wake (on by default), the code field when the invite needs one, and
"open it", which accepts as the person and brings the tile forward. Nothing is joined unasked. The
scheme clash between instances on one Mac is a dev-only problem (a Mac has one Port42); a test hands a
link to one instance with `open -a Port42Dev6.app 'port42://invite#…'`. Gate: `SharePillTests`
(a link is recognised clicked or pasted, with spaces around it; another site's link, a broken coupon
and an ordinary search are not), calibrated.

**Share, move, fork (Gordon, 2026-09-26).** One port, three verbs,
the same for another space on this instance and for another instance:

- *Share (sync):* one port, shown in both places, the holder deciding every call. Built for another
  instance in 4.6 (the remote tile); on this instance a port kept in another space is already a
  tile on both.
- *Fork:* a one-time copy that is then independent; for a remote port, `see` and a local
  `port.create` from its HTML.
- *Move:* a fork after which the source closes, so the port lives in one place only.

Decided: fork and move ship with the share dialog in 4.6b, and forking a port shared from another
instance needs a right of its own (`fork`), granted in the invite like the others, not implied by
`see`. It cannot be enforced (showing a port delivers its page), so it is the sharer's leave, which
Port42 honours by offering Fork only when given (Gordon, option A: "we just don't make it easy").

**Fork, built 2026-09-27.** "Fork: a copy" under "…" on your own web port, and "fork a copy" in the
pill panel of someone else's when they allowed it ("allow a copy" in the Share box, off by default;
a "copy" chip per person in the host's panel). The copy is a new web port of this instance in the
current space, titled "… (copy)", with no grants of its own and no tie to the original. Gates:
`ForkTests` (an independent copy; refused without leave, made with it, and never still theirs),
calibrated by three breaks. Suite 1350 green.

**Move, built 2026-09-27.** "Move to…" under "…" on your own web port lists your other spaces (the
existing re-home: only its space changes, the live view is untouched) and "another machine…", which
opens the Share box as a hand-over: an invite carrying `move`, with an optional code. Opening it takes
the port: its page goes to them as a port of their own, it closes here (archived, so restorable), and
no right is granted, since nothing stays to reach; a second redeem is refused. The accept box says
"take" and that it closes on their machine. `move` travels in the invite's rights, so no migration.
Gates: `ForkTests` (the hand-over, and taking it), calibrated by three breaks. Suite 1352 green.
4.6b is complete.

**Found by Gordon, fixed 2026-09-27: a fork kept driving the original.** The demo page had its own
port id written into its source to push to itself, so its copy pushed to the original (the
original's chrome named the copy as its driver). A page had no ready way to know its own id: only
`port.info()`, which nothing taught for this. Every page is now handed its own id before its script
runs, `port42.self.id`, and the manual tells authors to use it and never a written-in id or a lookup
by title. `port.info` on a copy of someone else's port answers from the copy, like `port42.self`.
No rewriting of old pages (Gordon: this release can break them). Gate: `PortSelfTests`, calibrated.

### 4.6c Companions across machines: one chat for a shared port

**The test this step exists for (Gordon, 2026-09-26):** a companion on Dev2 and a companion on Dev6
build the shared shader together, talking in the port's chat to split and hand off the work, while
Gordon watches both desktops. Everything below is what that needs, and nothing else.

**Measured today.**
- A port's chat lives on the instance that holds the port (`PortChat`, rows keyed by the port). Every
  post publishes a `chat` event on the port's topic, so the tile's subscription on the other instance
  already receives each one; the mirror drops them (`mirrorEvent` handles `state` and `push` only).
- A remote caller can `chat.post` into a shared port's chat, and with `wake_agents` its post wakes the
  host's companions (`postToChat`). The post is attributed to the instance as one principal
  (`remote`), so the host cannot tell the person there from a companion there, and the routing rule
  that stops two companions looping (a companion's post wakes only whom it names) does not apply to
  it: a companion on the guest posting plainly would wake the whole chat on the host.
- The tile on the guest has a chat of its own, keyed by the tile, which nobody on the host sees.
- A guest companion reaches the port only by its `port42://<peer>/<port>` address; a call naming the
  tile's local id is not forwarded (only the tile's own page is, `mirroredCall`).

**Decisions.**
- *One chat.* A shared port has one chat, on the host. The tile's chat on the guest shows it and posts
  to it; nothing is stored twice.
- *Names* (decided above). A companion or person on another instance is labelled with the person
  there: `wise-tern (Ada)`, and `wise-tern (gordon 56dv)` when two instances would show the same
  label. The mention is written with the existing escape rule (`@wise-tern%20(Ada)`), and the chat
  already shows an escaped mention as the name, so no new syntax. Remote in Settings gets an optional
  "this machine's name". A mention is delivered by peer id and companion id, never by label.
- *Who posted.* A call from another instance says which actor there made it: the person, or a named
  companion. The host believes the instance (Noise proved it) and records the actor as that
  instance's claim: `fromId` `<peer>/<actor id>`, `fromKind` `human` or `companion`, the label above.
  The loop rule then applies unchanged. The same actor names the driver in the host's driver chip.
- *Wakes both ways.* The host's companions wake for a guest's post only with `wake_agents` (built).
  The guest's companions wake for a mention in the host's chat only if the person on the guest has
  turned on "their companions can wake mine" for that tile. Default off: a wake runs on this
  machine's terminal and spends this person's model.

**Steps, each its own commit with gates.**
1. *One resolution layer (Gordon: addressing inside an instance is the same as across them).* Every
   reference to a port, a bare id, a title, `port42://<this peer>/<id>` or `port42://<other>/<id>`,
   resolves to one address, and a mirrored tile's id resolves to its host's address. Then one rule:
   this instance runs the call, any other is forwarded. The tile page's own path (`mirroredCall`)
   goes, and chat keys resolve the same way, so the tile's chat IS the host's chat and a companion
   naming the tile reaches the host's port. The mirror applies each `chat` event to the tile's chat
   live. Gates: a call naming a tile's id, from the page, a companion or the CLI, reaches the host
   with the host's id; a post on either side appears once on both, in order, stored only on the
   host; `port.update` naming the tile needs `edit`.
   **Built 2026-09-26.** `remotePort(for:)` is the one resolver: another instance's address, and a
   mirrored tile by id, title or this instance's address, resolve to the host's port, and the
   dispatcher forwards on that. The mirror loads the host's chat into the tile's (`chat.read`) and
   applies each `chat` event live. Gates: `RemoteTileTests` (tile by id, title and local address;
   the tile's chat shows the host's and posts go there, stored only there), each calibrated by
   breaking the resolver, the live events and the initial load. Suite 1301 green. Live, Dev2 and
   Dev6 in new spaces: a post on each side reads the same on both. The Dev6 post showed as "gordon",
   the instance's person, though a client made it: step 2.
2. *The actor crosses.* `remote_call` carries the actor (id, name, kind); the host attributes the
   post to it and routes by its kind. Gate: a guest companion's plain post wakes nobody on the host;
   a guest person's plain post wakes the chat's companions (with `wake_agents`); a claim of kind
   `human` from an instance never makes it the host's own person.
   **Built 2026-09-26.** `remote_call` and the call it becomes carry `actor` (id, name, kind); the
   host believes it only on an attested call and only as one of `human`, `companion`, `peer`,
   `port` (`RemoteActor`), and records a post as `<peer>/<actor>`, labelled `name (person there)`
   unless it is the person, with the actor's kind, so the loop rule holds across machines. A
   companion in a terminal calls through the CLI as a client and is sent as a companion, as
   `routeChat` knows it by name. The driver chip names the same actor (`ActorRef` `<peer>/<actor>`).
   Gates: `outbound_test.go` (the actor crosses), `RemoteActorTests` (4), calibrated by five breaks.
   Suite 1309 green. Live: a Dev6 client's post via the tile reads "nautilus-harness (gordon)" on
   Dev2, where it had read "gordon".
3. *Names and mentions.* Labels and the clash suffix; `whoami` and `companions.list` add the other
   instance's participants in the shared chats this companion is in, as mentionable names. Gate: a
   mention of a guest companion from the host reaches that companion and no other, including when two
   companions share a label.
   **Built 2026-09-26.** A machine is labelled when it enrols: the name it gave, or, when this person
   or another machine already goes by it, that name and the first four characters of its peer id.
   The first to take a name keeps it plain and a label never changes after it is shown, so two labels
   never clash (a refinement of the decision above, where each would gain the suffix). The label is
   returned in the redeem and kept by the guest (`knownAs`, migration v60), for step 4. `whoami`
   gains `elsewhere`: companions on other machines met in a shared port's chat, each with its
   mention (`@wise-tern%20%28Ada%29`, the existing escape) and that chat. Remote in Settings has
   "this machine's name", sent in place of the person's name when joining. Gates: `InviteTests`
   (labels at enrolment), `RemotePortTests` (knownAs kept), `RemoteActorTests` (whoami elsewhere; a
   mention of another machine's `wise-tern` never wakes this one's), calibrated by five breaks.
   Suite 1312 green. Two unrelated parallel-test races showed under a load average near 200 and
   passed alone: `MainThreadIOTests` (a global log sink) and `CompanionWatchTests` (timing).
4. *Guest wakes, and replies.* A mention in a mirrored chat wakes this instance's companion when the
   tile's switch is on; its reply goes back to the tile's chat, so to the host. Gate: off by default;
   on, one mention gives one wake and one reply in the host's chat; off again, none.

   **Built 2026-09-26.** Each tile has a switch in its chrome, "wakes mine", off by default
   (migration v61). With it on, a `chat` event from the host that mentions one of this instance's
   companions by the name the host knows it by (`wise-tern (Ada)`, from `knownAs`), exactly, wakes
   it here: a terminal companion by the same delivery as a local mention, a headless one by
   `launchAgents`, never for its own post. Replies go through `postReply`, which sends a reply to a
   mirrored tile's chat to the host as that companion, so nothing is kept here; both reply sites
   (a terminal's turn, a command companion) use it. Gates: `RemoteTileTests` (switch off, another
   machine's companion of the same name, its own post, on, off again; a reply goes to the host),
   calibrated by five breaks. Suite 1316 green.

**Live, the magic test (new spaces on Dev2 and Dev6; Gordon watches).** The shader on Dev2 shared with
`see`, `use`, `edit` and `wake_agents`; a companion on each instance; Gordon turns on wakes in Dev6's
tile and asks both, in the tile's chat, to build the shader together. It passes when both companions
post in the one chat, hand off by mention across machines, both edit the port (the driver chip and
the token history name each), the chat is the same on both desktops, and the result renders (lit
pixels, not only a clean console).

**Passed live, 2026-09-26 (Dev2 and Dev6 through relay1, new "shader-duo" spaces, Gordon watching):**
a Claude companion on each instance, `ember` on Dev2 where the port lives and `tide` on Dev6 through
its tile, built the WebGL shader together from one brief in the port's chat, in under three minutes.
ember wrote the canvas, shader and loop and handed the controls to `@tide (gordon)`; tide, woken on
Dev6, patched its sliders and the `port42:data` sync into its own marked slot on Dev2's port and
handed back to `@ember`; ember checked Dev2 (every pixel lit, the sliders change the frame's mean
colour with time frozen, tide's push arrived) and asked tide to check Dev6; tide confirmed Dev2's push
reached Dev6 with every pixel lit; ember said DONE. Seven posts, four hand-offs by mention across the
machines, the chat the same on both desktops, both companions' writes on the one port, and each post
attributed to its companion (`tide (gordon)` on Dev2).

Found in the run:
- `port.exec` naming the tile ran on the tile's own page here, because exec is never sent to another
  instance (it would run code in the port's real page, with that machine's permissions). `getDom`
  and `console` naming the tile went to the host. So a check of "the copy on screen" read the
  host's page, and only exec saw the copy; one of my own live checks read Dev2 twice.
  Decided (Gordon): your tile is a window onto the port. What the port is (read it, change it, push
  to it, its chat) goes to the port's machine; what your window shows (its page, its console, code
  run in it, whether it is on screen) stays here. `AppState.windowMethods`; by the port's address
  they still go to the port. Code run in the window reaches the port only as the window does, through
  the host and your rights there. Gate: `RemoteTileTests` (the window stays here; the address goes
  there), both halves calibrated.
- The brief's switch ("wakes mine") had to be found and flipped before anything worked. Replaced by
  the remote wake decision below.

**Remote wake (Gordon, 2026-09-26), replacing the tile switch as the way in.** Each side decides for
its own companions when it agrees to share: the sharer on the Share dialog ("remote wake", on by
default: may their companions wake mine), the accepter on the accept screen (the same, on by
default), and `invite.accept` takes `remoteWake`, default on, for an agent-driven accept. The tile's
chrome keeps the switch, renamed "remote wake", to change it later. `wake_agents` on the invite is
the sharer's side of the same setting. **Built 2026-09-26:** invites default to see, use and wake_agents;
`invite.accept` takes `remoteWake` (default true) and its card says so; the switch reads "remote
wake: on/off". The Share dialog and the accept screen, where a person makes these choices, come with
the rest of 4.6b. Gates in `InviteTests` and `RemoteTileTests`, calibrated. Suite 1327 green.

Decided (Gordon, 2026-09-26): "their companions can wake mine" is a switch on each tile, off by default.

### 4.7 The browser lane

**The goal.** Someone with no Port42 opens an invite link in an ordinary browser, on a laptop or a
phone, and uses the shared web port there: it renders, their clicks reach the port on the host's Mac,
and pushes from the host reach them. Same rights, same port, same relay, same end-to-end encryption
as the Port42 lane (4.6). Terminals and browser ports are never shared, so the browser lane is web
ports only.

**Measured today.**
- The relay speaks one protocol to every client (`gateway/relay`): a WebSocket to `wss://<relay>/v1`,
  a challenge nonce, a `hello` signed with the client's Ed25519 key over the relay URL, the nonce and
  the role, then `open {to: <host peer>}` answered `opened` or a refusal, then binary frames carrying
  the Noise IK handshake and the transport messages. The Go client is `relay/client.go`
  (`dialVia`, `Initiate`).
- Inside the session, the door's envelopes (`call`, `response`, `stream`, `error`) with a one-byte
  chunk header, at most 8 MiB a message (`transport/chunk.go`).
- The host side is complete: `invite.redeem`, rights, the remote door, attestation. A browser guest
  is one more peer to it.
- Node 22 and npm are on this Mac, so the browser client can be built and tested here.
- The gateway still serves the old `/port` spike with a query-string token (`gateway/main.go`).

**Decisions for Gordon.**
1. *Who builds the page.* This repo ships a reference `invite.html` and the guest script that works
   against Dev2, and the website agent puts that page on port42.ai as it is, adding only the site's
   look. Recommended: one implementation, tested here, rather than the agent rebuilding it from the
   spec and the two drifting.
2. *The browser tooling.* The guest script is written as ES modules on the `@noble` libraries, bundled
   by esbuild into one file under `guest/dist/`, with the bundle and its integrity hash committed, so
   the website needs no build step. npm and esbuild are development tools of this repo only.
3. *What a browser guest gets.* The port, and the port's chat beside it: a browser guest can talk with
   the people and companions there (4.6c). Not in 4.7: fork, move, accepting a second invite from the
   page, and anything that needs an installed Port42.
4. *Who the browser is.* A browser guest's key is made on its first Join and kept in that browser's
   storage for port42.ai, so a refresh or a return visit is the same guest and needs no new invite.
   Clearing the site's data makes a new guest.

**Decided (Gordon, 2026-09-27).** The invite page is managed in this repo and is one page for every
Port42: the link names the Mac, the relay and the port, and the page is the same program for all of
them, a guest-only Port42 in the browser with its own key. It is served from **`tele.port42.ai`**,
its own small Railway service built from this repo (a Go server that serves the page with its
security headers), published with each release, so the page and the app come from one commit. A
subdomain rather than a path on port42.ai: a browser guest's key is stored per origin, so on its own
origin nothing else on the website can reach it, and it deploys without the website. Invite links
become `https://tele.port42.ai/#<coupon>`; port42.ai may link or redirect to it. The page offers
**Open in Port42**, **Open here** and **Get Port42** (the release DMG). With no invite in the link,
its home is a box to paste one into (Gordon); a link it cannot read lands there too. The rest of the four decisions
above are as recommended.

**Steps, each its own commit with gates.**
1. *The guest runtime* (`guest/src`): the relay client (connect, signed `hello`, `open`, pings), a Noise
   IK initiator on `@noble` (X25519 from the Ed25519 key, ChaCha20-Poly1305, SHA-256, prologue
   `port42-noise-v1`), the chunk framing, and calls with `call_id`s, streams and refusals. Gate: a Go
   test runs the runtime in Node against an in-process relay and a Go host instance and completes a
   redeem, `getHtml`, a push and a subscribed event; and the handshake fails against a host with a
   different key. This is the interop gate: the browser speaks exactly the relay's protocol.
   **Built 2026-09-27.** `guest/src`: `peer.js` (ids as `transport/peerid.go`), `noise.js` (the IK
   initiator on `@noble`: the X25519 key from the first half of SHA-512 of the Ed25519 seed, as
   `NoiseKey`; the host's from its Ed25519 key, as `MontgomeryPublic`), `client.js` (the relay's
   challenge and signed hello, `open`, the handshake, chunked envelopes, calls, streams and refusals
   with every field). The relay now pings every client: a browser can answer a ping but not send one,
   and Cloudflare drops a connection quiet for about 100 seconds; relay1 needs redeploying before the
   live test. Gates: `guest_e2e_test.go` runs the runtime in Node against a real relay and a host
   gateway (redeem, a read, `stale_write` with `current` then the retry, a streamed event, 200 KB each
   way; host offline; a handshake the host cannot read is refused), and `TestTheRelayPingsItsClients`;
   calibrated by five breaks. Go green under `-race`, suite green.
2. *The guest page* (`guest/invite.html`, as the design's "For the website" section): decode the
   coupon, clear the fragment, show who shared what; "Open in Port42" (`port42://invite#…`) and
   "Open here"; name, code and Join; the port in a sandboxed iframe (`allow-scripts`, never
   `allow-same-origin`) with a `window.port42` shim that forwards over `postMessage` to the runtime,
   so the iframe never holds the key; `port42:data` and `state` delivered into it; `port42.self.id`
   the host's port id; the chat beside it; every refusal said plainly. Gates: in Node with a DOM
   (jsdom): no network before a click, the fragment cleared, the key never inside the iframe; the
   shim's calls reach the runtime and nothing else.
   **Built 2026-09-27.** `guest/invite.html` and `guest/src`: `coupon.js` (the invite from the
   fragment), `shim.js` (the frame's `window.port42`: a proxy whose calls are messages to the page,
   with `port42.self.id` the host's port id), `guest.js` (the identity kept for the origin, the
   session, redeem, the page, the chat, events, and offline with a retry every five seconds that
   ends on any refusal but offline), `page.js` (the intro with Open in Port42, Open here and Get
   Port42; the join form; the frame and chat wiring; nothing on load but reading the invite).
   `guest/src/methods.json` is every remotely reachable method's parameter names, generated from the
   registry (`GuestMethodsTests`, PORT42_REGEN_GUEST=1), so a page's positional calls are named as
   the app names them. Gates: `guest/test/page.test.mjs` in jsdom (no network before a click and the
   fragment cleared; a broken link; join redeems as the name given and the frame has no same-origin
   and no key; calls named by the registry, unknown ones refused; offline dims the port, stops the
   chat and says why; a refused invite is explained), run by `go test` (`TestTheInvitePage`);
   calibrated by five breaks.
3. *Bundle, server and hygiene:* the esbuild bundle with its integrity hash; `cmd/port42-tele`, the
   page's server, with its Content-Security-Policy (`connect-src` the relays only),
   `Referrer-Policy: no-referrer` and no third-party script; `tele.Dockerfile` for Railway; invite
   links on `tele.port42.ai`. Gates: the committed bundle matches a fresh build and the page names its
   hash; the server sends every header.
   **Built 2026-09-27.** The port runs in `frame.html`, not a `srcdoc`: a srcdoc frame inherits the
   page's policy, which must forbid inline script to protect the key, and ports are inline script.
   `frame.html` is served with the policy Port42 gives ports in the app (inline script and style,
   `data:` images, no network) and is sent the page by message; the frame keeps an opaque origin.
   `gateway/tele` serves the page (script only from itself, connections to any `wss:` relay since an
   invite may name a self-hosted one, frames from itself, no referrer, no framing), the frame and the
   bundle, and nothing else; `cmd/port42-tele` and `tele.Dockerfile` (context: the repo root) run it
   on Railway. `npm run build` bundles and writes the bundle's sha384 into the page. Invite links are
   `https://tele.port42.ai/#<coupon>`. Gates: `open_test.go` (every header, the page's `script-src`
   exactly `'self'`, a frame with no network, nothing else served) and `bundle.test.mjs` (the
   bundle is a fresh build and the page names its hash), calibrated by five breaks.
4. *The `/port` spike and its query-string token deleted* from the gateway. Gate: `/port` answers 404.

   **Built 2026-09-27.** `guestpage.go` and the `/port` route are deleted; the gateway's routes are
   `newMux` (`/ws`, `/call`, `/health`, `/`). Harness scenario 4's local half no longer fetches it.
   Gate: `TestTheOldPortRouteIsGone`, calibrated.

   **The page is the port (Gordon, 2026-09-27).** A link opens straight to the port under a header
   ("port42 · Gordon's chart", Open in Port42, Get Port42), with one card over it to join: the name
   (remembered), the code when needed, and Open. The first join takes that one click, because a link
   previewer that runs the page's script would otherwise spend a one-time invite; a browser that has
   joined this port before opens it at once, which a previewer, with no key, cannot. Found live: the
   port panel's own `display` beat the `hidden` attribute and covered the page; `[hidden]` now wins,
   with a gate. Gates in `page.test.mjs` (ten), calibrated.

**Deployed 2026-09-27.** `tele.port42.ai` runs as the Railway service `tele` in the project
`port42-relay`, next to `relay`, with `RAILWAY_DOCKERFILE_PATH=tele.Dockerfile`. The deploy uploads a
staged context (committed `gateway/`, `tele.Dockerfile`, `invite.html`, `frame.html`, the bundle), not
the repo root with its DMG. Cloudflare holds a DNS-only CNAME `tele` → `f7i1ufev.up.railway.app` and
the TXT `_railway-verify.tele`; Railway cannot verify ownership through Cloudflare's proxy, so the
record stays DNS only. Let's Encrypt certificate valid. Checked on the live host: the page and frame
answer 200 with their CSPs, and the bundle is byte-identical to the committed one. The Cloudflare
token (Zone DNS Edit, port42.ai only) is in the macOS Keychain as service `cloudflare-dns-port42`,
read at call time. relay1 was redeployed the same day with the server-side pings. Live: Gordon opened
a Dev2 invite to duo shader at `https://tele.port42.ai/#…` and joined it through relay1 (2026-09-27).

**Live.** Dev2 shares a port; the reference page, served from this Mac, opens it in Safari and in
Chrome on this Mac, then on a phone on cellular. The port renders, a click there moves it on Dev2 and
on a Dev6 tile of the same port, a push from Dev2 arrives in the browser, a refresh is the same guest,
and the host's chat shows the browser guest by name.

### 4.9 A relay anyone can run (asked for v1, Gordon via nautilus, 2026-09-27)

Settings already takes relay addresses; this makes running one a click. (1) A Docker image of
`cmd/port42-relay` (for example `ghcr.io/gordonmattey/port42-relay`), (2) static binaries for Linux
x86 and ARM and for macOS on each release, (3) a "Deploy on Railway" template from this repo and
`relay.Dockerfile`, so someone with no ops experience gets a `*.up.railway.app` address with TLS and
pastes `wss://<it>/v1` into Settings, (4) a short page on running one. Taken by the nautilus
session (Gordon), on branch `relay-dist` cut from this branch, new files only. Also decided for v1,
after this branch merges: pairing (`port42 pair`, approved in the app) and scoped tokens.

**Proposed (Gordon, 2026-09-27), not decided: an invite that works N times.** A count set when
sharing, 1 by default, so one posted link can serve a limited group ("the first 50"); each person who
opens it is their own guest, and the pill's panel shows "12 of 50 used". A link that works many
times can be forwarded, which is its purpose; one-use stays the default.

### 4.7b What the browser test found, and what follows (Gordon, 2026-09-27)

Live on Dev2 with Safari and Chrome as two guests through relay1 (the page served from this Mac):
both joined, clicks and chat crossed between them and Dev2. Found:

1. **A late joiner starts empty.** The demo keeps its count in the page, so the second browser loaded
   0 and its first click reset everyone to 1. The manual tells ports to keep state in
   `port42.storage`, and storage is never reachable from another machine, so any port built the
   recommended way loses its state when shared. **Decided (Gordon): shared port storage.** Found
   while designing it: storage is filed under the port's space and whoever made the port, so two
   ports one companion made in a space share a bucket, and a key like `state` collides; across
   machines that would be a leak. So, as one step: (a) a port's page stores under the port itself
   (breaking, allowed for this release); (b) a copy of a shared port on another machine reaches that
   port's own storage on the host, reading with `see` and writing with `use`, never the space's shared
   bucket or the global one; (c) every change is a `storage` event to every copy, the host's own page
   included; (d) the manual's state pattern: load on start, reload on `storage`. Later, the same
   storage may itself be shipped to guests rather than read from the host (Gordon). **Built 2026-09-27.**
   `BridgeServiceStorage`: a port's page stores under `port:<key>` in its port's space; a remote
   caller names `port` and reaches only that bucket (RemoteAccess: get and list `see`, set and delete
   `use`; the shared and global buckets refused); set and delete announce `storage {key}` to the port's
   own page, which publishes it to every copy; a mirrored tile and the browser page add `port` to their
   storage calls and pass the event to the page. `scope` and `shared` are declared, so a named caller
   may pass them flat. The manual's state pattern reloads on `storage`. Gates: `SharedStorageTests`
   (per-port buckets; see reads, use writes, nothing else reachable; every change announced once),
   `RemoteTileTests` and `page.test.mjs` (both copies name the port), calibrated by six breaks.
2. **A guest asked a companion for something new, and it made a port the guest cannot see.** ember
   on Dev2 made "shader" and posted its id. Decided: a port id in a chat is a link (it focuses the port
   in Port42, opens it on the page if you have access); a companion never gives access on its own; it
   **shares with the people in the chat** (grants the new port to the machines already in this
   port's chat, with the per-port card on the host), and the companion instructions say that someone
   on another machine sees only the ports shared with them.
3. **The page becomes a small desktop** (Gordon): a thin bar (port42, Open in Port42, Get Port42) and
   each shared port as a tile with the tile's chrome, movable, resizable, stacked, focusable,
   closable; no spaces, dock or galaxy. A newly shared port arrives as a new tile on the same
   session.

Order: shared storage, sharing with the chat and clickable ids, the desktop, the companion
instructions; then 4.8. Shared storage is built. Sharing with the chat and clickable ids moved to the
later list in `plan-shell-only.md` (Gordon, 2026-09-27).

**Found live, fixed 2026-09-27: an instance's identity was replaced when the Keychain could not be
read.** Dev6's tiles of Dev2's ports stopped syncing after sleeps and restarts, and never recovered:
Dev2's peer id had changed (`56dvfh4y…` to `rbliv6ag…`), so every call went to a peer that no
longer exists. Any failed Keychain read came back as "none", and a new key was made and saved over
the old one; a second build of Dev2 (another session's, another signature) and the harness token
breaking at the same time point to the same cause for the gateway root secret. Now a read says found,
missing or unreadable (`KeychainRead`), and `KeptSecret.resolve` makes a secret only when it is
missing: an unreadable identity leaves the launch without sharing (Settings says why), and an
unreadable root secret uses a temporary one for that launch, never saved. Gate: `KeptSecretTests`,
calibrated. Dev2's old key was overwritten and cannot be recovered; its shares to Dev6 need new invites.

**After the final integration (Gordon, 2026-09-27).** Test the invite deep link on the daily-driver
app (`port42://invite#…` and the page's Open in Port42 reach the join box); dev instances all claim
`port42://`, so it cannot be tested on them. Proposed then: Universal Links (the associated-domains
entitlement on the release build and an `apple-app-site-association` file on tele.port42.ai), so
`https://tele.port42.ai/#…` opens Port42 when installed; Safari, Mail and Messages honour it, Chrome
does not. Passed to nautilus for the integration list.

**Found live, fixed 2026-09-27: dead tiles locked out live ones.** Dev6's tiles of ports on Dev2's old
identity retried every five seconds, each retry a new relay session; the relay limits session requests
per key and per address (Dev2, Dev6 and the browsers here share one), so Dev6 was refused
`rate_limited` even for Dev2's live ports, and a live tile missed ember's new version. Now the gateway
remembers a peer it could not reach (15 seconds offline, 60 rate limited) and fails further calls to
it at once, and a tile's retries double from five seconds to five minutes, resetting once a
subscription holds 30 seconds. Gates: `TestAnUnreachablePeerIsNotDialledAgainAtOnce` and
`RemoteTileTests` (backs off), calibrated. Found with it: a tile restored after a restart ran the page it had saved, not
the host's current one, until the host next changed it; a restored tile now fetches the page first
(`RemoteTileTests`, calibrated). And the reason tiles stayed out of sync after a laptop sleep or an app
restart: mirrors were restored when the gateway's welcome came, and the tiles come back half a second
after launch; when the welcome won, there was no tile to mirror and it never tried again. Mirrors now
resume once both have happened, in either order (`resumeMirrorsWhenReady`; `RemoteTileTests`,
calibrated).

### 4.8 Scenario 4 in the harness

The harness's scenario 4 becomes the master plan's test: a browser on another machine renders the
port with no install, a click there appears here, the stale write of two is refused with `current`,
one retry lands, both chips agree. In each lane, on a chart and a chat port, and a guest asking beyond
its grant is refused. The relay's round trip from each network is recorded.

## Test plan

| Step | Automated (Swift and Go, every build) | Harness (live, Dev2 and Dev6+) | Gordon by hand |
|---|---|---|---|
| 4.0 | none; it is a measurement | relay round trip, Noise timings | pastes the test link into his apps |
| 4.1 | object declared (scan); a remote principal's reads, writes, listings and refusals per right; `exec`, machine methods and secrets refused; `wake agents` both ways; secret grants; local suite unchanged | none | nothing |
| 4.2 | remote address round trip with a foreign peer; own peer local; key only on stdin (scan) | peer id stable across a restart | nothing |
| 4.3 | door over the fake transport; chunking and the size cap; spike E's refusals both sides; `/ws` cannot claim a peer | none | nothing |
| 4.4 | relay and Noise in process: call, subscription, bad `hello`, unregistered key, tampered frame, each limit | test peer through local then deployed relay: read, refuse, subscribe, revoke | nothing |
| 4.5 | burn, expiry, required code and its try limit, notify and Remove, no port 0 or space, revoke one of several | invite created and redeemed by the test peer, with and without a code | opens an invite from a phone; removes a guest from the notification; reads Access |
| 4.6 | forwarding never resolves locally; outbound over the fake transport | Dev2 to Dev6: scenario 4 in Port42; companions messaging across | the shared tile on a second instance |
| 4.7 | no key in the iframe; refresh keeps the guest; nothing before the click | none | scenario 4 from a browser and a phone on cellular |
| all | suite and Go suites green | five of five, scenario 4 extended | the verify below |

## Verify, live

Scenario 4 in both lanes, on a chart and a chat port, with the guest on another network: rendered with
no install in the browser, a click there appears here, a stale write refused with `current` and one
retry landing, both driver chips agreeing, companions on the two machines exchanging messages in the
port's chat, and the guest refused when it asks for another port, a listing of spaces, or the
clipboard.

## Not in this phase

- **Teleport, the wider idea (Gordon, 2026-09-27).** Teleport is one concept, bringing something in
  from elsewhere: `port42 teleport` brings a terminal session into a port, and `tele.port42.ai`
  brings someone else's shared port in. Later, the same word could bring in a browser link through
  a plugin, or an app, by recording the screen and following what the person does, so a working
  day's tools become ports. Vision only; nothing here is designed or built.

- **A direct path** (WebRTC, port mapping, IPv6), as a per-session upgrade behind the seam
  (`research-phase4-transport.md`).
- **Local object scoping**: `port.exec` running as the target port, a port inheriting its creator's
  machine grants, the ungated port verbs for local callers, a revoked `child` client restored at
  launch (`research/security-bridge-authorization.md`).
- **Sharing a space**, and whether a grant on a container cascades.
- **The mesh of one's own hosts** (`research-host-mesh.md`).
- **Store and forward and offline hosts** (O-2), with the Signal or MLS evaluation (decision 7).
- **Asynchronous permission** (D-d).
- **Fan-out to many guests beyond the relay's per-host cap, and per-element co-editing.**
- **Rendering without shipping source** (`research/rpc-rendered-ports.md`), and forking.
- **Moving the local door to a unix socket** (`research/program-as-credential.md`).
