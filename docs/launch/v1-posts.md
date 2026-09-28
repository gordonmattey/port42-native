# Port42 1.0: launch posts

Drafts for GM (2026-09-27). GM owns the words. Positioning follows the live site (port42.ai: "a Mac
desktop for your AI companions … Port42 runs no model and holds no key"; tagline "What will you
imagine?"). The proof is the first demo video (GM, decision D2).

**Blocker before any post:** port42.ai's download goes to GitHub's latest release, which is v0.5.50.
Publish v1.0.0 (or point the button at its DMG) first, or every post sends people to the old app.

## X (tonight): a thread

1/ Port42 1.0 is out.

A Mac desktop where the coding agents you already use build live things with you. Say what you want
and it appears on your desktop as a real surface you can use, keep or throw away.

What will you imagine?

[video] port42.ai

2/ Your agents, not ours. Claude Code and Codex run in terminals on your desktop, signed in to your
own accounts. Port42 runs no model and holds no key.

3/ Press ⌘I and type one line: "a shader that reacts to music". A lead and two engineers get a space
of their own and build it, version by version, until it is done.

4/ Everything is a port: a shader, a chart, a terminal, a doc. Each has its own chat, where you and
the agents talk about it. Ports feed each other with no glue code.

5/ Share a port with a link. The other person opens it in Port42 or in a browser, through a relay
that only passes encrypted traffic. Anyone can run their own relay.

6/ Also in 1.0: hold space to talk (transcribed on your Mac), bring your running Claude and Codex
sessions in with one click, pin a port to every space.

macOS 14 or later. port42.ai

## LinkedIn (tomorrow)

Port42 1.0 is out today.

For the last year I have been building a desktop for working with AI agents, not a chat window
beside your work. The idea is simple: you say what you need, and it appears on your desktop as a
real, live thing. A chart of your data. A tool for the job in front of you. A shader, because why not.

The agents are the ones you already use. Claude Code and Codex run in terminals right on the desktop,
signed in to your own accounts. Port42 runs no model and holds no key. It gives your agents a place
to build, and you a place to see and use what they make.

A few things in 1.0 I am proud of:
• Imagine. Press ⌘I, type one line, and a lead and two engineers build it in a space of their own.
• Sharing. Send a port as a link; the other person opens it in Port42 or in a browser.
• Voice. Hold space and talk; it is transcribed on your Mac.
• Your sessions. Bring the Claude and Codex sessions you already have running into Port42 in one click.

It is a Mac app, macOS 14 or later, and it is at port42.ai.

What will you imagine?

## Hacker News: Show HN

**Title:** Show HN: Port42, a Mac desktop where Claude Code and Codex build live apps with you

**URL:** https://port42.ai

**First comment:**

Hi HN, I'm Gordon. Port42 is a macOS app: a desktop of live surfaces ("ports") that your coding
agents build and you use. A port is a web page, a terminal or a browser, tiled on the desktop, each
with its own chat.

How it works:
- The agents are the CLIs you already have. Claude Code and Codex run in terminal ports (libghostty),
  signed in to your own accounts. Port42 runs no model and stores no provider key.
- Port42 knows what an agent is doing from the CLI's own hooks (turn end, prompt submitted, needs
  you, turn failed), not by reading its screen, so a chat shows who is working on your message.
- Agents drive Port42 through one API, declared once in a registry (about 70 methods: ports, chat,
  storage, pipes between ports, devices), called from a page's JavaScript, the `port42` CLI or a
  local HTTP door. Every caller has its own token, and every write carries the port's version token,
  so two agents cannot silently overwrite each other.
- Imagine (⌘I) turns one line into a space with a lead and two engineers, who build a port in
  versions against a budget.
- Sharing goes through a small Go relay that pairs instances by key and forwards Noise IK traffic it
  cannot read. relay1.port42.ai is the default; the relay is one binary or container and you can run
  your own.
- Voice input is local: Parakeet on the Neural Engine.

Swift/SwiftUI with a Go gateway. Mac only for now, macOS 14 or later. You need Claude Code or Codex
installed; Port42 finds them at first run.

I would love to hear what you would build with it, and what breaks.

## Product Hunt

**Name:** Port42

**Tagline (60 max):** Your coding agents build live apps on your desktop

**Description (260 max):** A Mac desktop where Claude Code and Codex build live things with you. Say
what you want and it appears as a real surface you can use, keep or share. Press ⌘I and a team of
agents builds it in its own space. Your agents, your accounts: Port42 holds no key.

**Maker comment:**

Hi Product Hunt! I built Port42 because working with AI agents still means a chat window beside
your work. In Port42 the agents build on your desktop: ask for a chart, a tool, a shader, and it
appears as something you can use.

It uses the agents you already have, Claude Code and Codex, signed in to your own accounts. Press ⌘I
and type one line to have a lead and two engineers build something bigger in a space of their own.
Share any port with a link, hold space to talk, and bring your running agent sessions in with one
click.

Mac only, macOS 14 or later. What will you imagine?

## Claims used, and their status

| Claim | Status |
|---|---|
| Claude Code and Codex run in terminals on the desktop, on the person's own accounts | Built and tested (first run, session import) |
| Port42 runs no model and holds no key | Built (D9, nautilus Phase 1); the site states it |
| ⌘I: a lead and two engineers build it in versions | Built; verified live on dev instances |
| Ports feed each other with no glue code | Built; scenario 3 passes on the v1 build |
| Share a port by link, in Port42 or a browser, through an encrypted relay | Built; GM joined a Dev2 invite at tele.port42.ai through relay1 |
| Anyone can run their own relay | Built (image, binaries, guide); not yet published |
| Hold space to talk, transcribed on the Mac | Built; confirmed by hand on Dev7 |
| Bring running sessions in with one click | Built; not yet run live end to end |
| "About 70 methods" | 70 in the registry at the last count; confirm before posting |
