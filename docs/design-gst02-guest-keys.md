# Design: GST-02, guest keys the page cannot read

Status: approved (Gordon, 2026-09-29); built on the branch that carries this file.
Designed on `main` at 6dbdb70; built on `main` at 5f3d127.

## The finding

A browser guest's identity is one Ed25519 seed, stored as hex in `localStorage` under
`port42.guest.seed` (`guest/src/guest.js:10-22`). Any script running on the invite page's origin can
read it, and with it act as that guest to every host that let it in.

The audit's fix is to hold the key as a non-extractable WebCrypto key. That cannot be done by the guest
alone, because the seed does two jobs:

1. **It signs.** The relay hello is an Ed25519 signature over `port42-relay-v1|relay|nonce|guest`
   (`guest/src/client.js:26-28, 87-88`; checked by `ed25519.Verify` in `gateway/relay/server.go:218`).
2. **It is the Noise static key.** The guest's X25519 key is the first half of SHA-512 of the seed
   (`guest/src/noise.js:24-27`, the same as `NoiseKey` in `gateway/relay/noise.go:41-49`). The host's
   responder accepts the handshake only if that static key is the Montgomery form of the Ed25519 key the
   guest names in its payload (`gateway/relay/noise.go:123-131`).

A non-extractable Ed25519 key can do job 1. It can never do job 2: WebCrypto will not hand out the
scalar, and it offers no Ed25519-to-X25519 conversion. So a guest holding one could not complete a
handshake with any host as the protocol stands.

## The protocol change

A guest holds **two** non-extractable keys, and proves they belong together inside the handshake.

- **Identity key:** Ed25519, used as today. Its public key is the guest's peer id, so hosts see the same
  identity as now.
- **Noise key:** X25519, generated independently. It is the Noise static key. WebCrypto `deriveBits`
  does the two DH operations that need it (`ss` in message 1, `se` in message 2).

### What the guest sends

The handshake stays Noise_IK_25519_ChaChaPoly_SHA256, with the prologue `port42-noise-v2`. Message 1's
payload, sent encrypted as today, becomes 96 bytes:

| Bytes | Content |
|---|---|
| 0-31 | the guest's Ed25519 public key (its peer id), as in v1 |
| 32-95 | an Ed25519 signature by that key over the binding below |

The binding is:

```
"port42-noise-v2 static|" || host peer id (52 chars) || guest ephemeral e.pub (32) || guest static s.pub (32)
```

Including the ephemeral key ties the signature to this handshake, so a captured signature cannot be
replayed with a different session. Including the host's peer id ties it to this host.

### What the host verifies

In `Respond`, for a v2 handshake, after `ReadMessage` succeeds:

1. The payload is exactly 96 bytes.
2. The signature verifies under the claimed Ed25519 key, over the binding built from the host's own peer
   id, `hs.PeerEphemeral()` and `hs.PeerStatic()`.
3. The session's remote peer id is the claimed Ed25519 key, as in v1.

The Noise handshake itself already proves the guest holds the X25519 private key (the `ss` and `se` DH
operations), and step 2 proves the Ed25519 key vouches for that X25519 key in this session. Together they
replace v1's rule that the two keys are one key.

## Where the check runs

The check is in the host's gateway, not the relay. The relay pairs streams and verifies only the hello
signature, and the Noise session is end to end (`gateway/relay/client.go:254-266` runs `Respond` in the
host's bundled gateway). So **every host app is a party**: a host accepts v2 only once it runs an app
version with the new `Respond`. relay1 changes nothing, because WebCrypto Ed25519 signatures are standard
RFC 8032 signatures that its existing `ed25519.Verify` accepts (to verify in the test plan).

## Versioning and negotiation

- **This is v2.** The prologue changes to `port42-noise-v2`, so a v2 message 1 cannot be misread as v1:
  its transcript hash differs, and decryption fails under the wrong prologue.
- **The responder tries both.** Noise fixes the prologue before message 1 is read, so a new `Respond`
  reads message 1 under v2 first, and on failure builds a fresh v1 state and reads the same bytes again.
  No framing change is needed, and a v1 initiator never notices. The cost is one extra set of DH
  operations for a v1 caller.
- **The guest learns what a host accepts from the invite.** New hosts add `"noise": [1, 2]` to the
  coupon. The coupon keeps `"v": 1`, because today's tele bundle rejects any other `v`
  (`guest/src/coupon.js:16`), and old guests ignore the new field. A coupon without `noise` means the
  host speaks v1 only. The app's own `InviteCoupon` (`Sources/Port42Lib/Services/Invites.swift:16-26`)
  gains the field as optional, so older coupons still decode.
- **Host to host is unchanged.** Instances keep their Ed25519 keys in the Keychain, not in a browser, and
  keep using v1 with each other (`Initiate`). v2 is only for guests.
- **How long v1 stays accepted.** Hosts accept v1 from guests for as long as any guest out there still
  holds a seed: at least until every browser that can make the keys has migrated, and indefinitely for
  browsers that cannot (see the fallback). Retiring v1 for guests is a separate decision, made from data
  rather than a date.

## Compatibility

The relay needs no change, so the relay column is the same for old and new. A "new guest" is a tele
bundle with this change; what it does depends on the coupon it is given.

| Guest (tele) | Host app | Relay | Result |
|---|---|---|---|
| old | old | old or new | v1, works as today |
| old | new | old or new | v1, works: the new host still accepts v1 |
| new | old | old or new | the coupon has no `noise` field, so the guest uses its v1 path. Works if it still holds a seed; if it has already migrated, it cannot join this host (see rollout) |
| new | new | old or new | the coupon says v2, so the guest uses non-extractable keys. Works |

## Rollout order

1. **App release first.** `Respond` accepts v2 and v1, and new invites carry `"noise": [1, 2]`. Nothing
   changes for any guest yet, because tele still sends v1.
2. **Then tele.** Only after hosts have updated. Sparkle adoption is what to measure, not a fixed date.
   The new bundle:
   - uses v2 when the coupon advertises it;
   - on first v2 use, imports the existing seed as a non-extractable Ed25519 key (PKCS#8 import), so the
     guest keeps its peer id and every host keeps its grants, generates the X25519 key, stores both
     `CryptoKey`s in IndexedDB, and deletes the seed from `localStorage`;
   - for a coupon without `noise` (a host that has not updated), uses the seed if it still has one, and
     otherwise tells the person to ask the sharer to update Port42 and send a new invite.
3. **relay1:** no change and no deploy.

**Invites already out there.** An invite lasts at most 30 days (`inviteMaxLife`,
`Invites.swift:68`). Invites made before step 1 carry no `noise` field and keep working on v1. Thirty days
after step 1, every live invite from an updated host advertises v2.

**Guest identities already out there.** Kept. The seed is imported, not replaced, so the peer id, and
with it every host's enrolment and rights, is unchanged. The one cost: after migrating, a guest cannot
join a host that never updated, because it no longer holds the seed.

## Browsers that cannot make the keys

The guest detects support at load with `crypto.subtle.generateKey({ name: 'Ed25519' }, false, ...)` and
the same for `X25519`, and uses non-extractable keys only when both succeed.

Where either fails, the guest keeps today's v1 path: the seed stays in `localStorage`, and the finding
stands for that browser. It still works with every host, because hosts keep accepting v1.

Support, **unverified, to check before building**: Ed25519 and X25519 in WebCrypto are reported in
Safari 17, Firefox 129 (Ed25519) and 130 (X25519), and recent Chrome releases (X25519 around 133,
Ed25519 around 137). Older versions of each fall back.

## Test plan

**Host (Go, `gateway/relay`):**
- a v2 initiator (a Go test helper that holds a separate X25519 key and signs the binding) is accepted,
  and the session's remote peer id is its Ed25519 key;
- a v1 initiator is still accepted by the new `Respond`;
- v2 refusals: a bad signature, a signature over a different ephemeral key (replay), a signature naming
  another host, a payload of the wrong length, and an Ed25519 key that did not sign;
- host-to-host `Initiate`/`Respond` unchanged;
- calibration: with the signature check removed, the refusal tests fail on assertions.

**Guest (`guest/`, node:test; Node's WebCrypto has Ed25519 and X25519):**
- a v2 handshake against the Go responder in `gateway/guest_e2e_test.go`, extended to cover v2;
- keys are non-extractable (`exportKey` throws), and survive a reload from IndexedDB;
- migration: a stored seed is imported, the peer id is unchanged, and `localStorage` no longer holds it;
- fallback: when `generateKey` throws, the guest takes the v1 path and still connects;
- a v1-only coupon after migration gives the "ask them to update" message, not a hang;
- coupon: `"noise": [1, 2]` is read, and a coupon without it means v1.

**App (Swift):** `InviteCoupon` encodes `noise` on new invites and decodes coupons without it.

**Relay (`gateway/relay/relay_test.go`):** a hello signed by a WebCrypto Ed25519 key verifies, which
pins the "relay1 unchanged" claim.

## Decisions (Gordon, 2026-09-29)

- Option A approved as designed.
- The seed is deleted on migration.
- When hosts stop accepting v1 from guests is not decided; hosts keep accepting it until revisited.
- A guest on the new keys that meets a v1-only invite is told the person sharing needs to update Port42
  and send a new link.
