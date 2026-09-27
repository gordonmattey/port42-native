# Voice input: the plan

Branch `voice-input`, from `nautilus` at `a7463a3`. Research in `docs/research/voice-input.md` and
`docs/research/local-speech-model.md` on the `research` branch.

## The feature

Hold space past a threshold, speak, release. The text appears where the cursor is, as if typed.
Transcription is local. Inside Port42 first; other apps later, behind Accessibility.

## Decisions already made

- **Trigger: hold space, insert and retract.** The space is inserted normally so typing is untouched;
  if the key is still down at the threshold, a backspace retracts it and capture begins. Delaying
  delivery would lag every space typed.
- **Model: Parakeet TDT 0.6B v3 via FluidAudio**, on the Neural Engine. Chosen because WhisperKit
  drops words at Whisper's 30 second boundary and the intended utterances are 30 to 40 seconds.
- **Insertion: one path.** `(window.firstResponder as? NSTextInputClient)?.insertText(...)` reaches a
  terminal, a web port and a text field alike, as human input. Not `port.push`, which would attribute
  speech to a programmatic caller.
- **The shell owns this, not a port.** A hidden port holding a microphone is the construction the
  security work rules out.

## Phases

Each ships alone and is verifiable without the next.

### Phase 1: the trigger (DONE 2026-09-26, interaction confirmed in a dev instance)

A pure state machine for hold-versus-tap, wired to the key monitor, with a visible indicator and the
retract working on all three surfaces. **No microphone, no model.** Holding space shows that capture
would have started; releasing shows it would have ended.

This is first because it is the riskiest interaction and the cheapest to abandon. If the retract
flickers unacceptably in a Ghostty surface, the trigger changes and nothing else has been built on it.

*Verify:* type normally and spaces behave. Hold space in a terminal, a web port and the chat input:
one space appears and vanishes, the indicator shows, release clears it. Key repeat does not type
extra spaces. A space with any modifier is untouched.

*What shipped:*

- `VoiceTrigger` (`Sources/Port42Lib/Services/VoiceTrigger.swift`), pure and synchronous, 0.2s
  threshold, 14 tests in `Tests/Port42Tests/VoiceTriggerTests.swift`. Two gates calibrated by
  breaking them (the modifier guard, and the swallow of repeats while pending).
- Wired into `ShellView`'s `.keyDown` monitor ahead of the shell chords and the editor yield, so the
  hold is seen while a field, a web port or a terminal holds the keyboard. A `.keyUp` monitor closes
  it. The threshold is a timer armed only on a pending press and cancelled on key-up; if it fires
  late the machine refuses to begin.
- `ShellState.voiceCapturing` plus `VoiceIndicator`, drawn in the shell's overlay stack at
  zIndex 220, under the blocking permission overlay. The shell draws it, not a port, so nothing can
  listen without saying so.
- The retract goes through the responder chain (`deleteBackward:`), guarded by `responds(to:)` so a
  surface that does not implement it gets silence rather than a beep.

### Phase 2: capture and transcribe

Detailed plan: [plan-voice-phase2.md](plan-voice-phase2.md).

FluidAudio as a package dependency, Parakeet downloaded on first use, microphone capture between the
threshold and key-up, transcription on release. Text is logged, not inserted.

*Verify:* speak a known sentence, read it in the log. Measure time from release to text.

### Phase 3: insertion (DONE 2026-09-26)

One seam for all three surfaces: `NSTextInputClient` on the first responder, which is the same seam a
keystroke arrives on, so a surface cannot tell dictation from typing. Conformance is the test, not
`responds(to: "insertText:")`: NSResponder declares that method, so every responder claims to answer
it, including ones that type nothing. Dictation ends with one space, never doubled. Nowhere to type is
reported in the capsule rather than swallowed. The retract now uses the same seam.

Wire Phase 2's text into the Phase 1 trigger through `insertText` on the focused responder.

*Verify:* dictate into a terminal, a web port and the chat. The text arrives, attributed to the human,
and a terminal's `onHumanInput` fires.

### Phase 4: the surface

A microphone indicator the shell draws, because a port must not be able to suppress what it does not
draw. Streaming partials, if the re-decode cost measured in the research holds. The permission flow.

### Phase 5: other apps

Accessibility, clipboard-plus-paste with CGEvent as fallback. Separate because it needs a permission
the earlier phases do not.

## Shipping the model

Licenses, measured 2026-09-26:

| Thing | License | Note |
|---|---|---|
| FluidAudio (the Swift package) | Apache 2.0 | `LICENSE` in the repo, and GitHub's own license field |
| The weights, `FluidInference/parakeet-tdt-0.6b-v3-coreml` | CC BY 4.0, not gated | HuggingFace model API; converted from `nvidia/parakeet-tdt-0.6b-v3` |

CC BY 4.0 allows commercial redistribution with attribution, so bundling the weights is legally open.
Attribution belongs in `Sources/Port42Lib/Resources/THIRD-PARTY-LICENSES.txt`, naming NVIDIA for the
model and FluidInference for the Core ML conversion.

Three ways to ship 461 MB of weights:

1. **Download at setup, opt-in.** The DMG does not change size, one copy serves every instance on the
   machine (FluidAudio's cache is per user, not per app), and the download is a step the person agrees
   to rather than something a hold triggers. Costs a progress surface and a retry path.
2. **Bundle in the DMG.** Voice works with no network and no setup step, at the cost of 461 MB on every
   download and on every Sparkle update that is not a delta.
3. **Download on the first hold.** No setup friction, but the first dictation is the one that waits, and
   that is the hold a person is most likely to judge the feature by.

Position: 1, with the flag that already gates it (`voiceModelDownloadAllowed`) becoming the setup
step's answer. 3 is what is wired today for testing.

## Not in this plan

Voice as a port. The mic and transcriber could be one later; the trigger and the routing cannot be,
because each needs what the port model withholds.
