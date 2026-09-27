# Port42 v1: live checks

Run by hand on Dev5 (the merged tree, 2026-09-27: nautilus with Phase 4, the relay packaging and voice).
Dev5 starts from a fresh first run. Each check says what to do and what should happen. Mark a failure
with what happened instead; it goes back as a defect.

Sections A to H need one Mac. I needs two instances (Dev2 and Dev6) and the relay. J costs subscription:
it runs real agent teams.

## A. First run

1. **Cinematic.** Launch Dev5. Press space right after the first words appear, then keep pressing.
   Each press moves exactly one scene; the last press ends it.
2. **Boot lines.** The lines type out, including "Scanning for agent sessions... N", and end with
   "Welcome to Port42." and **"What will you imagine?"**.
3. **Name.** Type your name, Enter.
4. **Sessions.** A list of your running Claude Code and Codex sessions, grouped by project, headed
   "port42 grouped them into N spaces for you…". Drag one session to another group and onto "+ new
   space"; rename a group with ✎; tick two or three; bring them in.
5. **Echo's engine.** "Your first companion is called echo. Pick what it runs on:" with the CLI your
   sessions use preselected. Pick it.
6. **Analytics.** Only now: "help improve Port42?". Answer either way; setup finishes.
7. **Landing.** You land on echo's terminal in genesis, not in an imported space.
8. **Echo's welcome.** It says what Port42 is, names the spaces made for your imported sessions and
   who waits in each, and suggests "make me a shader port". Ask for it; the shader appears.
9. **Dolphin.** Zoom out (pinch out, or the button at the top right). The aquarium video grows from
   echo's port with the zoom, plays, and fades into your desktop. Echo then introduces ⌘I (imagine)
   and ⌘K.

## B. Chat

1. **Layout.** In echo's port chat: your messages on the right in a tint, echo's on the left under its
   name. Ask echo to send three short messages back to back: they group under one "echo".
2. **Time.** Scroll: a pill at the top shows the time of the top message in view and fades when you
   stop. Hover a message: its exact time.
3. **Copy.** Drag across several messages, ⌘C, paste anywhere: each line is `[time] name: text`,
   yours included. ⌘A ⌘C copies the whole chat that way.
4. **Input.** Type a long message: the box wraps up to 8 lines, the send arrow stays at the bottom,
   Return sends.
5. **Resize.** Drag a port chat's bottom edge down: it grows to cover the whole port. Open the space
   chat (its bar at the top, by the space name) and drag its bottom-right corner: it resizes. No bars or
   icons on either.
6. **Presence.** @mention a companion from a chat: under the transcript, "@name has your message", then
   "is working (Ns)" with a pulsing dot, and it clears when the reply lands. A permission question from
   Claude shows "is waiting for you" in orange.
7. **System.** Port42's own notices in a chat read "system", in grey, and system is not one of the
   avatars on the chat's bar.
8. **Long chats.** Open a long chat: it opens without a stall, and new messages arrive without one.
9. **Dock.** The dock has no Chat button; Terminal and Browser are there.
10. **Typed into a terminal.** Type straight into echo's terminal: your message appears in echo's port
    chat as you, echo's reply under it, and presence shows echo working meanwhile. It is not typed into
    the terminal a second time.
11. **⌘G.** Goes to the galaxy; ⌘G again comes back to the space.

## C. Ports

1. **Pin.** On a port's "…": **Pin** opens to "In this space", "In every space". Pin one in this space:
   a pin mark in its bar, and it stays above other ports when you raise them. Pin one in every space,
   switch spaces: it follows, in the same place, on top. Move it in one space: it moves in all. Unpin.
2. **Hide.** "…" → Hide: it leaves the desktop and keeps running; bring it back from the hidden list.
3. **Background.** "…" → Set as background: it becomes the desktop behind the tiles and keeps
   animating.
4. **Console.** Ask a companion to check a port: it reads the error count first
   (`port42 port.console id=<id> level=count`) and the errors only if there are any.

## D. Imagine

1. **Box.** ⌘I: the imagine box, bright and centered, with ideas to start from.
2. **Link.** In Terminal:
   `open -a ~/port42-build/Port42Dev5.app 'port42://imagine?line=a%20starfield%20you%20can%20steer&from=port42.ai'`.
   Dev5 comes forward with the box filled in and "from port42.ai: press ↵ to start" under it. Nothing
   starts until you press Enter. (Press Esc unless you want to run J.)
3. **Link in a first run.** Reset Dev5 (ask), fire the link before finishing setup: echo's welcome leads
   with your idea instead of the shader, and after the zoom-out and the dolphin the box opens with it.

## E. Voice

1. **Model.** Settings → Voice: the model state; the first hold of space starts the 461 MB download,
   shown on the space.
2. **Hold to talk.** In a chat input, hold space past a fifth of a second and speak: the words appear as
   you talk and commit when you release. A tap of space still types a space.
3. **Everywhere in Port42.** The same in a terminal port and in a web port with a text field.
4. **Other apps.** Settings → Voice → other apps, grant Accessibility: holding space in another app types
   there.

## F. Companions and sessions

1. **⌘K → "bring in running sessions".** The same grouped list as first run; bring one in: it opens in
   its space as a fork, and the original is left alone.
2. **Posting.** Ask a companion to post in its space's chat on its own, with an @mention of another
   companion in it: the post appears in the space chat, and the mentioned companion wakes.
3. **Failed turn.** When a turn fails (API error, dropped wifi), the chat that asked says "<name> could
   not reply: …" as system, and presence clears. Hard to force; note it when it happens.

## G. Settings

Tabs: Access, Secrets, Remote, Display, Voice, Updates (no AI tab). Remote → Relays lists
`relay1.port42.ai` with a green dot.

## H. Across a restart

Quit and relaunch Dev5: pins, positions, hidden and background ports, chats and companions are all as
you left them; companions come back with today's instructions.

## I. Sharing (two instances: Dev2 and Dev6)

Phase 4's checks, run with it. On Dev2: a port's share pill → invite → copy the link. On Dev6: paste the
link (⌘V anywhere) → accept: the port appears as a tile, marked whose. Drive it, chat in it; stop
sharing on Dev2: Dev6 loses it on its next call. After the `tele` CNAME: open the link in a browser at
`https://tele.port42.ai`: the invite page, valid certificate, and the port joins through relay1.

## J. Agent runs (cost subscription; run on request)

1. **The five scenarios** (`scripts/scenarios/`): make a thing, drive a thing, compose, share (local
   half), arrange.
2. **Imagine** end to end: ⌘I, "a shader that reacts to music", Enter: a space, a lead and two engineers,
   the port built by versions, DONE within the budget.
