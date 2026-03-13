# Gateway Security Audit Report

**Date**: 2026-03-13
**Scope**: `gateway/gateway.go`, `gateway/main.go`, `gateway/store.go`
**Context**: Hardening the gateway for public hosting scenarios (beyond localhost/self-hosted)

## Executive Summary

The Port42 gateway was audited for security vulnerabilities relevant to exposing it on a public network. Six critical and high-severity issues were identified. Four remediations were implemented and shipped, two remain as future work.

## Findings and Remediations

### 1. Mandatory Authentication [CRITICAL] -- FIXED

**Before**: Auth was optional. When `authVerifier` was configured, peers without identity tokens were still allowed through with a log warning.

**After**: When `authVerifier` is set (public hosting mode), peers that don't provide an identity token are rejected with `"authentication required"`. Localhost mode (no verifier) remains permissive for local development.

**File**: `gateway.go` lines 218-237

### 2. Channel Join Token Enforcement [CRITICAL] -- FIXED

**Before**: `joinChannel()` accepted any peer for any channel. Tokens were generated and validated cosmetically but joining was never blocked.

**After**: New members (not the channel creator, not an existing member) must present a valid single-use invite token. Enforcement is strict when `authVerifier` is enabled (public hosting). Localhost mode allows tokenless joins since channel UUIDs provide 128-bit entropy as implicit proof of membership.

**File**: `gateway.go` lines 395-415

### 3. Message Size Limit [HIGH] -- FIXED

**Before**: No limit on WebSocket message size. A malicious peer could send arbitrarily large payloads.

**After**: `conn.SetReadLimit(64KB)` applied to every connection. The WebSocket library terminates connections exceeding this limit.

**File**: `gateway.go` line 265

### 4. Per-Peer Rate Limiting [HIGH] -- FIXED

**Before**: Zero rate limiting. A peer could flood the relay with unlimited messages, typing indicators, token requests, or channel joins.

**After**: Sliding-window rate limiter at 30 messages/second per peer. Excess messages receive an error response and are dropped without processing.

**File**: `gateway.go` lines 66-82 (Peer.rateOK), line 272 (enforcement)

### 5. Input Validation [HIGH] -- FIXED

**Before**: No length limits on peer IDs, channel IDs, sender names, or companion ID lists. Unbounded maps for channels, tokens, and stored messages.

**After**: Enforced limits:
- Peer ID: 128 chars max
- Channel ID: 128 chars max
- Sender name: 256 chars max
- Companion IDs per join: 20 max
- Channels per peer: 50 max
- Tokens per channel: 100 max
- Stored messages per peer: 1000 max (was already capped, now explicit constant)

**File**: `gateway.go` lines 17-26 (constants), lines 210-215 (peer validation), lines 376-388 (join validation), line 505 (token cap)

### 6. No TLS [HIGH] -- NOT FIXED (by design)

**Status**: The gateway listens on plain HTTP/WebSocket. TLS termination is expected to be handled by a reverse proxy (nginx, Caddy, or ngrok).

**Rationale**: Adding TLS to the gateway binary would require certificate management (ACME, Let's Encrypt) which adds complexity. The bundled ngrok tunnel already provides TLS for the current remote hosting flow.

**Recommendation for production**: Place behind Caddy (auto-HTTPS) or nginx with certbot.

## Remaining Gaps (Future Work)

| Gap | Severity | Description |
|-----|----------|-------------|
| CORS wildcard | Medium | `OriginPatterns: []string{"*"}` allows any website to open WebSocket connections. Should restrict to known origins for public hosting. |
| No token expiration | Medium | Join tokens persist indefinitely in memory. Leaked tokens could be replayed. Add a TTL (e.g., 24 hours). |
| No nonce expiration | Low | Pending auth nonces are tracked but never expired. Memory leak if many connections drop before completing auth. Add a 5-minute TTL. |
| No connection rate limiting | Medium | Per-message rate limit exists, but no limit on connection attempts per IP. Rapid reconnect spam could exhaust memory. |
| No message replay protection | Low | Messages use client-generated IDs with server-side dedup for storage, but a network attacker could replay captured WebSocket frames. TLS (via reverse proxy) mitigates this. |
| SQLite not encrypted at rest | Low | Message history stored as plaintext JSON in SQLite. Content is already E2E encrypted (AES-GCM per channel), so the gateway only stores ciphertext blobs. Disk encryption (FileVault) provides the at-rest layer. |
| Log rotation | Low | Gateway logs to a single file with `O_TRUNC` on restart. No rotation or size limits for long-running instances. |

## Test Coverage

38 tests total covering the security hardening:

- **Auth enforcement**: 8 tests (challenge/nonce, token verification, rejection, replay prevention)
- **Token/channel access**: 4 tests (strict mode, permissive mode, valid token, rejoin)
- **Rate limiting**: 1 test (flood detection)
- **Input validation**: 2 tests (oversized peer ID, oversized channel ID)
- **Data integrity**: 4 tests (serialization, persistence, mapping)
- **Message store**: 9 tests (CRUD, dedup, pruning, ordering, restart survival)

## Architecture Notes

The security model has two modes:

1. **Localhost mode** (no `authVerifier`): Permissive. No auth required, tokenless joins allowed. Suitable for self-hosted/bundled gateway where the attack surface is the local machine.

2. **Public mode** (`authVerifier` configured): Strict. Sign in with Apple required, invite tokens enforced for channel joins. Suitable for exposing the gateway on the internet.

This dual-mode design avoids breaking the self-hosted experience while enabling secure public hosting.
