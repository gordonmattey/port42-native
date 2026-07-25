# Plan: gateway auth + TLS — 2026-07-24

GM: "we need to add https support on the gateway, and should add auth to it presumably too."

Auth first. TLS second. The ordering matters, and the reason is below.

## What is exposed today (read from the code, 2026-07-24)

- **The gateway binds every interface.** `GatewayProcess` launches it with `-addr :4242`
  (`GatewayProcess.swift:58`), not `127.0.0.1:4242`. Anything that can route to the machine can
  reach it: other devices on the coffee-shop wifi, not just this Mac.
- **`/call` has no authentication of any kind.** `HandleHTTPCall` (`gateway.go:802`) accepts any
  POST of `{method, args}` and proxies it to the host app, which dispatches it through the bridge
  registry. That is the same surface the LLM tool path uses: files, clipboard, screen, terminal,
  automation. Port42's permission prompts are the only thing in the way, so anything already
  granted (or declared permission-free) runs for whoever asked.
- **The WebSocket path already has an auth mechanism, switched off.** `authVerifier` (nonce
  challenge → Apple identity token, `gateway.go:204/244`) is nil unless configured, and nil means
  disabled. So the design exists on one path and is unused on the other. (This is F-511 "relay
  auth", still listed as remaining in CLAUDE.md.)
- **No `CheckOrigin` on the upgrader**, so the Origin policy is gorilla's default. That is a
  browser-only defence and nothing else honours it.

**Therefore: HTTPS alone fixes none of this.** Encrypting a channel that accepts unauthenticated
commands from the whole LAN just means the commands arrive encrypted. Auth is the control; TLS
protects it in transit.

## Phases

### P0 — bind to loopback (one line, do first)
`-addr 127.0.0.1:<port>` for the app-launched gateway. Removes LAN reachability immediately and
costs nothing: ngrok's agent dials the gateway from the same machine, so tunnelled sharing is
unaffected. A deliberately-hosted relay still opts into `:<port>` by launching itself.
**Breaks:** anyone pointing a second device straight at their Mac's LAN address instead of using an
invite link. Believed to be nobody, but it IS a behaviour change.

### P1 — authenticate `/call`
A per-install secret, generated on first launch, stored in the Keychain, required on every `/call`
as a header. The work is not the check, it is the **callers**, and they are the reason this needs a
plan rather than a patch:
- the global `~/.claude/CLAUDE.md` block that tells every Claude Code session to
  `curl http://127.0.0.1:4245/call` (rewritten per dev instance at boot — the same seam can inject
  the token)
- `port42-claude-shim` and the terminal hooks
- ports calling through `window.port42` (they go via the bridge, not HTTP — verify)
- any of GM's own scripts and skills
Decide: one shared install secret, or per-caller tokens with per-caller permission scope. The
second is the real answer long-term (a companion's terminal should not silently inherit the app's
whole authority) and folds into the existing `portPrincipal` model.

### P2 — TLS, scoped by the libp2p decision
**The transport endgame is already decided** (`membrane/slice-02-cross-instance.md`): go-libp2p,
native to the Go gateway, with PeerID as the instance address, Circuit-Relay v2 + DCUtR for reach,
and gossipsub for fan-out. That decision does most of P2's job for us, because libp2p brings an
**encrypted, mutually-authenticated channel as a primitive**: peers are keypairs, and a stream is
secured (Noise/TLS) before any bytes of ours cross it. There is no certificate authority, hostname,
or renewal in that world.

So the honest split:
- **Tunnelled sharing (today)** already has TLS: ngrok terminates HTTPS at its edge. Nothing to do.
- **A self-hosted internet relay with real certs** is the phase to NOT build. It is weeks of
  hostname/renewal/deployment work on the interim WebSocket transport, and libp2p replaces the need
  rather than inheriting it. Build it only if a concrete deployment demands it before libp2p lands.
- **Local HTTPS is mostly theatre**: a self-signed cert on loopback buys little once P0 and P1 land,
  and costs every caller a trust-store dance.

**Identity: SETTLED (`decision-identity-model.md`, 2026-07-24).** Three axes, not one competition:
**person** (the `AppUser` P256 key, today inert), **instance** (the libp2p PeerID, a per-device key
SIGNED by the person key, so "this peer is Gordon's" is provable without the person key travelling),
and **actor** (the `Principal` the bridge already carries).

The two pieces this plan was worried about collapse out of that model:
- The **Apple identity token is an authentication method**, not an identity — it proves person
  identity to a relay and maps onto the person id. It never becomes one (which also keeps a vendor
  out of the trust root of a local-first product).
- The **`/call` token is a capability that MINTS a principal** with a scope, not a fourth id. Grants
  keep keying on `principal.id` exactly as they do now, and P1 adds no new identity table.

Actor identifiers are written **peer-qualified** (`<peerID>/<principalId>`, local peer implicit) from
the start, so libp2p arrives as a prefix rather than a refactor. The membrane's **Gatekeeper** and
**Controller** remain the roles that own this; `/call` auth is their local case.

### P3 — origin + CSRF hardening
Explicit `CheckOrigin`, and a look at whether a malicious page can reach `/call` with a
simple-request POST (no preflight). Cheap once P1 exists, since a missing token fails the request
before origin matters.

## Testing

`gateway_httpcall_test.go` already exercises `/call` end to end, so P1 gets a real test: a call with
no token is rejected, a call with the token succeeds, and the token is not logged. P0 is asserted by
checking the listen address the app passes. TLS is verified by hand at whatever deployment lands.

## How this sits against the libp2p track

P0 and P1 are **transport-independent**: the `/call` HTTP surface is how local callers (Claude Code
sessions, the shim, hooks, scripts) drive this machine's app, and it stays local under libp2p too.
That work is never thrown away, which is exactly why it goes first.

P2 is the phase that libp2p **subsumes**. Anything bespoke built for internet-facing TLS on the
WebSocket relay is interim work with a known replacement, so the default answer is: don't, unless a
deployment forces it.

The one piece that must NOT be decided twice is identity (above). If `/call` auth invents its own
principal now, libp2p's PeerID arrives as a competing one later and the two have to be reconciled
under load. Cheaper to name the principal once, here, and let both transports present it.

## Open questions for GM

1. Is anything today deliberately hitting the gateway from another device on the LAN?
   (If not, P0 is a one-line change I can make immediately.)
2. One install-wide secret to start, or go straight to per-caller tokens with scope? The second
   folds into `portPrincipal` and into libp2p's peer identity; the first is faster and throwaway.
3. ~~Does the libp2p PeerID bind to the user's existing P256 identity?~~ **ANSWERED 2026-07-24:**
   yes — per-device key signed by the person key. See `decision-identity-model.md`.
4. Is a self-hosted internet-facing relay needed BEFORE libp2p lands? That is the only thing that
   would justify building certs on the interim transport.
