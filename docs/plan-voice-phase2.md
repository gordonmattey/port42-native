# Voice input, Phase 2: capture and transcribe

Detail for Phase 2 of [plan-voice-input.md](plan-voice-input.md). Phase 1 (the trigger) is done and
confirmed in a dev instance.

## Scope

A hold produces text. Capture starts on `beginCapture`, stops on `endCapture`, the audio is
transcribed, and the text is reported. **Insertion is Phase 3**, so this phase ends with the text in
the log and in the indicator, not in the field. That keeps the model work separable from the
responder work: if transcription is wrong, nothing has been typed into a document to undo.

## Measured, not assumed

| Fact | Value | Source |
|---|---|---|
| Package | `FluidInference/FluidAudio`, from `0.12.4` | repo README, read 2026-09-26 |
| Toolchain | Swift 6.0+, macOS and iOS | repo README |
| Default model | Parakeet TDT v3, 25 European languages plus Japanese | repo README |
| TDT v3 on disk | ~480 MB | Documentation/ASR/GettingStarted.md |
| Weights | downloaded from HuggingFace on first use; `ModelRegistry.baseURL` allows a custom or offline source | repo README |
| Audio in | 16 kHz mono; `[Float]`, `AVAudioPCMBuffer` or a file URL | repo README |
| Batch API | `transcribe(_ samples: [Float], source:) async throws -> TranscriptionResult` with `text` and `confidence`, no timings | GettingStarted.md |
| Streaming | `SlidingWindowAsrManager` exists; signatures not documented | GettingStarted.md |
| Throughput | ~190x realtime on an M4 Pro for batch | repo README |
| Parakeet Redux | ~220 MB, requires macOS 15 | GettingStarted.md |
| TDT v3 minimum macOS | **not documented** | open risk, below |

What the app already has:

- `AudioBridge.swift` (365 lines) already runs `AVAudioEngine` with an input tap and
  `SFSpeechRecognizer`, emitting `audio.transcription` events. It is **port owned**: a port calls
  `audio.capture`, the grant and the teardown hang off that port's life.
- `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` are already in
  `Info.plist`.
- `PermissionCoordinator` already has a `.microphone` permission with a per-caller grant.

## Decisions

1. **Batch on release, not streaming.** Insertion happens at release, so partials only serve the
   indicator, which is Phase 4. At ~190x realtime a 40 second utterance returns in well under a
   second, so there is nothing for streaming to hide. This also avoids an undocumented API surface.
2. **Its own capture object, not `AudioBridge`.** `AudioBridge` is shaped around a port that asks and
   a port that dies. Voice input is the shell capturing for the person at the keyboard, with no port
   in the picture, and it must not inherit port-ownership teardown. The tap and format conversion are
   the same shape and are written the same way.
3. **The keystroke is the authorization, the OS prompt is the gate.** No `PermissionCoordinator`
   entry: the shell is not a caller asking on someone's behalf, and a Port42 grant would imply a port
   could hold it. The macOS microphone prompt is the only consent surface, plus the system's own
   orange indicator, plus the shell's own "listening" capsule from Phase 1.
4. **Model downloaded on first use, not bundled.** 480 MB cannot ride in the DMG.
   `ModelRegistry.baseURL` keeps self-hosting available later without changing call sites.
5. **A hold with no model still works.** It captures nothing and the indicator says the model is not
   ready. The trigger must never depend on the model, or a failed download breaks the space bar.

## Build

- `VoiceCapture` (`Services/`): starts an `AVAudioEngine` input tap, converts to 16 kHz mono via
  `AVAudioConverter`, accumulates `[Float]`, returns the buffer on stop, tears the engine down on
  every exit path. No model, no transcription.
- `VoiceTranscriber` protocol with one method, plus `FluidVoiceTranscriber` (the real one) and a fake
  for tests. The protocol is what keeps the tests off the Neural Engine and off the network.
- `VoiceModel`: an `absent / downloading(progress) / ready / failed(reason)` state published on
  `ShellState`, so the indicator can say which of the three it is.
- `VoiceSession`: owns capture and the transcriber, driven by the `VoiceTrigger` actions already
  wired in `ShellView`.

## Tests

- 16 kHz mono conversion from a synthetic 44.1 kHz stereo buffer, sample count and duration.
- Buffer accumulation across many tap callbacks, and that a stop with no samples returns empty rather
  than throwing.
- The session against the fake transcriber: begin, end, text reported once, and a second hold works.
- A hold while the model is `absent` starts no engine and reports no text.
- **Mic leak gate:** after `endCapture`, and after an error mid-capture, no engine is running. This is
  the one that matters, an engine left running is a live microphone.
- A port's `audio.capture` still works while voice is idle (the two engines must coexist).

## Verify by hand

Hold, speak, release. The text lands in the log and in the indicator. A 40 second utterance comes
back whole. A second hold works. The system microphone indicator goes out on release. Holding with no
model shows the download state and types nothing.

## Open risk

The minimum macOS for TDT v3 is not documented, and the app's floor is macOS 14. Redux is documented
as macOS 15. If v3 also needs 15, the choice is a lower model, a raised floor, or voice input gated
to macOS 15. This is measured at the start of the build, before anything is wired to it.
