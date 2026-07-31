# Invite taxonomy: what a link means, and what accepting one does

**Opened 2026-07-31**, before slice-02 milestone B step 2 adds another one. Written as a thing to
argue with rather than encoded quietly in code.

## The axis that was not named: ACCESS versus RECIPE

Every link today is one of two fundamentally different things, and they have been sharing a grammar.

**Access** — accepting it reaches something of MINE. It carries a location and a credential, my
machine is involved from then on, and revoking has to be possible.

**Recipe** — accepting it builds something of YOURS. It carries a definition, nothing of mine is
exposed, there is nothing to revoke, and the sender could go offline forever with no effect.

`port42://agent?` is a recipe. Everything else is access. That is why it always felt like the odd one
out. **It is also going away** (GM, 2026-07-31): LLM-mode companions are fragile, brittle and not
that powerful, and are not going to be supported this way. So the recipe family empties, and every
remaining link is access. Recorded because the distinction still explains the history.

## What exists, as built

| link | family | carries | accepting does |
|---|---|---|---|
| `port42://space?gateway&id&name&token` | access | the host's gateway URL (ngrok tunnel), space id + name, a space join token | **writes the host's gateway into `UserDefaults["gatewayURL"]`, reconfigures sync, and joins the space.** The joiner LEAVES their own gateway |
| `port42://space?…&key=…` | access | the same, plus the space's AES key | routes to the agent-connect sheet instead, for an external agent |
| `port42://agent?name&prompt&provider&model` | recipe | an LLM companion's definition | creates that companion locally, on the accepter's own API key. Refuses command agents (`commandAgentNotShareable`) |
| `port42://openclaw?invite=…` | access | wraps one of the above | opens the agent-connect sheet |

## Three problems

**1. One host, two meanings, told apart by a query parameter.** `port42://space?` is a space join or
an agent connection depending on whether `key` is present. That is one fact with two carriers, the
same shape as `companionId` versus `companionPrompt`, which produced a session that was a companion
in every visible respect and had no identity (see `plan-caller-identity-fixes.md` RC2). It works
until the two disagree.

**2. The recipe link covers a shrinking slice, and the answer is to delete it.**
`AgentInvite.generateLink` returns an empty string for anything that is not `.llm` mode, so native
terminal companions cannot be shared at all. With LLM mode going, this link has nothing left to
carry.

**And the hard-coded refusal was the wrong instrument anyway** (GM, 2026-07-31): *"the permission is
what decides if a companion should be shareable at all. That's a user decision, we enable it, that's
it."* A capability the code refuses on the user's behalf is the same shape as the blanket pre-grant
D12 deleted, pointing the other way: both decide for the user instead of asking.

**3. There is no way to share ONE THING.** The only access link shares a whole space, and it does it
by moving the joiner onto your gateway. Slice-02's entire demonstration is narrower than that: a port
lives on instance A, and from instance B you address it.

## The proposal

**Enrolment is not authorization.** This is the load-bearing sentence, and everything else follows
from it. Accepting an invite makes B a named ACTOR on A. It grants nothing. Grants are per capability
per object and are still asked for, one at a time, through the permission card.

**Which is what makes a PEER invite defensible after all** (GM, 2026-07-31: *"the invite is just a
way to connect to another peer, and specific space and port permissions come later"*). My first
proposal was to invite someone to a single port, on the grounds that "peer invite" sounds like
handing over a machine. That objection is about naming, not about power, and the naming can be fixed
in the copy. The connection model is the better one for ongoing work: a port invite would need a new
link every time you shared a second thing, where a peer relationship is established once and then
each object is granted as it comes up.

**What gateway access a peer actually has, stated plainly.** A connected peer can knock on every
door, and every door still needs a grant. **That is precisely the standing a local Claude Code
session already has**, which is the useful benchmark: it is a bar already accepted, not a new one.
Port 0, the machine itself, never appears in a sharing surface; it is reached, if at all, one
permission card at a time.

**The consequence to design for:** the first thing a remote peer does raises a permission card, and
that card names a client today. It must name the peer AND the instance, or the user reads "Maker
wants filesystem access" with nothing to say it came from another machine.

**One host per meaning.** No overloading, no parameter deciding which of two things a link is:

| link | family | shares |
|---|---|---|
| `port42://space?` | access | a space, a zone |
| `port42://peer?` | access | a CONNECTION to my instance. Grants nothing. **New, slice-02 step 2** |
| `port42://connect?` | access | an external agent connecting to a space (today's `space?…&key=`) |
| ~~`port42://agent?`~~ | recipe | **deleted with LLM mode** |

**Reuse the flow, not the payload.** The link grammar, the deep-link accept path in
`TransitionRoot`, the clipboard and landing page, and above all the consent shape — a human shares, a
human accepts — carry over unchanged. That is what keeps D5's pairing decision closed: there is no
unauthenticated verb and no state machine, because the name is typed by a person and the act of
accepting is the consent.

What is genuinely new is small: a payload carrying the host's PeerID and a client token minted for
the invitee, and an accept that writes a `peer` client row **instead of switching gateways**.

## Open for GM

1. ~~Should a native terminal companion be shareable at all?~~ **CLOSED 2026-07-31 (GM):** the
   permission decides, not the code. And the recipe link goes with LLM mode.
2. **Does `space?…&key=` become `connect?`**, or does the external-agent path fold into something
   else entirely now that companions are mostly native?
3. **Does a peer invite name a space?** A connection is instance to instance, but a person almost
   always wants to share something in particular at the moment they send a link. Establishing the
   peer and landing them somewhere may be one act to a user and two to the model.
4. **Is the space invite's gateway-switching still what we want?** It is a client-server move — the
   joiner abandons their own gateway — and it predates both port 0 and libp2p. Milestone B's peers
   each keep their own.
5. **Has the space invite been exercised recently?** It depends on ngrok end to end, and step 2 would
   be building on it. GM, 2026-07-31: "it works today, well I haven't tested in a while."
