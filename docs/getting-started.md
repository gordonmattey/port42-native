# Getting started with Port42

Port42 is a Mac desktop for your AI agents. This guide takes you from the download to an agent building
something you can use, then through the rest of the app.

## Before you start

- A Mac with Apple silicon, on macOS 14 or later.
- Claude Code or Codex installed and signed in. Port42 runs your agents on your own account and holds
  no model key of its own.

## Install

1. Download Port42 from the [latest release](https://github.com/gordonmattey/port42-native/releases/latest).
2. Open the DMG and drag Port42 into Applications.
3. Open it. Updates arrive on their own after this (Settings → Updates).

## First run

1. **The opening.** A short sequence plays. Press space to step through it.
2. **Your name.** Type it and press Return.
3. **Your sessions.** Port42 lists the Claude Code and Codex sessions already running on your Mac,
   grouped by project into spaces. Drag a session between groups or onto "+ new space", rename a group,
   and tick the ones to bring in. Each comes in as a fork, and the original is left as it was.
4. **Echo.** Your first companion is called echo. Pick what it runs on (Claude Code or Codex).
5. **Analytics.** Say whether to help improve Port42 with usage data. Nothing is sent unless you say
   yes.

You land in echo's terminal. Echo says what Port42 is and which spaces it made for your sessions.

## Make your first port

Ask echo: `make me a shader port`. A port appears beside echo: a live page echo wrote, running now.
Ask for changes and it updates in place.

A port is any live surface: a page an agent wrote, a terminal, or a browser (the dock at the bottom
opens a new terminal or browser). Drag a port by its title bar, resize it from any edge, and use its
"…" menu to pin it (in this space or in every space), hide it, or set it as the background.

## Find your way around

- **The galaxy.** Zoom out (pinch, or ⌘G) to see every space. Click one to go in.
- **A space.** A desktop of ports. Click the space name at the top left to go back to the galaxy.
- **Focus.** Zoom into one port to give it the screen.
- **⌘K.** Jump to any space, port or companion by typing part of its name.

## Chat

Every port and every space has a chat. Open a port's chat from its title bar, or the space chat from
the bar at the top.

- **@mention a companion** to send it your message. Under the chat you see "@echo has your message",
  then "is working" while it works, and nothing once its reply lands. If it needs you in its terminal
  (a permission question), it says "is waiting for you".
- **What you type straight into a companion's terminal** also appears in that terminal's chat.
- **Copy** a stretch of chat and each line comes out as `[time] name: text`.

## Imagine

Press ⌘I, say what you want ("a starfield you can steer"), and press Return. Port42 makes a new space
with a lead and two engineers, and they build it there while you watch. Ideas to start from are in the
[catalog](https://port42.ai/elements.html#catalog); "open in Port42" on any of them fills the box for
you, and nothing starts until you press Return.

## Share a port

1. Choose Share from the port's "…" menu.
2. Choose what the other person can do: use it, edit it, wake your companions from it. Add a code if
   you want one sent separately from the link.
3. Copy the link and send it.

They open the link in their browser (tele.port42.ai) or paste it into their own Port42 (⌘V
anywhere). One link lets in two machines, so they can look in the browser first and then open it in
the app. The port's title bar then shows "shared"; click it to see who is in, change what they can
do, copy the link again, or stop sharing. Stopping sharing also closes the link they came in on.

Sharing goes through a relay that forwards encrypted traffic it cannot read. To use your own, see
[Run your own relay](run-a-relay.md).

## Voice

Hold space for a moment in any text field in Port42 and speak: the words appear as you talk, and when
you let go they are sent. A quick tap still types a space.

- The first hold downloads the speech model (461 MB, once). It runs on your Mac.
- Settings → Voice: turn off "send on release" to read your words over before sending.
- Settings → Voice → hold space in another app: grant Accessibility and it works outside Port42 too.

## The port42 command

Your companions use the `port42` command to do everything the app does. You can too, in any of their
terminals:

```bash
port42 whoami          # who you are, and which space you are in
port42 help api        # every method, with its arguments and permission
port42 help ports      # how to build a port
```

For a script elsewhere on your Mac, make it its own token in Settings → Access. The first time any
caller wants something sensitive (the terminal, files, the screen, the clipboard, the camera or
microphone, automation, REST), Port42 asks you. Settings → Access lists every grant, and you can
revoke any of them.

## Settings

- **Access:** the callers that can reach Port42, what each may do, and the ports you share.
- **Secrets:** API keys a companion may use through `rest.call`, never shown to it. Pick where the
  API wants the key: Bearer (the default), API Key (`x-api-key`), Basic, Header with the API's own
  header name, or Query with its parameter name. ElevenLabs, for example, is Header `xi-api-key`.
  Paste only the key as the value. If a call is refused, the companion is told where the key went.
- **Remote:** relays for sharing.
- **Display:** how Port42 takes the screen.
- **Voice:** the speech model, send on release, and other apps.
- **Updates:** automatic updates.
