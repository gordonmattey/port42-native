# port42-ports reference

The methods for making and changing ports. Generated from the running app's registry; do not edit.
Call any of them with `port42 <method> key=value` (`key:=<json>` for numbers, booleans,
arrays and objects; `key=@<file>` for a file's contents).

## invite.accept

Accept an invite someone sent you: this instance joins their port, which opens here as a tile. Returns { address, title, rights, tile }. Then call methods on the port by its address or the tile's id. remoteWake (default true): a mention of one of your companions in that port's chat wakes it here, on your model; the tile's chrome can turn it off later.

        code (string): The six-digit code, if the invite needs one.
        link (string, required): The invite link (https://tele.port42.ai/#…).
        remoteWake (boolean): Let their chat wake your companions for this port (default true).

    port42 invite.accept link=… code=… remoteWake=…

## invite.create

Make an invite link that lets one person on another machine open ONE port: in Port42 if they have it, otherwise in their browser. The link lets in two machines (say their browser, then their Port42) and is then used up. Returns { link, code?, id, expires, discloses }. rights: any of see, use, edit, wake_agents, fork (default see, use and wake_agents: remote wake, their companions may wake yours in this port's chat; fork lets them take a copy, which Port42 offers only when given). requireCode: a six-digit code they must type, sent to them another way. `discloses` lists what the port itself can do on this machine; whoever you let in can make it do so. Port 0 and spaces cannot be shared.

        expiresIn (integer): Seconds until the link stops working (default 7 days, at most 30).
        port (string, required): The port to share (id / udid / title).
        requireCode (boolean): Require a six-digit code, to send another way.
        rights (array): see, use, edit, wake_agents, fork. Default see, use and wake_agents.

    port42 invite.create port=… rights=… expiresIn=… requireCode=…

## invite.list

The invites this instance has made: id, port, rights, expiry, whether a code is required, and whether each is open, used, expired or withdrawn. A link lets in two machines (a move, one), so it stays open after the first: usedBy names the first and usedAgainBy the second, when it has let them in.

    port42 invite.list

## invite.revoke

Withdraw an invite that has not been used. To remove someone who already joined, remove them in Settings → Access.

        id (string, required)

    port42 invite.revoke id=…

## port.close

Close the calling port.

    port42 port.close

## port.console

Check a port for problems. level=count returns only how many errors and warnings it has logged, no text: the cheap check that a port you built works. The default (problems) adds the errors and warnings themselves (the most recent 20), to deal with them. level=all reads everything it printed, for debugging. A terminal's output has no levels, so for a terminal the default is its last 50 lines. `omitted` says how many lines were left out.

        id (string, required): The port's UDID (from ports_list), or a terminal's name.
        level (string): count: the numbers only. problems (default for a web port): errors and warnings. all: every line, for debugging.
        tail (integer): How many recent lines to return (default 20 for problems, 50 for all).

    port42 port.console id=… level=… tail=…

## port.create

Create a port and return its id. The uniform way to make any port. type:"web" needs html (a full port HTML body) and renders inline in chat. type:"terminal" needs command and opens a native terminal (runs in /bin/zsh; the command is typed in — claude/gemini get the Port42 hooks). type:"browser" needs url and opens an embedded browser tile with an address bar that follows links. type:"chat" reveals that space's chat port (idempotent — one chat per space; brings it back if parked, popped out or closed, and a DM is a space, so pass its space_id to open that conversation). For terminals you may also pass args, cwd, systemPrompt (companion personality), env, and initialInput (a line left waiting, unsent, in the CLI's input box). Drive the result with port_push (input to terminals, data to web ports) and list with ports_list. Pass space_id to target a space (default: current).

        args (array): type:"terminal" — arguments for the command.
        command (string): type:"terminal" — executable/CLI to run (e.g. "bash", "htop", "claude").
        cwd (string): type:"terminal" — working directory (default: home).
        env (object): type:"terminal" — custom environment variables for the shell.
        html (string): type:"web" — full port HTML body (include a <title> and <meta name="version">).
        initialInput (string): type:"terminal" — a line typed into the CLI once it is up but NOT submitted: it waits in the input box for the user to press Enter. For handing someone a first prompt to run. Use port_push instead to actually send input.
        presentation (string): Where the port appears: "tiled" (default, a desktop tile), "parked" (a chip in the rail) or "hidden" (runs with no tile: a background job, a pipe stage, or an agent nobody needs to watch; show it with port.manage show).
        space_id (string): Space to create the port in (default: current space).
        systemPrompt (string): type:"terminal" — companion personality/role appended to the CLI's system prompt.
        title (string): Port title (default: derived from html <title>, or the command).
        type (string, required): The port type to create.
        url (string): type:"browser" — the page to open (e.g. "https://example.com").

    port42 port.create

## port.delete

Delete a CLOSED port for good: its record, versions and chat. Close it first (port.manage close); an open port is refused, so nothing live is ever deleted in one step.

        id (string, required): The closed port's id.

    port42 port.delete id=…

## port.exec

Execute JavaScript on a live port. Use this to call functions, push data, or update state on an existing port without replacing its HTML. The JS runs in the port's webview context with access to window, document, and any globals the port defines.

        id (string, required): The port's UDID (from ports_list)
        js (string, required): JavaScript code to execute in the port's context. Return a value to get it back in the response, as {value, token}. A bare expression yields its value (multi-line is fine). A multi-statement body needs an explicit return: `foo(); 42` is a syntax error, `foo(); return 42;` works.
        token (string, required): REQUIRED. The port's `token`, as it was when you composed this write — from ports_list, port_create, or whatever your last write returned. Without it the write is refused with 'token_required'; if the port has changed since, with 'stale_write'. Both carry the current token, so retry once with that instead of clobbering whoever moved it.

    port42 port.exec id=… js=… token=…

## port.getDom

Read a WEB or BROWSER port's LIVE DOM — what is on screen right now, including everything its JS has changed since load. Use this, not port_get_html, when you need current state: port_get_html returns the stored SOURCE, which does not reflect any port_exec or port_push that has run since. Returns {html, token}; pass that token as 'token' on your next write and it will be refused rather than clobber someone if the port moved in between.

        id (string, required): The port's UDID (from ports_list)
        selector (string): Optional CSS selector to read just one subtree. Omit for the whole document.

    port42 port.getDom id=… selector=…

## port.getHtml

Read the HTML of a port. Omit 'version' to get the current HTML. Pass 'version' (from port_history) to read a specific historical snapshot.

        id (string, required): The port's UDID (from ports_list)
        version (integer): Optional version number (from port_history). Omit for current HTML.

    port42 port.getHtml id=… version=…

## port.history

List all saved versions of a port by its UDID. Returns version number, createdBy, and createdAt for each snapshot. Use port_get_html with a version number to read a specific snapshot, or port_restore to roll back.

        id (string, required): The port's UDID (from ports_list)

    port42 port.history id=…

## port.info

Return the calling port's own id, title, space, capabilities, and activity token.

    port42 port.info

## port.manage

Manage a port. Actions: focus (raise to the front of the desktop), close (archive it: it can be reopened with port.reopen), hide (off the desktop and out of the rail, still running, with its chat and subscriptions), show (bring a hidden port back onto its desktop), pin (keep it above the other ports in its space), pinEverywhere (show it in every space, above the other ports, at one position), unpin. Check the status field from ports_list: 'tiled' | 'parked' | 'hidden'.

        action (string, required): One of: focus, close, hide, show, pin, pinEverywhere, unpin (minimize, dock, restore and undock are older names for hide and show)
        id (string, required): The port's UDID or title
        token (string, required): REQUIRED. The port's `token`, as it was when you composed this write — from ports_list, port_create, or whatever your last write returned. Without it the write is refused with 'token_required'; if the port has changed since, with 'stale_write'. Both carry the current token, so retry once with that instead of clobbering whoever moved it.

    port42 port.manage id=… action=… token=…

## port.move

Move a port's tile to specific desktop coordinates. Use screen_info to get display bounds first.

        id (string, required): The port's UDID (from ports_list)
        space_id (string): Which desktop to move it on. A port kept from another space is a tile on BOTH, with a position on each. Defaults to the current space when the port is on it, else the port's home space.
        token (string, required): REQUIRED. The port's `token`, as it was when you composed this write — from ports_list, port_create, or whatever your last write returned. Without it the write is refused with 'token_required'; if the port has changed since, with 'stale_write'. Both carry the current token, so retry once with that instead of clobbering whoever moved it.
        x (number, required): Horizontal position in desktop points
        y (number, required): Vertical position in desktop points

    port42 port.move id=… x=… y=… space_id=… token=…

## port.patch

Make a targeted edit to a port's HTML — replace an exact string with new content. Much safer than port_update for small changes because only the specified text is replaced; everything else is preserved exactly. Use port_get_html first to read the current HTML, find the exact string to replace, then call port_patch. Errors if 'search' is not found in the current HTML, so the port is never silently mangled. Snapshots the result the same as port_update, and reaches the page the same way (reloading only when it has to; see port_update).

        id (string, required): The port's UDID (from ports_list)
        replace (string, required): The string to replace it with.
        search (string, required): The exact string to find in the current HTML. Must match exactly — copy it from port_get_html output.
        token (string, required): REQUIRED. The port's `token`, as it was when you composed this write — from ports_list, port_create, or whatever your last write returned. Without it the write is refused with 'token_required'; if the port has changed since, with 'stale_write'. Both carry the current token, so retry once with that instead of clobbering whoever moved it.

    port42 port.patch id=… search=… replace=… token=…

## port.position

Return a port's position and size on one desktop (a kept port has a position per desktop).

    port42 port.position id=… space_id=…

## port.push

Send input to a port — one verb, dispatched by the port's type. A WEB port receives the data as a 'port42:data' CustomEvent with the payload in event.detail. A TERMINAL port receives the data as raw keystrokes typed into the shell: end with a newline (e.g. "ls\n") to run the command, or omit it to leave the line waiting unsubmitted. Use the id from ports_list. Prefer this over port_exec for data transfer.

        data (required): For web ports: any JSON value (object/array/string/number) delivered as event.detail. For terminal ports: a string of raw keystrokes (include \n to execute). Required — omitting it is refused with missing_arg rather than sent as nothing, and a terminal refuses an explicit null because there is no keystroke for null.
        id (string, required): The port's UDID (from ports_list), or a terminal's name.
        token (string, required): REQUIRED. The port's `token`, as it was when you composed this write — from ports_list, port_create, or whatever your last write returned. Without it the write is refused with 'token_required'; if the port has changed since, with 'stale_write'. Both carry the current token, so retry once with that instead of clobbering whoever moved it.

    port42 port.push id=… data=… token=…

## port.rename

Rename a port. Sets the port's display title (shown in the title bar). Works for tiled, parked, docked, and inline ports. Use the port's id from ports_list.

        id (string, required): The port's UDID (from ports_list)
        title (string, required): The new title for the port
        token (string, required): REQUIRED. The port's `token`, as it was when you composed this write — from ports_list, port_create, or whatever your last write returned. Without it the write is refused with 'token_required'; if the port has changed since, with 'stale_write'. Both carry the current token, so retry once with that instead of clobbering whoever moved it.

    port42 port.rename id=… title=… token=…

## port.reopen

Reopen a closed port with its id, content, position and chat. A terminal relaunches its command in its last working directory. Closed ports are listed by ports_list with include_closed.

        id (string, required): The closed port's id.

    port42 port.reopen id=…

## port.restore

Restore a port to a specific earlier version. The port's live HTML is replaced with the snapshot and a new version entry is recorded. Use port_history to find available version numbers.

        id (string, required): The port's UDID (from ports_list)
        token (string, required): REQUIRED. The port's `token`, as it was when you composed this write — from ports_list, port_create, or whatever your last write returned. Without it the write is refused with 'token_required'; if the port has changed since, with 'stale_write'. Both carry the current token, so retry once with that instead of clobbering whoever moved it.
        version (integer, required): The version number to restore to (from port_history)

    port42 port.restore id=… version=… token=…

## port.setCapabilities

Set the calling port's own capabilities list.

    port42 port.setCapabilities capabilities=…

## port.setTitle

Set the calling port's own title.

    port42 port.setTitle title=…

## port.update

Update an existing port's HTML content. The port can be identified by its UDID or title. Works whether the port is windowed or minimized. The page is reloaded only when it has to be: a change confined to <style> is applied in place, and any other change is first offered to the page as a cancelable 'port42:update' event (detail.html is the new HTML), which the page may apply itself by calling preventDefault(), keeping its state. Returns applied: unchanged, styles, handledByPage or reloaded.

        html (string, required): The new HTML content for the port (full HTML, not a diff)
        id (string, required): The port's UDID or title to identify which port to update
        token (string, required): REQUIRED. The port's `token`, as it was when you composed this write — from ports_list, port_create, or whatever your last write returned. Without it the write is refused with 'token_required'; if the port has changed since, with 'stale_write'. Both carry the current token, so retry once with that instead of clobbering whoever moved it.

    port42 port.update id=… html=… token=…

## ports.list

List active ports. Each port has an id (UDID), title, capabilities array, status, spaceId, createdBy (an id) with createdByName (who that is, for display), and cwd (if it has a terminal). Terminal ports also report surfaceBound. Use capabilities: ["terminal"] to filter to terminal ports; pass space_id to list only that space's ports. Use the id field with port_push for reliable routing (raw keystrokes to terminals, data to web ports). Always show the id and capabilities fields when presenting results — they are required for follow-up tool calls.

        capabilities (array): Filter to ports that have all of these capabilities. Examples: "terminal", "claude-code", "browser". Omit to list all ports.
        include_closed (boolean): Also list closed (archived) ports, with status 'closed'. Reopen one with port.reopen.
        space_id (string): List only this space's ports. Omit to list every space you can see (a port or companion sees only its own space).

    port42 ports.list capabilities=… space_id=… include_closed=…

## presentation

The calling port's current presentation state { state, visible, w, h }: whether its surface is on screen right now and at what content size, so the port can pause its animation loop when not visible and scale fidelity to its size. The same value is delivered as the 'presentation' event on every change; this call returns the current snapshot for the initial read.

    port42 presentation

## storage.delete

Delete a value from persistent storage

        key (string, required): The storage key to delete
        port (string): For a copy of a port shared from another machine: that port's id, to reach its own storage there.
        scope (string): "global" for storage shared across spaces; omit for this space's.
        shared (boolean): true for the space's shared bucket rather than the caller's own.

    port42 storage.delete key=…

## storage.get

Get a value from persistent key-value storage

        key (string, required): The storage key
        port (string): For a copy of a port shared from another machine: that port's id, to reach its own storage there.
        scope (string): "global" for storage shared across spaces; omit for this space's.
        shared (boolean): true for the space's shared bucket rather than the caller's own.

    port42 storage.get key=…

## storage.list

List all keys in persistent storage

        port (string): For a copy of a port shared from another machine: that port's id, to reach its own storage there.
        scope (string): "global" for storage shared across spaces; omit for this space's.
        shared (boolean): true for the space's shared bucket rather than the caller's own.

    port42 storage.list

## storage.set

Store a value in persistent key-value storage

        key (string, required): The storage key
        port (string): For a copy of a port shared from another machine: that port's id, to reach its own storage there.
        scope (string): "global" for storage shared across spaces; omit for this space's.
        shared (boolean): true for the space's shared bucket rather than the caller's own.
        value (string, required): The value to store

    port42 storage.set key=… value=…
