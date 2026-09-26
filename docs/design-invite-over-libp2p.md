# The invite, redesigned for libp2p

Against `nautilus` at `51eab10`, 2026-09-26. A design note, not an approved plan. Companion to
`docs/research-host-mesh.md`, which covers meshing your own machines; this covers giving someone
else access to one thing.

## What libp2p changes

The old invite carried a secret. A link held an `id`, a `name`, an encryption `key` and a `token`
(`gateway/main.go:125`), and whoever held the link held the access. That shape exists because the
transport could not say who was calling.

libp2p's Noise handshake authenticates a peer id on every connection, so the transport can. That
turns the invite from a credential into an **enrolment coupon**:

- the link carries **no access**, only enough to find the host and name what is offered,
- redeeming it binds **this peer id** to a grant on the host,
- the coupon is then dead, and the grant is attributable to a peer forever after.

This is strictly better than a bearer token in three ways. A stolen link is worthless once redeemed
rather than worthless once expired. Revocation names a peer rather than invalidating a secret. And
the audit trail says who, not what.

**The browser lane works the same way.** js-libp2p gives a browser a peer id over WebRTC-direct or
WebTransport, so a guest page generates a key pair, redeems the coupon, and is thereafter a named
peer with a grant. That is what makes D10's "the same invite opens in Port42 or in a browser" true
rather than two mechanisms wearing one URL.

## The payload

One type, not three.

**Port invite.** Names a peer id, a port, a capability set, and a redemption nonce. Everything else is
presentation.

**Space invite is the same type.** A space is a port that holds other ports, so inviting to a space is
inviting to a port. This resolves D10's "sharing a whole space is deferred" into a question that is
not about invites at all, below.

**Agent invite goes.** It described which companion joins, which is the inviter deciding staffing on
the invitee's machine. Under the port model the recipient subscribes whichever of their own
companions they like to the port they were given. Access and personnel stop being one act.

A payload therefore carries: the host peer id, reachability hints (relay addresses, mDNS is
discovery not payload), the port address, the capability set, a redemption nonce, an expiry, and a
display name for the landing page. Nothing secret.

## The fork this exposes: does a grant on a container cascade?

A space is a port that holds ports. So an invite to a space either

- **grants the container only**, and the guest sees a space with contents they cannot open, or
- **cascades**, and the guest gets everything the space holds, including ports added later.

Neither is obviously right and the codebase has not had to answer it. `PortObject.swift:9-27` already
notes the shape: `caller -> port -> action -> permission`, with port 0 as the machine itself and the
object slot built but barely used ("every grant in production is a port 0 capability"). Port 0 being
"never invitable" is the same question answered once, by hand, for the one case where cascade would
be catastrophic.

Worth deciding explicitly rather than falling into. A cascade that includes future contents is a
standing grant on a container, which is a different promise from "here is my chart".

## Replication, which is the part that is not easy

An invite decides who may act on a port. It says nothing about where the port's state lives, and that
is the open problem. A port has three kinds of state and they replicate differently:

**1. The transcript.** Append-only by D1, one per port, a file the chat port owns. This is the easy
case: an op log with per-entry identity converges without a CRDT library, and `chat.read` already
returns entries carrying `seq` and `at`.

**2. Declared storage.** The storage service's key-value state. Replicable with the concurrency
control that already exists: `token_required` and `stale_write` with `current` in the error
(`BridgeErrorCode.swift:71`) is optimistic concurrency, which is precisely a single-writer merge
rule. A guest that writes against stale state is already told so and already retries.

**3. The live surface.** A web port's DOM and JS heap. **This does not replicate at all.** It can only
be re-derived by replaying the inputs that produced it. Any design that promises "the port works
offline" is promising this one, and cannot deliver it without the port itself being written to
support it.

That taxonomy suggests three honest modes rather than one:

| Mode | What the guest holds | Works when the host is offline | Fits |
|---|---|---|---|
| **RPC** | nothing | no | a stranger's shared port, scenario 4, the guest page today |
| **Mirror** | transcript and storage, cached; writes go to the host | reads yes, writes no | a phone watching your desk |
| **Converge** | both sides write, an op log merges | yes | a mesh where hosts sleep, which is what phones do |

Port42 is at RPC today and the CAS token means Mirror is a smaller step than it looks. Converge is a
real project and should not be smuggled in as an implementation detail of "the phone works offline".

## What to settle before building

- **Does a container grant cascade to contents, including future ones?**
- **Which replication mode is promised per port type?** A chart can be RPC forever. A chat port on a
  phone is the one that wants Mirror, and it is also the one that is cheap, because a transcript is
  an op log.
- **Where does a redeemed grant live when the host is not the only host?** In a mesh, a grant made on
  the laptop should probably be visible from the desk. That is replication of authorization state,
  which is the same problem one level up.
- **What does the landing page become?** It currently speaks channels. Under this design it needs the
  host's display name, the port's title, what is being granted, and a redeem button, and it must work
  for a visitor with no Port42 installed.
