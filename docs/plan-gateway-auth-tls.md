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

### P2 — TLS
Two different problems wearing one word:
- **Tunnelled sharing** already has TLS: ngrok terminates HTTPS at its edge. Nothing to do.
- **A self-hosted remote relay** over the internet has none. That needs real certs
  (Let's Encrypt / a reverse proxy), which drags in a hostname, renewal, and a deployment story.
- **Local HTTPS is mostly theatre**: a self-signed cert on loopback buys little once P0 and P1 land,
  and costs every caller a trust-store dance. Do it only if something concrete requires it.

### P3 — origin + CSRF hardening
Explicit `CheckOrigin`, and a look at whether a malicious page can reach `/call` with a
simple-request POST (no preflight). Cheap once P1 exists, since a missing token fails the request
before origin matters.

## Testing

`gateway_httpcall_test.go` already exercises `/call` end to end, so P1 gets a real test: a call with
no token is rejected, a call with the token succeeds, and the token is not logged. P0 is asserted by
checking the listen address the app passes. TLS is verified by hand at whatever deployment lands.

## Open questions for GM

1. Is anything today deliberately hitting the gateway from another device on the LAN?
2. One install-wide secret to start, or go straight to per-caller tokens with scope?
3. Is a self-hosted internet-facing relay a real target, or is ngrok the sharing story for now?
   The answer decides whether P2 is a week or a no-op.
