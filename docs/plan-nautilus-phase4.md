# Nautilus Phase 4: the remote pipe

Detailed plan for Phase 4 of `plan-shell-only.md`. Scenario served: 4. Written 2026-09-26 against
`nautilus` at `638e1c2` on branch `nautilus-phase4`, for Gordon's review. Nothing is built. Sources:
`membrane/slice-02-cross-instance.md` (milestones B and C, spikes E and F), `browser-guest.md`,
`plan-web-port-sharing.md`, `slice02-risks-and-decisions.md`, `invite-taxonomy.md`, and three notes on
the `research` branch (`design-invite-over-libp2p.md`, `research-host-mesh.md`,
`research/security-bridge-authorization.md`).

All testing is on Dev2 (`./build.sh --dev2`, gateway 4244). Dev3, Dev4 and prod are never built,
launched or called.

## Goal

Someone on another machine sees and drives one of my ports, from Port42 or from a plain browser, and
reaches nothing else. No token crosses the internet, no server holds the port's state, and a guest
that asks for anything beyond its grant is refused.

## What changes, for a person and for an agent

- **Share a port with a link.** One link per port. Opened where Port42 is installed, the port appears
  as a tile on the other person's desktop. Opened anywhere else, it runs in the browser tab. Either
  way both people drive it, both driver chips agree, and a stale write is refused with `current`.
- **The link works once.** A forwarded link after it was opened enrols nobody. Revoking one share
  leaves the others.
- **Access lists who has what.** Each person or browser you shared with appears in Settings → Access
  with the ports they hold, and revoking takes effect on their next call.
- **An agent on the other machine can drive it too.** `port42 port.push id=port42://<peer>/<port>`
  from a companion on the second machine reaches the shared port through the same path as the tile.
- **A guest sees one port.** It cannot list your spaces, read another port, use your clipboard, your
  secrets or your terminal, or reach anything on your machine except the port it was given.

## Decisions

Settled ones are stated so they can be checked. The rest are for Gordon, each with a recommendation.
**The one blocker is decision 3**: crossing NAT reliably, and reaching a browser at all, needs a relay
Port42 operates.

1. **Address grammar (for Gordon).** Recommended: the remote form is `port42://<peer>/<portId>`, and
   the peer is written as a lowercase base32 CID (`bafz…`), the form libp2p provides for case-blind
   contexts. Three reasons. Every scope is a port and a port id is unique within an instance, so the
   space segment adds nothing. A space segment goes stale when a port moves space, and it hands a
   guest the id of a space it was not given. And a URL host is lowercased by many parsers and
   linkifiers, which breaks a base58 peer id (`12D3KooW…`). The local form `port42://space/<s>/<p>`
   keeps parsing unchanged. The built remote form (`port42://<peer>/space/<s>/<p>`,
   `PortAddress.swift`) has no production caller and is replaced. An invite is not an address (4).
2. **Transport: go-libp2p in the gateway, behind a four-verb seam, without gossipsub (for Gordon).**
   libp2p first and Iroh as a swap are D5 and D6, settled. The seam is listen, dial, peer id and open
   a stream, the four verbs `plan-shell-only.md` names. Recommended change to slice-02: **no
   gossipsub in this phase.** A subscription is a stream from the host to the subscriber carrying the
   door's existing `stream` frames. The host is the one source of truth, a stream is ordered and
   reliable, so there is no gap detection to build (slice-02 step 5), and a broken stream is
   answered by resubscribing and one `getHtml`. Gossipsub's mesh, where subscribers relay to each
   other, earns its cost with many peers and no single source, which is not this phase. It is also
   the one piece Iroh does not provide in the same shape, so leaving it out keeps the seam
   swappable. Iroh is measured beside libp2p in step 4.8, and a swap is put to Gordon only if
   libp2p falls short of the threshold there and Iroh clears it.
3. **Reachability, and who runs the relay (for Gordon, the blocker).** On a LAN, mDNS. Across NAT,
   AutoNAT to learn whether the host is reachable, then Circuit Relay v2 with DCUtR hole punching.
   **A relay is a server.** go-libp2p's default relay limits (2 minutes and 128 KiB per relayed
   connection, to confirm in 4.0) make a public relay good for coordinating a hole punch and useless
   for carrying a session that failed to punch. A browser can never be dialed, and a page served over
   HTTPS can only open a secure WebSocket, so the browser lane needs a relay with a real certificate
   even when the host's NAT would allow a punch. Options:
   - **(a) Port42 runs a small relay fleet** (recommended). Stateless, carries only ciphertext it
     cannot read, and serves the guest page too (6). New operational scope for Port42.
   - **(b) Public relays only.** No server to run. A failed punch is a failed share, and the browser
     lane works only where WebRTC reaches the host directly, which is unmeasured (4.0).
   How it is measured is step 4.8.
4. **The per-port invite, in both lanes (partly settled, two choices for Gordon).** Settled by D10: an
   invite names one port and grants that port only; port 0 and spaces are never invitable; sharing a
   second port is a second invite. Recommended shape:
   - **One HTTPS link**, `https://<guest origin>/i#<coupon>`. The coupon is in the fragment, which a
     browser never sends to a server. The page offers "Open in Port42" (`port42://invite#<coupon>`)
     and "Open here". A page cannot tell whether an app is installed, so it asks rather than guesses.
   - **The coupon carries no standing access.** Host peer id, relay hints, port id, rights (view, or
     view and drive), a one-time 128-bit nonce, an expiry, and display names (host, port title).
   - **Redeeming it is enrolment.** The redeemer dials the host, whose Noise handshake authenticates
     the redeemer's peer id, and presents the nonce once. The host burns the nonce, creates a `peer`
     client row for that peer id if there is none, and records one grant: that peer, that port,
     those rights. The Port42 lane redeems as the second instance's own peer; the browser lane as a
     key made in the page.
   - **Until it is redeemed the coupon is a bearer secret.** Whoever opens it first gets the grant.
     The host sees the redeemer in Access and can revoke. This is the price of a link that works with
     the host away; asking the host at redemption is the alternative and needs the host present.
   - **For Gordon, (i) what a browser guest keeps.** Recommended: its key persists in that browser's
     storage, so a refresh is the same guest and keeps the grant, listed in Access as a browser guest
     and reaped after it goes unused for a period Gordon sets. Alternative: nothing persists, and a
     refresh after redemption loses access, because the link is already burned.
   - **For Gordon, (ii) default rights.** Recommended: view and drive, since scenario 4 drives.
5. **Read scoping before anything is remote (settled in principle by the master plan; the local half
   is for Gordon).** A remote caller is **denied by default**. Every registry method declares what it
   acts on: a port argument, a listing, the machine (port 0), or nothing. A remote principal may call
   only port methods, only on ports it holds a grant for, within the grant's rights. Listings return
   only its granted ports. Machine capabilities, spaces, companions, `port.create`, `port.exec`,
   `terminal.exec`, `rest.call`, `fs.*` and secrets are refused with a new code, `not_granted`, that
   says the grant covers one port. `port.exec` is refused even on the granted port, because it runs
   inside the host's page as that port's own principal (`security-bridge-authorization.md`,
   unverified end to end). `rest.call` refused also closes a remote caller reaching the host's
   loopback services. Nothing a remote caller does can raise a permission card, so nothing blocks on
   a person who is not there (slice-02 assumption 2 and D-d are answered by refusal in this phase).
   **Named secrets get a per-caller grant.** Using a secret needs a grant for the caller's own
   grantee: a companion's ticked secrets write those grants for the companion; any other local caller
   (a port, a plain terminal, a manual client) is asked by a card that names the secret; a remote
   caller never. **For Gordon: local callers.** Recommended: scope remote callers only in this phase.
   Local callers keep today's reach, because object scoping for them is a re-consent for every local
   grantee and scenario 3's ports read each other. The research note's local findings (`port.exec`
   escalation, a port inheriting its creator's grants) are recorded under "Not in this phase".
6. **Where the guest page is served from (for Gordon).** The gateway stays on loopback (D5), so a
   browser elsewhere cannot fetch today's `/port` page from it. Recommended: a static page on a
   Port42 origin, served by the relay from decision 3 so there is one server rather than two. It
   holds no state and never sees the coupon (fragment). It bundles js-libp2p, dials the host through
   the relay over secure WebSocket, and upgrades to WebRTC where the host's NAT allows. The page
   renders the port's source in a sandboxed iframe with the bridge shim, as today's spike does. The
   gateway's `/port` route stays for loopback testing until step 4.7 and then goes. Needs from
   Gordon: the origin (a path on `port42.ai`, or its own subdomain).
7. **Where the Signal Protocol fits: not in this phase (recommended).** Live traffic is encrypted end
   to end by Noise (TCP) or TLS 1.3 (QUIC), including through a relay, which forwards ciphertext. This
   phase stores and forwards nothing: a port whose host is offline is unavailable (slice-02 O-2,
   deferred). Signal's contribution, forward secrecy for a message held for a recipient who is
   offline, has nothing to protect until something is held. When a chat port is mirrored to peers who
   are offline (the Mirror mode in `design-invite-over-libp2p.md`), evaluate MLS (RFC 9420) beside
   Signal: a chat port has many subscribers, and Signal's Double Ratchet is pairwise. Status: a
   recommendation, nothing measured.
8. **The instance's peer key (settled).** The P-256 signing key slice-02 planned to derive from was
   removed in Phase 1 (v48, `e71fb81`: "libp2p makes its own peer key"). So each instance generates
   one Ed25519 key at first need, keeps it in the Keychain under the instance name beside the gateway
   root secret (`Port42AuthStore`), and hands it to the gateway on stdin at spawn. Per instance,
   never per person, so two Macs of one person are two peers. Rotating it orphans every grant keyed
   on it, so nothing rotates it in this phase.
9. **The app never trusts an unverified peer field (settled by spike E, one correction).** The
   gateway authenticates the peer id in the handshake and forwards the call with that peer id and a
   MAC over it. The app verifies the MAC before it forms a principal, in `resolveGatewayCaller`, the
   one place a caller identity is formed. **The MAC key must be a second per-spawn secret that only
   travels on stdin.** Spike E used the host credential, and the app sends that over the socket in
   `identify` (`GatewayDoor.swift:154`), so a process squatting the gateway's port would learn it
   and could forge peers.
10. **The second machine (for Gordon).** Milestone B is not proven by two instances on one Mac, and
    only one Dev2 runs per Mac. Most of the phase is verified on this Mac with a Go test peer (a
    small program with its own libp2p key that dials Dev2), which is a harness tool and not a
    product. The LAN and cross-network runs need a second Mac running a Dev2 build. Which Mac?

## What is measured

Against `638e1c2` unless a date says otherwise.

- **Nothing is reachable from off this machine.** The gateway listens on `127.0.0.1`
  (`GatewayProcess.swift:95`) and its only dependency is a WebSocket library (`gateway/go.mod`).
  ngrok was deleted in Phase 1.
- **The address can name another instance and resolves none.** `PortAddress` parses
  `port42://<peer>/space/<s>/<p>`, and the resolver refuses any peer that is not this one
  (`PortResolution.swift:130`), where this one is always nil because no instance has a peer id.
- **There is no key.** `AppUser` carries no key material since v48. `Principal.peer`'s comments still
  describe an authenticated `peer.ID` flattened to a label (`Principal.swift:4-8`, `:22-24`), which
  has not been true since slice-02 5a and 5b.
- **Callers are clients with stateless tokens.** `p42_<id>_<mac>`, verified by recomputing an HMAC
  over the instance's root secret, with no expiry and no one-time form. Kinds are `paired`, `child`,
  `manual` and `installed` (`ClientRegistry.swift`). Revocation marks the row and is effective on the
  next call.
- **The envelope already uses the name `peer_id`**, for the gateway's WebSocket connection id
  (`gateway.go:39`). The remote identity needs a different field name.
- **Authorization is by capability, never by object.** In `BridgeMethods.swift`, 41 methods declare
  `permission: nil` and 28 name one. The grant object is hardcoded to port 0 at every read and write
  of a grant (`BridgeDispatcher.swift:45`, `:112`, `:117`, `:524`; `PortBridge.swift:76`).
  `ports.list` lists every space's ports (`BridgeMethods.swift:1346`). So any enrolled client can
  read, write, execute JS in and subscribe to any port. Locally that needs a process already on the
  machine; remotely it would be the whole desktop.
- **Secrets are scoped for companions only.** The `rest.call` check applies when the caller is, or
  acts as, a companion (`BridgeMethods.swift:853`). A port, a plain terminal or a manual client with
  the REST grant can use any named secret.
- **The invite's door survived and its payload did not.** The `port42://` handler is installed
  (`Port42App.swift:22`) and reaches `TransitionRoot.handleDeepLink` (`TransitionRoot.swift:283`),
  which accepts nothing. `/invite` still builds `port42://channel?…` for the deleted hub
  (`gateway/main.go:125`, `:142`).
- **The guest page is a working spike on loopback.** `/port` (`gateway/main.go:53`) takes a full
  client token in the query string (`guestpage.go:50`), renders the port's source in a sandboxed
  iframe and forwards the page's bridge calls to `/call`. The guest therefore holds the port's code;
  rendering without it is viable only for static markup (`research/rpc-rendered-ports.md`).
- **Events leave the process with tokens.** `port.subscribe` over `/ws` delivers `stream` frames
  carrying the port's token (slice-02 §10c, §10d), and a write that replaces state publishes `state`
  (`BridgeDispatcher.swift:65`, `:91`). The OUTPUT seam the master plan wanted before the remote pipe
  is built.
- **go-libp2p in the signed bundle, spike F (2026-07-30, v0.49.0):** +22.2 MB gateway (2.5x), host
  start 4 to 5 ms, idle CPU about 0.2%, mDNS discovery 4.0 s from a cold start, connect 34 to 39 ms,
  stream round trip 291 to 466 µs, hardened runtime no obstacle. **Not measured:** the macOS local
  network prompt when Port42's own app spawns the gateway; `Info.plist` has neither
  `NSLocalNetworkUsageDescription` nor `NSBonjourServices`.
- **Hole-punch rates are reported, not measured here.** About 70% for libp2p and 90% for Iroh are the
  projects' own figures. The master plan's viability line is about 80% direct.

## Steps

Each step is its own commit: merged from `nautilus` first, suite and Go suites green, harness five
of five on Dev2, this plan and `plan-shell-only.md` updated. Every gate is calibrated by breaking the
code it guards on the side that enforces it, and watching it fail. 4.1 comes before any wire, so a
remote principal is scoped before one can arrive.

### 4.0 Measure before building

No product code. Each item states what would change the plan.

- **The browser lane.** A static page with js-libp2p dials a go-libp2p host behind a home NAT through
  a relay on a public host. Measured: which of secure WebSocket through the relay, WebRTC to the
  host, and WebTransport connect, in Chrome and in Safari; round trip and throughput on each. **If a
  NATed host is reachable from a browser only through the relay**, every browser byte crosses the
  relay and decision 3 is costed on that.
- **Relay limits.** A session through a public relay and through a relay with Port42's intended
  settings: when does the public one cut it, and what does it say.
- **The local network prompt.** A Dev2 bundle with the two `Info.plist` keys, its gateway advertising
  over mDNS: does macOS prompt, whom does it name, and does discovery work after allowing.

*Gates:* the figures, recorded here. No code gate; this step changes the plan, not the tree.

### 4.1 Remote callers see only what they were granted

Local, no wire. A remote principal can be built in a test without one.

- **Every method declares its object.** A new required field on `BridgeMethod` and
  `BridgeStreamMethod`: `.port(param)`, `.listing`, `.machine` or `.none`, beside `writesTarget`.
  The compiler forces the declaration, and a gate checks it agrees with `writesTarget` and
  `permission` (a method with a permission is `.machine`).
- **A remote principal.** `Principal.remote(peer:actor:displayName:)`: the grantee is the peer; the
  actor it reports (for example `<peer>/claude`) is display only, since this host cannot verify it.
- **Port grants.** The object slot gets its first non-zero use: `grants(grantee, .port(key), rights)`
  with rights `view` or `drive`. `view` covers `getHtml`, `history`, `getDom`, `info`, `console`,
  `subscribe` and `chat.read`; `drive` adds `push`, `patch`, `update`, `restore`, `rename`,
  `setTitle` and `chat.post`. Nothing else is grantable to a remote caller in this phase.
- **The gate, in the dispatcher**, before the permission gate: a remote principal calling a method
  that is not `.port`, or naming a port it holds no grant for, or needing a right it lacks, is
  refused with `not_granted`. `.listing` methods filter their result. `port.exec` is refused.
- **Per-caller secret grants.** A secret is usable only with a grant for the caller's grantee. The
  companion card's ticks write them (through `companion(actingAs:)`, so a terminal companion is
  covered as it is today). A local caller without one is asked by a card that names the secret.
- **Stale comments fixed** on `Principal.peer` and `local-http`.

*Gates:* every registry method declares an object (source scan; calibrated by deleting one
declaration). A remote principal holding `view` on P reads P, subscribes to P, is refused writes to
P, is refused P's `exec`, is refused Q, and sees only P in `ports.list`. With `drive` it writes P with
CAS as a local caller does. It is refused every `.machine` and `.none` method, `rest.call` with or
without a secret, and `port.create`. A plain terminal and a port are refused a secret they hold no
grant for and served one they do. Local callers pass the existing suite unchanged. Each calibrated by
removing the check it pins.

### 4.2 The instance has a peer id, and the address names it

- The Ed25519 key (decision 8), generated at first need and handed to the gateway on stdin with the
  host credential and the new attestation key (decision 9).
- **The gateway computes the peer id** and tells the app on the host connection, so the id has one
  implementation (the cross-language drift rule in `credentials.go`). The app fills `localPeerID`.
- `PortAddress` takes the remote form of decision 1 and drops the one it replaces.
- `clients.kind` gains `peer`, with a `peer_id` column (new migration).

*Gates:* round trip of the remote form with a foreign peer id kept distinct from ours in both
directions (a slot with one value is indistinguishable from a rename, slice-02 §10b); our own peer id
resolves locally; the local form unchanged; the key never reaches the gateway other than on stdin
(tree scan, calibrated by writing it to the environment); the peer id is unchanged across a restart
of Dev2.

### 4.3 The door over a seam, proven with a fake transport

Go. No libp2p yet.

- `transport.go`: an interface of the four verbs, and an in-memory implementation for tests.
- An inbound stream carries call envelopes in the door's existing framing. The gateway sets
  `remote_peer` (the authenticated id) and `remote_attest` (the MAC, decision 9) and forwards to the
  host. A frame arriving on `/ws` or `/call` has both fields stripped, so a local caller cannot claim
  to be remote.
- The app verifies the attestation, finds the `peer` client row, and forms `Principal.remote`.
  Responses and `stream` frames return down the same stream.

*Gates:* the door works over the fake transport, which is the test that the seam is pluggable; spike
E's nine cases as a Go and Swift test pair (no attestation, a key this app never issued, an
attestation replayed onto another peer, a revoked peer, a local caller claiming a peer). Calibrated
on both sides: removing the verifier lets the unattested case through, and removing the strip lets a
`/ws` caller claim a peer.

### 4.4 libp2p behind the seam, on one LAN (milestone B)

- A go-libp2p host (QUIC and TCP, Noise), mDNS, a `/port42/door/1` protocol, implementing the seam.
- `Info.plist` gains the two local network keys (named by 4.0).
- The Go test peer (decision 10) in `gateway/cmd/`, dialing by address.

*Gates:* two in-process libp2p hosts round-trip a call and a subscription, and the door sees the
authenticated peer id; an unenrolled peer is refused with a code that names the invite. *Live, this
Mac:* the test peer against Dev2 reads a granted port, is refused an ungranted one, keeps a
subscription through a host write, and is refused on its next call after revoke with no restart.
*Live, second Mac on the LAN:* the same, found by mDNS.

### 4.5 The per-port invite

- `invite.create {port, rights, expires}` returns the link; `invite.list` and `invite.revoke`. Refused
  for port 0 and for a space.
- Redemption is a protocol on the door, before any call: nonce in, grant out (decision 4).
- Settings → Access shows peers with their ports and the invites outstanding, each revocable.
- The deep link accepts `port42://invite#…`; the gateway's `/invite` channel page and its template
  are deleted.

*Gates:* a link redeems once and the second redemption is refused with a reason; an expired link is
refused; port 0 and a space cannot be invited; revoking one grant leaves the peer's other grants;
revoking the peer removes all. Calibrated by removing the burn.

### 4.6 The Port42 lane: a shared port on the other desktop

- **Outbound calls.** The app asks its own gateway to dial a peer and forward a call; responses and
  stream frames come back on the host connection. The resolver forwards any address naming another
  peer, so `window.port42`, the `port42` CLI and companions on the second machine reach a remote port
  with the same verbs.
- **The remote tile.** A web port whose HTML comes from the host and whose bridge calls go to the
  host, subscribing for `state` and pushes. It is listed as remote, cannot be forked or edited
  locally, and shows the host as offline rather than broken when the stream drops (`host_offline`).
- **Driver chips.** The host's chip names `<peer>/<actor>`; the guest's names the host's actor.

*Gates:* the outbound path over the fake transport; the resolver forwards a foreign address and
never falls through to a local port with the same id. *Live, two Macs:* scenario 4 in Port42, on a
chart and on a chat port.

### 4.7 The browser lane

- The guest page moves to the origin of decision 6 and becomes js-libp2p: make or load the key
  (decision 4 (i)), redeem, `getHtml`, subscribe, render in the sandboxed iframe with the shim.
- The gateway's `/port` route and its query-string token are deleted.

*Gates:* the shim forwards only the page's own calls and the iframe never sees the key; a second
tab of the same browser is the same guest or a new one, as decided. *Live:* scenario 4 from a
browser on the second Mac and from a phone browser.

### 4.8 Across networks (milestone C), measured

- Relay (decision 3), AutoNAT and DCUtR switched on.
- **`net.peers`**, a read method for the local user: each connection's path (direct or relayed),
  transport, time to direct, and round trip. Hole-punch attempts and outcomes are logged by the
  gateway.
- **The measurement.** The harness dials from the second Mac on at least four networks (home, café,
  office, tethered phone), both directions, several attempts each, and writes one row per attempt.
  The rate recorded here is direct connections over attempts. The same pairs are run with an Iroh
  sidecar speaking the seam, as a spike, so the comparison is ours and not the projects' figures.
  Below about 80% direct for libp2p with Iroh above it, the swap goes to Gordon.

*Gates:* `net.peers` reports relayed then direct across a punch in the in-process test. The rates
are measured, not gated.

### 4.9 Scenario 4 in the harness

The harness's scenario 4 becomes the master plan's test: a browser on another machine renders the
port with no install, a click there appears here, the stale write of two is refused with `current`,
one retry lands, both chips agree. Once in the Port42 lane and once in the browser lane, on a chart
and a chat port, and a guest asking beyond its grant is refused.

## Test plan

Three layers, as in every phase. Every automated gate is calibrated by breaking the code it guards.

| Step | Automated (Swift and Go, every build) | Harness (live, Dev2) | Gordon by hand |
|---|---|---|---|
| 4.0 | none; it is a measurement | the browser, relay and prompt figures | nothing |
| 4.1 | every method declares an object (scan); a remote principal's reads, writes, listings and refusals per right; `exec`, machine methods and secrets refused; secret grants for ports and plain terminals; local suite unchanged | none (no wire yet) | nothing |
| 4.2 | remote address round trip with a foreign peer; own peer resolves locally; key only on stdin (scan) | peer id stable across a Dev2 restart | nothing |
| 4.3 | door over the fake transport; spike E's cases, both sides; `/ws` cannot claim a peer | none | nothing |
| 4.4 | two in-process libp2p hosts, call and subscription, peer id at the door | test peer against Dev2: read, refuse, subscribe, revoke | allows the local network prompt; second Mac on the LAN |
| 4.5 | burn on use, expiry, no port 0 or space, revoke one of several | invite created and redeemed by the test peer | reads Access with a peer and its ports |
| 4.6 | outbound over the fake transport; a foreign address never resolves locally | none (needs two instances) | scenario 4 in Port42 across two Macs |
| 4.7 | the iframe never holds the key; guest persistence as decided | none | scenario 4 from a browser and a phone |
| 4.8 | `net.peers` relayed to direct in process | none | the network matrix, both transports |
| all | suite and Go suites green | five of five, scenario 4 extended | the verify below |

## Verify, live

Scenario 4 from a second Mac in both lanes, on a chart and on a chat port: rendered there with no
install in the browser lane, a click there appears here, a stale write refused with `current` and one
retry landing, both driver chips agreeing, and the guest refused when it asks for another port, a
listing of spaces, or the clipboard. The direct-connection rate recorded for four networks.

## Not in this phase

- **Local object scoping** (decision 5): `port.exec` running as the target port, a port inheriting
  its creator's machine grants, the ungated port verbs for local callers, and a revoked `child`
  client restored at launch (`research/security-bridge-authorization.md`). Real defects, local
  exposure only, and a re-consent to fix.
- **Sharing a space**, and whether a grant on a container cascades to its contents.
- **The mesh of one's own hosts** (`research-host-mesh.md`): membership rather than per-port grants.
- **Store and forward, and offline hosts** (O-2), with the Signal or MLS evaluation (decision 7).
- **Asynchronous permission** (D-d): no remote caller can raise a card in this phase.
- **Gossipsub, N-peer fan-out and per-element co-editing.**
- **Rendering without shipping source** (`research/rpc-rendered-ports.md`), and forking.
- **Moving the local door to a unix socket** (`research/program-as-credential.md`).
