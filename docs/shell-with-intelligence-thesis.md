# Port42 — the thesis

**The shell never got smart.** Fifty years on, the substrate where you actually
compose computing — the command line, the desktop — is still dumb. It waits. You
bring every ounce of intelligence: you know the commands, you arrange the windows,
you maintain the mess. Meanwhile every "AI product" bolts a chatbot onto someone
else's cloud app and calls it the future. Both are wrong. The chatbot has
intelligence but no hands. The shell has hands but no intelligence.

**Port42's bet: put the intelligence *in the shell*. A shell with a resident mind
that composes the machine for you — and renders the UI you need, exactly when you
need it, then throws it away.**

## The core idea: the UI is a function of need

Today's software is something you *install and maintain*. You acquire apps, arrange
windows, and pay a permanent tax in clutter and upkeep for tools you use for thirty
seconds. Port42 inverts it. The atomic unit is the **port** — a live interactive
surface (a web view or a real terminal) that a companion spins up on demand: a map,
a form, a dashboard, a shell, whatever the task's shape actually is.

And ports are **disposable by design.** A port isn't an app competing with Notion.
It's the *render of a task* — closer to the output of a command than to a program.
`ls` doesn't compete with Finder; it shows you what you need and vanishes. A port is
`ls` that can be anything, summoned by intent and evaporated when the task dies. The
UI stops being a thing you own and becomes a thing that's **continuously recomputed
from what you're trying to do.**

That's the emotional unlock nothing else offers: **a UI with no persistence
anxiety.** The desktop punished you for opening things. An intelligent shell rewards
it — spin up, use, gone, no "close 40 windows" guilt. Ephemeral is the default;
*keeping* something is the deliberate act, never the reverse.

## How it works — one substrate, two hands

A single local HTTP gateway exposes the whole machine — clipboard, screen, terminal,
files, camera, browser, automation — as one uniform API. The trick is that the *same*
API is callable two ways: as JavaScript inside a port, and as tool-use by the
companion in the conversation. Same methods, same permissions, same primitive.
**There is no real difference between "an app," "an agent action," and "a thing you
typed."** They're all calls against one bridge. The companion doesn't *describe* a
dashboard — it `port.create`s one into your space and drives it live.

## The environment is a place you own

Ports live in **spaces** — E2E-encrypted, local-first, shared with your people and
your companions. The shell makes the space the whole computer: tiles you arrange, a
zoom ladder from galaxy to space to a single focused surface, and notifications that
are *themselves* live ports peeking in from another space — which you can zoom into
and adopt, or dismiss and let go. Peek → adopt → dismiss: the new verb set of a
disposable-surface shell. Your computing environment becomes a **place you carry, not
a login you rent back.**

## Why now

Models finally cross the line where "give the agent real hands on the real machine"
beats "give it a sandboxed toy." Everyone else is racing to trap agents in *their*
cloud. Port42 puts the mind *in your shell*, with real hands on your own machine —
local-first, companion-native, recursive enough that **the tool becomes the medium
for building itself.** We design Port42 by rendering live ports inside Port42.

## The one-liner

**Port42 is a shell with intelligence** — a local, companion-native computing
environment where a resident mind composes your machine for you, the UI is disposable
and need-shaped, and your space is a place you own instead of an account you rent.

## The design law it all reduces to

> A port should be as cheap to discard as a command's output, and as cheap to summon
> as typing the next command. The intelligence turns intent into the right transient
> surface. The UI is recomputed from need — never installed, never maintained.

---

## Open questions to wrestle with

Stack-ranked by how much they can kill the thesis.

1. **The trust paradox (the core one).** "AI with real hands on your actual machine"
   is also the exact thing a security-conscious person should never install. One
   prompt-injected companion reading a malicious page can `fs.read` your keys and
   `rest.call` them out. Making "the agent can touch everything" and "I trust this
   with my terminal" true *at the same time* is the thesis's survival condition — not
   a feature. The capability model has to be legible enough that the user's mental
   model matches reality, or they approve-all out of fatigue (unsafe) or never approve
   (inert).

2. **Local-first vs. the reasons everyone went to the cloud.** Zero-install,
   cross-device, "my laptop is asleep," managed updates. The moment you add a hosted
   relay for sync/presence you reintroduce the vendor you were escaping. Where's the
   honest line between "you own it" and "you depend on us"?

3. **Who is the first user, really?** "Shell with intelligence" is a beachhead pitch,
   not a civilizational one — good. But whose hair is on fire *today*? Developers who
   want a companion with terminal + files? Pipeline builders who need an instant
   frontend? Pick wrong and you build a beautiful shell nobody urgently needs.

4. **The half-life of a port.** Disposability is the whole point, so the system must
   *respect* it. If ports pile up like browser tabs, you've built clutter. If they
   truly evaporate, you've built a UI with no persistence anxiety. The peek → adopt →
   dismiss lifecycle grammar is where this is won or lost.

5. **Disposable-by-default vs. the things you want to keep.** Some surfaces earn
   permanence (a daily dashboard, a running terminal). The shell needs a clean gesture
   for "this one stays" without dragging the whole system back into window-management
   hell. Ephemeral must stay the default; *keep* is the deliberate act.

6. **Model dependence and cost.** Every companion action is tokens; the recursive
   magic is also a cost multiplier, and the capability floor is set by frontier models
   you don't own. What are the unit economics of an always-present resident mind — and
   what's the moat the day an OS vendor ships a competent local agent with kernel hooks
   you can't match?

7. **The two-surfaces bet.** "Same API from JS and from tool-use" is elegant — but
   does the *user* ever feel it, or is it an architecture aesthetic that mostly
   benefits the builder? Worth pressure-testing whether it's a real force multiplier.

**The meta-question under all of them:** is Port42 an *OS* (platform others build on)
or an *app* (a great companion shell you use)? The API-as-substrate framing says OS;
the thing you can ship this month says app. Most roadmap decisions live in that
tension.
