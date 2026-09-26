# A virtual network of your own hosts

Measured against `nautilus` at `51eab10`, 2026-09-26. Not iOS-specific: the same primitive serves a
desk and a laptop, a machine at home and one in a cloud network, and a phone.

GM, 2026-09-26: a device is "a peer, but it is your virtual network of hosts, which has some sort of
privileged access control to be able to pool together in that way."

## The primitive Port42 does not have

Two grant shapes exist today. A **client** is enrolled on one instance and gets grants per method and
per port object. An **invite** (D10) names one port and grants that port only.

A mesh is neither. It says **this host is me**, and the ports of every host in it pool into one
namespace. That is a membership fact, not a per-port grant, and nothing in the current model
expresses it.

What it needs, none of which exists:

- **A principal class above "client".** `Principal.swift` and `ClientRegistry.swift` key a caller to
  an instance. A mesh needs "this peer id is the same person as me", so enrolling a device is one act
  rather than one invite per port. Revoking it is one act too: losing a phone removes a host and
  touches no port grant.
- **A namespace that spans hosts.** The built address is `port42://space/<spaceId>/<portId>` and the
  remote form adds a peer id (`PortAddress.swift:8`, `PortObject.swift:34`). Addressing by host is
  correct for a stranger's port and wrong for your own: pooling means a port is a port, with the host
  as an attribute rather than a prefix you have to know.
- **A trust root that is not a token.** Phase 4 authenticates a peer id through the Noise handshake,
  which is the right primitive to key membership on. The question a mesh adds is who may join, and on
  whose say-so.
- **A policy for what pools.** Every port, or only ports a host offers? A phone should probably not
  publish its camera into the mesh by default.

## What exists today, measured

**The transport is not there.** `GatewayProcess.swift:90` spawns the gateway with
`["-addr", "127.0.0.1:\(port)"]`, so it listens on loopback only. `TunnelService.swift` and ngrok
were deleted in Phase 1. No other device can reach a Port42 instance at all right now. Phase 4's
libp2p work is what changes this, with mDNS on a LAN as milestone B.

**The invite mechanism: the door is open, the payload is dead.**

| Piece | State |
|---|---|
| `port42://` URL scheme | Registered, `Info.plist:42-45` |
| The app's deep-link handler | Alive, `Port42App.swift:18-22` installs the `kAEGetURL` Apple Event handler |
| The landing page | Alive, `gateway/main.go:125` `handleInvite`, `/invite` routed |
| Invite payload types | **Gone.** No `AgentInvite.swift`, `SpaceInvite.swift` or `ChannelInvite.swift` remain |
| What the landing page emits | **Stale.** It reads `id`, `name`, `key`, `token` and builds `port42://channel?...`, which is the messaging hub's vocabulary, deleted in Phase 1 |

`TransitionRoot.swift:280` states the same thing in the code: "The deep-link door stays; what came
through it is gone."

So the recollection that "the invite mechanism was taken out" is half right in a way that matters:
the mechanism's shell survived deliberately, and its content did not. Restoring it is not undoing a
deletion. It is writing a new payload in the port vocabulary, a generator for it, an accept path, and
a landing page that speaks ports instead of channels.

**The guest page is intact and unreachable.** `gateway/guestpage.go`, 182 lines, `/port` routed. It
needs two things it does not have: a way to reach the machine (transport) and a credential to arrive
with (invite payload).

## What this implies for sequencing

The mesh and the per-port invite are not the same feature and should not be built as one.

- **The invite (D10)** is for someone who is not you: one port, one grant, burned on use. The landing
  page and the browser guest page serve it.
- **The mesh** is for machines that are you: enrol once, pool everything the host offers, revoke by
  device. No landing page, no per-port act.

They share the transport and the peer id, and they diverge everywhere above that. Phase 4 currently
describes the first. The second is worth writing down before that work starts, because a membership
model retrofitted onto per-port grants is the kind of thing that ends up as a special case in every
authorization path.

## Open

- **Who may join a mesh, and on whose authority?** A device with the user's Apple account, a device
  the user enrols by hand from an existing host, or a device that presents a mesh credential.
- **Does a mesh have a name, or is it just "mine"?** A shared household or a small team is the same
  shape with a different trust root, and deciding now costs nothing while deciding later costs a
  migration.
- **What happens when two hosts hold ports with the same id?** Pooling makes collisions possible in a
  way per-host addressing does not.
- **How does a sleeping host behave?** A phone suspends and a laptop closes. A mesh where half the
  hosts are unreachable most of the time needs an answer better than a failed dial.
