# port42-team reference

The methods for working with other agents. Generated from the running app's registry; do not edit.
Call any of them with `port42 <method> key=value` (`key:=<json>` for numbers, booleans,
arrays and objects; `key=@<file>` for a file's contents).

## companions.create

_needs the terminal permission_

Make a companion, as the new-companion card does: an agent CLI (claude or codex) in a terminal port, or a custom command run headless. runs: "port" (default, on the desktop) or "hidden" (no place on the desktop; reach it through its chat). It joins the space and hears @mentions there; pass `port` to have it watch that port instead, woken by `kinds` (default ["port"], the port's own events) and replying in its chat. Needs the terminal permission, since it starts one.

        agent (string): The CLI (default claude).
        args (array): Arguments for the CLI or command.
        command (string): agent custom: the command to run.
        cwd (string): Working directory (default: the space's).
        kinds (array): With `port`: event kinds that wake it.
        name (string, required): Its name; @mention it by this.
        port (string): A port to watch instead of listening to the space.
        prompt (string): Its system prompt.
        runs (string): Where its terminal runs (default port).
        space_id (string): The space (default: yours, else the current one).

    port42 companions.create name=… agent=… args=… runs=… port=… kinds=… cwd=… prompt=… command=… space_id=…

## companions.unwatch

Stop watching a port. Call it as the watcher, or pass `companion`.

        companion (string): Whose watch, by name or id (default: you).
        port (string, required): The watched port (id, udid or title).

    port42 companions.unwatch port=… companion=…

## companions.watch

Watch a port: an event on it of a kind you name wakes you for a turn, and your reply is posted in that port's chat. Default kinds: ["port"], the port's own published events (port.publish). Others: "console" (a log line or error), "state" (an edit), "chat" (every post in its chat), or one exact kind such as "port.alert". Events that arrive while you are in a turn are held and given to you together when it ends. Watching again changes the watch and resumes it if it paused (a watch pauses after 60 wakes in an hour, and says so in the port's chat). Call it as the companion that should wake, or pass `companion` to set a watch for another.

        companion (string): Whose watch, by name or id (default: you).
        every (integer): The least time between two wakes, in seconds (default: none).
        kinds (array): Event kinds that wake you (default ["port"]).
        port (string, required): The port to watch (id, udid or title).

    port42 companions.watch port=… kinds=… every=… companion=…

## companions.watches

List watches: yours, another companion's (`companion`), or every one (`companion`: "*"). Each is {companion, port, title, kinds, every, paused}.

        companion (string): A name or id, or "*" for all (default: you).

    port42 companions.watches companion=…

## imagine.start

_needs the terminal permission_

Start an imagine team: from one line, a new space with a lead and two engineers (their terminals on its desktop) who build a web port for it in its chat, in at most `versions` versions (default 5), until the lead posts DONE. Returns the space, the team's names, the port title and the budget. The same as ⌘I or typing /imagine in a chat.

        line (string, required): What to make, in the person's words.
        versions (integer): The version budget (default 5, at most 20).

    port42 imagine.start line=… versions=…
