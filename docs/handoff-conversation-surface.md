# Handoff: Onboarding Into The Shell → the L2 lease

## Where this left off (2026-07-24, overnight)

**v0.5.49 shipped** (notarized, stapled, GitHub Release, appcast pushed): onboarding runs inside the
shell, all six phases of `plan-unify-onboarding-shell.md` done.

**Then, on GM's "build as much as possible until you need manual testing":**
`docs/plan-port42-protocol-local-bus.md` §L2 — the right-of-way lease — is built through **L2.d**,
full suite **1057 green**. Only **L2.e** (the holder shown in the tile header) is left, because it is
pure visual and has no automated gate. Read §L2's "What building it taught us" first: the biggest
item is that the header must SUBSCRIBE to the `holder` envelopes rather than read the lease, since
`LeaseRegistry` is not `@Published`.

**Waiting on GM (manual, in Dev3):** a companion writing to a port the human has zoomed into should
be refused by name, and focusing a port a companion is mid-write on should NOT steal it. Both are
unit-tested; neither has been seen live.

**Also shipped tonight:** the gateway binds loopback (`127.0.0.1:<port>`) instead of every interface
— the LAN could previously reach `/call`, which authenticates nobody and proxies into the bridge.
`docs/decision-identity-model.md` settles person/instance/actor and unblocked L2.

---

# Handoff: The Conversation Surface → Onboarding Into The Shell

Living status. The thread: making the chat a real surface for ports, and the onboarding around it. This
session shipped the generic port-card work and pivoted to a bigger piece: unifying the first-swim
onboarding into the real shell. Grounded from git, not memory.

## Where things are

- Branch `main`, HEAD `745e495`. **The working tree is intentionally DIRTY** — everything below is
  uncommitted (GM has not asked to commit). Do NOT commit unless asked.
- Dev3 (`:4245`) is the test instance this session (`build.sh --dev3`, isolated `com.port42.dev3`).
  Dev (`:4243`) may be running GM's Maker/Critic loop — **test in Dev3 only.** Note: booting a dev
  instance rewrites the global `~/.claude/CLAUDE.md` port42 block to that instance's port (currently
  `:4245`), so a Claude session leaning on it curls Dev3, not prod.

## Shipped this session (committed 2026-07-24; tested-working in Dev3 unless noted)

- **Generic port cards.** Any surface-type port created from chat leaves a `[portref:<kind>:<id>:<title>]`
  card inline; its open action = open water + focus the port. `PortCardKind` (public) + `portRefInfo` /
  `portRefCard` in `ConversationContent.swift`; `postPortCard` + `openPort(id:kind:)` in `AppState.swift`
  (createPort emits for terminal + tiled web, gated on `createdBy != nil`). Terminal card **confirmed
  working by GM.** Supersedes the per-type `[terminal:]`/`[port:]` cards (kept for old messages).
- **Companion multi-message split.** A reply splits on a `[[SPLIT]]`-only line into separate chat
  messages (`splitIntoMessages` + rewritten `llmDidFinish` in `AppState.swift`). Onboarding uses it:
  welcome+port, then a separate terminal nudge. Confirmed working.
- **Inline port height floor.** `InlinePortLayout.minHeight = 300` (inline-only; ports stay resizable on
  the desktop) — fixes the collapsed-strip shader. Confirmed.
- **Ports beside the response (chat-UI step 2).** `MessageRow` renders text-left / ports-right when wide
  (`portsRegion`, `MessageWidthKey`, 720pt threshold), stacked when narrow.
- **Pop-out / card-open → open water.** All three pop-out paths + the card open call
  `ShellState.enterOpenWater()` (zoom → `.space`).
- **`echo-prompt.txt`** rewrite: welcome grounded in `port42-growth/positioning-core.md` (live surfaces,
  yours/local; NO "open water"/multiplayer wording); a bolder full-bleed alive shader port; the terminal
  nudge as a separate `[[SPLIT]]` message telling the user to type, verbatim, "create a terminal port and
  run claude".
- **Terminal prefill (`initialInput`), GM 2026-07-24: prefill WITHOUT send.** A terminal port can
  open with a line waiting, unsent, in the CLI's input box — the user presses Enter. Teaches the
  grammar (plain language → a live surface) instead of describing it, and keeps the action theirs;
  auto-run was rejected because it spends the first impression on an action the user did not take
  and lands on claude's own first-run friction (folder-trust, auth). `TerminalPortConfig.initialInput`
  (tolerant decode) → `Coordinator.typePrefill` (types the burst with NO trailing `\r`, once per
  surface) → `PortWindowManager.prefillTerminal` → fired from `makeTerminalController`'s
  `onSessionStarted`, the only honest "the TUI is up" signal (a timer races claude's boot). Exposed
  as `initialInput` on `port.create`; `echo-prompt.txt` tells Echo to pass one on the onboarding
  terminal and to point the CTA at it. NOT carried by `terminalSpawnRecords`, so a respawn does not
  re-prefill — deliberate, a prefill is a first-run gesture.
- **Tool-loop context fix (`LLMEngine.continueWithToolResults`).** Each continuation rebuilt from
  the caller's original messages, so every round but the current one was dropped: the model
  re-called tools it had already run and burned the depth limit mid-reply. The engine now carries a
  running `continuationMessages` transcript. Found via onboarding (Echo stopping after its
  preamble), but it affected EVERY multi-round tool turn. Note: tool-heavy turns now carry their
  full context, so a turn that calls `help` keeps that ~15k for the rest of the round trip.
- **`build.sh --dev3`** (`com.port42.dev3` / `:4245` / `Port42Dev3`).
- **`docs/summer2026-todo.md`**: two roadmap items — claude turn-detection → cross-space port peek;
  gemini + codex CLI-companion parity (the loop is claude-specific today).

## Unify onboarding into the shell — phases 1-4 BUILT + COMMITTED (2026-07-24)

Onboarding now runs inside the real shell. `SetupView.startTransition` ends in
`AppState.enterShellFromSetup()`; the shell opens focused on the space's chat tile (applied
reactively, latched) and seeds the first message there. `SetupView.swim` is unreachable and
retires with phase 6. Also: first boot goes straight to the BIOS (no lock screen, no dreamscape
loop, black plate behind the terminal), the seam takes a black reveal plus a scale/opacity
materialize rather than the blue dive tint, and the first space is named `genesis`. The opening
line is PREFILLED in the input, not sent — the user presses Enter (same call as the terminal's
`initialInput`). Phase 4's nudge is resolved as prompt text in `echo-prompt.txt` (zoom out to the
terminal, where claude waits with a line already typed), not shell chrome. Full detail, including
the GM decisions and the THREE root-cause bugs found while testing it (LLMEngine tool-loop context
loss, double companion turn per message, welcome port posted as a tool card ahead of the text), is
in `docs/plan-unify-onboarding-shell.md` §Phases. New suite: `OnboardingShellTests` (11).

**Phase 5 BUILT but UNCOMMITTED** (in the tree, seen and approved by GM): inline ports are capped
at 520 (`InlinePortLayout.maxWidth`, a port's default width) while the TEXT keeps the full width of
the chat, and ports-beside-response is deleted outright. The centered-column layout the plan
originally called for was built, shown, and rejected — see the plan's phase 5 for what replaced it.

**ALL SIX PHASES DONE (2026-07-24).** Phase 6 deleted the `.swim` phase, the 🐬 button, the branded
bar, `sendFirstMessage`, `.enterAquariumRequested` + its transition, and the orphaned Settings sheet.
The breakout moved onto the first zoom-out: it starts on the focused port's frame, grows to full
screen over 2.6s, and any ladder move skips it. Setup is now the BIOS and the handover, nothing else.

## Original next-steps note (superseded by the section above)

Read **`docs/plan-unify-onboarding-shell.md`** in full — resolved flow, six phases, testing spine, the
component/interface/invariant review, and Spike 1's verified finding. Summary of the target flow (GM,
2026-07-24): boot terminal with NO background video → drop into the **focused shell chat** in the first
space (the swim = focus view on the chat tile) → after the first terminal port, a text hint "zoom out to
see your space (or the top-right arrow)" → **kill the 🐬 "swim in open water" button** → the first
zoom-out (focus→space) plays the breakout video and lands you in open water. Centered-column layout = the
focus view.

**Immediate next step: Phase 1 (entry seam).** After `completeSetup`, flip `isSetupComplete` + set a
one-shot `isOnboarding`, drop into `ShellView` instead of `SetupView.swim`, focus the chat tile
**reactively when the chat panel appears** (Spike-1 caveat — `switchToSpace`→`ensureChatPort` guarantees
it exists, but not at a fixed `onAppear`), seed the first message in-shell, and drop the boot-terminal
background video. Not yet: breakout-on-zoom-out, the hint, killing the 🐬 button, centered-column. Build
Phase 1, fresh-reset Dev3, verify onboarding lands in the focused shell chat with Echo playing and no
blank frame — that proves the risky part.

## Hard rules (survive the boundary)

- **Test in Dev3 (`:4245`) only** (`./build.sh --dev3 --run`), never prod. Fresh onboarding needs a data
  reset: move `~/Library/Application Support/Port42Dev3` aside, then relaunch.
- **Never run `./build.sh` or relaunch Dev without asking.** **Do not commit or refactor unless asked.**
- Build gotchas: on cp "Operation not permitted", `xattr -cr .build/arm64-apple-macosx/debug`. Never pipe
  `./build.sh` through head/tail (redirect to a file). `ConversationContent.body` is at the type-check
  limit — extract subviews before adding. `AppState` has no SwiftUI import (put view animation in
  `ShellState`). Run test suites by EXACT name (bare "Port" once SIGTERMed prod); keep `completeSetup`
  behind `isTestProcess`; never interrupt a build/test (wedges the `.build` lock).
- No em dashes in prose; US spelling; report style in docs.
