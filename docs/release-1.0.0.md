# Release: Port42 1.0.0

Prepared 2026-09-27 for a push on the morning of 2026-09-28 (GM: push regardless of the audit's state).
Everything up to the final step is done or listed below with its status. The final step is the only one
that publishes.

## State

| Item | Status |
|---|---|
| Branch | `nautilus`, fast-forwarded into local `main` (nothing pushed). `origin/main` is at `43eea3e` (v0.5.50's line); the push carries 538 commits |
| Version | `VERSION` = 1.0.0. No `v1.0.0` tag or release exists on GitHub; the latest public release is v0.5.50 |
| Tests | Full Swift suite green (1487 at `21d9f57`), guest tests 20/20, Go gateway suite green |
| Update feed | Installed copies read `main`'s `dist/appcast.xml`, so the release runs from `main`. The built app's `SUPublicEDKey` matches the signing key in the keychain (`EEYKlz61…fbI=`); v0.5.50 installs will accept the update |
| Secrets | The 538 outgoing commits (every added line, history included) scanned for API keys, tokens, private keys and analytics keys: none |
| Notarized DMG | Build 2427 (NO_PUBLISH) notarized and installed on GM's Mac; the release build makes its own |
| Invite page | `tele.port42.ai` live with the current guest bundle; its served page matches the committed one |
| Security audit | The squad works on `squad/security-v1` from `nautilus`; its ledger lists 68 findings, 13 verified fixed on `nautilus`. What is merged by the morning ships; the rest follows in 1.0.x |
| Pairing and scoped tokens | Not built. Designed (`plan-pairing-scopes.md`), all decisions made. Moves after 1.0.0 unless GM says otherwise |
| Presence in the API | On branch `presence-api` (`0056aad`), not in 1.0.0 |
| macOS 14 on Sonoma hardware | Not verified; GM decided 14 ships |
| Live sharing checks (v1-live-checks.md, I) | Unit-tested today (two machines per link, stop sharing withdraws the link); the two-instance run is still to do |

## The final step

From the main checkout, with nothing uncommitted outside `dist/`:

```
git checkout main
git merge --ff-only nautilus          # takes anything merged into nautilus overnight
./build.sh --release                  # tests, build, sign, notarize, appcast, push main, GitHub release
git add -f dist/Port42.app dist/Port42.dmg && git commit -m "Release: v1.0.0" && git push
```

`./build.sh --release` runs the suite first and stops on a failure. It pushes `main` before tagging, so
the `v1.0.0` tag names the commit the DMG was built from. It stops the app only when that app runs from
the build folder; production runs from `/Applications` and is left alone.

Then, in order:
1. Replace the generated release body with the summary below (`gh release edit v1.0.0 --notes-file …`),
   keeping the generated commit list under it.
2. Push `relay-v1.0.0`: the workflow publishes the relay image to ghcr.io and the binaries for Linux,
   macOS and Windows to its release. Make the image public in the package settings.
3. Switch relay1 on Railway to `ghcr.io/gordonmattey/port42-relay:latest`, then make the Railway
   template (`docs/run-a-relay.md`).
4. Check an installed v0.5.50 offers the update, and that the download link in the README serves 1.0.0.

## Release notes (summary for the top of the release)

Port42 1.0.0 is a desktop where your AI agents work in the open. Each agent runs in its own terminal
port, every port has a chat, and the ports they make live beside them in spaces you zoom between.

- **Spaces and ports.** A galaxy of spaces, each a desktop of ports: web pages your agents write,
  terminals and browsers. Pin a port in one space or all, hide it, set it as the background, resize it
  from any edge. ⌘G for the galaxy, ⌘K to jump.
- **Companions.** Claude Code and Codex, in terminal ports. Bring in the sessions already running on
  your Mac, grouped into spaces. Every chat shows who has your message, who is working and who is
  waiting for you.
- **Imagine.** ⌘I, say what you want, and a lead and two engineers build it in a new space. Ideas from
  the catalog on port42.ai open straight into the box.
- **Chat.** A chat on every port and every space; copying keeps each line's time and sender.
- **Sharing.** Invite someone to one port. They join from their Port42 or from a browser at
  tele.port42.ai, through a relay that cannot read the traffic (end-to-end encrypted). You choose what
  they can do, and stop sharing at any time. Run your own relay if you prefer (`docs/run-a-relay.md`).
- **Voice.** Hold space to talk, in any field of Port42 and, with Accessibility, in other apps. The
  speech model runs on your Mac. Letting go sends it.
- **One API.** Everything the app does is a method: from a port's page, from your agents, and from
  the `port42` command.

Security: callers from other machines are refused unless an invite grants them a specific port, and
each right is granted per port. An invite admits two machines (a browser, then the app) and can
require a code; five wrong codes close it.

Requires macOS 14 or later, on Apple silicon.
