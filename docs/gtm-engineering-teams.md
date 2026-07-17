# GTM: Engineering Teams

**Your agent already lives in a terminal. Give it a room.**

---

## The beachhead

Engineering teams. The only market that has already crossed the gap:

- **They have agents in production use today.** Claude Code, Cursor, Codex. Nobody needs convincing
  that AI can do the work; they watched it happen this morning.
- **They feel the harness problem without a word for it.** The agent runs in a pane, alone. Its
  output is text about what it did. Nobody else on the team can see it. It has no memory of the room.
  When it needs permission to touch something real, there's nobody there to ask.
- **They buy bottom-up.** One person installs a DMG. No procurement, no pilot committee, no
  compliance review before the first run.
- **They tolerate early software that's honest about being early.**
- **They build every other vertical's harness.** The hospital's harness gets built by the hospital's
  engineers. The horizontal is the distribution channel into the verticals.

## The wedge

A CLI agent (Claude Code, gemini, codex) runs as a command companion: a first-class member of a
space, in a native terminal port, addressable, on the same bridge as every other surface. The agent
stops being a process in a pane and becomes a participant in a place.

Then it builds you a surface. Not a report about the data. The chart, live, that you both drive. That
is the moment the harness stops being a metaphor.

## The motion

**Land.** One developer, one machine, no account. Notarized DMG, local-first, offline, your keys.
First run reaches *"my agent is in a room and it just made me something I can touch"* without a
signup. This ships today.

**Expand.** A team space: two humans and their agents, E2E encrypted, synced between instances.
Downstream of cross-instance addressing, which is the keystone and is not built.

**Monetize.** Open questions, stated:
- Local and solo has near-zero marginal cost and is the acquisition engine. Probably free.
- Teams need a relay with a public IP. Real cost, natural paid line.
- BYO-key today, so no token resale. Sovereignty as a feature, no usage margin as a constraint.
- Open-source v1 is unrefreshed and interacts with the thesis: you cannot tell a company "own your
  harness" while renting them a black box. That may force the licensing answer before revenue does.

## Proof

The pitch says companies build their harness inside Port42. The first company doing that is Port42.
That's not a marketing tactic, it's the deepest evidence available: a real harness, carrying real
work, under the hardest user in the market. Every surface exists because the work demanded it. Every
failure lands on the founder first.

2026-07-16: an agent working inside Port42 found that every permission-gated call over its own
gateway hangs forever, proved it with three probes, and wrote the fix. Thesis, failure, and repair in
one session.

Doing it in public is how that proof travels. The build log isn't the marketing; the build is. The
log just lets people watch. Engineering teams don't believe demos. They believe a bug hunt.

The `port42-ports` skill points the same lever outward: package the port-authoring knowledge so any
agent builds a correct surface without Port42's context. That's how the harness reaches teams who
never installed anything.

## Blockers: first-run is the funnel

1. **Permissions.** A new developer's first act is calling the API from Claude Code. Gated calls hang
   indefinitely with no prompt anywhere (verified in dev 2026-07-16: `notify.send`, `clipboard.read`,
   `terminal.exec` all time out). In progress.
2. **One API.** `port.getHtml` doesn't exist over the gateway; the real tool is `port.get_html`.
   Dotted methods map naively to underscores, so every camelCase method in the published docs is
   unreachable. Ten minutes of `Unknown tool` on documented calls, before the pitch starts.
3. **The skill**, so the knowledge travels to agents outside the app.
4. **Ports must idle and evict**, before anyone runs more than a few.
5. **Teardown must be exhaustive**, before anything runs unattended.

These are the existing engineering backlog. The GTM reorders nothing.

## Metrics

Retire tool count (84 tools, 244 to 84 switches). It counts artifacts; the thesis is about work
getting done in a place.

- Ports created by companions, and ports **driven** after creation.
- Spaces with more than one human.
- Return the next day.
- Ports built by someone else's agent, post-skill.
- Work produced that wasn't a chat message.

None of this is instrumented yet.

## Risks

- **Cursor, Claude Code, and the IDE vendors grow the room themselves.** They own the surface devs
  already sit in. A harness is not an editor feature, but that's an argument, not a moat, until
  addressing lands.
- **Devs may not want a new desktop.** The heaviest ask in the product. The wedge dodges it; if the
  shell is the thing people won't cross, the wedge becomes "a space you visit," not "the desktop you
  live in." Test this first: cheap now, expensive late.
- **Teams may not need shared agent surfaces yet.** Solo dev plus agent is proven demand. Two devs
  and two agents in one room is a bet. If expand doesn't pull, Port42 is a strong single-player tool
  with a multiplayer story.
- **The thesis is a belief.** Nothing in the repo proves companies want their own harness. The first
  external design partner is worth more than further architecture.
