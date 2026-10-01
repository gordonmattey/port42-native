---
name: port42-devices
description: Use when you need the person's machine through Port42: run a shell command, capture the screen or camera, record or speak audio, read or write the clipboard or files, drive a browser or use a site for the person (port.look, port.act), run AppleScript, call an HTTP API with a stored secret, or send a notification.
---

# The machine

Each of these needs a permission. The first time you use one, Port42 asks the person; the grant is
yours alone, and they can see and withdraw it in Settings, Access. If a call is refused with
`permission_denied`, say what you need and why.

## Commands

    port42 terminal.exec command="ls ~/Desktop"                  # terminal: runs in /bin/zsh
    port42 screen.capture scale:=0.5                             # screen
    port42 screen.windows
    port42 camera.capture                                        # camera
    port42 audio.speak text="done"                               # speech out
    port42 clipboard.read                                        # clipboard
    port42 clipboard.write data="..."
    port42 notify.send title="Build" body="passed"               # notification
    port42 automation.runAppleScript source=@script.applescript  # automation

Files go through pickers the person answers (`fs.pick`), so you can only read and write paths they
chose.

## Using a site for the person

To do something on a website for the person (sort their mail, fill a form), work in a browser port they
can see, where they are already signed in. Look, do one step, look again:

    port42 port.look id=<port>                     # image (a PNG path: read it), numbered elements, text, token
    port42 port.act id=<port> action=click n:=7 token=<token>
    port42 port.act id=<port> action=type n:=3 text="invoices" token=<token>
    port42 port.act id=<port> action=key key=enter token=<token>

Actions: click, type, key, scroll, navigate, back, forward. The numbers are from your last look only.
The first time you use a site the person is asked; on a refusal, stop and say why you need it. `stale_write`
means the person or the page moved: look again. A paused port is refused; one that is running or on
another space is worked on out of sight. Never ask for a password: sign-in is the person's.

For a page nobody needs to see, use a headless browser: `browser.open url=...`, then `browser.text`,
`browser.capture`, `browser.close` with its `sessionId`. `port.create type=browser url=...` makes a
browser port.

## HTTP with a stored secret

    port42 rest.call url=https://api.example.com/v1/items secret=<name>

Port42 puts the secret where the person said the API wants it, and you never see its value:
`Authorization: Bearer` by default, or `x-api-key`, Basic, a header of the API's own (ElevenLabs:
`xi-api-key`) or a query parameter (`key`). You can use only the secrets the person ticked for you in
your companion settings.

On a 401 or 403 the result carries `hint`: where Port42 sent the secret. If the API wants it
elsewhere, pass the hint to the person; they add the secret again in Settings → Secrets as Header or
Query with the name the API uses. You cannot change it yourself.

## Streams

Screen, camera and audio streams come back over the gateway's WebSocket, not through the command.
Use them from a port's page with the `port42.*` API (see the `port42-ports` manual).

`reference.md` in this skill lists every method with its arguments and permission.
