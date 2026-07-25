# Plan: unify onboarding into the shell (retire the separate first-swim chrome) — 2026-07-24

Decision (GM, 2026-07-24): the first-swim onboarding must run inside the real shell, not a bespoke
`SetupView` surface. One chat chrome everywhere. This fixes three things at once: the port card's
open/pop action navigates to open water, the onboarding chrome matches the regular chrome, and the
centered-column chat layout is applied once.

## Root cause (why the three symptoms are one seam)

- `TransitionRoot` shows **`SetupView`** until the user presses the 🐬 "swim in open water" button,
  which posts `.enterAquariumRequested` → a breakout video → **`ShellView`** permanently.
- `SetupView` is a phase machine: `boot → name → auth → consent → transition → swim`. Only the
  **`.swim`** phase (`SetupView.swift` ~771-847) hosts the chat, with its own branded top bar + the
  🐬 button. The pre-chat phases (boot/name/auth/consent) are real setup and stay.
- The regular experience: `ChatView` hosts the same `ConversationContent` inside a shell chat tile.
  Every space has a chat tile (`ShellView.swift:589`). Zoom spine: galaxy ↔ space ↔ focus.
  `.space` = open water (the desktop with all tiles); `.focus(id)` = one unit front-and-center.
- `enterOpenWater()` = zoom `.space`. It works in the shell but not in `SetupView` (which sits on
  top of the shell), so the port card's open/pop can't navigate during onboarding.

## Target

- Keep `SetupView`'s pre-chat phases. **Replace the `.swim` phase**: after `completeSetup`, drop
  into `ShellView` with the space's **chat tile focused** (`.focus(chatTile)`), and seed the first
  message there. The first swim looks front-and-center as it does today, but it IS the shell.
- "Swim into open water" becomes the **normal zoom-out** (focus → space), the existing gesture the
  rest of the app already uses. Retire the branded bar + the bespoke swim `ConversationContent` host.
- Apply the **centered-column** chat layout (a max-width middle column with space top/bottom, the
  background showing around it) to `ConversationContent`, so it reads the same in onboarding and
  regular use.

## Design review: components, interfaces, invariants, dependencies

### Components touched (role · current interface · change)

- **`TransitionRoot`** (View, root screen selector). State: `transitionPhase` (none/playingVideo/
  fadingOut), `isDiving`, dreamscape/bootCinematic flags. Reads `appState.isSetupComplete`. Selects
  LockScreen / ShellView / SetupView (body ~50-57); owns the breakout video; handles
  `.enterAquariumRequested` → `startEnterAquariumTransition()` → flips `isSetupComplete = true` after
  a 1s dive. **Change:** re-point the SetupView→Shell selection + move the flip earlier.
- **`SetupView`** (View, onboarding phase machine `boot→name→auth→consent→transition→swim`). `.swim`
  hosts `ConversationContent` + the branded bar + the 🐬 button. **Change:** delete the `.swim` phase;
  end onboarding by handing to the shell.
- **`AppState.completeSetup(displayName:)`**: creates the space, welcome msg, Echo, `startSwim`.
  **Change:** signal onboarding + drive the first-message/focus, and own the flip point.
- **`AppState.isSetupComplete`** (`@Published`, `didSet` at 729 gated on `portPanelsRestored`). The
  root gate. **Change:** flip at completeSetup/onboarding-complete instead of at the 🐬 dive.
- **`ShellState`** (pure `@MainActor` state, `ShellStateTests`-gated — the good home for invariants).
  `Zoom = galaxy | space | focus(udid)`; `initialZoom(hasCurrentSpace:allRested:)`; `enterOpenWater()`.
  **Change:** `initialZoom` gains an onboarding input → `.focus(chatUdid)`; add a one-shot onboarding
  flag + nudge state.
- **`ShellView`** (hosts `ShellDesktop`, sets initial zoom ~243, zoom `onChange` side effects).
  **Change:** honor the onboarding initial focus + host the first-run nudge.
- **`ChatView` / `ConversationContent`**: the chat surface. **Change:** centered-column layout (B).
- **Chat `PortPanel`** (`isChatPort == true`, one per space — the focus target udid is
  `appState.portWindows.panels.first { $0.isChatPort && $0.spaceId == sid }?.udid`).

### New/changed interfaces (extract as pure → testable)

- `RootScreen.decide(isSetupComplete:transitionPhase:onboarding:) -> {lock|shell|setup|transition}` —
  replaces the inline `if/else if` in `TransitionRoot.body`. Pure truth table.
- `ShellState.initialZoom(hasCurrentSpace:allRested:onboarding:chatUdid:) -> Zoom` — onboarding ⇒
  `.focus(chatUdid)`, else existing behavior. Pure.
- `AppState.isOnboarding` (one-shot): true from completeSetup until the first open-water; drives the
  initial focus + the nudge; cleared on first zoom-out. Reset semantics mirror `isSetupComplete`.
- First-message seeding hook: fires once when the shell chat is live and only if messages are empty
  (moved from `SetupView.sendFirstMessage`, same empty-guard).

### Invariants that must hold

1. `isSetupComplete` is monotonic within a session (false→true once; reset only on sign-out, 3304/3338).
2. Exactly one `isChatPort` panel per space — the focus target always resolves.
3. **Ordering:** the chat panel exists + `portPanelsRestored` before the shell focuses it. The flip
   must not outrun panel creation (the `isSetupComplete.didSet` already gates on `portPanelsRestored` —
   reuse that, don't bypass it). This is the crux hazard.
   **SPIKE 1 VERIFIED (2026-07-24, read-only):** invariant holds. `switchToSpace()`
   (`PortWindowManager.swift:940`) calls `ensureChatPort()` which creates the `isChatPort` panel if
   absent; `switchToSpace` fires from `isSetupComplete.didSet` / the `portPanelsRestored` block once
   BOTH the flip and restore are true. So the chat panel is guaranteed present by the time the shell
   shows the space. **Caveat for phase 2:** the onboarding `.focus(chatUdid)` must be applied
   REACTIVELY when the chat panel appears (post-`ensureChatPort`), not at a fixed `ShellView.onAppear`
   — otherwise it races an empty panel list.
4. Returning user (setup already complete) gets NO onboarding focus/nudge — normal `initialZoom`.
5. `focus(udid)` is valid only while that udid is a live desktop unit (`exitFocusIfGone` already guards).
6. `completeSetup` stays behind `isTestProcess` for the sync/gateway path (prior SIGTERM incident).

### Dependency / coupling flow

`SetupView.submitName → completeSetup → (space · Echo · chat panel · startSwim) → isSetupComplete flip
→ TransitionRoot selects ShellView → ShellState.initialZoom(onboarding, chatUdid) → focus chat →
seed first message → Echo plays`. ShellState only READS AppState (clean). The one fragile node is
`TransitionRoot`'s timing-based transition machine (`DispatchQueue.asyncAfter` dive/breakout/boot) —
minimize touching it; reuse the existing `isSetupComplete` flip rather than adding a parallel path.

### Reviewed vs. not (honesty)

- **Reviewed:** TransitionRoot root logic + both transitions + the flip; SetupView phase flow + swim +
  submitName; ChatView; ConversationContent card/inline path; ShellState enum/zoom/initialZoom;
  completeSetup; chat-tile identity.
- **NOT yet fully reviewed (confirm during phase 1 before editing):** ShellView's initialZoom
  application (~243) + zoom `onChange` side effects; ShellDesktop's chat-tile render + focus mechanics;
  the breakout video internals; `portPanelsRestored` sequencing vs completeSetup; peek-path
  interactions with a focused chat. These are all in the phase-1 blast radius.

### Assessment

Component boundaries are reasonable: `ShellState` is already pure and test-gated (the right home for
the zoom/onboarding invariants), the root selection cleanly extracts to a pure function, and the
onboarding flag is a small, well-scoped addition. The **only** high-risk coupling is TransitionRoot's
timing-based transition state machine — the plan deliberately reuses its existing `isSetupComplete`
flip instead of threading a new path through it. Net: the interfaces are clean enough to proceed,
provided phase 1 confirms the `portPanelsRestored`-before-focus ordering (invariant 3) first.

## Phases

1. **Entry seam.** BUILT 2026-07-24. `SetupView.startTransition` ends in
   `AppState.enterShellFromSetup()` (sets the one-shot `isOnboarding`, THEN flips
   `isSetupComplete`, so the flip's `didSet` → `switchToSpace` → `ensureChatPort` still
   guarantees the chat tile). `TransitionRoot`'s inline if-chain became the pure
   `RootScreen.decide(showDreamscape:isSetupComplete:transitionPlaying:bootCinematicDone:)`.
   The first-run flip takes a BLACK reveal (0.45s hold, 0.9s ease-out), not the dive: the blue
   dive tint read as a flash at this seam (GM). Breakout video skipped here.
   Two decisions taken while building:
   - **First boot goes straight to the BIOS** (GM): `loadInitialState` sets
     `showDreamscape = false` when there is no identity, so a fresh install never shows the lock
     screen or the dreamscape loop. `TransitionRoot.onAppear` now sets `bootCinematicDone`
     unconditionally (it was already true on every launch, since `showDreamscape` started true).
     The boot terminal renders on a black plate, no video behind it.
   - **The first space is `genesis`** (GM): a direct space is named after its companion, which
     read as a space called "echo" next to the companion echo. `completeSetup` renames it right
     after `startSwim`. Later DMs keep companion names.
2. **Focus the chat tile on first run.** BUILT 2026-07-24.
   `ShellState.initialZoom` gained `onboarding:`/`chatUdid:` (defaulted, existing callers
   untouched); onboarding with no udid yet holds at `.space`, never the galaxy. `ShellView`
   applies the focus REACTIVELY (`onChange(of: onboardingChatUdid)` + `onAppear`), latched by
   `onboardingFocusApplied` — the Spike-1 caveat.
3. **Seed the first message in-shell.** BUILT 2026-07-24. `AppState.seedOnboardingFirstMessage()`
   (one-shot + the empty-guard moved from `SetupView.sendFirstMessage`), fired at the same point
   the focus lands. **It PREFILLS the chat input rather than sending** (GM: the first thing that
   happens in Port42 should be something the user chose to do) — same call as the terminal's
   `initialInput`. Written to `chatDrafts` after the input mounts; `ConversationContent` now picks
   up an externally written draft (it only read one on appear), guarded so it never overwrites
   typing.
   **Bug found and fixed here, not in this seam:** Echo stopped after "Now let me get the space
   context…". `LLMEngine.continueWithToolResults` rebuilt each round from the caller's ORIGINAL
   messages, dropping every earlier round — the model never saw results it already had, re-called
   the same tools (`help` → `space_current` → `help` …), and hit the depth limit at 6/5 before
   writing anything. The engine now carries a running `continuationMessages` transcript. This
   affected every multi-round tool turn in the app, not just onboarding.
   **Two more root causes found the same way (both wider than onboarding):**
   - **Double turn per message.** `sendMessage` excluded only `.allMessages` companions from the
     initiative check, on the premise that mentionOnly companions are not in normal routing.
     False: `findTargetAgents` returns EVERY space member when there are no @mentions, and
     `launchAgents` does not filter by trigger. So a DM's sole companion ran twice whenever it
     also matched an initiative signal — two turns, and two of whatever the turn made (GM saw two
     terminals from one request). Now excludes every target normal routing launched.
   - **The welcome port arrived before the text, as a card.** Echo built it with the `port_create`
     TOOL instead of a `` ```port `` fence: a tool call executes mid-turn, so its card posts ahead
     of the message text, and a tool-created port is a desktop tile, not a live inline surface.
     `echo-prompt.txt` now specifies fence for the welcome port, tool for the terminal, with why.
4. **First-run "swim into open water" affordance.** RESOLVED (GM, 2026-07-24): **Echo narrates it,
   there is no shell chrome for it.** `echo-prompt.txt` now instructs that the message after the
   terminal port exists ends on ONE call to action — zoom out (trackpad pinch, or the top-right
   zoom-out button) to see the terminal on the desktop and chat with claude there — and explicitly
   not on "try giving it something to do". No bespoke nudge view, no dismissal state, nothing to
   test beyond the prompt. The CTA now points at the terminal's **prefilled line**: GM chose
   prefill-WITHOUT-send (`TerminalPortConfig.initialInput`, typed on the CLI's SessionStart with no
   trailing Enter), so the user zooms out to find claude holding a sentence they press Enter on.
5. **Port-width inline ports.** BUILT 2026-07-24, and NOT as originally planned. A centered
   max-width column for the whole conversation was built, shown, and rejected (GM): the text must
   run the FULL width of the chat; it is the inline PORT that holds a port's shape. So
   `ChatView` fills its host exactly as before (no cap, no centering, no transparent surround),
   and `InlinePortLayout.maxWidth = 520` caps the port segment — the width a port opens at on the
   desktop (terminal 520x380, chat 520x420), sitting beside the existing `minHeight` floor.
   Applied at the segment call site so it covers both the live inline port and the unactivated
   compact card; a chat narrower than 520 falls under the cap and fills.
   **Ports-beside-response is REMOVED** (GM: "never put it on the side"). Not disabled — the
   branch, the 720 threshold, the `availableWidth` state, the `MessageWidthKey` preference and
   its `GeometryReader` are all gone, so every message row is one less geometry reader and one
   less preference publish per resize. Reading order no longer changes with width.
6. **Retire the bespoke swim chrome.** Remove `SetupView`'s `.swim` phase (branded bar +
   `ConversationContent` host) and the now-redundant `.enterAquariumRequested` plumbing, keeping
   whatever the breakout transition still needs.

## Resolved flow (GM, 2026-07-24)

The full reworked first-run sequence:

1. **Boot terminal — NO background video.** The setup phases (boot/name/auth/consent) render as the
   terminal window with no dreamscape video behind them. (Today `showDreamscapeVideo` is true during
   setup; drop that for the boot terminal.)
2. **Drop into the focused chat in your first space** — the swim with Echo IS the shell's focus view
   on the chat tile. Echo plays the welcome + shader port + split nudge here.
3. **After the first port (terminal), a hint:** "zoom out to see your space (or click the arrow
   top-right)." Just a text nudge pointing at the existing zoom-out arrow — not a special button.
4. **Kill the "swim in open water" 🐬 button.** The only exit is the normal zoom-out (arrow / ⌘↑ /
   gesture). "Out is the way."
5. **The first zoom-out (focus → space) plays the breakout video**, and at the end you're in your
   space view (open water). The breakout moves off the (deleted) 🐬 button onto the first focus→space
   transition.

Decisions, resolved: **(1) breakout video — reworked**, plays on the first zoom-out, not at boot;
**(2) nudge — a text hint + the existing top-right zoom-out arrow**, no bespoke button; **(3) centered
column — it IS the focus view** (the focused chat renders as the middle column on the background).

## Testing at each step

Principle: the **decision logic** at each seam is extracted into a pure function and gated with Swift
Testing; the **visual/navigation outcome** (SwiftUI views, zoom transitions, the breakout video —
none unit-testable) is verified manually in a fresh Dev3. Every phase has both, and no phase is
"done" until its manual check passes on a clean first-launch.

Test hazards to respect (from prior incidents): run suites by EXACT name, never a substring that
matches the module (`Port42Tests` → bare "Port" ran the whole suite and SIGTERMed the prod app);
`completeSetup` in a test process is now guarded by `isTestProcess` (keep it that way); never
interrupt a `swift build`/`swift test` (wedges the `.build` lock). Manual tests in Dev3 (:4245) only.

| Phase | Automated (Swift Testing, pure logic) | Manual (fresh Dev3) |
|---|---|---|
| 1. Entry seam | Extract `RootScreen.decide(isSetupComplete:transitionPhase:onboarding:)` → truth-table test: fresh → shell-onboarding, returning → shell, mid-transition → transition frame. | Fresh launch: name/auth/consent → lands in shell, chat focused, no blank frame, no double-render. |
| 2. Focus chat tile | `ShellState.initialZoom(…, onboarding:)` returns `.focus(chatTile)` on onboarding, existing behavior otherwise. | Chat is front-and-center on first run; a returning user is NOT force-focused. |
| 3. Seed first message | The onboarding hook enqueues exactly one "what is this place?" and only when messages are empty (guard test, moved from `SetupView.sendFirstMessage`). | Echo's welcome + shader port + split nudge play in the shell chat. |
| 4. Zoom-out nudge | Pure predicate: nudge shows only on first run, once, clears after first zoom-out. | Nudge appears after the terminal is made; zooming out to open water dismisses it; never returns. |
| 5. Centered-column layout | (none — pure visual) | Chat is a max-width centered column, background visible top/bottom/sides, in onboarding AND regular chat; resizes sanely. |
| 6. Retire swim chrome | Existing setup/shell suites stay green (`AppStateTests`, `ShellStateTests`, the setup-safety suite); no dead `.enterAquariumRequested` refs. | Full onboarding end-to-end + returning-user launch both land correctly; no orphaned branded bar. |

Cross-cutting regression (run once at the end): the returning-user launch (setup already complete)
still lands in the shell at the normal zoom with no onboarding focus/nudge; the port-card open,
pop-out, and terminal-card paths (already shipped this session) still navigate to open water.

## Risks

- The `SetupView` phase machine + `isSetupComplete`/`transitionPhase` timing is intricate; the entry
  seam (phase 1) is where a wrong gate shows a blank screen or double-renders.
- Fresh-user guidance: without the explicit swim button, a user could sit in the focused chat not
  knowing to zoom out. The one-time nudge mitigates.
- The returning-user path must keep landing in the shell normally (no onboarding focus).
