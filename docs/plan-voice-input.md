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

### Phase 1: the trigger

A pure state machine for hold-versus-tap, wired to the key monitor, with a visible indicator and the
retract working on all three surfaces. **No microphone, no model.** Holding space shows that capture
would have started; releasing shows it would have ended.

This is first because it is the riskiest interaction and the cheapest to abandon. If the retract
flickers unacceptably in a Ghostty surface, the trigger changes and nothing else has been built on it.

*Verify:* type normally and spaces behave. Hold space in a terminal, a web port and the chat input:
one space appears and vanishes, the indicator shows, release clears it. Key repeat does not type
extra spaces. A space with any modifier is untouched.

### Phase 2: capture and transcribe

FluidAudio as a package dependency, Parakeet downloaded on first use, microphone capture between the
threshold and key-up, transcription on release. Text is logged, not inserted.

*Verify:* speak a known sentence, read it in the log. Measure time from release to text.

### Phase 3: insertion

Wire Phase 2's text into the Phase 1 trigger through `insertText` on the focused responder.

*Verify:* dictate into a terminal, a web port and the chat. The text arrives, attributed to the human,
and a terminal's `onHumanInput` fires.

### Phase 4: the surface

A microphone indicator the shell draws, because a port must not be able to suppress what it does not
draw. Streaming partials, if the re-decode cost measured in the research holds. The permission flow.

### Phase 5: other apps

Accessibility, clipboard-plus-paste with CGEvent as fallback. Separate because it needs a permission
the earlier phases do not.

## Not in this plan

Voice as a port. The mic and transcriber could be one later; the trigger and the routing cannot be,
because each needs what the port model withholds.
