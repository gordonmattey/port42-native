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
`see`.

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

**Live, the magic test (new spaces on Dev2 and Dev6; Gordon watches).** The shader on Dev2 shared with
`see`, `use`, `edit` and `wake_agents`; a companion on each instance; Gordon turns on wakes in Dev6's
tile and asks both, in the tile's chat, to build the shader together. It passes when both companions
post in the one chat, hand off by mention across machines, both edit the port (the driver chip and
the token history name each), the chat is the same on both desktops, and the result renders (lit
pixels, not only a clean console).

Decided (Gordon, 2026-09-26): "their companions can wake mine" is a switch on each tile, off by default.

### 4.7 The browser lane

- `port42.ai/invite.html` gains the coupon handling, "Open here" and the bundled script (decision 6),
  with the page hygiene of decision 4.
- The gateway's `/port` route and its query-string token are deleted.

*Gates:* the iframe never holds the key; a refresh is the same guest; the page makes no network call
before the click. *Live:* scenario 4 from a browser on another network and from a phone on cellular.

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
