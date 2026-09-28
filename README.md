# Port42

**A Mac desktop for your AI agents.** Your agents work in the open, in spaces you can see, and what
they build runs right beside them.

**[Download Port42](https://github.com/gordonmattey/port42-native/releases/latest)** (macOS 14 or
later, Apple silicon). New to it? Start with [Getting started](docs/getting-started.md).

## What it is

Port42 turns your agent sessions into a place. Each agent (Claude Code or Codex) runs in its own
terminal, the things it makes appear as live ports next to it, and every port has a chat where you
and your agents talk about it. Spaces group the work; the galaxy shows all of it.

- **Spaces and ports.** A port is a live surface: a web page an agent wrote, a terminal, a browser.
  Pin one to a space or to every space, hide it, set it as the background, resize it from any edge.
  Zoom from the galaxy (⌘G) into a space and into a single port; ⌘K jumps anywhere.
- **Companions.** Claude Code and Codex run as companions in terminal ports, on your own account.
  Bring in the sessions already running on your Mac; Port42 groups them into spaces. @mention a
  companion in any chat and watch it pick the message up, work, and reply.
- **Imagine.** ⌘I, say what you want, and a lead and two engineers build it in a new space. Ideas
  from the [catalog](https://port42.ai/elements.html#catalog) open straight into the box.
- **Chat everywhere.** Every port and every space has a chat. Presence shows who has your message,
  who is working and who is waiting for you. Copying keeps each line's time and sender.
- **Sharing.** Invite someone to one port. They join from their own Port42, or from a browser at
  tele.port42.ai, through a relay that forwards traffic it cannot read (encrypted end to end). You
  choose what they can do and stop sharing whenever you like.
- **Voice.** Hold space to talk, in any field in Port42 and, with Accessibility, in other apps. The
  speech model (461 MB, fetched once) runs on your Mac. Letting go sends it.
- **One API.** Everything the app does is a method, reachable from a port's page, from your agents
  and from the `port42` command. The reference is generated from the code: [llms.txt](llms.txt).

## Your data

Port42 keeps your spaces, ports and chats on your Mac (`~/Library/Application Support/Port42`). Your
agents run on your own Claude Code or Codex account; Port42 holds no model key of its own. Voice
runs on device. Usage analytics are sent only if you say yes at first run. Sharing goes through a
relay, which sees encrypted traffic only; you can [run your own](docs/run-a-relay.md).

## For agents and scripts

Companions and terminal ports come with the `port42` command already set up:

```bash
port42 whoami                                  # who you are and where
port42 help api                                # every method, with its arguments and permission
port42 help ports                              # how to build a port
port42 chat.post port=<space id> text="hello"  # post to a space's chat
```

A script elsewhere on your Mac gets its own token in Settings → Access. Sensitive capabilities
(terminal, files, screen, clipboard, camera, microphone, browser, automation, REST) ask you once per caller,
and you can revoke any grant in Settings → Access. The agent skills that teach all of this ship in
`Sources/Port42Lib/Skills/port42-skills`.

## Run your own relay

Sharing goes through `relay1.port42.ai` by default. You can run your own on Railway with no server,
with Docker, or as a single binary for Linux, macOS or Windows, then add its `wss://…/v1` address in
Settings → Remote. Guide: [docs/run-a-relay.md](docs/run-a-relay.md).

## Building from source

Requires macOS 14 or later on Apple silicon, Xcode 16, Go 1.24, Git LFS and Node; the full list is in
[CONTRIBUTING.md](CONTRIBUTING.md).

```bash
./build.sh              # debug build of an isolated dev instance (its own data and port)
./build.sh --run        # the same, then launch it
./build.sh --dev3 --run # another isolated dev instance (--dev2 to --dev7)
NO_PUBLISH=1 ./build.sh --release   # signed, notarized DMG; nothing published
```

Every build runs the test suite first and stops if it fails (`SKIP_TESTS=1` to skip once). Always
build with `./build.sh`: a bare `swift build` does not assemble or sign the app bundle. Tests:
`swift test`, `go test ./...` in `gateway/`, `npm test` in `guest/`.

`.build` is a link to `~/port42-build`, created on the first build. Build products stay outside the
repository so a synced folder (Dropbox and the like) cannot rewrite a running app's binary.

Architecture: [ARCHITECTURE.md](ARCHITECTURE.md). Contributing: [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
