# Port42: The Harness

**Every company is going to want its own harness for AI. Port42 is that harness.**

*Draft, 2026-07-16. Replaces the Oct-2025 one-pager ("Reality Compiler for Personal Computing").
Figures from that version are deliberately not carried forward. See the working notes.*

---

## Everyone bought the horse. Nobody has the collar.

For most of recorded history people had horses and couldn't use them for work. The old
throat-and-girth harness ran across the animal's windpipe: the harder it pulled, the more it choked
itself. So horses carried messages and nobles, while oxen (slower, dumber, strong in the wrong ways)
pulled the ploughs. Then the horse collar arrived in Europe around the 10th century. It moved the
load onto the shoulders. The same animal, unchanged, could suddenly pull a plough through heavy soil
all day. Within a few generations European agriculture had reorganized around it.

The horse was never the bottleneck. The harness was.

Every company now has the horse. Frontier models are extraordinary, they get better every quarter,
and they are available to your competitors at the same price on the same afternoon. **The model is
not where the advantage is, and everyone has quietly worked this out.** What no company has is the
harness: the thing that connects that power to the actual work, in their actual context, under their
actual control.

You can see the gap from your desk. It's the copy and paste. Out of the agent, into the work, back
out again, a hundred times a day. Every one of those is a place the agent should have had hands and
didn't. **The human is the integration layer.** That isn't a workflow. It's a missing harness with a
person standing in for it.

## Everyone is building a harness. Theirs.

The vendors know the harness is the prize. Claude Desktop, Codex, Cursor: they have surfaces, they
keep context, they are racing to be the place your work happens. Nobody needs persuading that the
harness matters. That argument is over, and it's the strongest confirmation this thesis has.

It's also the problem. Their harness is built to hold their model, and to hold you. Your work lives
inside their experience, on their terms, moving at their roadmap. You are a tenant.

And it only works if everyone brings the same horse. A vendor's harness assumes your whole team
standardized on one model, permanently, while the frontier moves every quarter and your best engineer
wants a different tool by Thursday. **A harness that only fits one horse isn't a harness. It's a
saddle for one animal.**

## So every company builds its own

The harness is not a feature of the model. It's the shape of *your* work: your surfaces, your rules,
your people, your data, the memory of what happened here last week. That is exactly the part a model
vendor cannot ship you, because it isn't theirs to know. And it's exactly the part you cannot afford
to rent.

A hospital's harness is not a law firm's harness is not a trading desk's. The horizontal case,
developers, is the same shape with different surfaces.

Today they build it from scratch, badly, out of glue: a chat wrapper, a pile of API keys, a
permissions story invented in a meeting, and no shared surface anywhere. Port42 is that harness, as a
platform, so the company builds *their* harness instead of the plumbing under it. Your keys.
Anthropic, Gemini, any OpenAI-compatible endpoint, a local model. CLI agents like Claude Code sit in
the room as first-class members. **The harness is yours; the horse stays a choice you keep
making.**

## What the harness actually is

- **A space is a room.** People and AI companions are both *in* it. It persists: it has memory, a
  history, and a working directory on real disk. The AI has a place, and the place remembers.
- **A port is a live surface both of you drive.** Not the agent sending you a report about the chart
  or opening it in a web browser. You and the agent *in* the chart, at the same time, on the same
  surface. Web or terminal; a port is the unit the room is made of.
- **One bridge, two callers.** A human reaches the clipboard, the screen, the files, the terminal
  through the UI. An agent reaches the same methods as tools. Same surface, same permissions, one
  implementation. That symmetry is the whole design, and it's already how the product works.
- **Permission is the leash.** Every capability is gated per category, per asker, and revocable. The
  harness's job is not only to transmit power. It's to make power *safe to apply*. This is the part
  the glue-code version never has, and the reason those pilots quietly never ship.

## Chat already proves it. You just haven't noticed.

Nobody screen-shares a chat window. You sync the messages, and each end renders its own chat,
natively. It would be absurd to stream pixels of a conversation across the internet.

That's the model for *every* surface. Chat just got there first, because messages were always data.
Port42's bet is that a port is the same kind of object: you send it queries and it emits a stream, so
it can be driven by a human, or an agent, or a peer on another machine, through one contract.
Streaming pixels is what you do to surfaces you don't own. It's the fax machine of collaboration:
it works, and it throws away everything that made the thing a thing.

A port describes itself completely, so it moves. Send one to another instance (different machine,
different database) and it arrives running. There is nothing to export. What doesn't travel yet are
the *addresses* it refers to: **the copy is free; the addressing is the remaining work.**

## What's real today

Port42 ships as a Mac app. The desktop *is* live ports: the conventional windowed mode was
deleted in July, not deprecated. Spaces, companions (both API models and CLI agents like Claude
Code), the unified bridge across ~40 capability methods, local-first storage, end-to-end encrypted
sync between instances, and full version history for every port. It is used daily to build itself.

## Go to market: engineering teams first

**Your agent already lives in a terminal. Give it a room.**

Engineering teams are the only market that has already crossed the gap above. They don't need
convincing that an agent can do the work; they watched it happen this morning. They feel the harness
problem daily without a word for it: the agent runs in a pane, alone, reporting text about work
nobody else can see. 	And they buy bottom-up. One person installs a DMG, with no procurement between
them and the first run.

They are also how every other vertical gets reached. The hospital's harness will be built by the
hospital's engineers. The horizontal isn't a detour from the verticals; it's the channel into them.

**Land:** one developer, one machine, no account. Local-first, offline, your keys. First run reaches
*"my agent is in a room and it just made me something I can touch."* That ships today.
**Expand:** a team space, two humans and their agents, encrypted, synced. That one is downstream of
cross-instance addressing, which is the keystone and isn't built.
**Prove:** the first company building its harness inside Port42 is Port42. Every surface exists
because the work demanded it, and every failure lands on me first. Doing that in public is how the
proof travels: engineering teams don't believe demos, they believe a bug hunt.

*Full plan, blockers, metrics and risks: `gtm-engineering-teams.md`.*

## Why me

I started at the terminal when I was eight, and the thing I remember is that it was *immediate*:
thought went in, reality came out. Then I spent twenty-five years building platforms at 500M-user
scale and watched that immediacy get renovated away, one window at a time.

Port42 is built with Port42. Every claim above is one I use before I make it.

---

*Working notes, verification status, the metaphor bench, and the full ships-vs-direction audit:
`one-pager-working-notes.md`. **Traction and ask figures from the Oct-2025 version are stale and
intentionally absent. They must be refreshed before this goes to anyone.***
