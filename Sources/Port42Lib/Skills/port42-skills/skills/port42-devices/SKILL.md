---
name: port42-devices
description: Use when you need the person's machine through Port42: run a shell command, capture the screen or camera, record or speak audio, read or write the clipboard or files, drive a browser, run AppleScript, call an HTTP API with a stored secret, or send a notification.
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

## A browser

    port42 browser.open url=https://example.com
    port42 browser.text sessionId=<id>
    port42 browser.capture sessionId=<id>
    port42 browser.close sessionId=<id>

A browser port on the desktop is made with `port42 port.create type=browser url=...`.

## HTTP with a stored secret

    port42 rest.call url=https://api.example.com/v1/items secret=<name>

Port42 adds the secret's header; you never see its value. You can use only the secrets the person
ticked for you in your companion settings.

## Streams

Screen, camera and audio streams come back over the gateway's WebSocket, not through the command.
Use them from a port's page with the `port42.*` API (see the `port42-ports` manual).

`reference.md` in this skill lists every method with its arguments and permission.
