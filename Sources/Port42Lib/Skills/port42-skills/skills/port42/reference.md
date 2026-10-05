# port42 reference

The methods for calling Port42: the command, identity, chats and errors. Generated from the running app's registry; do not edit.
Call any of them with `port42 <method> key=value` (`key:=<json>` for numbers, booleans,
arrays and objects; `key=@<file>` for a file's contents).

## chat.post

Post to a port's chat. Every port has one: pass port 0 for the desktop, a space id, or a port's id. The entry is attributed to you, the caller, and every subscriber of the port gets a `chat` event carrying it.

        port (string, required): Whose chat: `0` (the desktop), a space id, or a port id / udid / title.
        text (string, required): What to say.

    port42 chat.post port=… text=…

## chat.read

Read a port's chat, oldest first. Pass `after` (a seq you have seen) to get only what is newer. Returns { entries, last, agents? }. Each entry's `from` is {id, name, kind, handle, computer?}: `name` as people read it, which on a port shared with another computer carries the author's computer, `scribe (gordon's Port42)`; `handle` is the bare name, to match on and @mention; `computer` is set when the chat shows one. `last` is the newest seq in the chat (0 when empty), and `agents`, on a port shared with another computer, names this computer's agents on it as the chat shows them, whether or not they have posted.

        after (integer): Only entries with a seq greater than this.
        limit (integer): At most this many, the newest ones (default 50, max 200).
        port (string, required): Whose chat: `0` (the desktop), a space id, or a port id / udid / title.

    port42 chat.read port=… after=… limit=…

## companions.get

Get details about a specific companion by ID, with `spaces`, the spaces it is a member of ([{id, name}]): the spaces whose chats and ports it can read.

        id (string, required): The companion's ID

    port42 companions.get id=…

## companions.list

List the companions in a space with their names, models, and trigger modes. Defaults to YOUR space — the companions you share this space with — because a companion acts within its space, not the whole instance. Pass space_id to target a different space, or space_id:"*" for the full global roster across every space in the Port42 instance (rarely what you want). From another computer: the companions of the shared port's own space, named by `port`.

        port (string): From another computer: the shared port whose space to list.
        space_id (string): Omit for your own space (the default). A space id targets that space. "*" returns the whole-instance roster.

    port42 companions.list space_id=… port=…

## help

Return the Port42 API reference. Pass topic:"ports" for the port-authoring manual (read it BEFORE building or editing a port: sizing, module-scope, patterns, the design system). No topic returns the full method reference.

        topic (string): Optional. "ports" = the port-authoring manual. Omit for the API reference.

    port42 help topic=…

## presence.list

Who is on a chat's messages right now: each companion that has a message from this chat (`received`), is working on it (`working`), or is waiting for the person (`waiting`, with `why` when it said). `doing` says what it is doing right now ("editing ShellView.swift", "running swift test") when its CLI reports tools (Claude Code does); a caller on another computer is told only the kind ("editing a file"). Returns { presence: [{name, handle, computer?, state, since, why?, doing?}] }, `handle` the bare name and `name` as the chat shows it, empty when nobody is. Subscribe to the port for the `presence` event to hear each change; the event carries only the kind of what each is doing.

        port (string, required): Whose chat: a space id, or a port id / udid / title.

    port42 presence.list port=…

## space.create

Create a space. Returns {id, name}. The name is lowercased with spaces as dashes. Pass switch: true to also make it the current space; by default the person stays where they are.

        name (string, required): The space's name.
        switch (boolean): Also switch to it (default false).

    port42 space.create name=… switch=…

## space.current

Get a space's metadata and member list: { id, name, type, memberCount, members: [{ id, name, type, owner, qualifiedName }] }. Pass space_id to inspect a specific space (e.g. your own PORT42_SPACE_ID); omit it for the currently selected space. From another computer: the shared port's own space, named by `port`.

        port (string): From another computer: the shared port whose space to read.
        space_id (string): Optional space id to inspect. Defaults to the currently selected space.

    port42 space.current space_id=… port=…

## space.delete

Delete a space: its own ports and terminals close, then the space and its chat go. A port adopted into another space stays there. Cannot be undone. The same as Delete in the galaxy.

        space_id (string, required): The space to delete (from space_list).

    port42 space.delete space_id=…

## space.list

List all spaces the user belongs to, with each one's accent color, whether it is resting, and its place in the galaxy order (the list is in that order).

    port42 space.list

## space.reorder

Move a space in the galaxy order, as dragging it does: it lands just before the space named in before, or at the end when before is omitted. Returns the order, as space ids.

        before (string): The space it should come before. Omit to put it last.
        space_id (string, required): The space to move.

    port42 space.reorder space_id=… before=…

## space.rest

Put a space at rest: off the galaxy front, unindexed and silent, nothing lost (Rest in the space settings card). Resting the space the person is in moves them to another working space. A space already at rest is refused.

        space_id (string, required): The space to rest.

    port42 space.rest space_id=…

## space.setWorkingDirectory

_needs the filesystem permission_

Set (or clear) a space's working directory. Command companions spawned in the space default their cwd here so they share one workspace; each still gets its own claude session. Clearing falls back to home, and is a deliberate act: send path as null (or an empty string). OMITTING path is an error, not a clear. Defaults to the current space.

        path (required): Absolute directory path. Send null or "" to clear it and fall back to home. Required: omitting it is refused with missing_arg, so a malformed call cannot silently clear the setting.
        space_id (string): Space id (default: current space).

    port42 space.setWorkingDirectory space_id=… path=…

## space.switchTo

Switch the app's current space by id.

    port42 space.switchTo space_id=…

## space.update

Change a space's name or accent color, as the space settings card does. The name is lowercased with spaces as dashes, and may not be one another space holds. The accent is a hex color like #4ECDC4. Returns the space.

        accent (string): A hex color, #RRGGBB.
        name (string): The new name.
        space_id (string, required): The space (from space_list).

    port42 space.update space_id=… name=… accent=…

## space.wake

Wake a resting space: back into the working set, on the galaxy front. It does not switch to it (space_switchTo does). A space not at rest is refused.

        space_id (string, required): The space to wake.

    port42 space.wake space_id=…

## user.get

Get the current user's identity (id and display name)

    port42 user.get

## whoami

Who you are to Port42: your name, your space and who is in it (the companions you can @mention), and, for a companion running in a Port42 terminal, that terminal's port id and chat. `spaces` lists every space you are a member of, [{id, name}]: you can read their chats and ports, and post there. `elsewhere` lists companions on other computers met in the chat of a port shared with them, each with its mention and that port's chat: mention them there. Call it first.

    port42 whoami
