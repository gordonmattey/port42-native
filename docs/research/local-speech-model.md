# Local speech to text: the engine, the model, and the delivery

**Question (GM, 2026-09-26):** local speech to text with a better model than Apple's, delivered into
whatever Port42 surface is focused, and into other apps too.

Builds on [voice-input.md](voice-input.md), which established that macOS dictation already reaches all
three Port42 surfaces attributed to the human, that `GhosttyTerminalView` conforms to
`NSTextInputClient` and funnels through one write seam, that `requiresOnDeviceRecognition` is false so
Apple's path sends audio off the machine, and that "hold space" is dead. None of that is redone here.

Measured on this branch (`nautilus` merged with `origin/research`) and on this machine: MacBook Pro,
Apple M1 Max, 10 cores (8P/2E), 32 GB, macOS 15.6.1 (24G90), Xcode 26.3, Swift 6.2.4. Every runtime
below was built and run in `/tmp/p42-stt`, outside the repo, against no Port42 instance. Third-party
numbers are labeled as such. None of this is an approved decision.

---

## The answer

**Runtime and model: Parakeet TDT 0.6B v3 on the Neural Engine, via the FluidAudio Swift package.**
It is an SPM package at the macOS 14 floor, Apache-2.0 code over CC-BY-4.0 weights, 470 MB on disk,
and on the measurements below it beat Whisper on every axis that matters for this workload at the same
time: it transcribed a 37.5-second utterance completely in 0.61 s of wall clock where WhisperKit
dropped words at the 30-second boundary, it returned a correct one-word transcript where WhisperKit
returned nothing, it returned empty on silence where Whisper hallucinated, and it holds 117 MB against
WhisperKit's 266 MB and whisper.cpp's 852 MB.

**Delivery: one path for Port42's own surfaces, a second for everything else, behind one faculty.**
The first half is the finding. Measured, not inferred: `WKWebView` conforms to `NSTextInputClient` at
runtime although its public header never says so, and `insertText` on it produces
`beforeinput(insertText)` and `input(insertText)` in the page with no `keydown`, which is the exact
event signature that already counts dictation. A `TextField`'s first responder is the window's field
editor, an `NSTextView`, which conforms too. The terminal already conforms by source. So

```swift
(window.firstResponder as? NSTextInputClient)?
    .insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
```

delivers into a web port, a terminal port and the chat input, as the human, through the seams that
already exist. It is not three paths. It is the door the OS itself uses for dictation, called
directly.

**Two things changed from the prior note, and one of them was my instruction to change.** The blanket
refusal of `CGEventTap` was wrong as stated: the constraint is that a *port* must not do this
invisibly, not that Port42 may not ask for Accessibility like every other dictation utility. And
Apple's newer on-device speech API is not merely worse, it is unavailable: `SpeechTranscriber` is
`@available(macOS 26.0)`.

---

## 1. The macOS 14 floor, and what it rules out

The floor is real and declared in two places: `Package.swift:6` is `platforms: [.macOS(.v14)]`, and
`Info.plist:17-18` sets `LSMinimumSystemVersion` to `14.0`.

Apple's Speech framework rewrite is out of reach, and this is a hard fact read off the SDK on disk
rather than from documentation. In
`MacOSX.sdk/System/Library/Frameworks/Speech.framework/Modules/Speech.swiftmodule/arm64e-apple-macos.swiftinterface`:

| Line | Declaration | Availability |
|---|---|---|
| 220 | `final public actor SpeechAnalyzer` | `@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)` |
| 404 | `final public class SpeechTranscriber` | `@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)` |

Counted over that file: 21 declarations gated at macOS 26.0, four at macOS 14. **`SpeechAnalyzer` and
`SpeechTranscriber` are unavailable at this floor.** Raising the floor to macOS 26 to get them would
be a separate and much larger decision.

What Apple *does* offer at the floor is worth recording, because it bears on the vocabulary question
in §7. `SFSpeechLanguageModel` and `SFCustomLanguageModelData` are `API_AVAILABLE(ios(17), macos(14))`
(`SFSpeechLanguageModel.h:18`, `:48`; swiftinterface:595), so **custom language model boosting is
available on Apple's path today**. Separately `contextualStrings` exists, and its header caps it:
"Limit the total number of phrases to no more than 100" (`SFSpeechRecognitionRequest.h:45`).

---

## 2. The runtime options

Four candidates, on how they integrate rather than on how they benchmark.

| Runtime | Integration | Min macOS | Streams partials | Compute | License (code / weights) |
|---|---|---|---|---|---|
| **FluidAudio** | SPM package, `.library(name: "FluidAudio")` | **v14** (`Package.swift:8`) | Yes, two ways (§4) | CoreML, **ANE**, selectable | Apache-2.0 / CC-BY-4.0 (Parakeet) |
| **WhisperKit** (`argmax-oss-swift`) | SPM package | **v13** (`Package.swift:11`) | Yes, `AudioStreamTranscriber` | CoreML, **ANE** by default at macOS 14+ | MIT / MIT |
| **whisper.cpp** | **No SPM manifest.** XCFramework via `build-xcframework.sh`, or a C module map | none declared | Chunked re-decode only | Metal GPU; CoreML **encoder only** | MIT / MIT (HF tag confirmed, §3) |
| **Apple `SFSpeechRecognizer`** | In-tree already (`AudioBridge.swift`) | 10.15 | Yes, `shouldReportPartialResults` | Opaque | n/a |
| MLX (`mlx-swift`, `mlx-audio-swift`) | SPM package | v14 | Model-dependent | **GPU only, no ANE** | MIT |

Three integration findings that only appear when you actually build them.

**WhisperKit's library builds; its own CLI does not.** `swift build -c release --target WhisperKit`
succeeds in 15.4 s with zero errors. `swift build --product whisperkit-cli` **fails**, because the
`whisperkit-cli` executable maps to the `ArgmaxCLI` target which pulls in `ArgmaxOSS` and therefore
`TTSKit`, and `TTSKit` does not compile under Swift 6.2.4 against the macOS 26.2 SDK:

```
Sources/TTSKit/Qwen3TTS/Qwen3SpeechDecoder.swift:190:30: error: non-Sendable type 'MLModelAsset'
cannot exit caller isolation inheriting-isolated context in call to nonisolated property 'functionNames'
```

This does not block Port42, because the `WhisperKit` library product declares only `ArgmaxCore` as a
dependency (`Package.swift:65-70`), so a consumer that imports `WhisperKit` never compiles `TTSKit`. I
verified that by building a scratch package that depends on the `WhisperKit` product alone at
`platforms: [.macOS(.v14)]`. It compiled and ran.

**MLX cannot reach the Neural Engine.** The ANE is reachable only through CoreML's compiler, which
wants static shapes; MLX is a dynamic array framework with Metal and CPU backends. The practical
consequence for this app is specific rather than abstract: a GPU-resident model competes with the same
Metal queue that SwiftUI and every `WKWebView` port render on. The maintainers of the one Swift MLX
Parakeet port, `FluidInference/swift-parakeet-mlx`, archived it in July 2025 and redirected users to
their CoreML implementation for exactly this reason (third-party, github.com/FluidInference/swift-parakeet-mlx).

**whisper.cpp moves only the encoder to the ANE.** `WHISPER_COREML=1` compiles a CoreML encoder and
leaves the ggml decoder where it was, which is why the ggml `.bin` is still required alongside the
`.mlmodelc`. That split turns out to cost more than it buys on this machine (§3).

---

## 3. Measured on this machine

### 3.1 whisper.cpp v1.8.2, and why its ANE path loses

Built twice from the release tarball: `-DGGML_METAL=ON` and again with `-DWHISPER_COREML=ON`.
`system_info` confirms which is which (`COREML = 0` against `COREML = 1`). Audio is
`samples/jfk.wav`, 11.0 s of real human speech. Peak RSS is `/usr/bin/time -l`.

| Build | Model | Load | Encode | **Total** | RTF | Peak RSS |
|---|---|---|---|---|---|---|
| Metal | base.en | 154.8 ms | 51.4 ms | **398 ms** | 0.036 | 363 MB |
| Metal | large-v3-turbo-q5_0 | 385.3 ms | 575.8 ms | **1,197 ms** | 0.109 | 852 MB |
| CoreML/ANE | base.en | 85.1 ms | 83.3 ms | **545 ms** (warm) | 0.050 | 380 MB |
| CoreML/ANE | large-v3-turbo-q5_0 | 283.8 ms | 1,002.2 ms | **1,791 ms** (warm) | 0.163 | 792 MB |

**On this M1 Max the CoreML encoder path is slower than plain Metal**, by 1.4x for base.en and 1.5x
for turbo. That is not a contradiction of whisper.cpp's README, which claims "more than x3 faster
compared with CPU-only execution": ANE beats CPU, and Metal beats ANE. The mechanism is the split.
Only the encoder moved, so every decode step crosses back to ggml, and encode time actually *rose*
(51 ms to 83 ms for base.en, 576 ms to 1,002 ms for turbo).

Two one-time costs measured here, both of which matter for a shipped app:

- **Metal shader compile, first run ever: 9.180 s** (`ggml_metal_library_init: loaded in 9.180 sec`).
  Every run after: 0.013 s.
- **CoreML/ANE first load of the large encoder: 179,962 ms.** Three minutes, with peak RSS of
  2.36 GB during the compile. Warm afterwards at 1,791 ms. base.en's equivalent first load was
  9,047 ms.

### 3.2 WhisperKit v1.1.0, and ANE against GPU

Measured through a scratch SPM package importing the `WhisperKit` product, instrumented to timestamp
the first `TranscriptionCallback` (time to first partial, TTFP) and to read `resident_size`.
Compute units set explicitly per run. `jfk-11s.wav`.

| Model | Units | Warm load | TTFP | **Total** | RTF | Peak RSS |
|---|---|---|---|---|---|---|
| base.en | **ANE** | 13,632 ms | **39.5 ms** | **175 ms** | 0.016 | 92 MB |
| base.en | GPU | 10,712 ms | 249.4 ms | 461 ms | 0.042 | 149 MB |
| large-v3-turbo | ANE | 26,352 ms | 569.9 ms | 958 ms | 0.087 | 266 MB |

**Here the ANE wins by 2.6x, the opposite of whisper.cpp.** The reason is that WhisperKit is CoreML
end to end, encoder and decoder both, so there is no per-step device crossing. The defaults encode
this: `ModelComputeOptions` sets `textDecoderCompute` to `.cpuAndNeuralEngine` always, and
`audioEncoderCompute` to `.cpuAndNeuralEngine` **only on macOS 14+**, falling back to `.cpuAndGPU`
below (`Models.swift:98-116`). Our floor is exactly the version where the encoder becomes ANE-eligible.

WhisperKit is also far leaner than whisper.cpp for the same model class: 266 MB for large-v3-turbo
against 852 MB for a *quantized* turbo under whisper.cpp.

**The load cost is the problem.** First load ever, including download and ANE compile, was
**158,870 ms for base.en** and **1,412,188 ms for large-v3-turbo**, that second figure being 23.5
minutes. Worse, the warm load never becomes cheap: repeated invocations with the model already on
disk measured 10.7 s, 13.6 s and 10.7 s for base.en, and 26 s to 34 s for turbo. `aned` and
`ANECompilerServ` are both running on this machine and `H11ANE` device nodes are present, so the ANE
is real and the cost is ANE model preparation, paid per process. A design that loads WhisperKit per
utterance is not viable; it must be loaded once and held resident.

### 3.3 Parakeet TDT 0.6B v3 via FluidAudio v0.17.4

`swift build -c release --product fluidaudiocli` succeeded (183.9 s, zero errors). First run
downloaded the model, 228 s. Model on disk is **470 MB** at
`~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3`, as four `.mlmodelc` packages
(`Encoder`, `Decoder`, `JointDecisionv3`, `Preprocessor`) plus vocab JSON. That corrects a
widely-repeated third-party figure of roughly 2.3 GB for this model's CoreML form.

Numbers below are **whole-process wall clock**, `/usr/bin/time`: process launch plus model load plus
inference. That is a harsher measure than WhisperKit's, which excluded load.

| Clip | Duration | **Wall clock, whole process** | Peak RSS |
|---|---|---|---|
| jfk (real speech) | 11.0 s | 0.45 s | 83 MB |
| evalA | 10.04 s | 0.42 s | 83 MB |
| evalB | 37.52 s | **0.61 s** | 117 MB |
| one word | 0.94 s | 0.37 s | 79 MB |
| silence | 4.0 s | 0.29 s | 80 MB |

A 37.5-second utterance, from cold process start to finished punctuated text, in 0.61 s. Load is not
a separate design problem here the way it is for WhisperKit.

---

## 4. The model question

### 4.1 What is current

Searched on 2026-09-26 rather than recalled. The shortlist was drawn from the Open ASR Leaderboard
as reported by two secondary sources (marktechpost.com 2026-07-23; northflank.com), **labeled
third-party and not independently verified**, which put Parakeet TDT 0.6B v3 at 6.32% average WER with
RTFx 3332, Kyutai STT 2.6B at 6.40%, Canary-Qwen-2.5B at 5.63%, Qwen3-ASR-1.7B at 5.76% and IBM
Granite Speech 4.1 2B at 5.33%. Average WER is English-only and, as §4.4 shows, does not predict what
matters here.

Three candidates were ruled out before measurement, each for a concrete reason:

- **CrisperWhisper**, the Whisper fine-tune built to transcribe disfluencies verbatim, is the most
  on-topic model in the field for the self-correction axis. Its weights ship under the Nyra Health
  Non-Commercial Research License. **Disqualified for a shipped product**, and no CoreML conversion
  exists anyway.
- **Kyutai STT** is architecturally the best fit of anything surveyed: streaming-first, native
  punctuation, built-in semantic VAD, CC-BY-4.0. It has no credible maintained Apple Silicon
  conversion. Architecturally excellent, unavailable.
- **Qwen3-ASR** (Apache-2.0, the cleanest license of any candidate) has MLX community packages and no
  CoreML conversion, so **GPU only, no ANE**, and no Swift streaming SDK.

The strongest signal from the market is that **Parakeet displaced or joined Whisper as the default
local model in commercial Mac dictation apps during 2026**: MacWhisper 13 added Parakeet, and
Superwhisper ships both (third-party).

### 4.2 The clips, and their limitation stated up front

Two clips matching the real workload, 10 s and 37.5 s, of connected technical prose containing
self-corrections, plus three probes. **They are synthetic**, generated with macOS `say` using the
`Daniel` en_GB voice at rate 165, then resampled to 16 kHz mono. Only the legacy voices are installed
on this machine; no Premium or Enhanced voice was available (`say -v '?'` returns zero matches for
either).

This is a real limitation and it cuts one way: synthetic speech is cleanly articulated, so it
**overstates every model's accuracy and compresses the differences between them**. It is still the
right instrument for what is being compared here, which is punctuation, casing, technical vocabulary,
long-form coherence, chunk-boundary behavior and latency, because every model receives byte-identical
input. `jfk.wav` is the one real-human-speech control. Accuracy on GM's actual voice is listed in §9
as not determined.

Reference text of clip B, 37.52 s:

> I want to talk through the architecture for a moment. The transcription stage is already port
> shaped, so that part composes cleanly with the existing bridge. The trigger is not, because a port
> cannot see a key it does not have focus for. Actually, let me back up. The real question is whether
> one insertion path can serve all three surfaces, the terminal, the web port, and the chat input. I
> thought we needed three paths behind one faculty, but the measurement says otherwise. Every one of
> those surfaces conforms to N S Text Input Client at runtime, so insert text on the first responder
> reaches all of them.

### 4.3 Verbatim transcripts, which are the evidence

**Clip B, 37.52 s. Parakeet TDT v3 (FluidAudio, ANE), 0.61 s:**

> I want to talk through the architecture for a moment. The transcription stage is already
> port-shaped, so that part composes cleanly with the existing bridge. The trigger is not, because a
> port cannot see a key it does not have focus for. Actually, let me back up. The real question is
> whether one insertion path can serve all three surfaces: the terminal, the web port, and the chat
> input. I thought we needed three paths behind one faculty, but the measurement says otherwise, every
> one of those surfaces conforms to NSText input client at runtime, so insert text on the first
> responder reaches all of them.

Complete. It hyphenated "port-shaped", chose a **colon** before the list, and produced "NSText input
client" with the acronym cased. One flaw: a comma splice at "says otherwise, every one" where the
reference has a sentence break.

**Clip B. WhisperKit large-v3-turbo (ANE), 3.83 s, TTFP 578 ms:**

> ...I thought we needed three paths behind one faculty, but the measurement says otherwise. surfaces
> conforms to ns text input client at runtime. So insert text on the first responder reaches all of
> them.

**"Every one of those" is gone**, and the acronym has collapsed to lowercase "ns text input client".
Reproduced in both passes of both runs.

**Clip B. WhisperKit base.en (ANE), 0.76 s, TTFP 45 ms:**

> ...but the measurement says otherwise. Those surfaces conforms to NSText input client at runtime.

Also drops "Every one of". So this is not a model-size effect.

**Clip B. whisper.cpp large-v3-turbo-q5_0 (Metal), 2.66 s** kept the segment:

```
[00:00:28.680 --> ...]   But the measurement says otherwise.
[00:00:29.240 --> 00:00:33.500]   Every one of those surfaces conforms to ns text input client at runtime.
```

That timestamp locates the fault precisely. **The lost segment is the one that straddles Whisper's
30-second receptive field boundary, and the loss is WhisperKit's VAD chunking and stitching, not
Whisper's.** whisper.cpp stitches the same audio without losing it, while still lowercasing the
acronym. GM's long utterances are 30 to 40 seconds, which is exactly and only this regime.

**Clip A, 10.04 s.** All three got the words right and differed on the self-correction:

| Runtime | Rendering of "No wait, actually," |
|---|---|
| Parakeet TDT v3 | `No wait. Actually, the shell has to decide...` |
| WhisperKit large-v3-turbo | `No wait. Actually. The shell has to decide...` |
| WhisperKit base.en | `No wait. Actually, the shell has to decide...` |

Every model transcribed the self-correction **faithfully rather than cleaning it up**. None deleted
the stumble. Parakeet and base.en kept "Actually," attached to its clause; turbo broke it into a
one-word sentence. This is the axis GM should judge from the transcripts, and the judgment available
is narrow: on this evidence all three are verbatim transcribers, and the difference is only in where
they put the full stops.

### 4.4 Short utterances and silence

| Probe | Parakeet TDT v3 | WhisperKit large-v3-turbo |
|---|---|---|
| One word, 0.94 s ("architecture") | **`Architecture`** | **empty, no callback fired** |
| Digital silence, 4 s | **empty** | `you` |
| Pink room tone, 4 s | **empty** | `.` then `Thank` on a second run |

Whisper's hallucination on silence is mild here but real, and non-deterministic between runs. The
sharper failure is the sub-second clip: **WhisperKit returned nothing at all and never fired a
callback**, its VAD chunker having discarded the whole buffer. Parakeet transcribed it correctly. GM
downgraded this axis on the grounds that utterances are 5 to 40 seconds, and that is fair, so it is
recorded rather than ranked. It still says something about which model degrades gracefully.

### 4.5 Streaming, and the finding that makes it mostly unnecessary

FluidAudio ships a dedicated 120M streaming model with end-of-utterance detection. It runs, and it is
a serious downgrade. Clip B through `parakeet-eou`:

> want to talk through the architecture for a moment the transcription stages already port shaped so
> that part of composes cleanly with the existing bridge the trigger is not because a cord cannot see
> a key does not have focus for actually let me back up the real question is whether one insertion
> path can serve all three surfaces the terminal the webcord and the chatin port i thought would
> needed three paths behind one faculty but the measurement sets otherwise every one of those surfaces
> can forms to n st input cloud at runtime so insert text on the first responder reaches all of them

No punctuation, no casing, dropped leading "I", and "port" became "cord", "web port" became
"webcord", "chat input" became "chatin port", "NSTextInputClient" became "n st input cloud". Unusable
as final text.

So I measured the alternative: re-decode the **full** model against a growing buffer. Whole-process
wall clock, prefixes of clip B:

| Prefix | 2 s | 5 s | 10 s | 20 s | 30 s | 37 s |
|---|---|---|---|---|---|---|
| Wall clock | 0.41 s | 0.31 s | 0.44 s | 0.91 s | 0.60 s | 0.61 s |

**The cost barely grows with buffer length, and it includes process launch and model load every time.**
In-process, with the model already resident, re-decoding the entire utterance so far is affordable
several times a second. That gives fully punctuated, correctly cased partials from the good model, and
makes the weak streaming model unnecessary.

One caveat visible in that table: a truncated buffer invents a plausible completion. The 10-second
prefix ends "The trigger is not a good one." Partials must therefore be rendered as provisional and
replaced wholesale on the next decode, never appended to.

### 4.6 Technical vocabulary

No published benchmark evaluates any of these models on software or architecture speech. Saying so is
the honest answer. The adjacent evidence is that jargon failure is invisible in aggregate WER: a
biased-WER study reports B-WER on jargon of 0.88 to 0.90 against U-WER of 0.06 to 0.19 on the same
systems (third-party, ACL Anthology 2026.lrec-1.32). Leaderboard WER should not be read as a proxy
for Port42 vocabulary.

Both shortlisted runtimes expose a biasing lever, and one of these resolves an open question:

- **FluidAudio exposes custom vocabulary in the shipped Swift CLI**, which web research could not
  confirm. `TranscribeCommand.swift` parses `--custom-vocab` (:294), `--vocab-min-similarity` (:381),
  `--vocab-cbw` (:386) and `--vocab-margin` (:391). Word boosting is available on the Apple Silicon
  path, not just in NeMo.
- **Whisper supports prompt conditioning** through `initial_prompt`, natively.
- **Apple supports it too**, at our floor, via `SFCustomLanguageModelData` and `contextualStrings`
  (§1).

Port42 has an unusually good source of boost terms: its own registry. The 78 bridge method names, the
port ids, and the vocabulary in `CLAUDE.md` are exactly the terms a general model will get wrong.
Feeding that list to `--custom-vocab` is the cheapest accuracy lever available and it is untested.

### 4.7 Recommendation, and the counterfactual

**One model and one runtime: Parakeet TDT 0.6B v3 on FluidAudio.** It won on completeness at 37 s,
latency, memory, short-utterance behavior, silence behavior, and punctuation, while clearing the
macOS 14 floor and exposing vocabulary biasing. Its cost is the CC-BY-4.0 attribution obligation
(§5).

**If the priority were accuracy rather than latency, the answer does not become Whisper.** It becomes
Parakeet TDT v3 with the sliding-window manager and a larger chunk, because the measured accuracy
difference on these clips favored Parakeet and the measured Whisper failure at 30 s is an accuracy
failure, not a speed one. The genuine accuracy-first alternative is Canary-Qwen-2.5B or Granite Speech
4.1 (both reported below Parakeet's WER, third-party), and neither has a maintained CoreML conversion,
so neither is available. **The honest accuracy-first answer at this floor is the same model with more
compute spent on it.**

---

## 5. Size and distribution

Weights against the signed, notarized bundle.

| Option | On disk |
|---|---|
| Parakeet TDT 0.6B v3, CoreML (measured) | **470 MB** |
| Whisper large-v3-turbo, WhisperKit CoreML (measured, cache dir) | ~1 GB class, download took 23.5 min including ANE compile |
| Whisper base.en, WhisperKit CoreML (measured) | 143 MB |
| whisper.cpp ggml base.en / turbo-q5_0 (measured) | 141 MB / 547 MB |
| whisper.cpp CoreML encoders (measured, unzipped) | 39 MB / **1.2 GB** |

`dist/Port42.dmg` is already tracked through Git LFS. Adding 470 MB of weights to the bundle would
roughly triple the download and put every model update through notarization, since changing a bundled
resource changes the bundle. Against that, **download on first use has four costs that are all
concrete rather than theoretical**:

1. **Where it goes.** FluidAudio already chooses correctly:
   `~/Library/Application Support/FluidAudio/Models/`. WhisperKit does not, defaulting its cache to
   **`~/Documents/huggingface/models/argmaxinc/whisperkit-coreml`**, which is user-visible, backed up
   by iCloud on many machines, and TCC-adjacent. If WhisperKit were ever used, `downloadBase` must be
   overridden. Measured: that is where it landed on this machine.
2. **Integrity.** Neither runtime's download was observed to verify a signature or digest. The weights
   arrive over TLS from HuggingFace and are then loaded as executable CoreML. A pinned expected digest
   per model file, checked before first load, is the mitigation and neither runtime provides it.
3. **Offline.** First use with no network means no dictation at all. The feature must degrade to
   Apple's dictation rather than to a spinner, and the download must be resumable.
4. **The first-load compile, which is the one people forget.** Measured on this machine: the ANE
   preparation step cost 180 s for whisper.cpp's large CoreML encoder and 23.5 min for WhisperKit's
   turbo including download. Parakeet's first run was 228 s including download, and 0.42 s afterwards.
   Whatever is shipped, **first use is not first launch**, and the UI has to say so.

**Download fits a notarized app better, at 470 MB.** Bundling ties model updates to the notarization
pipeline for no benefit, and 470 MB is small enough that download-on-first-use is a one-time wait
rather than a barrier. The decision would flip if the model were 100 MB class, where bundling removes
a whole category of failure for little size.

---

## 6. Delivery

### 6.1 Into Port42's own surfaces: one path, measured

The prior note left this as three candidate focus oracles that disagree and concluded only
`window.firstResponder` predicts where a character lands. That holds, and there is a stronger result
underneath it.

I built a scratch AppKit probe (`/tmp/p42-stt/ResponderProbe.swift`) that makes each surface first
responder, asks the OS at runtime whether that responder is an `NSTextInputClient`, calls `insertText`
through the protocol, and reads back both the resulting value and every DOM event the page observed.
Verbatim output:

```
=== SURFACE 1: WKWebView (stands in for a web port) ===
firstResponder: class=WKWebView asNSTextInputClient=true respondsTo(insertText:replacementRange:)=true inputContext=true
insert: sent via NSTextInputClient cast
page observed: {"value":"hello from voice","events":["textInput(|hello from voice)",
                "beforeinput(insertText|hello from voice)","input(insertText|hello from voice)"]}

=== SURFACE 2: NSTextField (stands in for the SwiftUI chat input) ===
firstResponder: class=NSTextView asNSTextInputClient=true respondsTo(insertText:replacementRange:)=true inputContext=true
is the field itself the responder? false
insert: sent via NSTextInputClient cast
field.stringValue = 'hello from voice'

=== SURFACE 3 control: a plain NSView that is NOT a text client ===
plain NSView: class=NSView asNSTextInputClient=false respondsTo(insertText:replacementRange:)=false inputContext=false
insert: NOT DELIVERABLE: responder is not a text input client
```

Four things follow.

1. **`WKWebView` conforms to `NSTextInputClient` at runtime even though its public header does not
   declare it.** Grepping `WebKit.framework/Headers/*.h` for `NSTextInputClient` returns nothing;
   `WKWebView.h:67` declares only `@interface WKWebView : NSView`. The conformance is real anyway and
   the Swift `as?` cast succeeds. This is why the prior note's web-port question has a clean answer.
2. **The page sees `beforeinput` and `input` with `inputType: "insertText"`, and no `keydown` or
   `keypress`.** That is precisely the signature `docs/architecture-invariants.md` records for
   dictation (web 7/7 via `beforeinput`). A web port cannot tell this apart from OS dictation, because
   there is nothing to tell apart: it is the same mechanism.
3. **A `TextField`'s first responder is the window's field editor, an `NSTextView`, not the
   `NSTextField`.** Any code that special-cases the field object will miss. The chat input is
   `PortChatPanel.swift:113`.
4. The terminal needs no probe. `GhosttyInputView` conforms at
   `Sources/Port42Lib/Views/GhosttyTerminalView.swift:379`, and its `insertText` at `:389-399` calls
   `onHumanInput?()` and then `write(text, mode: .keys)`, the one funnel pinned by
   `Tests/Port42Tests/TerminalWriteFunnelTests.swift`.

**So it is one path, not three**, and it is attributed to the human by construction on the terminal
because `insertText` is the function that already calls `onHumanInput`.

There is a simplification hiding here. `ShellView.responderIsEditor` (`ShellView.swift:405-419`) is a
hand-maintained list that matches `NSText`, `NSTextView`, `WKWebView`, and any type whose *name*
contains `WKWeb`, `WKContent`, `Ghostty`, `Terminal` or `Surface`. That list is an approximation, by
string matching, of the question the OS answers authoritatively: does this responder conform to
`NSTextInputClient`. The probe shows the runtime check is available and correct for every case the
list enumerates. Replacing the name matching with the protocol check would make
`shouldYieldKey` (`ShellState.swift:846-850`) exact rather than nearly right, and is worth doing
independently of voice.

### 6.2 Into other apps: four mechanisms, and what ships

This is the half the prior note ruled out and GM has now put back in scope. The correct constraint is
narrower than the one I was given: a *port* must not hold a microphone and a keyboard invisibly. Port42
the application, asking for Accessibility explicitly and showing when the mic is hot, is the normal
design for this category. Superwhisper, MacWhisper, VoiceInk and Wispr Flow all do it.

| Mechanism | Permission | Reaches terminal / web view / Electron | Verdict |
|---|---|---|---|
| **CGEvent synthesis** | Accessibility (the `kTCCServicePostEvent` bucket, granted by the same toggle) | Broadly yes, but a documented drop in kitty-keyboard-protocol terminals, and Unicode and pacing edge cases | The fallback |
| **AXUIElement set value** | Accessibility | Electron documented unreliable (`AXManualAccessibility` throws `kAXErrorAttributeUnsupported`); web view unresolved; whether it fires `beforeinput` is **unresolved** | Do not rely on it |
| **Clipboard plus synthetic Cmd+V** | Accessibility, for the Cmd+V | Broadest reach in practice | Clobbers the clipboard; restore races the async paste |
| **InputMethodKit** | **None documented** | Reported working in TextEdit, iTerm2, Chrome and VS Code by one real implementation | Blocked on activation, see below |

**InputMethodKit deserved the hard look and does not survive it.** The attraction is real: an input
method delivers text through the door the OS built for it, and the one open-source dictation tool
found using this way (`brandon-fryslie/low-talker`, third-party) needs no Accessibility grant, declines
every real key so normal typing is untouched, and reports reaching a terminal, a browser and an
Electron app. Two costs kill it for this use. It must be the *selected* input source, so it occupies
the user's input-source slot and their layout-switching shortcut; and **programmatic activation is
blocked in the session that installs it**, with `TISSelectInputSource` returning -50 and
`TISEnableInputSource` returning 0, so installing and switching requires a logout. A dictation feature
that needs a logout before first use and takes over the keyboard layout is not the shape of this
faculty. None of the four commercial tools use it. Worth revisiting only if the activation
restriction changes.

**The permission measurement here is weaker than the others and I will not overstate it.** A scratch
probe reported `AXIsProcessTrusted() = true`, `CGPreflightPostEventAccess() = true` and
`CGPreflightListenEventAccess() = true`, but an unsigned binary launched from a terminal **inherits
that terminal's Accessibility grant**, so this measured the terminal, not what a fresh signed
`Port42.app` would see. Notably, even with trust reported, reading the system-wide focused element
returned `AXError -25204 cannotComplete`, which is a small piece of evidence for the AX path being
unreliable. What a notarized Port42 sees on first ask is not determined.

### 6.3 Two paths behind one faculty

The honest architecture is not one path and not three.

- **Port42 frontmost:** use the internal seam. `(window.firstResponder as? NSTextInputClient)?.insertText`.
  No Accessibility grant, no synthetic events, attributed to the human at the existing seam, and it
  cannot miss because it asks the OS which responder will receive text.
- **Another app frontmost:** use the OS path, clipboard-plus-paste primary with CGEvent character
  typing as the fallback for paste-blocked fields, gated on Accessibility, marking the transient
  pasteboard item `org.nspasteboard.TransientType` and `org.nspasteboard.ConcealedType` so compliant
  clipboard managers do not record dictated text, restoring the previous contents only if
  `NSPasteboard.changeCount` is unchanged.

Two paths, chosen by one predicate (is Port42 the frontmost application), behind one user-visible
faculty. The internal path is strictly better where it applies, and it applies to the case Gordon
uses most.

**And `port.push` stays out of it.** `BridgeMethods.swift:183` pushes as `PortInput.Kind.programmatic`
attributed to the calling principal. Routing speech through it launders human input into programmatic
input, which is the one distinction the input seam exists to keep honest. Speech goes through
`insertText`, which fires `onHumanInput`. That constraint from the prior note survives intact and is
the reason the internal path is the right one rather than merely the cheap one.

---

## 7. Against simply using macOS dictation

Apple's dictation works today in all three surfaces, costs nothing, and is attributed to the human.
Where a local model does not beat it, say so.

| Axis | Honest verdict |
|---|---|
| **Privacy** | **The clear win, and it is not marginal.** `AudioBridge.swift:103` sets `requiresOnDeviceRecognition = false`, and `SFSpeechRecognizer.h:159` is explicit that a request honors on-device only when `supportsOnDeviceRecognition` is true. Today Port42's own audio path sends audio to Apple. A local model sends nothing. |
| **Duration limit** | **A win.** `SFSpeechRecognizer.h:70`: "Plan for a one-minute limit on audio duration." A 40-second utterance is inside that but not comfortably, and the framework header also warns of per-device daily caps and per-app throttling (`:69`). Parakeet has no such limit. |
| **Accuracy on GM's speech** | **Not determined.** Synthetic clips cannot settle it, and Apple's on-device model was not benchmarked against Parakeet here. Apple's own documentation concedes on-device "won't be as accurate" than its server path, which is a statement about Apple's two paths, not about Parakeet. |
| **Technical vocabulary** | **Probably a win, and testable.** Both offer biasing, but Apple caps `contextualStrings` at 100 phrases while FluidAudio's `--custom-vocab` has no documented cap. Untested on either. |
| **Punctuation and casing** | **A modest win at best.** Apple's dictation punctuates competently. Parakeet punctuated better than Whisper on clip B, but no measurement here compares either against Apple. |
| **Latency** | **Apple's is fine, and may be better.** Its partials appear as you speak with no model to load. Parakeet's 0.61 s for a 37.5 s utterance is excellent but arrives after you stop. |
| **Reaching the focused surface** | **Apple's is strictly better and free.** The OS does the insertion. This is the half of the feature that already works, and §6.1 shows a local model can match it exactly rather than beat it. |
| **Trigger from another app** | **Neither.** Apple's dictation already has a user-configured push-to-talk shortcut, and it types into the app you are in. What Port42 adds is routing into a *chosen* port, and a hotkey it owns. |

**The case for a local model rests on privacy, the one-minute limit, and vocabulary, not on accuracy or
latency.** On accuracy the comparison has not been made, and on delivery latency Apple's streaming
insertion is the thing to match, not beat. If GM's motivation is "Apple sends my audio to Apple", the
work is justified. If it is "Apple mishears me", that needs a measurement on his own voice first,
because it might be answered for free by setting `requiresOnDeviceRecognition = true` and boosting
`contextualStrings` with Port42's own vocabulary.

That last point is worth stating as a cheap first experiment rather than buried: **flipping one boolean
in `AudioBridge.swift:103` stops the audio leaving the machine today**, at some accuracy cost, with no
model, no download, no Accessibility grant, and no new code. Whatever is decided about Parakeet, that
line should not stay as it is.

---

## 8. What could not be determined

1. **Accuracy on GM's actual voice.** Every clip here is synthetic apart from `jfk.wav`. Only Premium
   or Enhanced voices were absent; real recordings were never available. This is the gap that decides
   whether the accuracy argument holds, and it needs a few recorded utterances.
2. **Apple's on-device recognizer against Parakeet.** `supportsOnDeviceRecognition` for en-US on this
   machine was not queried, and no head-to-head was run. Both are cheap to do next.
3. **What a notarized Port42 sees when it asks for Accessibility.** The probe inherited the launching
   terminal's grant, so the measured `true` values say nothing about a fresh signed app. Needs a
   signed build.
4. **Whether the ANE is actually resident during inference**, as opposed to CoreML having been asked
   for it. `H11ANE` nodes, `aned` and `ANECompilerServ` are present, and ANE-versus-GPU timings differ
   by 2.6x for WhisperKit, which is strong behavioral evidence. Direct utilization measurement needs
   `powermetrics`, which needs sudo, which was not taken.
5. **Whether WhisperKit's 30-second word loss is a fixable configuration** rather than a defect.
   `VADAudioChunker`'s `silenceThreshold` and `requiredSegmentsForConfirmation` were left at defaults.
   Since the recommendation is Parakeet, this was not pursued.
6. **Parakeet's reported empty-decode bug on short utterances with trailing silence**
   (NVIDIA-NeMo/Speech #15757, third-party). Not reproduced here: the 0.94 s clip transcribed
   correctly. Not tested with a deliberate trailing-silence tail.
7. **Whether `--custom-vocab` measurably helps on Port42 vocabulary.** The flag exists and was not
   exercised. This is the highest-value untested lever in the note.
8. **Whether `AXUIElement` value setting fires `beforeinput` in a `WKWebView`.** Searched and
   unresolved in the literature, and not measured, because the recommendation does not use AX.
9. **CC-BY-4.0 attribution mechanics.** Parakeet's weights require attributing NVIDIA. Where that
   notice has to appear in a shipped Mac app, and whether an acknowledgements panel suffices, was not
   settled.

---

## Appendix: reproducing the measurements

Everything lives in `/tmp/p42-stt`, outside the repo, and nothing here touched a Port42 instance.

| Artifact | What it does |
|---|---|
| `whisper.cpp-1.8.2/build`, `build-coreml` | Metal and CoreML builds, from the v1.8.2 release tarball |
| `argmax-oss-swift-1.1.0` | WhisperKit v1.1.0 source |
| `wkbench/` | Scratch SPM package importing the `WhisperKit` product; reports load, TTFP, total, RTF, RSS |
| `FluidAudio-0.17.4` | FluidAudio v0.17.4, `fluidaudiocli` built from it |
| `ResponderProbe.swift` | The §6.1 insertion probe |
| `PermProbe.swift` | The §6.2 permission probe |
| `mkclips.sh`, `evalA.wav`, `evalB.wav`, `evalSilence.wav`, `evalRoomTone.wav`, `evalWord.wav` | Clip generation and the clips |
| `matrix.sh`, `evalwk.sh`, `evalpk.sh`, `prefix.sh` | The measurement runs |

Model caches created outside that directory, and worth deleting if this is not pursued:
`~/Documents/huggingface/models/argmaxinc/` (WhisperKit, 143 MB plus the turbo package) and
`~/Library/Application Support/FluidAudio/Models/` (Parakeet, 470 MB plus the streaming model).
