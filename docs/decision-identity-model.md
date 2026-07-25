# Decision: the identity model (person · instance · actor) — 2026-07-24

*Decided with GM, 2026-07-24. The shared input to three tracks that were each about to invent their
own answer: the L2 right-of-way lease (`plan-port42-protocol-local-bus.md`), gateway auth
(`plan-gateway-auth-tls.md`), and cross-instance (`membrane/slice-02-cross-instance.md`).*

## The problem in one line

Port42 has three keypairs and one person, and nothing says which is which.

## What exists today

| Thing | Where | What it does today |
|---|---|---|
| **`AppUser` P256 keypair** | generated at setup, Keychain (`AppUser.swift`) | shown as a fingerprint on the setup screen. **Signs nothing.** An identity that exists and is inert. |
| **Apple identity token** | gateway `authVerifier` (`gateway.go:204/244`) | nonce challenge → token verify. **Switched off** (nil = disabled). |
| **`Principal`** | `Principal.swift:15` | the subject the bridge authorizes: `id`, `spaceId`, `portId`. Not a keypair. Does all the real work. |
| **libp2p PeerID** | not built (slice-02) | will be a keypair per instance. |

The mistake available here is to treat those as four candidates for one slot. They are not. They
answer **three different questions**, and the model is to name the questions.

## The three axes

### 1. WHO — the person
The `AppUser` P256 keypair, which already exists and already has a fingerprint UI. One per human,
long-lived, never leaves the machine it was made on. Today it is inert; this decision makes it the
root of the other two by having it **sign** things.

### 2. WHICH MACHINE — the instance
The libp2p PeerID: a **per-device** keypair, **signed by the person key**. That signature is the
whole point — it makes "this peer belongs to Gordon" a provable claim without the person key ever
travelling, and it lets one person hold three machines without holding three identities.

This is the Signal / Matrix device model, deliberately: device keys under an account key is
well-trodden ground, and the failure modes (revocation, rotation, a lost device) are known rather
than discovered.

### 3. WHAT IS ACTING — the actor
`Principal`. A human, a companion, or a port. **Not a keypair**, and the thing the lease actually
holds. Locally it stands alone. Remotely it is a pair: *this actor, at that instance* —
"Maker, on Gordon's laptop".

## Where the other two pieces land

They collapse out of the model rather than competing with it:

- **The Apple identity token is an authentication METHOD, not an identity.** It is one way to prove
  person identity to a relay. It maps onto the person id; it does not become one. (This also keeps
  Apple out of the trust root, which matters for a local-first product.)
- **The `/call` token is a capability, not an identity.** It MINTS a principal with a scope — "this
  caller acts as X, may do Y" — which is exactly what the bridge already models. It must not become
  a fourth id.

## The qualified principal

An actor's full name is `<peerID>/<principalId>`, with **the local peer implicit** (empty prefix).
That is deliberately the same shape as the port address slice-02 already specifies:

```
port42://<peerID>/space/<spaceId>/<portId>     the port
         <peerID>/<principalId>                 the actor driving it
```

**So the local case is the degenerate form of the remote case, not a different thing.** This is the
single consequence that matters, and it is why this had to be decided before L2 rather than after.

## Consequences, per track

- **L2 (lease).** `Lease.holder` is a qualified principal string, local-degenerate today. If it were
  bare `principal.id`, the local lease and the remote lease would be different objects and slice-02
  would have to reconcile them under load. One line now; a migration later.
- **Gateway P1 (`/call` auth).** The token mints a principal. No new identity, no separate user
  table, and grants keep keying on `principal.id` exactly as they do now.
- **slice-02 (cross-instance).** Gets identity for free instead of designing it: the PeerID is the
  instance axis, the person signature makes ownership provable, and the actor is the principal it
  already carries.

## What NOT to do (each was reachable from where we stood)

- **Don't make the PeerID the person.** A person has devices; conflating them means a new laptop is
  a new user, and every grant, lease and space membership has to be re-established.
- **Don't make the Apple token the identity.** It is a proof, it expires, and it puts a vendor in
  the trust root of a local-first product.
- **Don't invent a fourth id for `/call`.** Local callers are actors like any other.
- **Don't give companions their own keypairs yet.** They are principals without key material, which
  is correct while they run inside your instance. Revisit only if a companion needs to act on a
  machine you do not own.

## Deferred, deliberately

Revocation (a lost device), key rotation, multi-person spaces sharing a port, and whether a
companion's identity is ever separable from the instance hosting it. None of them block the three
tracks; all of them get harder if the axes are conflated now, which is the argument for deciding
this before writing the lease.

## First implementable step

Nothing needs building today. The commitment is: **holder and caller identifiers are written
peer-qualified from the start**, with the local peer as the empty prefix, so libp2p arrives as a
prefix rather than a refactor. When it lands, the person key signs the instance key and the
attestation becomes the thing a remote peer checks.
