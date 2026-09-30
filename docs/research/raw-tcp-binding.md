# Research spike: a raw TCP binding for the Port42 protocol

**Ticket** #219. **Base** main at 5fa5d58. **Branch** spike/raw-tcp-binding. **Date** 2026-09-30.
Measurements come from `gateway/spikes/rawtcp/`, which runs the gateway's own Noise code
(`relay.Initiate`, `relay.Respond`) over three framings. Claims about the tree carry a file and symbol.
Claims about the draft cite `port42-rfc-v1.txt` (draft-mattey-port42-protocol-00) by section. Claims
about the port registry come from the IANA CSV fetched on 2026-09-30, and about BOLT 8 from
`lightning/bolts` `08-transport.md` fetched the same day.

## Question

Today machine to machine traffic is Noise IK inside a WebSocket, over TLS on 443, through a relay. Can
Noise frames also run over a plain TCP stream, as an optional second binding, and what does that change?
Six sub-questions.

1. Framing and handshake on a byte stream.
2. How it plugs into the transport seam (`gateway/transport/`).
3. What it saves in latency and overhead.
4. How the relay serves both bindings.
5. What it means for the protocol draft.
6. What it does for the case for a registered port (42424), with
   Lightning's BOLT 8 on 9735 as the precedent.

The answer settles it when it gives a wire format, a list of the code and draft sections that change,
measured savings against the WebSocket binding, and the costs the binding brings.

## Decision needed

**Options**

| | Option | What it gives | What it costs |
|---|---|---|---|
| A | WebSocket only (today) | Every network, every browser | One relay hop and an HTTP upgrade round trip on every connection |
| B | Add a TCP binding for direct and self-hosted use, default off | 3 round trips to first response instead of 4.5 to 5; no relay in the path; a real listener for a port request | A listener beyond loopback, and the draft's "nothing listens, neither end learns the other's IP" no longer holds on that path |
| C | Make TCP the primary binding | Fewest round trips | Browsers cannot open it, and 443 is the only port every network passes. Not viable |

**Recommendation.** Option B. Keep WebSocket on 443 as the required binding and add TCP as an optional
one, offered only while an instance is sharing, advertised in a separate invite field, framed with a
2-byte length in front of each Noise message.

**The one blocker.** A direct listener gives up two properties the draft states outright (Section 9
opening: "Nothing on either machine listens beyond loopback, and neither end learns the other's IP
address"; Section 13). That is a product and privacy decision, not an engineering one.

**Needs Gordon.**
1. Is a listener on a non-loopback interface acceptable, gated to while a port is shared and off by
   default?
2. Port sequencing. Request a User Port (42424) once a listener ships, and argue the request on the
   protocol alone (section 7).

**A defect found on the way, for the dev lead.** An empty message is never delivered by
`session.Recv` (section 8). It affects the WebSocket binding today.

## 1. What is fixed today

- **The seam is four verbs.** `transport.Transport` has `Accept`, `Dial`, `PeerID`, and a `Session` with
  `Send`, `Recv`, `RemotePeer`, `Close` (`gateway/transport/transport.go`). A session carries whole
  messages, and splitting them to fit is the transport's job (`transport/chunk.go`).
- **The Noise layer does not know about WebSocket.** `relay.Initiate` and `relay.Respond` take an
  interface of three methods, `SendFrame`, `RecvFrame`, `Close` (`relay/noise.go`, type `frames`). The
  handshake and the session run over whatever provides them. The spike's TCP implementation is about 30
  lines and the Noise code is used unchanged.
- **The WebSocket is confined to two files.** In `relay/server.go` the WebSocket is used through
  `Read` and `Write` with a message type (text for control, binary for data), `Close` and `Ping`. In
  `relay/client.go` the same, plus a 20 second keepalive for proxies that close quiet connections.
- **A relay session costs several control exchanges before Noise starts.** Upgrade, `challenge`,
  `hello`, `ok`, `open`, `incoming`, `accept`, `opened` (draft 9.3), then the Noise handshake.
- **Browsers only speak WebSocket.** The guest page (`guest/src/`) is a Noise initiator in JS over
  `wss://`. Its coupon check rejects an invite whose `relays` list holds anything that is not `wss://`
  (or `ws://` to loopback): `guest/src/coupon.js` line 17, `json.relays.every(secureRelay)`, and a
  failure returns null for the whole coupon.
- **Older gateways skip an address they do not know.** `relay.Transport.Dial` tries each relay in
  order and `connect` refuses a scheme it does not accept (`SecureRelayURL`, REL-03). Measured: a
  gateway given `[tcp://127.0.0.1:42424, ws://…/v1]` reached the host through the second
  (`TestOldGatewaySkipsAnUnknownRelayScheme`).

## 2. Framing and handshake on a byte stream

TCP has no message boundaries, so each Noise message needs one. Two candidates.

**A. A 2-byte big-endian length, then the Noise message** (what the spike implements). A frame is the
handshake message or the ciphertext of one chunk (draft 9.5), at most 65,535 bytes. Cost is 2 bytes per
frame. The length is not authenticated, so an on-path attacker who alters it desynchronizes the stream,
the next read fails authentication and the session ends. That is denial of service, which an on-path
attacker has anyway.

**B. BOLT 8 style, an encrypted length.** After the handshake, each message is a 2-byte length
encrypted with its own AEAD tag (18 bytes), then the message and its tag. Lightning does this "to make
traffic analysis more difficult" and to avoid a decryption oracle (BOLT 8, "Encrypted Messages"). Cost
is 18 bytes and one extra AEAD operation per frame, and both ends must consume nonces in the same order.
It hides frame boundaries from a passive observer, but a TCP observer still sees segment sizes, and the
WebSocket binding already exposes frame sizes to the relay. The benefit over A is small here.

**Recommendation.** A for the first version. The handshake messages use the same framing. The draft
should state the choice so that B can be added as a later binding version without ambiguity.

**Handshake.** Direct TCP needs no relay control exchange. The dialer connects and starts Noise IK as
initiator, exactly as after `opened` today. Sizes on the wire from the spike, framing included:
message 1 is 130 bytes (v1 prologue), message 2 is 50 bytes. The responder still tries the v2 prologue
and then v1 on the same bytes (`readFirst`, `relay/noise.go`), so nothing about GST-02 changes. The
prologue stays `port42-noise-v1` and `-v2`; the binding is not a security-relevant difference and a
separate prologue would split one identity into two protocols.

**Identity is unchanged.** The peer id is the Ed25519 key, the Noise static key is its X25519
conversion, and the responder authenticates the caller from message 1 (draft 9.4). The relay `hello`
proves a key to the relay, so it has no direct-path equivalent and none is needed. An unenrolled caller
may still only call `invite.redeem` (draft 9.6).

**Comparison with BOLT 8.** Lightning runs `Noise_XK_secp256k1_ChaChaPoly_SHA256` in three acts of 50,
50 and 66 bytes, so the initiator waits one and a half round trips before it may send. Port42 runs IK
and needs one. The difference in properties is that in XK the responder's static key is never sent and
the initiator's is sent last; in IK the initiator's static key travels in message 1, encrypted to the
responder's static key. Anyone who later obtains a responder's long-term key can read the identities of
the initiators recorded against it. On the relay path a recording is easy for the relay. The same holds
on TCP. I did not evaluate switching to XK, which would change the WebSocket binding as well.

## 3. How it plugs into the transport seam

Code that changes, by place.

- **New TCP transport in the gateway.** A `Transport` whose `Accept` runs `relay.Respond` on each
  accepted connection under a handshake deadline, and whose `Dial` connects and runs `relay.Initiate`.
  No change to `transport/` or `relay.Initiate` and `relay.Respond`.
- **Listener control.** `gateway/main.go` starts remote serving from a `-relay` flag, and
  `relayhost.go` switches registration on and off from the app while a port is shared (GW-16). A TCP
  listener should be switched by the same command, so a machine that shares nothing listens on nothing.
- **Choosing a path.** `outbound.go` builds a dialer from the `relays` in a `remote_call`
  (`newDialer(key, env.Relays)`). It gains a list of direct addresses, tries them before the relays or
  alongside them, and falls back. The draft already says a direct path is "chosen per session" (9.1).
- **Where an address comes from.** `Dial` takes only a peer id today, and the relay list comes from the
  invite (`InviteCoupon.relays`, `Invites.swift`). A direct address needs the same route. Use a new
  optional coupon field (for example `direct`, an array of `host:port`). The coupon already carries one
  field older pages ignore (`noise`, with `v` staying 1), so this follows precedent. Putting a `tcp://`
  entry in `relays` would make today's browser guest reject the whole invite (section 1).
- **Discovery without an invite.** Bonjour with the service name `_port42._tcp` is the natural fit and
  is what the growth research proposes for the service-name registration. Advertising a peer id on a LAN
  discloses identity to everyone on it, so it should be opt in. Not built or measured.

## 4. What it saves

Method. `rawtcp_test.go` runs the same Noise handshake and the same 200 byte echo over: TCP with the
2-byte frame; a WebSocket (nhooyr, the library the relay uses) without TLS; and a WebSocket over TLS
1.3 with a self-signed certificate. A proxy in the middle adds a fixed one-way delay per direction,
delays the TCP handshake by one round trip, and counts bytes. The relay path uses the real
`relay.Server` and `relay.Transport`, with the guest and host legs each at half the delay so the
physical distance matches the direct path. Everything runs on one Mac (macOS 15.6.1, Go 1.25.0).

### Round trips to a first response

Path one-way delay 100 ms (RTT 200 ms), median of 5.

| Path | Median ms | In RTTs | Counted |
|---|---|---|---|
| Direct, TCP + Noise | 610.7 | 3.05 | connect 1, Noise 1, message 1 |
| Direct, WebSocket + Noise | 812.6 | 4.06 | adds the HTTP upgrade, 1 |
| Direct, WebSocket over TLS + Noise | 1,025.7 | 5.13 | adds the TLS 1.3 handshake, 1 |
| Relay, WebSocket (no TLS) + Noise | 963.0 | 4.82 | connect, upgrade, hello, open and accept, Noise, message |

The relay row is 4.5 path round trips by count (the guest to relay steps are half a path round trip
each) plus roughly 0.3 measured. With TLS the relay path is 5.0 by the same count. I did not build a
TCP relay, so the relay-over-TCP rows below are computed, not measured.

| Relay path | Round trips | Basis |
|---|---|---|
| Relay over WebSocket and TLS (today, production) | 5.0 | 4.5 measured without TLS, plus 0.5 for TLS on the guest leg |
| Relay over TCP, no TLS | 4.0 | removes the upgrade, 0.5 |
| Relay over TCP inside TLS | 4.5 | TLS stays, upgrade removed |
| Direct TCP | 3.0 | measured |

At 50 ms the ordering held but the WebSocket rows were noisy (5.5 and 5.2 RTTs), and at 5 ms one-way
the WebSocket paths carried 50 to 100 ms of fixed cost I did not attribute (53, 103, 154 and 77 ms for
the four rows). On a LAN with sub-millisecond RTT that fixed cost, and not round trips, decides the
time to first response, and this harness does not say what it is in the real app. Treat the 100 ms rows
as the round trip count, and the LAN saving as unmeasured beyond the loopback figures below.

### Bytes

Total bytes at the proxy for the handshake plus one echoed message.

| Message | TCP | WebSocket | WebSocket over TLS |
|---|---|---|---|
| 1 byte | 220 | 607 | 3,920 |
| 200 bytes | 618 | 1,009 | 4,322 |
| 64 KiB (65,000) | 130,218 | 130,609 | 134,450 |
| 1 MiB | 2,097,978 | 2,098,497 | 2,109,664 |

The saving is at connection setup: about 390 bytes against plain WebSocket (the HTTP upgrade), and TLS adds
another 3.3 KB (the handshake, with a small self-signed chain, so a real chain adds more). Per frame it
is 2 bytes for TCP against 4 to 8 for WebSocket (server and client frames) and 22 for each TLS record.
On bulk data the difference is 0.02% and 0.56%. Bandwidth is not a reason to add the binding.

### CPU and small-message latency, loopback only

| Binding | 256 MiB echo: seconds | MiB/s | CPU seconds | 200 B round trip p50 / p99 |
|---|---|---|---|---|
| TCP | 7.86 | 33 | 5.94 | 81 µs / 1,029 µs |
| WebSocket | 18.85 | 14 | 8.97 | 127 µs / 1,456 µs |
| WebSocket over TLS | 15.50 | 17 | 10.42 | 225 µs / 16,100 µs |

Both ends share one process, and the Noise ChaCha work is the largest cost in every row. The gap is in
the WebSocket library and TLS, and applies to that library and this harness. It shows the WebSocket
binding costs more CPU per byte, not that it is slow enough to matter on a person's network.

**Where the real saving is.** A direct path removes the relay hop. The round trips above hold the
physical distance equal. A relay that is not on the line between the two machines adds stretch on top,
and the relay's location relative to two people is unmeasured. The phase 4 design note puts the failure
rate of direct connections without a relay at 7 to 25% (`design-phase4-relay.md`, citing its own
research); I did not re-verify that figure. A TCP direct path only works where the dialer can reach the
listener: the same LAN, a private overlay such as Tailscale, a self-hosted server with a public address,
or a forwarded port.

## 5. How the relay serves both

The relay's session logic needs, from a connection, an ordered read and write of messages labeled as
control or data, a close, and a keepalive. A TCP connection provides bytes only. The adapter is a small
frame around each message.

- **Frame.** One byte for the kind (control JSON, data, ping, pong) and a 2-byte length, then the
  payload. Control messages fit in 64 KiB, and data frames are already capped at 64 KiB plus 64 bytes
  (`DefaultLimits.MaxFrame`). This adds one byte to each frame over the direct framing.
- **After `opened`.** A guest connection is one session and carries no prefix on the WebSocket today.
  The same holds on TCP: after `opened` the stream may drop the kind byte and carry direct-binding
  frames, or keep it. Keeping it is simpler and costs one byte. The host connection multiplexes
  sessions with a 16 byte session id in front of each data frame, unchanged.
- **Keepalive.** WebSocket pings exist because Cloudflare closes a quiet connection after about 100
  seconds (`relay/client.go`, `PingEvery`). A TCP relay behind a plain load balancer or NAT needs the
  same, as the ping kind or TCP keepalive. Not measured.
- **Limits.** `ConnsPerIP`, `OpensPerIPMin` and the other limits key on the client address
  (`Server.clientIP`, with Cloudflare header handling for the WebSocket path). A TCP listener has the
  address directly.
- **Confidentiality of the relay control channel.** Plain WebSocket to a non-loopback relay is refused
  today because `hello` and the pairing metadata would be visible on the path (REL-03). Plain TCP has
  the same property, so a TCP relay beyond loopback and private ranges should be wrapped in TLS. That
  makes it "TLS on a chosen port", which passes fewer networks than 443 and saves only the upgrade
  round trip. The relay-over-TCP case is therefore mostly for loopback, LAN and self-hosted use, where
  the operator controls the path.
- **What does not change.** Sessions do not span relay processes, the relay stores nothing, and a
  browser guest still needs the WebSocket listener on the same relay.

The default relay would keep serving `wss://` on 443 and could also open a TCP listener. That decision
is the relay operator's, and adds an unauthenticated internet-facing TCP surface (section 6).

## 6. Costs and risks

- **The listener.** A direct path means the host accepts connections from any address it is reachable
  from. The spike measured what an unauthenticated connection costs: 3,000 connections that send one
  garbage first message took 2.55 s wall and 2.70 s CPU across both ends, about 0.9 ms each, or roughly
  1,100 a second on one core, counting both ends' CPU. The responder tries two prologues, so each bad first message costs two failed
  decryptions. The relay already limits connections and opens per address; a new listener needs the
  same limits, a handshake deadline (the relay transport uses 10 s), a cap on concurrent unauthenticated
  handshakes, and to be off unless a port is shared. A silent connection is held until that deadline.
- **Address exposure.** The dialer learns the host's IP and the host learns the dialer's. Section 13 of
  the draft says neither end does today. A direct address in an invite is a persistent disclosure.
- **Scanner exposure.** Any listening port draws unsolicited probes. Traffic on 42424 was not looked at.
- **Reachability.** Outbound connections to an unusual port are blocked on many corporate and hotel
  networks, which is why the phase 4 design chose 443 (`design-phase4-relay.md`, "Why relay first").
  The TCP binding is therefore an addition on networks that permit it, never a replacement.
- **macOS prompts.** The phase 4 design lists the macOS Local Network prompt among the unknowns it
  avoided by having nothing talk to the LAN. Dialing or listening on a private address may raise it,
  and an incoming connection may raise the firewall prompt. I did not test either, and a Dev9 check
  needs a running listener.
- **Replay.** Noise IK message 1 can be replayed to a responder that will then answer and hold state
  until the deadline. The attacker cannot continue the session. This exists on the relay path today.
  The binding should not add early data to message 1.

## 7. What it means for the draft and the port request

**Draft changes** (`port42-rfc-v1.txt`)

- **Section 9 opening.** "Between machines, every connection goes through a relay" becomes "The
  required binding goes through a relay over WebSocket. An implementation MAY also offer a TCP binding."
  The two "nothing listens" and "neither end learns the other's IP" statements become properties of the
  relay binding.
- **Section 9.1.** The seam text already allows it. Add that a session's binding is chosen by the
  dialer and that a host MAY offer several.
- **Sections 9.4 and 9.5.** Noise and chunking are binding independent. State them as such, and say a
  binding supplies ordered frames of at most 65,535 bytes.
- **New section, TCP binding.** The 2-byte length framing, the direct handshake, the listener rules
  (handshake deadline, limits, off unless sharing), and the error on a length above 65,535.
- **Coupon.** One optional field for direct addresses, ignored by a guest that does not know it.
- **Sections 12 and 13.** Add the pre-authentication surface and the address disclosure of a direct path.
- **Section 14.3.** If the binding is adopted, replace it with the port request for the binding (42424),
  stated in the terms below.

**Registered port**

- **42424 is unassigned.** The IANA CSV fetched today lists 41798-42507 as Unassigned. TCP 4242, the
  local default, is inside `vrml-multi-use` 4200-4299. TCP 9735, Lightning's port, is inside the
  Unassigned range 9701-9746, so Lightning runs on an unregistered port, and BOLT 1 describes 9735 as a
  convention that follows Bitcoin Core's. That is the precedent that adoption does not need registration,
  and RFC 7605 section 7.8 says de facto use does not by itself justify a later assignment.
- **What the binding supplies.** The growth research names the one blocker as no service listening for
  unsolicited connections (9.2). A TCP binding is such a service, so it supports the service-name
  registration already in draft 14.2 and a User Port request by Expert Review, with 42424 as the number.
- **How the request reads.** It describes the protocol and leaves the product out. A peer transport that
  carries Noise messages over a stream, framed with a 2-byte length, between a dialer that knows the
  responder's key and the responder, for self-hosted relays, local networks and direct machine to machine
  paths. The reason for a stable number is operational: a firewall rule, a self-hosted relay's published
  address and a service-discovery record need one. The name appears only where the registry requires an
  identifier, in the service-name field. A request that leans on what the number spells reads as vanity
  to a reviewer (RFC 7605 section 7.3 asks whether an IANA-chosen number would do), so the text says
  any number in the User range is acceptable and proposes 42424 because it is unassigned.
- **Sequence for the draft.** Adding a User Port request in the same draft is consistent with the draft's
  position that the protocol does not depend on a particular port, since the request can be declined
  without affecting the protocol.

## 8. Defect found on the way

An empty message is one chunk in the draft (9.5) and `SplitMessage` produces it. `Reassembler.Add`
returns `r.buf` for the last chunk, which is nil when the message is empty, and `session.Recv` in
`relay/noise.go` treats a nil result as "more expected" and keeps reading (`if msg != nil { return msg }`).
The spike's first run hung on a zero-length echo for this reason, and `TestEmptyMessageReassembly`
prints `msg==nil: true`. No caller sends an empty envelope today, so it has not shown up. It applies to
every binding and is a one-line fix for the dev lead.

## Not verified

- **No running app was involved.** This is a protocol study and the measurements are Go tests. Nothing
  was tried on Dev9, and I did not take its lock. A listener has not been built in the gateway, so
  there was nothing for a person to try.
- **Relay over TCP** is computed from the measured direct paths, not built.
- **Real networks.** The delay is a fixed value from a proxy on one machine. No jitter, loss, MTU, NAT
  or middlebox behavior, and no real TLS certificate chain.
- **LAN latency.** The WebSocket paths showed a fixed setup cost at 5 ms one-way that I did not explain.
- **The WebSocket library** is nhooyr v1.8.17. Another library or an optimized one may close the CPU gap.
- **The macOS Local Network and firewall prompts**, Bonjour behavior with a sandboxed or signed app,
  and how a proxy or load balancer in front of a relay handles idle raw TCP.
- **Browser-side.** The guest page cannot use this binding. Any future WebTransport or similar path was
  not looked at.
- **Switching IK to XK** for initiator identity hiding, and the encrypted-length framing (B), were not
  built or measured.
- **Scanner traffic on 42424**, and how often outbound 42424 is blocked.
- **The 7 to 25% figure** for direct connection failure comes from the phase 4 research and was not re-checked.
- **Root-package Go tests** (`go test ./...` in `gateway/`) fail in `TestABrowserGuest*` and
  `TestTheInvitePage` because `npm install` has not been run in `guest/` in this worktree. That is
  unrelated to this work. The `relay`, `tele` and spike packages pass.

## Reproduce

    cd gateway
    go test ./spikes/rawtcp -run 'TestWireBytes|TestThroughput|TestPingPong|TestPreAuthCost' -v -count=1
    P42_ONEWAY_MS=100 go test ./spikes/rawtcp -run TestTimeToFirstResponse -v -count=1
    go test ./spikes/rawtcp -run 'TestOldGateway|TestEmpty' -v -count=1

Raw output is in `gateway/spikes/rawtcp/results-*.txt`.
