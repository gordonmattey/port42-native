# Handoff: Port42 App Dev — Right-of-Way

## Where this left off (2026-07-26)

**HEAD `3c3f370`, branch `main`.** The tree is UNCOMMITTED (GM has not asked to commit) and carries
the cinematic fix, a SECURITY P0 fix, and L2 **R1, R1b, R2, R2b, R3** (+ the new `port.getDom`).
Full suite **1099 green**. Dev3 (`./build.sh --dev3 --run`, `:4245`) is running ALL of it, live-verified.
Dev3 builds no longer need GM's go-ahead (GM, 2026-07-26); Dev `:4243` and prod still do.

**v0.5.49 shipped** — notarized, stapled, GitHub Release, appcast pushed. Onboarding runs inside the
shell; all six phases of `plan-unify-onboarding-shell.md` are done.

### 1. DONE — the pre-boot cinematic regression (`summer2026-todo.md`, top item)

Fixed and live-verified on a fresh-data Dev3 launch (GM: "works great"). The cinematic had only ever
been triggered by `LockScreenView.diveIn()`, which first boot no longer renders, so it now runs from
the root instead: `RootScreen.playsBootCinematicAtLaunch(hasIdentity:isSetupComplete:)` is a pure
launch decision, and `TransitionRoot.onAppear` leaves `bootCinematicDone` **false** across it (so
`decide` returns `.none` and the overlay covers the gap, rather than the setup terminal rendering
under the video). `OnboardingShellTests` +2. Suite **1067 green**.

### 2. NEXT UP — the L2 protocol revision, R1–R7

`docs/plan-port42-protocol-local-bus.md` §"Phase L2 REVISED" is the current design; the section below
it is superseded and says so. Read the REVISED section, its **Verification** findings 1–7, and the
two spikes before writing code.

- **What L2.a–e originally built (now SUPERSEDED by R1–R3 below, kept for the history):** a per-port
  lease, a dispatch gate that REFUSED writes, the holder broadcast, a `human` principal,
  interaction-claims, and the tile-header chip. The refusal is gone; everything else became presence.
- **What the design became:** the lease conflated correctness with coordination. Correctness moves to
  **state tokens (CAS)** — one activity `seq` per port, bumped by every external mutation — and the
  lease is **demoted to presence** (shows who is driving, refuses nothing).
- **R1 (demote) is DONE**, both gates passed — including the manual one live in Dev3: GM clicked into
  a port (taking presence) and a gateway `port.exec` against it LANDED, where the pre-R1 build
  refused it by name. `claimWrite` → `recordDriving`,
  `LeaseRegistry.check` → `record`, `LeaseDecision.denied` deleted, `port_busy` gone from the
  codebase. The call it forced: **last driver wins** — the step's gate requires presence to MOVE on
  a second writer, and a record that refuses to move would leave the chip naming a companion that
  stopped while you type. See the plan's §"R1 as built". Suite **1067 green**.
- **Spike A is RUN** (see the plan's §"Spike A findings"). An in-memory dict on `AppState` works, with
  four corrections: resolve the port ONCE at the seam and share the key (the resolve is the only
  non-free part, not the lookup); do NOT make it `@Published` (R2b bumps per keystroke); do NOT
  forget it on close (opposite lifecycle to presence — a reset counter lets a token from a dead id
  pass against a reused one); and **a bare counter is unsafe across a restart**, so qualify the
  token with a per-launch epoch the way `ActorRef` was made peer-qualified from day one.
- **R2 is BUILT**, gate passed. `PortActivity` on `AppState`, token = **`<epoch>:<seq>`** (GM took
  A4: epoch now, not a wire-format migration at slice-02). The seam resolves the port once and hands
  one key to both the bump and `recordDriving`. The bump fires before the async body (wrong in the
  safe direction). The presence throttle deliberately does NOT reach the token — throttled, a
  4-second-old companion write would pass CAS against a line you are mid-way through typing.
- **R1b — rename + a throttle fix.** The lease was demoted but kept every one of its names, which
  made the whole subsystem unreadable (GM: "I thought we got rid of leasing"). `PortLease.swift` →
  `PortPresence.swift`, `LeaseRegistry` → `DriverRegistry`, `ClaimThrottle` → `PresenceThrottle`,
  wire `kind:"holder"` → `kind:"driver"`. Renaming it surfaced a live defect GM had already spotted:
  the 5s presence throttle meant a human clicking against a companion writing every 2s could NEVER
  win the header chip back. The throttle's premise ("re-claiming a lease you already hold is noise")
  died with the lock. Now it throttles a REFRESH and never a TAKEOVER. Suite **1081 green**.
- **R2b is BUILT**, gate passed, manual gate open. `GhosttyInputView.write(_:mode:)` is the ONLY
  caller of `ghostty_surface_text*`; five sites route through it (paste, file drop, inject's two
  halves, startup command, prefill), plus the web file-drop and browser address-bar paths. Pinned by
  `TerminalWriteFunnelTests`, a grep gate — the property is structural, not a list. Human keystrokes
  are a separate C entry point (`ghostty_surface_key`) with their own seam; the gate covers both so
  neither grows a second caller. Suite **1086 green**.
- **Spike B is RUN** (late — it gates R2's browser row and R2/R2b were built without it; the process
  lesson is in the plan). Answer: `didCommit` is necessary but NOT sufficient. Verified live that
  `history.pushState` changes the URL with no document load, so no commit fires and every SPA route
  change is invisible. Use **KVO on `webView.url`**. Browser CAS is the weakest token, with a reason
  now rather than a suspicion.
- **Spike B also found a SECURITY P0** (`summer2026-todo.md`, top): a normal web port's JS can
  navigate to any site and the `window.port42` bridge FOLLOWS IT. Live-verified — a page on
  `example.com` called `ports.list()` and got the user's real ports back. The nav policy allows
  `.other` (script-initiated, the hostile case) and cancels `.linkActivated` (a human clicking), the
  inverse of its stated intent. Browser ports carry the bridge onto every site by construction.
- **Spike C is RUN, partially** — the input sweep across all surfaces. Six ad-hoc seams for "input
  reached a port", split by surface TECHNOLOGY, which is the root cause of finding 7 repeating. The
  web listener is `keydown`+`pointerdown` only, so voice/IME/context-paste/autofill are suspected
  blind spots. **The remaining half needs a live probe with real input devices** — do not fix against
  a guessed list.
- **MEMBRANE REVIEW is on the backlog** (`summer2026-todo.md`) and **should be decided before R4/R5**:
  one `PortInput` seam carrying `(port, kind, actor, trusted)`, each surface technology reduced to
  translating into it. R5 ("terminals require a token") is only sound if every way in counts.
- **R3 (CAS) is DONE**, gate passed and live-verified — the first step that REFUSES anything, and the
  replacement for the lock R1 removed. Optional `expect` on every write verb; a mismatch throws
  `stale_write` carrying `current`, so a caller self-corrects in one retry. `expect` is injected
  centrally (`mapValues { $0.acceptingExpect() }`), so a write verb added tomorrow gets CAS by
  construction. Live: a 5-second-stale write was refused and the clobber never landed.
- **`port.getDom` is NEW, and came out of a gap R3 exposed.** `port.exec` is correctly a write, so
  inspecting a live port bumped its token and a caller invalidated its own read — "write against what
  you saw" was not expressible. `getDom(id, selector?) → {html, token}` is a true read: no bump, no
  `js` parameter (so a mutation cannot be smuggled through a read verb), and html+token from one
  instant. `port.getHtml` remains the stored SOURCE, which does not reflect live `exec`/`push`.
- **Next: the MEMBRANE decision**, before R4/R5 (see Spike C and the backlog item). Then R4–R7.
  Suite **1099 green**.
- **The rule that came out of it:** *bump at the SURFACE, not the API*. Enumerating callers failed
  three times (finding 7); the guarantee has to be structural, verifiable by grep.

### 3. Security thread (open)

`docs/plan-gateway-auth-tls.md`: P0 shipped (gateway binds loopback). P1 — authenticating `/call`,
which today authenticates nobody — is open, and the callers are the work.
`docs/decision-identity-model.md` settles person/instance/actor and is the shared input to L2, the
gateway, and slice-02. **A port can still forge the human's presence claim** (`isTrusted` is
shadowable); R7 moves the claim to the native monitor.

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
