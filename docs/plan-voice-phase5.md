# Voice input, Phase 5: other apps

Detail for Phase 5 of [plan-voice-input.md](plan-voice-input.md). Phases 1 to 4 are done: hold space
inside Port42 and the words stream into the focused surface.

## Scope

Hold space in Safari, Slack, Xcode, anywhere, and the words arrive there. Port42 does not need to be
frontmost or visible.

Three things are needed that the earlier phases did not: seeing the key when another app has it, putting
text into an app that is not ours, and showing the microphone when our own window is not on screen.

## What macOS allows, and at what price

| Need | Mechanism | Price |
|---|---|---|
| See space while another app has the keyboard | `CGEventTap` on the session tap | Accessibility. The tap sees every keystroke on the machine |
| Swallow or replay that space | Only a tap can, a global monitor cannot consume | as above |
| Type into another app | `CGEventCreateKeyboardEvent` with `CGEventKeyboardSetUnicodeString` | Accessibility. Works in AppKit, Electron and terminals alike, because it is literally typing |
| Read what is focused in another app | AX API (`kAXFocusedUIElement`) | Accessibility, and it is unreliable outside AppKit, so it is not used |
| Show the mic with no window | A non-activating floating panel at status-bar level | none |

Insertion is by synthesized typing rather than by the AX API: the AX path is the one that works in
TextEdit and fails in Electron and terminals, which is most of where this is wanted.

## Decisions

1. **The tap looks at one key and nothing else.** The callback reads a key code and modifier flags,
   decides, and returns. It never accumulates, stores, logs or forwards a keystroke. Nothing on the port
   bridge can reach it, and no port can ask for it. This is the whole security position of the phase, and
   it is pinned by a test rather than by a comment.
2. **Off until turned on.** The tap is installed only when the feature is switched on and Accessibility
   is granted. Voice inside Port42 keeps working with neither.
3. **Pass the space through, then take it back.** Same model as inside Port42: the space types, and a
   hold sends one backspace to the app. The alternative (hold the space for 200 ms and replay it if it
   was a tap) adds latency to every space typed anywhere on the machine, which is a worse trade for a
   feature that is not being used most of the time. Cost: in an app where backspace is not "delete a
   character" (a game, vim in normal mode), a hold leaves a stray space and a stray backspace.
4. **Partials type as the smallest edit.** The same prefix diff the terminal path already uses:
   backspaces plus a suffix. Nothing else works in an app we cannot compose into.
5. **The indicator is a panel, not a window.** Borderless, non-activating, ignores the mouse, status-bar
   level, bottom right of the screen with the frontmost app. It cannot take focus, so it cannot change
   where the words land.

## Build

- `VoiceGlobalTrigger`: the event tap, reusing the pure `VoiceTrigger` for hold-versus-tap, so the
  decision logic is the same code that is already tested.
- `VoiceTyper`: synthesized typing and backspacing, with the prefix diff from `VoiceInserter`.
- `VoiceHUD`: the floating panel that shows the hot mic when Port42 is not frontmost.
- Routing in `VoiceSession`: when a hold starts and Port42 is not frontmost, the words go to the typer
  instead of to the first responder.

## Tests

- The tap's decision, driven through `VoiceTrigger` with synthetic key codes: space with no modifiers is
  ours, space with any modifier is not, and every other key passes through untouched.
- The typer's plan for a partial: the edit from what was typed to what was heard, reusing the tested diff.
- A source gate: `CGEvent` appears only in the typer and the tap, and nowhere on the in-app path.
- A source gate: no bridge method and no tool reaches the tap or the typer.
- The panel cannot become key.

## Verify by hand

Turn it on, grant Accessibility. Hold space in TextEdit, in Safari's address bar, in Slack, in a terminal
outside Port42. The words arrive, wrapped by that app. Type normally in each: spaces behave. Turn it off:
holding space types a space, and nothing else happens.

## Known cost

A hold in an app that treats backspace as something other than "delete a character" leaves a stray space
and a stray backspace behind. Decision 3 accepts that in exchange for no added latency on every space
typed on the machine.
