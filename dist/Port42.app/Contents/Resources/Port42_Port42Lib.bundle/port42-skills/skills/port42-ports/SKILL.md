---
name: port42-ports
description: Use before making or changing a Port42 port (a web, terminal or browser surface on the person's desktop), and when a port misbehaves. Covers creating, patching and checking ports, live updates, running ports, storage and the gotchas that break them.
---

# Making and changing ports

A port is a live surface on the person's desktop: web (HTML, CSS, JS), terminal, or browser. Make
every kind with `port42 port.create`. Never answer with a ```port code fence; a fence is not a port.

## Before you make one

Look first, so you do not make a second:

    port42 ports.list

If a port with that title is in your space, work on it.

## Make one

Write the HTML to a file, then:

    port42 port.create type=web html=@port.html

- Include a `<title>` and `<meta name="version" content="1">`, and bump the version on every change.
- Write only what goes inside `<body>`. The Port42 dark theme is injected for you.
- Call `port42.state.set([{label, value}])` as it changes: small or off the desktop, it shows only that.
- It returns the port's `id` and `token`. Answer with the title and id.

## Asked for a website, an app or a page

Make it a web port: the port is the site. Put what it needs in its HTML (inline scripts and styles)
and fetch data from the page with `port42.rest.call`.

- Do not start a server for it (`python -m http.server`, `npm run dev`, `vite`) and point a browser
  port at localhost. That leaves the person a process to manage and a second port that only frames
  the first.
- A server is for a project that already needs one (a backend, the person's own dev server). Run it
  in your own terminal, never a new one, and say that it is running and how to stop it.
- A browser port shows a URL the person should see: open one for every link you hand them.

## Change one

Read it, change the least you can, write it back with its token:

    port42 port.getHtml id=<id>
    port42 port.patch id=<id> search=@old.txt replace=@new.txt token=<token>
    port42 port.update id=<id> html=@port.html token=<token>

Prefer `port.patch`; never rewrite a working port to fix one bug. Each write returns the next token.

A write reloads the port only when it must, and returns `applied`:

- `unchanged`: the HTML was identical; nothing happened.
- `styles`: only `<style>` changed; it was applied in place, state kept.
- `handledByPage`: the page took the `port42:update` event (below) and applied the change itself.
- `reloaded`: the page reloaded; in-memory state reset.

A port that should keep its state across edits (a shader, a game, a long form) listens for
`port42:update`, applies `e.detail.html` itself, and calls `e.preventDefault()`. Anything that must
survive a reload goes in `port42.storage`, and subscriptions are re-made on load.

## Check it works before you say it is done

    port42 port.console id=<id> level=count
    port42 port.getDom id=<id>

The count says whether the port logged errors or warnings. Only if it did, read them and fix them:

    port42 port.console id=<id>

The whole log, every level, is for debugging:

    port42 port.console id=<id> level=all

Check the DOM for the controls you added, then say what you checked.

## Ports off the desktop

A port with nothing to show (a pipe stage, a poller, a scheduler, a watcher) runs off the desktop:

    port42 port.create type=web presentation=running html=@stage.html

It runs with its storage, chat and subscriptions, as a card under Running in the rail. `port42
port.manage id=<id> action=show token=<token>` brings it back; `hide` or `pause` (slowed) sends it
off. A running claude or codex terminal is an agent reached through its chat.

## Arrange one

- Move or size it: `port42 port.move id=<id> x:=40 y:=60 width:=800 height:=500 token=<token>`
  (either pair alone works).
- Show it in another space too, the same live port: `port42 port.manage id=<id> action=showIn
  space_id=<other> token=<token>`; `hideFrom` stops; `ports.list` reports where as `alsoIn`.
- `action=reload` reloads its page in place. `action=background` makes it a space's backdrop (each
  space has its own; `space_id` names which), `unbackground` puts it back.
- An independent copy, no grants: `port42 port.fork id=<id>` (into `space_id`, else the current space).

## Share one

Only when the person asks you to share a port with someone:

    port42 invite.create port=<id>

It returns a `link` to send them; it works once, in Port42 or their browser. Rights default to
`see`, `use` and `wake_agents`; add `edit` or `fork` in `rights`, and `requireCode:=true` for a
six-digit `code` sent another way. Tell the person what `discloses` lists: what the port can do on
this machine for whoever joins. `port42 invite.revoke id=<id>` withdraws an unused one.

After it is shared: `port42 invite.shared port=<id>` lists who has it and their rights; `port42
invite.setRights port=<id> peer=<name> rights:='["use","edit"]'` changes them (adding any asks the
person); `port42 invite.stop port=<id> peer=<name>` removes someone. A port shared with this machine is a
tile with `mirrors` in `ports.list`: `port42 remote.leave tile=<id>` leaves it, and `port42
remote.setWake tile=<id> on:=true` lets its host's chat wake your companions (both ask the person).

## Gotchas (each one broke a real port, silently)

- **A port is a tile, not a window.** Its size is arbitrary and changes. Size from your own element,
  never `innerWidth`/`innerHeight`; map pointer coordinates through `getBoundingClientRect()`; use
  relative units.
- **Never let a canvas's backing store feed its layout.** Lock the display size in CSS
  (`width:100%; height:100%`), then size the backing store from it, or it grows without end.
- **three.js:** `renderer.setSize(w, h)`, not `setSize(w, h, false)`.
- **WebGL screenshots are black** without `preserveDrawingBuffer: true`.
- **Scripts run as ES modules.** Inline `onclick="fn()"` cannot see your functions; use
  `addEventListener` or `window.fn = fn`.
- **Remote scripts, styles and images are blocked.** Inline your libraries. For network, use
  `port42.rest.call`.
- **Animation:** start the loop running, then pause it when `port42.on('presentation', p => ...)`
  reports `p.visible` false. Never wait for that event to start: it fires on change. Use
  `port42.presentation()` for the state at startup.
- **Off screen** (running, paused, another space) a port still gets every event, and its timers never
  stop: full rate when running, else about once a second (a long interval may fire late); frames stop.
- **A failed bridge call rejects.** Wrap startup in try/catch so one failure cannot blank the port;
  show failures in the UI.
- **`port.exec`** runs your JS as a function body: a multi-statement line needs an explicit `return`,
  and never return a promise that does not settle.

## More

- `manual.md` in this skill: the full port manual, with the `port42.*` API a page uses, the stateful
  app pattern, storage scoping, every device API and complete examples. `port42 help ports` prints it.
- `reference.md`: the port methods you call from outside.
