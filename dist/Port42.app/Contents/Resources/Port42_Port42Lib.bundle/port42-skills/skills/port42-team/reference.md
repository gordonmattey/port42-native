# port42-team reference

The methods for working with other agents. Generated from the running app's registry; do not edit.
Call any of them with `port42 <method> key=value` (`key:=<json>` for numbers, booleans,
arrays and objects; `key=@<file>` for a file's contents).

## companions.create

_needs the terminal permission_

Make a companion, as the new-companion card does: an agent CLI (claude or codex) in a terminal port, or a custom command run headless. runs: "port" (default, on the desktop) or "running" (off the desktop, a card under Running in the rail; reach it through its chat). It joins the space and hears @mentions there; pass `port` to have it watch that port instead, woken by `kinds` (default ["port"], the port's own events) and replying in its chat. Needs the terminal permission, since it starts one.

        agent (string): The CLI (default claude).
        args (array): Arguments for the CLI or command.
        command (string): agent custom: the command to run.
        cwd (string): Working directory (default: the space's).
        kinds (array): With `port`: event kinds that wake it.
        name (string, required): Its name; @mention it by this.
        port (string): A port to watch instead of listening to the space.
        prompt (string): Its system prompt.
        runs (string): Where its terminal runs: port (a tile on the desktop, the default) or running (off the desktop, a card under Running in the rail; hidden is the older name).
        space_id (string): The space (default: yours, else the current one).

    port42 companions.create name=… agent=… args=… runs=… port=… kinds=… cwd=… prompt=… command=… space_id=…

## companions.delete

Delete a companion for good: it leaves every space, its watches go, and the ports it made close. Cannot be undone; use companions.remove to take it off one space's roster instead. The person may delete any; anyone else asks the person, naming the companion, every time, and a yes is never kept. companion is its id or name.

        companion (string, required): The companion's id or name.

    port42 companions.delete companion=…

## companions.remove

Take a companion off a space's roster, as its card's "Remove from this space" does. It stops hearing @mentions there; the companion itself, its ports and its files are kept, and it can be added back. companion is its id or name; space_id defaults to your space. Removing a companion that is not on the roster is not_found.

        companion (string, required): The companion's id or name.
        space_id (string): The space whose roster it leaves (default: your space).

    port42 companions.remove companion=… space_id=…

## companions.unwatch

Stop watching a port. Call it as the watcher, or pass `companion`.

        companion (string): Whose watch, by name or id (default: you).
        port (string, required): The watched port (id, udid or title).

    port42 companions.unwatch port=… companion=…

## companions.update

Change a companion's settings, as its settings box does: name, system prompt, model, where it runs (port or running), command and args, working directory, and trigger (mentionOnly or allMessages). Pass only what changes. A companion changes itself freely; anyone else asks the person, naming the companion and what changes, every time. Its secrets are not changeable here. A new prompt, command or folder reaches a running session when it next starts; a new name takes effect at once. companion is its id or name.

        args (array): Arguments for the CLI or command.
        command (string): agent custom: the command to run.
        companion (string, required): The companion's id or name.
        cwd (string): Working directory.
        model (string): Its model, where the CLI takes one.
        name (string): A new name. Two companions cannot share one.
        prompt (string): Its system prompt.
        runs (string): Where its terminal runs.
        trigger (string): What wakes it in a chat.

    port42 companions.update companion=… name=… prompt=… model=… runs=… command=… args=… cwd=… trigger=…

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

## imagine.budget

Set the version budget of the imagine team in a space, for example to let it keep going after the budget is spent. The team's writes to its port past the budget are refused with budget_spent; a budget of 0 has no limit. The same as typing /imagine --versions N in that space's chat.

        space (string, required): The space the team was imagined in.
        versions (integer): The new budget, in versions of the port: any number, or 0 (or leave it out) for no limit.

    port42 imagine.budget space=… versions=…

## imagine.start

_needs the terminal permission_

Start an imagine team: from one line, a new space with its port (a placeholder until v1) and a lead and two engineers (their terminals on its desktop) who build that port, in at most `versions` versions (default 10; 0 is no limit), until the lead posts DONE. Returns the space, the port, the team's names, the port title and the budget. The same as ⌘I or typing /imagine in a chat.

        line (string, required): What to make, in the person's words.
        versions (integer): The version budget (default 10; no upper limit; 0 is no limit at all).

    port42 imagine.start line=… versions=…

## sessions.find

_needs the terminal permission_

The Claude Code and Codex sessions running on this Mac that Port42 did not start, each with its project, branch, title, last activity and the app it runs in, grouped into a space per project. What the first-run import and ⌘K 'bring in running sessions' offer.

    port42 sessions.find

## sessions.import

_needs the terminal permission_

Bring running sessions into Port42 as forks: each becomes a companion in its space whose terminal starts with a copy of the whole conversation; the original is not touched and should then be closed. Each item: {id, cli, cwd, space, name}.

        sessions (array, required): The sessions to bring in: {id, cli (claude|codex), cwd, space, name}.

    port42 sessions.import sessions=…
