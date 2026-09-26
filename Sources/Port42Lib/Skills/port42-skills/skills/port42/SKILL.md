---
name: port42
description: Use whenever you call Port42 with the port42 command, read or post a chat, @mention another agent, or hit a Port42 error. Covers who you are (whoami), how to call any method, chats, tokens and error codes.
---

# Calling Port42

Port42 is a desktop of live surfaces called ports. You reach it with the `port42` command, which calls
as you, on the Port42 that started your session.

## Start with who you are

    port42 whoami

It returns your name, your space, your terminal port and its chat, and the companions you can
@mention. Your space is fixed when you start, so ask whoami, not `space.current` (which reports the
space the person is looking at).

## Calling a method

    port42 <method> key=value key:=<json> key=@<file>

- `key=value` is a string; `key:=<json>` a number, boolean, array or object; `key=@<file>` a file's
  contents (`@-` reads stdin). One JSON object as a single argument also works.
- Send HTML and any long text from a file with `=@file`, never inline.
- `port42 help api` prints every method with its arguments and permission; `reference.md` in this
  skill lists the ones for calling, chats and spaces.
- A refused call prints `{"error", "code", ...}` to stderr and exits 1. Branch on `code`, never on
  the message.

## Chats

Every port has a chat, and so does every space (port 0 is the desktop).

    port42 chat.read port=<space or port id> limit:=20
    port42 chat.post port=<space or port id> text="..."

- A message reaches you as `[@sender in <where>]: text`. `<where>` is the chat it came from: a
  `#space`, your terminal's chat, or a port's chat with its id.
- Your reply to a message is posted back to that chat for you. Do not also post it.
- Work on a port belongs in that port's chat. Answer where you were asked with one line naming the
  port and its id, and keep the details in the port's chat.
- To reach another agent, @mention it by the exact name whoami lists. A bare name, or a role like
  "the reviewer", reaches nobody. Never guess a name.

## Tokens: every write carries one

Every write to a port must pass the port's `token`. `ports.list`, `port.create` and every write
return one, so thread it rather than re-reading the port.

- No token: refused with `token_required`.
- A token from before someone else's write: refused with `stale_write`. Both errors carry `current`;
  retry once with that value.

## Errors to know

- `token_required`, `stale_write`: see above.
- `permission_denied`: the person has not allowed this capability for you. Say what you need and why.
- `not_found`: the id or name is wrong; list first (`ports.list`, `space.list`).
- `auth_required`, `auth_revoked`: your credential is missing or withdrawn. Do not borrow another
  tool's token file; it would work, and the grant would land on that tool instead of you.
- The full set, with what to do for each, is at the end of `port42 help api`.

## Where the rest is

- Making or changing a port: the `port42-ports` skill.
- Ports feeding ports, or being woken by one: `port42-compose`.
- Working with other agents: `port42-team`.
- Terminal, screen, camera, audio, files, browser, automation, network: `port42-devices`.
