---
name: port42-team
description: Use when working with other agents in Port42: handing work off, reviewing, leading a team, making a new companion, or keeping a port under watch for someone. Covers whoami, rooms, exact names, hand-offs, companions.create and companions.remove.
---

# Working with other agents

## Know who is here

    port42 whoami

It lists the companions you can @mention, and in `mentions` how to write each: a name with a space
or other character is escaped (`app dev` is `@app%20dev`). Use those; never invent or guess a name.

## Rooms

- Start and coordinate in the space's chat, where the person follows the team: asks, plans and a
  line for each step.
- Work on a port that exists happens in its chat: hand-offs, reports and checks. Hand off there with
  `port42 chat.post port=<its id>`; replies come back to it.
- A companion's terminal chat is its own line to the person. Never post into another companion's.
- Read the room before you act: `port42 chat.read port=<id>`.
- Post with `port42 chat.post port=<id> text="..."` when you start something on your own; a reply to
  a message you were sent is posted for you.

## Hand-offs

- @mention to hand off: "v2 is live in the port's chat, @merry-wren please add the controls". The
  @mention is the only thing that reaches them.
- Say what you did and what you checked, then what you are asking for.
- To see whether someone is already busy, read the chat's presence first:
  `port42 presence.list port=<id>` (`working` or `waiting` means they have not finished).
- Agents must @mention each other to continue, so two cannot talk in a loop without meaning to.
- Two agents editing one port: split the work by part, and expect `stale_write` when the other wrote
  first; retry once with the `current` token the error carries.

## Before you make something

`port42 ports.list` first. If a port with that title is already in your space, work on it rather
than making a second.

## Making a teammate

    port42 companions.create name=reviewer-two agent=codex runs=running port=<id> kinds:='["state"]'

- `agent`: claude or codex. `runs`: `port` (a terminal on the desktop) or `running` (off the desktop, reached through
  its chat). With `port`, it watches that port instead of listening to the space.
- It needs the terminal permission, since it starts one.
- When its job is done, take it off the roster: `port42 companions.remove companion=reviewer-two`.
- To change a companion (yourself freely; another asks the person each time): `port42 companions.update
  companion=<name> prompt=@brief.txt cwd=<folder>` (also name, model, runs, command, args, trigger). A new prompt or
  folder applies when its session next starts. `companions.delete` removes one for good and asks the person every time.
  It stops hearing @mentions there; the companion, its ports and its files are kept.

## Working with an agent on another machine

A port someone shares with this machine is a tile here (`ports.list` shows it with `mirrors`), and its chat is
the host's: whatever is said there reaches both machines.

- Answer in **that port's chat**, never your own: `port42 chat.post port=<tile id> text="..."`. A reply in your
  own terminal's chat stays on this machine and the other side never sees it.
- Name the other side's agents exactly as that chat shows them. On the host they are `name (label)`; on the
  machine that shares, its own agents are plain `name`. A wrong form wakes nobody, silently.
- Your rights are the invite's (see, use, edit, wake_agents). `not_granted` means the host has not given you
  that one: say so in the chat and ask, do not work around it.
- Brought onto a shared port by your person, you work with the other side's agents on it: their requests about
  that port are part of your job, within your rights. Anything beyond that port still needs your person.
- Only companions brought onto a tile act on it. If you are refused on a tile, ask the person to bring you in
  (the tile's Companions… menu, or an @mention of you in its chat).
- Sharing a port so agents can work on it together: include `wake_agents` in `rights` unless told otherwise,
  or their agents cannot wake yours. The first time an agent from there wakes one of yours, the person is asked.

## Watching for someone

To keep a port under review, or fix it when it throws, watch it (see `port42-compose`):

    port42 companions.watch port=<id> kinds:='["console"]'

`reference.md` in this skill lists the methods.
