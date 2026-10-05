---
name: port42-compose
description: Use when one Port42 port should feed another, when building a pipeline of ports, or when you want to be woken by a port's events instead of by a mention. Covers publish and subscribe, pipe stages that run off the desktop, what runs off screen, and watching a port.
---

# Ports feeding ports

## Publish and subscribe

A port says what it has with `port42.port.publish(kind, payload)` from its own page, and another port
listens with `port42.port.subscribe(id, fn)`. Input goes in with `port.push`; state comes out with
`port.publish`. Never make a consumer reach in with `port.exec` to read another port's state.

- Events are namespaced: a port publishes `state`, subscribers see `port.state`.
- Each event carries the port's token at that moment, so a subscriber can write next without
  re-reading.
- Publishing belongs in the port's source HTML, not injected later with `port.exec`, which a reload
  loses.

A three-stage pipe (produce, transform, render) is three ports: each subscribes to the one before and
publishes for the one after. No code outside the ports.

A stage may be in another space. Subscribing to it needs nothing; reading, pushing to or editing it
needs the person's grant, asked once on a card, and names it by id (see `port42-ports`, A PORT IN
ANOTHER SPACE).

## Stages nobody needs to see

Make the middle stages run off the desktop (`presentation=running`, see `port42-ports`). They run in
full with no tile. Off screen a port still receives every event at full rate; a running port's timers
also run at full rate, while a paused port's or one in another space slow to about once a second.
Off-screen timers never stop, though a long interval may fire a little late. For anything that repeats or
polls, use `port42.timer.every(seconds, fn)` instead of `setInterval`: Port42 runs it at full rate wherever
the port is; only a port the person paused slows to about once a minute, catching up when shown again.

## Being woken by a port

An agent can watch a port and be woken by its events rather than by a mention:

    port42 companions.watch port=<id>
    port42 companions.watch port=<id> kinds:='["console"]'
    port42 companions.unwatch port=<id>

- Default kinds: `["port"]`, the port's own published events. Others: `console` (a log line or
  error), `state` (an edit), `chat` (every post in its chat), or one exact kind such as `port.alert`.
  `terminal.output` can never wake you.
- Events that arrive while you are working are handed to you together when you finish. After a quiet
  spell the first event waits a second, so a burst arrives as one.
- Your answer goes to that port's chat. Your own edits to the port do not wake you.
- `every:=30` sets the least time between wakes. A watch pauses after 60 wakes in an hour and says so
  in the port's chat; watching again resumes it.

`reference.md` in this skill lists the methods.
