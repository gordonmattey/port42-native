# Nautilus Phase 4: the remote pipe

Detailed plan for Phase 4 of `plan-shell-only.md`. Scenario served: 4. Written 2026-09-26 against
`nautilus` at `638e1c2` on branch `nautilus-phase4`, and reviewed with Gordon the same day. Nothing
is built. Sources: `membrane/slice-02-cross-instance.md` (milestones B and C, spike E),
`browser-guest.md`, `plan-web-port-sharing.md`, `slice02-risks-and-decisions.md`,
`invite-taxonomy.md`, and three notes on the `research` branch (`design-invite-over-libp2p.md`,
`research-host-mesh.md`, `research/security-bridge-authorization.md`).

Testing is on Dev2 (`./build.sh --dev2`, gateway 4244) and on further instances Gordon allowed for
this phase (Dev6, Dev7 and on). Dev3, Dev4 and prod are never built, launched or called.

## Goal

Someone on another machine sees and drives one of my ports, from Port42 or from a plain browser, and
reaches nothing else. No token crosses the internet, no Mac is given a public address, no server
holds a port's state, and a guest that asks for anything beyond its grant is refused.

## What changes, for a person and for an agent

- **Share a port with a link.** One link per port, on `port42.ai/invite.html`. Opened where Port42 is
  installed, the port appears as a tile on the other person's desktop. Opened anywhere else, it runs
  in the browser tab. Both people drive it, both driver chips agree, and a stale write is refused
  with `current`.
- **The link works once.** A forwarded link after it was opened enrols nobody. Revoking one share
  leaves the others.
- **Access lists who has what.** Each person or browser you shared with appears in Settings → Access
  with the ports they hold and the rights on each, and revoking takes effect on their next call.
- **Agents on both machines can work together.** A companion on the other machine drives the shared
  port with the same verbs it uses locally (`port42 port.push id=port42://<peer>/<port>`), and, if the
  invite allows it, messages your companions in that port's chat.
- **A guest reaches one port.** It cannot list your spaces, read another port, or use your clipboard,
  secrets, terminal or network.

## Decisions

All decided with Gordon on 2026-09-26 except where marked open. **The one blocker is where the relay
service is hosted** (decision 3).

1. **Address: `port42://<peer>/<portId>`.** The peer is the lowercase base32 of the instance's
   Ed25519 public key (decision 8), so the address names an instance, not a transport. There is no
   space segment. A port id is a UUID, unique on its machine and in practice everywhere, and the
   resolver already finds a port by id alone (a nil space means any, `PortResolution.swift`). A space
   is where a port sits, which can change, and naming it would hand a guest the id of a space it was
   not given. Lowercase because many URL parsers and linkifiers lowercase a host. The local form
   `port42://space/<s>/<p>` keeps parsing unchanged; the unused remote form
   `port42://<peer>/space/<s>/<p>` in `PortAddress.swift` is replaced. An invite is not an address (4).
2. **Transport: WebRTC, with pion in the Go gateway, behind a seam.** It is what browsers speak
   natively, so the browser lane needs no networking library in the page and the Port42 lane is the
   same protocol. ICE finds a direct path (on a LAN, or through two routers by hole punching) and
   falls back to a TURN relay. Data channels carry the door's existing frames: one reliable, ordered
   channel per call or subscription, so a subscription needs no gap detection and a dropped channel
   is answered by resubscribing and one `getHtml`. The seam is the four verbs `plan-shell-only.md`
   names (listen, dial, peer id, open a stream), and step 4.3 proves it with a fake transport.
   Considered and not chosen: **libp2p** (large and general for the small part used here, weaker
   reported hole punching, and a browser needs js-libp2p to reach it); **Iroh** (strong reported
   traversal, but Rust beside a Go gateway, and a browser reaches it only through a relay);
   **Tailscale** (both ends must install it and join one tailnet, which fits one person's machines,
   not an invite). No gossipsub or other fan-out mesh: the host is the one source of truth.
3. **Port42 runs a relay service (decided); where it is hosted is open, and is the blocker.** Two
   jobs, on one small server that holds no port state:
   - **Signaling.** Two machines behind routers cannot find each other unaided. Each host keeps one
     outbound WebSocket to the service, registered under its peer id by signing a challenge. A caller
     asks for a peer, and the two exchange connection offers and address candidates through it. The
     service learns who connects to whom, and their addresses. It never sees content.
   - **TURN.** When no direct path forms (both routers strict), traffic flows through the relay. It
     carries encrypted bytes it cannot read. TURN over UDP, and over TLS on port 443 for networks
     that block everything else. Credentials are short-lived and issued by the signaling service only
     to a registered host or a caller holding a live invite or grant, so it is not an open relay.
   No Mac is ever given a public address; every connection starts outward. Hosting needs UDP and a
   public IP, which rules out a platform that forwards only HTTP. Options: Fly.io, or a small VPS.
   **Open: which, and under which account.**
4. **The per-port invite, both lanes.** An invite names one port and grants that port only (D10).
   Port 0 and spaces are never invitable; a second port is a second invite.
   - **One link, on the page that exists:** `https://port42.ai/invite.html#<coupon>`. The coupon is in
     the fragment, which a browser never sends to a server, so it reaches neither Netlify nor PostHog
     (today's page takes its key and token in the query string). The page offers "Open in Port42"
     (`port42://invite#<coupon>`) and "Open here", since a page cannot tell whether the app is
     installed.
   - **The coupon:** host peer id, port id, rights (5), a one-time 128-bit nonce, an expiry, display
     names (host, port title), and the signaling address. No standing access.
   - **Redeeming is enrolment.** The redeemer connects (its key authenticated, decision 9) and
     presents the nonce once. The host burns it, creates a `peer` client row for that key if there is
     none, and records one grant: that peer, that port, those rights. The Port42 lane redeems as the
     second instance's key; the browser lane as a key made in the page.
   - **Until redeemed, the coupon is a bearer secret**: whoever opens it first gets the grant, and
     the host sees who did in Access and can revoke. That is what lets a link work with the host away.
   - **A browser guest keeps its key** in that browser (a non-extractable WebCrypto key in
     IndexedDB), so a refresh is the same guest with the same grant. It is listed in Access as a
     browser guest and reaped after a period unused; the period is Gordon's to set.
   - **Default rights: view and drive**, which are `see` and `use` below.
   - **Coordination outside this repo.** The page's source is not in this repository and is to be
     found. The app recognizes a pasted `https://port42.ai/invite.html#…` link again (the old
     recognition went with `fbee08d`).
5. **Remote callers are locked down; local callers are unchanged in this phase.** A remote caller is
   denied by default. Every registry method declares what it acts on: a port argument, a listing,
   the machine (port 0), or nothing. A remote principal may call only port methods, only on ports it
   holds a grant for, within the grant's rights; a listing returns only its granted ports. Machine
   capabilities, spaces, companions, `port.create`, `port.exec`, `terminal.exec`, `rest.call`,
   `fs.*` and secrets are refused with a new code, `not_granted`. `port.exec` is refused even on the
   granted port, because it runs inside the host's page as that port's own principal. Nothing a
   remote caller does raises a permission card, so nothing waits on a person who is not there.
   Remote access grows into its own permission system, a port being something like a VM (Gordon).
   **Its first rights, open for Gordon to confirm:**
   - **`see`**: the port's source and rendered page (`getHtml`, `history`, `getDom`, `info`), its
     console, and its live events (`subscribe`). The browser lane ships the source, so `see` cannot
     prevent a copy.
   - **`use`**: input and chat (`push`, `publish`, `chat.read`, `chat.post`). Every write carries CAS,
     so scenario 4's stale-write refusal needs only this.
   - **`edit`**: change the port itself (`update`, `patch`, `restore`, `rename`, `setTitle`). Off by
     default: using an app and changing it are different rights.
   - **`wake agents`**: whether the guest's chat posts and events wake the host's companions
     (@mentions, Phase 3 watches). Gordon wants remote agents at least to message the host's agents,
     so it is grantable, off by default, and a woken companion is told the message came from a remote
     peer. A companion runs with the host's terminal, so granting it lets a remote party put text in
     front of an agent that has a shell, and each wake spends the host's model tokens.
   - **Limits**: per-peer rate and message size at the gateway, expiry and revoke on every grant.
   **Also open: what the port can do on the host when a guest drives it.** A guest's own calls get
   nothing of the machine, but the host's copy of the port keeps its own grants (clipboard, REST),
   and the guest's input can make it use them; the host cannot tell which input caused which call.
   Recommended: the invite dialog lists what the port can do on this machine and says the guest can
   trigger it. Alternative: the port's machine grants are suspended while it is shared.
   **Named secrets get a per-caller grant.** Using one needs a grant for the caller's own grantee: a
   companion's ticked secrets write those grants; any other local caller (a port, a plain terminal, a
   manual client) is asked by a card naming the secret; a remote caller never.
6. **The guest page is `port42.ai/invite.html`.** A static page on Netlify, as today. It opens a
   WebRTC connection to the host through the signaling service, renders the port's source in a
   sandboxed iframe, and forwards the page's bridge calls over the data channel through the shim, as
   today's spike does. The gateway's `/port` route stays for loopback testing until step 4.7.
7. **The Signal Protocol is not in this phase.** WebRTC encrypts end to end with DTLS, including
   through TURN, which forwards ciphertext. Nothing is stored and forwarded: a port whose host is
   offline is unavailable (slice-02 O-2). Signal's contribution, forward secrecy for a message held
   for an offline recipient, has nothing to protect until something is held. When a chat port is
   mirrored to offline peers, MLS (RFC 9420) is evaluated beside Signal, since a chat port has many
   subscribers and Signal's Double Ratchet is pairwise.
8. **Each instance has its own Ed25519 key.** Generated at first need, kept in the Keychain under the
   instance name beside the gateway root secret (`Port42AuthStore`), handed to the gateway on stdin
   at spawn. Per instance, never per person, so two Macs of one person are two peers. Rotating it
   orphans every grant keyed on it, so nothing rotates it in this phase. (The P-256 key slice-02
   planned to derive from was removed in Phase 1, v48.)
9. **A peer is authenticated by its key, and the app never trusts an unverified peer field.** WebRTC's
   DTLS certificate is not an identity by itself. During signaling each side signs both certificate
   fingerprints and a nonce with its key; once DTLS completes, each checks that the certificate it
   actually met is the one signed. The signaling service can therefore relay offers but cannot stand
   in for either side. The gateway then forwards each call with the verified peer id and a MAC over
   it, and the app checks the MAC before it forms a principal in `resolveGatewayCaller`. **The MAC
   key is a second per-spawn secret that only travels on stdin**: the host credential cannot serve,
   because the app sends it over the socket in `identify` (`GatewayDoor.swift:154`), where a process
   squatting the gateway's port would learn it.
10. **Instances and machines.** Dev2 plus Dev6, Dev7 and on, on this Mac, cover the Port42 lane and a
    LAN path between processes; `build.sh` gains the flags. A second Mac on a different network is
    what proves traversal (4.0, 4.8). **Open: which Mac.**

Stated limit: every connection is introduced by the signaling service, so two Macs on one LAN with
no internet cannot connect in this phase. Local introduction (Bonjour) is the way to add it later.

## What is measured

Against `638e1c2` unless a date says otherwise.

- **Nothing is reachable from off this machine.** The gateway listens on `127.0.0.1`
  (`GatewayProcess.swift:95`) and its only dependency is a WebSocket library (`gateway/go.mod`).
  ngrok was deleted in Phase 1.
- **The address can name another instance and resolves none.** `PortAddress` parses
  `port42://<peer>/space/<s>/<p>`, and the resolver refuses any peer that is not this one
  (`PortResolution.swift:130`), where this one is always nil because no instance has a key.
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
  `permission: nil` and 28 name one. The grant object is hardcoded to port 0 wherever a grant is read
  or written (`BridgeDispatcher.swift:45`, `:112`, `:117`, `:524`; `PortBridge.swift:76`).
  `ports.list` lists every space's ports (`BridgeMethods.swift:1346`). Any enrolled client can read,
  write, execute JS in and subscribe to any port. Locally that needs a process already on the
  machine; remotely it would be the whole desktop.
- **Secrets are scoped for companions only.** The `rest.call` check applies when the caller is, or
  acts as, a companion (`BridgeMethods.swift:853`). A port, a plain terminal or a manual client with
  the REST grant can use any named secret.
- **The invite's door survived and its payload did not.** The `port42://` handler is installed
  (`Port42App.swift:22`) and reaches `TransitionRoot.handleDeepLink` (`TransitionRoot.swift:283`),
  which accepts nothing. The gateway's `/invite` still builds `port42://channel?…` for the deleted
  hub (`gateway/main.go:125`, `:142`). The live `port42.ai/invite.html` reads `gateway`, `id`,
  `name`, `key` and `token` from its query string and offers `port42://channel?…`.
- **The guest page is a working spike on loopback.** `/port` (`gateway/main.go:53`) takes a full
  client token in the query string (`guestpage.go:50`), renders the port's source in a sandboxed
  iframe and forwards the page's bridge calls to `/call`. A guest therefore holds the port's code;
  rendering without it is viable only for static markup (`research/rpc-rendered-ports.md`).
- **Events leave the process with tokens.** `port.subscribe` over `/ws` delivers `stream` frames
  carrying the port's token (slice-02 §10c, §10d), and a write that replaces state publishes `state`
  (`BridgeDispatcher.swift:65`, `:91`).
- **Nothing about WebRTC is measured here yet**: pion's cost in the signed gateway, the direct-path
  rate on real networks, data-channel message limits between pion and each browser, WebCrypto
  Ed25519 in Safari, and whether the macOS local network prompt fires when the gateway gathers LAN
  candidates. Figures commonly quoted for how often WebRTC connects without TURN are reports, not
  ours.

## Steps

Each step is its own commit: merged from `nautilus` first, suite and Go suites green, harness five
of five on Dev2, this plan and `plan-shell-only.md` updated. Every gate is calibrated by breaking the
code it guards, on the side that enforces it, and watching it fail. 4.1 comes before any wire, so a
remote principal is scoped before one can arrive. 4.1 to 4.3 do not depend on 4.0's figures.

### 4.0 Measure WebRTC before building on it

Spike code in a scratch directory, not the product tree. Each item says what would change the plan.

- **The direct-path rate.** pion on this Mac and pion on a second Mac on another network, neither
  with a public address, through a throwaway signaling and TURN server. Per attempt: whether a
  direct path forms, time to connect, round trip, and throughput direct and through TURN. At least
  four networks (home, café, office, phone hotspot), both directions. **If most attempts need
  TURN**, the relay carries most traffic and its hosting is costed on that.
- **The browser.** Chrome and Safari to pion, including a phone: connect, round trip, the largest
  data-channel message each accepts (port HTML can be large, so the framing is sized from this),
  and whether WebCrypto Ed25519 works or the guest key falls back to P-256.
- **The gateway's cost.** Binary size, launch time and idle CPU with pion linked, signed with the
  hardened runtime.
- **The local network prompt.** A Dev2 bundle whose gateway gathers LAN candidates: does macOS
  prompt, whom does it name, and does a LAN path form after allowing. Needs Gordon at the machine.

*Gates:* the figures, recorded here. No code gate.

### 4.1 Remote callers see only what they were granted

Local, no wire. A remote principal can be built in a test without one.

- **Every method declares its object**, a new required field on `BridgeMethod` and
  `BridgeStreamMethod`: `.port(param)`, `.listing`, `.machine` or `.none`, beside `writesTarget`. A
  gate checks it agrees with `writesTarget` and `permission` (a method with a permission is
  `.machine`).
- **A remote principal**, `Principal.remote(peer:actor:displayName:)`. The grantee is the peer; the
  actor it reports (for example `<peer>/claude`) is display only, since this host cannot verify it.
- **Port grants.** The grant object gets its first non-zero use: `grants(grantee, .port(key), rights)`
  with the rights of decision 5. Nothing else is grantable to a remote caller in this phase.
- **The gate**, in the dispatcher before the permission gate: a remote principal calling a method
  that is not `.port`, or naming a port it holds no grant for, or needing a right it lacks, is
  refused with `not_granted`. `.listing` methods filter their result. `port.exec` is refused. A
  remote caller's post or event wakes a companion only with `wake agents`.
- **Per-caller secret grants** (decision 5).
- **Stale comments fixed** on `Principal.peer` and `local-http`.

*Gates:* every registry method declares an object (source scan; calibrated by deleting one). A remote
principal with `see` on P reads and subscribes to P, is refused writes to P and P's `exec`, is refused
Q, and sees only P in `ports.list`. With `use` it pushes to P with CAS as a local caller does; without
`edit` it cannot update P. It is refused every `.machine` and `.none` method, `rest.call` with or
without a secret, and `port.create`. Its @mention wakes nobody without `wake agents` and wakes the
named companion with it. A plain terminal and a port are refused a secret they hold no grant for and
served one they do. Local callers pass the existing suite unchanged. Each calibrated by removing the
check it pins.

### 4.2 The instance key, and the address that names it

- The Ed25519 key (decision 8), handed to the gateway on stdin with the host credential and the MAC
  key (decision 9).
- The peer id is derived in one place, the gateway, and told to the app on the host connection, so
  the encoding has one implementation (the cross-language drift rule in `credentials.go`). The app
  fills `localPeerID`.
- `PortAddress` takes the form of decision 1.
- `clients.kind` gains `peer`, with a `peer_key` column (new migration).

*Gates:* round trip of the remote form with a foreign peer kept distinct from ours in both directions
(a slot with one value is indistinguishable from a rename, slice-02 §10b); our own peer resolves
locally; the local form unchanged; the key reaches the gateway only on stdin (tree scan, calibrated by
passing it in the environment); the peer id is unchanged across a restart of Dev2.

### 4.3 The door over a seam, proven with a fake transport

Go. No WebRTC yet.

- `transport.go`: the four verbs as an interface, and an in-memory implementation for tests.
- An inbound stream carries the door's existing call framing, chunked for the message limit 4.0
  measures. The gateway sets `remote_peer` (the verified key) and `remote_attest` (the MAC) and
  forwards to the host. A frame arriving on `/ws` or `/call` has both fields stripped, so a local
  caller cannot claim to be remote.
- The app verifies the MAC, finds the `peer` client row, and forms `Principal.remote`. Responses and
  `stream` frames return down the same stream.

*Gates:* the door works over the fake transport, which is the test that the seam is pluggable; spike
E's refusals as a Go and Swift test pair (no MAC, a key this app never issued, a MAC replayed onto
another peer, a revoked peer, a local caller claiming a peer). Calibrated on both sides: removing the
verifier lets the unattested case through; removing the strip lets a `/ws` caller claim a peer.

### 4.4 WebRTC behind the seam, and the relay service

- pion in the gateway implementing the seam: data channels per stream, the fingerprint binding of
  decision 9, ICE with STUN and TURN.
- The relay service, in `relay/` in this repo: signaling over WebSocket (register by signed
  challenge, introduce, pass offers and candidates, report a host offline) and TURN (pion/turn),
  issuing short-lived TURN credentials. Deployed where decision 3 lands.
- A Go test peer in `gateway/cmd/`, with its own key, that dials an address. A harness tool, not a
  product.

*Gates:* two in-process pion peers through an in-process signaling service round-trip a call and a
subscription, and the door sees the verified key; a signaling service that swaps one side's offer is
refused by the fingerprint check (calibrated by removing the check); an unenrolled peer is refused
with a code that names the invite; TURN refuses a caller with no credential. *Live, this Mac:* the test
peer against Dev2 reads a granted port, is refused an ungranted one, keeps a subscription through a
host write, and is refused on its next call after revoke with no restart.

### 4.5 The per-port invite

- `invite.create {port, rights, expires}` returns the link; `invite.list` and `invite.revoke`. Refused
  for port 0 and for a space.
- Redemption is a protocol on the door, before any call: nonce in, grant out (decision 4).
- Settings → Access shows peers with their ports and rights, and the invites outstanding, each
  revocable. The invite dialog discloses what the port can do on this machine (decision 5).
- The deep link accepts `port42://invite#…`, and ⌘K accepts a pasted invite link. The gateway's
  `/invite` channel page and its template are deleted.

*Gates:* a link redeems once and the second redemption is refused with a reason; an expired link is
refused; port 0 and a space cannot be invited; revoking one grant leaves the peer's others; revoking
the peer removes all. Calibrated by removing the burn.

### 4.6 The Port42 lane: a shared port on the other desktop

- **Outbound calls.** The app asks its own gateway to dial a peer and forward a call; responses and
  stream frames return on the host connection. The resolver forwards any address naming another
  peer, so `window.port42`, the `port42` CLI and companions on the second machine reach a remote port
  with the same verbs.
- **The remote tile.** A web port whose HTML comes from the host and whose bridge calls go to the
  host, subscribing for `state` and pushes. It is marked remote, is not edited locally without
  `edit`, and shows the host as offline rather than broken when the channel drops (`host_offline`).
- **Driver chips.** The host's chip names `<peer>/<actor>`; the guest's names the host's actor.

*Gates:* the outbound path over the fake transport; a foreign address is forwarded and never falls
through to a local port with the same id. *Live:* Dev2 and Dev6 on this Mac, then two Macs: scenario
4 in Port42 on a chart and on a chat port, and a companion on each side messaging the other through
the port's chat with `wake agents` granted.

### 4.7 The browser lane

- `port42.ai/invite.html` gains the coupon, "Open here" and the guest runtime: load or make the key,
  connect through signaling, redeem, `getHtml`, subscribe, render in the sandboxed iframe with the
  shim. No networking library; the browser's own `RTCPeerConnection`.
- The gateway's `/port` route and its query-string token are deleted.

*Gates:* the shim forwards only the page's own calls and the iframe never holds the key; a refresh
is the same guest. *Live:* scenario 4 from a browser on the second Mac and from a phone.

### 4.8 Across networks, measured

- **`net.peers`**, a read method for the local user: each connection's path (direct on the LAN,
  direct through the routers, or through TURN), time to connect and round trip.
- **The measurement.** 4.0's matrix rerun on the product: the second Mac on at least four networks,
  both directions, one row per attempt, plus the browser. The rate recorded here is direct
  connections over attempts; about 80% direct is the master plan's viability line.

*Gates:* `net.peers` reports the path of an in-process connection correctly for direct and relayed.
The rates are measured, not gated.

### 4.9 Scenario 4 in the harness

The harness's scenario 4 becomes the master plan's test: a browser on another machine renders the
port with no install, a click there appears here, the stale write of two is refused with `current`,
one retry lands, both chips agree. Once in each lane, on a chart and a chat port, and a guest asking
beyond its grant is refused.

## Test plan

Three layers, as in every phase. Every automated gate is calibrated by breaking the code it guards.

| Step | Automated (Swift and Go, every build) | Harness (live, Dev2 and Dev6+) | Gordon by hand |
|---|---|---|---|
| 4.0 | none; it is a measurement | the WebRTC figures | the local network prompt; the second Mac on four networks |
| 4.1 | every method declares an object (scan); a remote principal's reads, writes, listings and refusals per right; `exec`, machine methods and secrets refused; `wake agents` both ways; secret grants for ports and plain terminals; local suite unchanged | none (no wire yet) | nothing |
| 4.2 | remote address round trip with a foreign peer; own peer resolves locally; key only on stdin (scan) | peer id stable across a Dev2 restart | nothing |
| 4.3 | door over the fake transport; spike E's refusals, both sides; `/ws` cannot claim a peer | none | nothing |
| 4.4 | two in-process pion peers, call and subscription, verified key at the door; swapped offer refused; TURN refuses without credential | test peer against Dev2: read, refuse, subscribe, revoke | nothing |
| 4.5 | burn on use, expiry, no port 0 or space, revoke one of several | invite created and redeemed by the test peer | reads Access with a peer, its ports and rights |
| 4.6 | outbound over the fake transport; a foreign address never resolves locally | Dev2 to Dev6: scenario 4 in Port42; companions messaging across | scenario 4 in Port42 across two Macs |
| 4.7 | the iframe never holds the key; a refresh is the same guest | none | scenario 4 from a browser and a phone |
| 4.8 | `net.peers` path reporting in process | none | the network matrix |
| all | suite and Go suites green | five of five, scenario 4 extended | the verify below |

## Verify, live

Scenario 4 from a second Mac in both lanes, on a chart and on a chat port: rendered there with no
install in the browser lane, a click there appears here, a stale write refused with `current` and one
retry landing, both driver chips agreeing, companions on the two machines exchanging messages in the
port's chat, and the guest refused when it asks for another port, a listing of spaces, or the
clipboard. The direct-connection rate recorded for four networks.

## Not in this phase

- **Local object scoping**: `port.exec` running as the target port, a port inheriting its creator's
  machine grants, the ungated port verbs for local callers, and a revoked `child` client restored at
  launch (`research/security-bridge-authorization.md`). Real defects, local exposure only, and a
  re-consent to fix.
- **Sharing a space**, and whether a grant on a container cascades to its contents.
- **The mesh of one's own hosts** (`research-host-mesh.md`): membership rather than per-port grants.
- **Connecting on a LAN with no internet** (local introduction over Bonjour).
- **Store and forward, and offline hosts** (O-2), with the Signal or MLS evaluation (decision 7).
- **Asynchronous permission** (D-d): no remote caller can raise a card in this phase.
- **Fan-out to many peers and per-element co-editing.**
- **Media over WebRTC** (the roadmap's live media plane), which this transport makes the natural next
  step.
- **Rendering without shipping source** (`research/rpc-rendered-ports.md`), and forking.
- **Moving the local door to a unix socket** (`research/program-as-credential.md`).
