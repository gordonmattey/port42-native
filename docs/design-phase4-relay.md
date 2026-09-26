# Phase 4 architecture: the relay-first remote pipe

The design spec for `plan-nautilus-phase4.md`. Decided by Gordon, 2026-09-26: **relay first**. Every
remote connection goes through a relay over a secure WebSocket, encrypted end to end between the two
instances' keys, so the relay carries bytes it cannot read. A direct path is a later upgrade behind the
same seam (as Tailscale starts on its relays and upgrades to direct), not part of this phase. The
peer-to-peer research that led here is in `research-phase4-transport.md`.

## Why relay first

- **It connects from every network on day one.** Home, café, office, hotel, phone, any browser: all of
  them allow an outbound secure WebSocket on port 443. The research estimated 7 to 25% of peer-to-peer
  attempts fail without a relay, and put them in exactly the places people would open a shared port.
- **It removes the unknowns the research found:** NAT traversal, router port mapping, IPv6 firewalls
  and address churn, public Nostr relays refusing traffic, the macOS local network prompt (nothing
  talks to the LAN), pion's pre-authentication crash surface (nothing listens), data-channel size and
  lifecycle quirks.
- **It hides each side's IP address from the other.** The relay sees both; neither party sees the
  other's.
- **It is what comparable products do.** Block's Buzz runs every message through a relay the team
  hosts; Goose's phone app reached its agent through a tunnel on Cloudflare's servers.
- **It stays self-sovereign.** The relay is one small open program with no database. Port42 runs a
  default one; anyone can run their own and put it in their invites.

The cost: a server to run, its bandwidth, and one extra hop of latency.

## The pieces

```
  HOST MAC (instance A)                    RELAY                     GUEST
  ┌──────────────────────────┐        ┌───────────────┐       ┌──────────────────────────┐
  │ app: grants, invites,    │        │ pairs keys,    │       │ Port42 (instance B):     │
  │ Principal.remote, Access │        │ forwards       │       │   its own gateway        │
  │          ▲ host conn     │        │ ciphertext,    │       │ or a browser:            │
  │ gateway: relay link,     │─WSS───▶│ enforces       │◀──WSS─│   port42.ai/invite.html  │
  │ Noise responder, framing │ 443    │ limits         │  443  │   (Noise initiator in JS)│
  │ HTTP door on loopback    │        │ stores nothing │       │                          │
  └──────────────────────────┘        └───────────────┘       └──────────────────────────┘
         Noise_IK session, end to end: the relay forwards messages it cannot read or forge
```

Both machines only ever connect outward. Nothing on the Mac listens beyond loopback.

### Identity

- **Each instance has one Ed25519 key**, generated at first need and kept in the Keychain under the
  instance name (`Port42AuthStore`). Its public key is the instance's **peer id**, written in lowercase
  base32 in addresses: `port42://<peer>/<portId>`.
- **The same key gives the Noise static key** by the standard Ed25519 to X25519 conversion, so there
  is one identity per instance and no second key to store or lose. A peer proves its identity by
  completing the Noise handshake with the static key that converts from the peer id it claims.
- **A browser guest's key** is an Ed25519 seed generated in the page and kept in the browser
  (IndexedDB), so a refresh is the same guest. Safari clears it after seven days without a visit; the
  guest then needs a new invite.
- **The gateway holds the instance private key**, handed over on stdin at spawn with the host
  credential and a second per-spawn secret for attestation (below). It never reaches disk outside the
  Keychain or the environment of any process.

### The relay

A Go program in `relay/` in this repo, one static binary and a Dockerfile. It holds only in-memory
state: which host keys are connected, and which sessions pair which sockets.

**Transport.** WebSocket over TLS on 443. Text frames carry control messages (JSON); binary frames
carry session data. WebSocket pings every 20 seconds keep idle connections through middleboxes.

**Registering and pairing.** Every connection starts the same way:

| Step | Direction | Message |
|---|---|---|
| 1 | relay to client | `{"t":"challenge","relay":"<relay host>","nonce":"<b64>"}` |
| 2 | client to relay | `{"t":"hello","role":"host"\|"guest","key":"<b64 ed25519 pub>","sig":"<b64>"}`, the signature over `port42-relay-v1\|<relay host>\|<nonce>\|<role>` |
| 3 | relay to client | `{"t":"ok"}` or `{"t":"error","code":…}` |

A host keeps its one connection open. A guest then asks for a session:

| Step | Direction | Message |
|---|---|---|
| 4 | guest to relay | `{"t":"open","to":"<host key>"}` |
| 5 | relay to host | `{"t":"incoming","sid":"<16-byte b64>","from":"<guest key>"}` |
| 6 | host to relay | `{"t":"accept","sid":…}` or `{"t":"refuse","sid":…,"code":…}` |
| 7 | relay to guest | `{"t":"opened","sid":…}`, or `{"t":"error","code":"host_offline"\|"refused"\|"rate_limited"}` |
| then | both ways | binary frames: the host's carry a 16-byte session id prefix; the guest's socket is one session and carries none |
| end | either | `{"t":"close","sid":…}`, or the socket closing |

The signed `hello` means nobody can register as a host key it does not hold, so a guest asking for
`<host key>` reaches that host or nobody. `from` is advisory: the host learns the guest's identity from
the Noise handshake, not from the relay.

**Limits** (initial values, to tune from use): a data frame at most 64 KiB plus the prefix; at most 32
sessions per host; at most 4 open sessions per guest key; `open` requests at most 30 a minute per IP
and 10 a minute per target host; per-session throughput capped (a starting figure of 1 MB/s); sessions
idle 5 minutes closed. A refusal says which limit was hit.

**What the relay learns:** which host keys are online and from which IPs, which guest keys connect to
which hosts and from which IPs, when, and how many bytes. **Not** content, port ids, rights, invite
codes or names. It logs counts, never payloads.

**Several relays.** A host registers on one relay by default and may register on more. The invite
lists the host's relays; the guest tries them in order. Each relay is one process with its own
hostname (`relay1.port42.ai`), so pairing never crosses processes; more capacity is more hostnames,
as DERP regions are.

### End-to-end encryption: Noise IK

- **Pattern:** `Noise_IK_25519_ChaChaPoly_SHA256`. IK because the guest already knows the host's key
  from the invite or address: one round trip, mutual authentication, forward secrecy, and the guest's
  identity is sent encrypted.
- **Prologue:** `port42-noise-v1`, binding both sides to this protocol.
- **First message payload (guest):** its Ed25519 public key. The host checks that the Noise remote
  static converts from it, which is what makes the guest's peer id authenticated.
- **Transport messages** are at most 65,535 bytes, Noise's limit, which sets the chunk size below.
- **Libraries:** `flynn/noise` in Go. In the browser, a small Noise IK implementation on the `@noble`
  curves, ciphers and hashes libraries (audited, no dependencies), bundled with the page. No
  WebCrypto dependency, so every current browser behaves the same.
- **A relay that is compromised** can drop, delay or reorder sessions, and cannot read or forge them.

### Inside the session: the door's own envelopes

The session carries the gateway's existing `Envelope` JSON (`call`, `response`, `stream`,
`error`), already multiplexed by `call_id`, so there is no second multiplexer. Each envelope is one
logical message:

- **Framing:** a message longer than one Noise transport message is split into chunks with a one-byte
  header (more follows, or last) and reassembled by the receiver, which refuses a message over 8 MiB.
- **Backpressure:** each side stops reading from its local source when its socket's send buffer passes
  a threshold (`bufferedAmount` in the browser, a bounded channel in Go).
- **Resumption:** a dropped session is reopened with a new handshake. Every call carries a request id,
  so a retried write is applied once, and subscriptions are re-issued, followed by one `getHtml`.

### The gateway

New, in Go, beside the door it already is:

- **The relay link.** At spawn, the app tells the gateway its relays. The gateway connects to each,
  registers as host, reconnects with backoff after any drop (including sleep), and reports link state
  to the app on the host connection.
- **Inbound sessions.** On `incoming` the gateway accepts (capacity permitting) and runs the Noise
  responder. Each decrypted envelope is forwarded to the app exactly as a `/ws` caller's is, with two
  fields added: `remote_peer` (the verified guest key) and `remote_attest` (an HMAC over it with the
  stdin-only secret). Responses and stream frames for that call return down the session.
- **Outbound sessions** (the Port42 lane, on the guest's instance). The app asks its gateway to call
  a method on `port42://<peer>/<portId>`; the gateway opens a session to that peer through its relays
  as a guest, runs the Noise initiator, and returns the response and stream frames to the app.
- **Stripping.** `remote_peer` and `remote_attest` are removed from anything arriving on `/ws` or
  `/call`, so a local caller cannot claim to be remote.
- **The seam.** All of the above sits behind the four verbs of `plan-shell-only.md` (listen, dial, peer
  id, stream), with an in-memory implementation for tests. A direct path later is a second
  implementation, chosen per session.

### The app

- **Verifying.** The app checks `remote_attest` before forming a principal, in `resolveGatewayCaller`,
  the one place a caller identity is formed, then looks up the `peer` client row for that key.
- **`Principal.remote`** and the rights of the plan's decision 5 (`see`, `use`, `edit`,
  `wake agents`), enforced in the dispatcher: a remote caller reaches only the ports it holds grants
  on, within those rights, and nothing on the machine.
- **Invites, Access, the remote tile and address forwarding**, as in the plan.

### The invite

- **The link:** `https://port42.ai/invite.html#<coupon>`, the coupon base64url in the fragment. It
  holds: version, host peer key, the host's relays, port id, rights, a one-time 128-bit nonce, an
  expiry, and display names (host, port title). No standing access.
- **The page never acts on load.** It reads the coupon, clears it from the address bar
  (`history.replaceState`), and offers "Open in Port42" (`port42://invite#<coupon>`) or "Open here".
  Link previews and mail scanners that run scripts therefore redeem nothing.
- **Redeeming is a waiting room.** The page shows who shared what, a name field and Join. After
  Join: connect to a relay, open a session to the host, handshake, then send
  `invite.redeem {nonce, name}` as the first call, and show "Waiting for <host> to let you in". The
  host checks the nonce is live and raises a request (a peek, and a notification when the app is in
  the background): "<name> wants to open '<port>' (<rights>), from <browser and device>", Allow or
  Deny. Allow burns the nonce, creates a `peer` client row for the guest's key under that name if
  there is none, grants that port with those rights, and answers the call; the page then loads the
  port. Deny answers with `refused`. An unanswered request waits while the guest's session is open and
  the invite is unexpired. A guest who already holds a grant reconnects without a nonce.
- **The Port42 lane.** `port42://invite#…` opens a card in the guest's Port42 naming the host, the
  port and the rights; accepting runs the same redemption from the guest instance's gateway and places
  a remote tile.
- **Page hygiene.** The page and its script are served from `port42.ai` with no third-party script (the
  current page loads PostHog, which could read the coupon), a strict Content-Security-Policy that
  allows only the listed relays for `connect-src`, `Referrer-Policy: no-referrer`, and subresource
  integrity on its script.

### Presence, sleep and failure

- **Host offline:** the relay answers `open` with `host_offline` at once, and the guest page says "the
  host's Mac is offline" and retries on a timer. No spinner without a reason.
- **Host sleeps:** its relay link drops, guests' sessions close, and the gateway re-registers on wake.
  Guests resume as above.
- **Relay down:** the guest tries the next relay in the invite. With one relay, it says so.
- **Every failure a guest can meet has a message** naming what happened and what to do: offline,
  refused, not approved, invite used, invite expired, rate limited, relay unreachable.

## Security properties

| Property | How |
|---|---|
| Only the host key's holder can answer for it | signed `hello` at the relay; Noise IK with the host's static key from the invite |
| The relay cannot read or alter traffic | Noise end to end; the relay forwards ciphertext |
| The guest's identity is authenticated | Noise remote static converts from the claimed Ed25519 key |
| The app never trusts an unverified peer field | HMAC attestation with a stdin-only per-spawn secret; the fields stripped from local doors |
| A forwarded or previewed link grants nothing by itself | no redemption without the guest's Join and the host's Allow; the nonce burns on first use |
| A guest reaches one port | deny by default in the dispatcher; rights per port; no machine methods |
| Neither side learns the other's IP | only the relay connects to both |
| Nothing on the Mac is exposed | no listening socket beyond loopback |

What the relay operator can see is stated in the invite dialog: who connects to whom, when, and how
much, never what.

## Hosting

The relay needs one public hostname with TLS and WebSockets; no UDP. **Railway** (Gordon's account)
hosts the default, `relay1.port42.ai`, and terminates TLS at its edge on 443; the Noise session
inside is end to end regardless. 443 because restrictive networks commonly allow only web ports
outbound; a self-hosted relay may listen on any port. Whether Railway's proxy closes long-lived
idle WebSockets is measured in 4.0; the relay's 20-second pings are meant to prevent it. Self-hosting is documented: run the binary with a domain, put it in Settings, and
new invites list it.

## What is not in this design

- **Direct connections** (WebRTC, port mapping, IPv6): a later upgrade per session behind the seam,
  researched in `research-phase4-transport.md`.
- **Store and forward**: nothing is held for an offline host.
- **Nostr**: not used. The relay's protocol is our own, small and documented; Buzz shows a Nostr relay
  can carry a workspace, but port traffic (megabyte pages, event streams) fits a forwarding relay.
