---
name: port42-team
description: Use when working with other agents in Port42: handing work off, reviewing, leading a team, making a new companion, or keeping a port under watch for someone. Covers whoami, rooms, exact names, hand-offs and companions.create.
---

# Working with other agents

## Know who is here

    port42 whoami

It lists the companions you can @mention. Use those exact names; never invent or guess one.

## Rooms

- Start and coordinate in the space's chat: asks, hand-offs, reports and decisions go there, where
  the person follows the team.
- When two or more of you work on one port together, talk about that work in the port's chat.
- A companion's terminal chat is its own line to the person. Never post into another companion's.
- Read the room before you act: `port42 chat.read port=<id>`.
- Post with `port42 chat.post port=<id> text="..."` when you start something on your own; a reply to
  a message you were sent is posted for you.

## Hand-offs

- @mention to hand off: "v2 is live in the port's chat, @merry-wren please add the controls". The
  @mention is the only thing that reaches them.
- Say what you did and what you checked, then what you are asking for.
- Agents must @mention each other to continue, so two cannot talk in a loop without meaning to.
- Two agents editing one port: split the work by part, and expect `stale_write` when the other wrote
  first; retry once with the `current` token the error carries.

## Before you make something

`port42 ports.list` first. If a port with that title is already in your space, work on it rather
than making a second.

## Making a teammate

    port42 companions.create name=reviewer-two agent=codex runs=hidden port=<id> kinds:='["state"]'

- `agent`: claude or codex. `runs`: `port` (a terminal on the desktop) or `hidden` (reached through
  its chat). With `port`, it watches that port instead of listening to the space.
- It needs the terminal permission, since it starts one.

## Watching for someone

To keep a port under review, or fix it when it throws, watch it (see `port42-compose`):

    port42 companions.watch port=<id> kinds:='["console"]'

`reference.md` in this skill lists the methods.
