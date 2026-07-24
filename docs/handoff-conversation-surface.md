# Handoff: The Conversation Surface

Living status for the next session. The thread: making the chat a real surface — ports that live in the
conversation (beside the reply, inline cards, terminals that open in open water) and the onboarding that
introduces it. Grounded from git, not memory.

## Where things are

- Branch `main`, HEAD `246137c`, working tree clean (only `dist/` build artifacts).
- Dev (`:4243`) is running the latest build. Prod is `:4242`. **Test in Dev only, never prod.**

## Shipped this session (all pushed to main)

- `246137c` — **multi-line auto-expanding input** (grows to 10 rows then scrolls; Enter=send,
  Shift+Enter=newline). Required extracting the input field into an `inputTextField` computed property
  because `ConversationContent.body` was at SwiftUI's type-check ceiling.
- `bf60483` — **RCA-2.3 freeze fix** (confirmed live). A scroll-offset preference loop in
  `ConversationContent` re-evaluated `body` every frame under animating inline content; now debounced
  (commit scroll state only after the offset settles ~120ms). See `docs/rca-app-freeze-2.3.md`.
- `3b0bd9a` — **onboarding**: clearer Echo welcome (concrete, not mysterious), a living shader first
  port, a SEPARATE follow-up telling the user to create a terminal + launch claude code themselves;
  auto first-message is now "what is this place?". Plus `build.sh --dev2` (isolated fresh-boot instance:
  `com.port42.dev2` / `:4244` / `Port42Dev2`).
- `912b001` — **`port.publish`** primitive + consumer-model port instructions (ports-context/core, llms).
- Roadmap + specs across `docs/summer2026-todo.md`: busWatch companions (synth tick jam), teleport CLI,
  reopen-closed-ports, invisible ports, share-a-port's-code, terminal-cards→open-water, ports-beside-
  response. Plus `docs/spike-synth-tick-architecture.md`.

## Next steps (do these first)

Read `docs/plan-chat-ui.md` — it has the ordered plan + 2026-07-24 findings. Then:

1. **Chat-UI step 2 — ports beside the response.** When there's horizontal room, render a message's port
   segment to the RIGHT of the text (full-screen first swim has wide gutters); inline-below when narrow.
   In `ConversationContent.swift` `MessageRow` (~830–905). NOTE: "pop" already means pop-out-to-desktop —
   name this differently (beside / side-by-side).
2. **Chat-UI step 3 — terminal cards that open in open water.** Terminal/web port cards already exist
   (`ChatEntry.terminalPortInfo` = `[terminal:<id>:<title>]`, `webPortInfo` = `[port:<id>:<title>]`).
   Ensure a created terminal emits its card, render it as a `PortCompactBlock`-style block, and make its
   open action route to **open water + focus the terminal** (not inline render).
3. **Instruction-review fixes** (never applied — a review agent produced them earlier this session):
   storage `value` type mismatch (llms says string, context says any-JSON — data-loss risk), `port.patch`
   RELOADS note (like `port.update`), window→tile wording, drop the `if (space)` guard in examples,
   `port.manage` action vocab drift, `screen_capture`→`screen.capture` in llms, etc. Re-run the review or
   apply from memory. Files: `Sources/Port42Lib/Resources/ports-context.txt`, `ports-core.txt`, `llms.txt`.

Bigger builds when GM wants them: **busWatch** trigger (the synth tick jam's missing primitive — spec in
`spike-synth-tick-architecture.md`) and **teleport** CLI.

## Hard rules (survive the boundary)

- Test in **Port42Dev (:4243) only**, never prod.
- **Never run `./build.sh` or relaunch Dev without asking** — it kills GM's in-flight work. (GM asks
  explicitly when they want a build.)
- **Do not commit or refactor unless asked.** Fix root causes.
- Build gotcha: if `./build.sh` fails with cp "Operation not permitted" on resources, clear stale
  xattrs: `xattr -cr .build/arm64-apple-macosx/debug`. Never pipe `./build.sh` through `head`/`tail`
  (SIGPIPE kills it mid-assembly) — redirect to a file.
- `ConversationContent.body` is at SwiftUI's type-check limit — extract into subviews before adding to it.
- No em dashes in prose; US spelling; report style in docs.
