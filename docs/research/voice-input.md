# Voice input as a mode

**Proposal (GM, 2026-09-26):** voice input as a mode. Hold space anywhere, audio from the mic goes to
the active window. The question asked: is that a port in the hidden state?

Measured against this branch (`nautilus` merged with `origin/research`). Every claim carries a
file:line, a command output, or an SDK header quote. None of this is an approved decision.

---

## The answer

**No. Three of the four parts are a port today. The hotkey is not one, cannot become one without a
primitive that should not exist, and the hidden state is the part to refuse outright.**

Voice input is a **shell faculty with a port-shaped transcription stage**. The mic and the
transcriber are already a port capability and work. The trigger belongs to the shell, because a port
cannot see a key it does not have focus for, and the delivery target cannot be named by a port,
because nothing tells a port what else is focused.

Two further findings change the shape of the proposal before any of that matters:

1. **Most of the feature already exists and Apple ships it.** macOS dictation reaches every Port42
   surface today, and Port42 wired the terminal for it deliberately. A terminal conforms to
   `NSTextInputClient` (`Sources/Port42Lib/Views/GhosttyTerminalView.swift:379`), its `insertText`
   funnels through the one write seam and attributes the text to the human
   (`GhosttyTerminalView.swift:389-399`), a web port counts dictation through `beforeinput` (measured
   7 of 7, `docs/architecture-invariants.md:64-70`), and the chat input is a SwiftUI `TextField`
   (`Sources/Port42Lib/Views/PortChatPanel.swift:113`), which is `NSTextField`-backed. What the
   proposal adds over that is push-to-talk **from other apps into Port42**, and routing to a chosen
   port rather than to whatever holds the caret.
2. **"Hold space" does not survive contact with the key path.** Space is a printing character, the
   shell yields every key to any focused port, and the app monitors no `keyUp` at all, so "hold"
   has no signal to end on. Details in §2.

---

## 1. What already exists

### `audio.capture`: transcription is built in, streams partials, and the port owns it

`Sources/Port42Lib/Services/AudioBridge.swift`, one shared `@MainActor` instance on `AppState`.

| Property | Measured |
|---|---|
| Transcription default | `transcribe` defaults **true** (`AudioBridge.swift:51`) |
| Framework | `Speech.framework`, `SFSpeechRecognizer` + `SFSpeechAudioBufferRecognitionRequest` (`:15-17`, `:93`, `:100`) |
| Streams or whole utterance | **Streams.** `shouldReportPartialResults = true` (`:101`); each callback pushes an `audio.transcription` event carrying `{text, isFinal}` (`:113-116`) |
| On device or network | **Network by default.** `requiresOnDeviceRecognition = false` (`:103`) |
| Raw audio | Optional, `rawAudio` defaults false (`:53`); when on, every tap buffer is base64'd and pushed (`:143-157`) |
| Concurrency | **One capture at a time**, machine-wide. A second call returns `wrong_state` (`:47-49`) |
| Ownership | A capture remembers the `PortBridge` that started it and the port id (`:20-25`); events route only there |
| Gate | `permission: .microphone` on both `audio.capture` and `audio.stopCapture` (`Sources/Port42Lib/Services/BridgeMethods.swift:683`, `:688`) |
| TCC | Two system dialogs: `AVCaptureDevice.requestAccess(for: .audio)` (`:56`) then `SFSpeechRecognizer.requestAuthorization` (`:64-68`). Narrated in advance by `PermissionCoordinator.systemFollowUp` (`Sources/Port42Lib/Services/PermissionCoordinator.swift:63-65`) |

Framework limits, from the SDK headers on disk
(`/Applications/Xcode-26.3.app/.../MacOSX.sdk/System/Library/Frameworks/Speech.framework/Headers/`):

- `SFSpeechRecognizer.h:70`: "**Plan for a one-minute limit on audio duration.** … the framework stops
  speech recognition tasks that last longer than one minute."
- `SFSpeechRecognizer.h:69`: "Because speech recognition is a network-based service, limits are
  enforced … Individual devices may be limited in the number of recognitions that can be performed
  per day, and each app may be throttled globally based on the number of requests it makes per day."
- `SFSpeechRecognizer.h:159`: a request only honors `requiresOnDeviceRecognition` when
  `supportsOnDeviceRecognition` is true; otherwise the recognizer requires a network.

A per-utterance push-to-talk never approaches the one-minute cap. An always-listening mode would trip
it every minute and would be network-billed and throttled. That alone argues for per-utterance.

`audio.capture` accepts a nil owner (`AudioBridge.swift:46`, `owner: PortBridge? = nil`). A headless
caller (the CLI over the gateway) can therefore start a capture whose `bridgeRef` is nil, so every
transcription callback fires and every event is dropped (`:113`, `:150`). Headless capture with
transcription on is currently a mic that runs and produces nothing reachable.

### The global key monitors: there is no global monitor

Every monitor in the app is **local** (`NSEvent.addLocalMonitorForEvents`), which sees only events
dispatched through this app's `NSApplication.sendEvent:`. A grep for
`addGlobalMonitorForEvents|CGEventTap|CGEvent.tapCreate|RegisterEventHotKey|AXIsProcessTrusted|IOHIDCheckAccess`
over `Sources/` and `gateway/` returns **nothing**.

| Site | Mask | Purpose |
|---|---|---|
| `Sources/Port42Lib/Views/ShellView.swift:335` | `.magnify` | pinch drives the zoom ladder |
| `ShellView.swift:341` | `.mouseMoved` | background parallax, never consumes |
| `ShellView.swift:352` | `.keyDown` | the shell chords and the zoom ladder |
| `Sources/Port42/Port42App.swift:136` | `.mouseMoved` | |
| `Port42App.swift:177` | `.keyDown` | Esc quits the shell takeover |

**No `.keyUp` monitor exists, and no `.flagsChanged` monitor exists.** "Hold" has no end signal in the
app today.

### What yields, and what counts as an editor

`ShellState.shouldYieldKey` (`Sources/Port42Lib/Services/ShellState.swift:846-850`) is two lines:

```swift
if keyCode == 53 { return isEditor || focusedPortIsTerminal }   // 53 = Esc
return isEditor
```

So for every key except Esc, **`isEditor` alone decides**, and when it is true the shell sees nothing.

`ShellView.responderIsEditor` (`ShellView.swift:405-419`) returns true for `NSText`, `NSTextView`,
`WKWebView`, any responder whose type name contains `WKWeb`, `WKContent`, `Ghostty`, `Terminal` or
`Surface`, and any `NSView` nested inside a `WKWebView`. That is **every web port, every browser
port, every terminal port, and the chat field**. In other words: every surface a person works in.

The one bypass is `ShellState.shellGlobalChord` (`ShellState.swift:726-739`), which is consulted
before the yield (`ShellView.swift:356-367`). Its first line is:

```swift
guard command, !option, !control else { return nil }
```

**The bypass requires Command by construction.** A bare key cannot join it without changing that
guard.

### The input seam: how text reaches a port

| Target | Funnel | Evidence |
|---|---|---|
| Terminal port | `port.push` → `GhosttyTerminalController.sendRaw` → `GhosttyInputView.write(_:mode:)` | `BridgeMethods.swift:183`, `:229`; `GhosttyTerminalController.swift:470-483`; `GhosttyTerminalView.swift:119-126` |
| Terminal port, from the OS | `NSTextInputClient.insertText` → `onHumanInput()` → the same `write(_:mode:)` | `GhosttyTerminalView.swift:389-399` |
| Web port | `port.push` → `window.dispatchEvent(new CustomEvent('port42:data', {detail: …}))` | `BridgeMethods.swift:240-250` |
| A port's own chat | `chat.post` | `Sources/Port42Lib/Services/PortChat.swift:292-312` |
| A port, from a port | `port.publish` on the port's own topic | `BridgeMethods.swift:255` |

`GhosttyInputView.write(_:mode:)` is pinned as the only path to a pty by a source-scanning test
(`Tests/Port42Tests/TerminalWriteFunnelTests.swift`), which scans every `.swift` under `Sources/` and
allows exactly one file.

**One difference matters for voice.** `insertText` calls `onHumanInput?()` before writing
(`GhosttyTerminalView.swift:397-398`), so OS dictation is attributed to the person. `port.push` does
not, and its `PortInput.Kind` is `programmatic`, attributed to the calling principal. Routing spoken
words through `port.push` **launders human input into programmatic input**, which is exactly the
distinction the input seam was built to keep honest
(`docs/plan-port42-protocol-local-bus.md:1287-1320`).

### Invisible (hidden) ports, from Phase 3

`docs/plan-nautilus-phase3.md:170-205`, built 2026-09-26. A hidden port has no tile, is in no desktop,
rail, dock or exposé, and keeps everything else: its web view and bridge, its terminal surface, its
chat, storage, subscriptions, console and driver chip. `ports.list` reports it `hidden`
(`BridgeMethods.swift:1408` region, `status: pt.isBackground ? "hidden" : pt.presentation`), and ⌘K
lists hidden ports in their own section with show, close and delete (decision 4, `:51-53`).

Two properties bear directly on a voice port:

- **A hidden port keeps its timers at full rate.** `minimize` disables WebKit's unseen-page timer
  clamp (`Sources/Port42Lib/Views/PortWindowManager.swift:658-659`), `restore` re-enables it (`:669`).
  Hidden is the only state that runs a JS loop at speed.
- **Hiding does not release the mic.** `minimize` suspends AI billing and touches nothing else
  (`PortWindowManager.swift:656-663`). Release is on `close` and `stop` only
  (`PortWindowManager.swift:545`, `:680`, calling `releaseAcquisitions` →
  `AudioBridge.releaseIfOwned(byPortId:)`, `AudioBridge.swift:211-223`).

What a hidden port **cannot** do: see a key. It has no window, so no key event reaches its web view,
and no registry method delivers keyboard events at all (see §4).

---

## 2. The hotkey

### Anywhere in Port42

Holding space inside Port42 reaches the shell **only when no port and no text field has focus**. In
every state where a person is working, `responderIsEditor` is true, `shouldYieldKey` returns true, and
the space is typed as a space. Concretely, holding space types a space and the shell sees nothing
whenever focus is:

- any web port's `WKWebView`, including an inline port,
- any terminal port's `GhosttyInputView`,
- any browser port,
- the chat `TextField`,
- the ⌘K switcher field, the imagine box, or any settings field.

The only states left are a bare desktop with nothing focused and the galaxy rung. That is not
"anywhere", it is "nowhere you would be".

Making space a shell-global chord means changing
`guard command, !option, !control else { return nil }` (`ShellState.swift:730`) to let a bare space
through, which makes the shell swallow the space bar in every terminal and every text field in the
app. That is not a trade-off, it is a broken space bar.

**Holding is separately unbuildable today.** Press-and-hold needs a `keyUp` (or `flagsChanged`) edge.
The app monitors neither, and a held `keyDown` auto-repeats, so "held" cannot be distinguished from
"pressed 30 times" without the release edge.

### System-wide

Two APIs, both costing a TCC class Port42 does not hold, quoted from the SDK headers on disk.

**Passive observation.** `AppKit/NSEvent.h:541`:

> Use +addGlobal to install an event monitor that receives copies of events posted to other
> applications. Events are delivered asynchronously to your app and **you can only observe the event;
> you cannot modify or otherwise prevent the event from being delivered to its original target
> application. Key-related events may only be monitored if accessibility is enabled or if your
> application is trusted for accessibility access** (see AXIsProcessTrusted in AXUIElement.h).

So a global monitor costs Accessibility **and still types the space into the other app**.

**Active filtering.** `CoreGraphics/CGEvent.h:272-279`:

> Taps placed at `kCGHIDEventTap', `kCGSessionEventTap', `kCGAnnotatedSessionEventTap', or on a
> specific process **may only receive key up and down events if access for assistive devices is
> enabled** … or the caller is enabled for assistive device access, as by `AXMakeProcessTrusted'. If
> the tap is not permitted to monitor these events when the tap is created, then the appropriate bits
> in the mask are cleared. If that results in an empty mask, then NULL is returned.

An active tap can swallow the space. It is also a keylogger-shaped grant on every keystroke in every
app, in an app that hosts arbitrary third-party HTML and whose ports inherit their creator's grants
(§5). **Recommendation: do not build the tap.**

What the app holds today, for comparison: `Port42.release.entitlements` is network client, network
server, `disable-library-validation`, `apple-events`, `allow-jit`,
`allow-unsigned-executable-memory`. Not sandboxed, so the mic needs no
`com.apple.security.device.audio-input`; TCC still applies. `Info.plist:29-32` declares
`NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`. Nothing in the tree asks for
Accessibility or Input Monitoring.

### Does the proposal survive, and what else there is

**"Hold space" does not survive. Push-to-talk does.** Three alternatives, in order of cost:

1. **Nothing. Use macOS dictation.** It already reaches every Port42 surface (§1), it is already
   push-to-talk with a user-configured shortcut, and it is already attributed to the human at the
   seam. Zero code, zero new TCC class. It does not solve "from another app into a chosen port".
2. **A Command chord, tap to toggle.** `shellGlobalChord` takes a new case and nothing else changes:
   the guard already requires Command, the bypass already runs ahead of the yield, and a toggle needs
   no `keyUp`. This is the cheapest thing that is actually new, and it is Port42-only. ⌘Space is
   Spotlight, so pick another.
3. **A modifier-only hold, in-app.** A `.flagsChanged` local monitor on a modifier that does not
   print (right Option, for instance) gives a real hold with no printing-character conflict. Note that
   Fn is taken on GM's machine: `fn fn` opens the emoji picker
   (`docs/plan-port42-protocol-local-bus.md:1309`).

System-wide in any form requires Accessibility. On a printing key it additionally requires an active
tap. Those are separable decisions and the second should be refused.

---

## 3. "The active window"

**There is no window.** The shell retired port windows; a port is a tile in one app window, and the
shell hides the Dock and menu bar during takeover (`Port42App.swift:169-196`; the milestone note in
`CLAUDE.md`). So "the active window" has to resolve to one of three in-code things, and **they
disagree**:

| Candidate | Where | What it means |
|---|---|---|
| `ShellState.zoom == .focus(udid)` | `ShellState.swift:15-21` | one port immersive on the ladder. Absent at the `.space` and `.galaxy` rungs |
| `ShellState.selectedTileId` | `ShellState.swift:25` | the highlighted tile. **Hover- and click-driven, not keyboard focus** |
| `window.firstResponder` | read at `ShellView.swift:370` | the actual keyboard target, and the only one that predicts where a typed character lands |

A tile's web view can hold `firstResponder` while `zoom` is `.space` and `selectedTileId` is a
different tile. Anything built on "the active one" has to pick, and the only honest pick for text is
`firstResponder`, because that is what the OS will type into.

**Delivering transcribed text, reusing the existing funnels:**

- **To a terminal port:** `port.push(id, "…")` → `sendRaw` → `write(_:mode:)`. Awaited to completion
  through a continuation (`GhosttyTerminalController.swift:479-481`), so the caller knows the
  keystrokes landed. Omit the trailing newline to leave the line unsubmitted, which is the right
  default for dictation (`BridgeMethods.swift:185`).
- **To a web port:** `port.push(id, "…")` → `port42:data` CustomEvent. The port decides where the text
  goes, which is correct, and means a web port must opt in.
- **To the shell's own chat:** `chat.post(port, text)` (`PortChat.swift:292`).
- **To whatever holds the caret, with no target resolution at all:** `NSTextInputClient.insertText` on
  the first responder. This is the path macOS dictation uses, it already works for terminals and web
  ports, and it is the only one that lands in the right place without the shell having to guess.

The last row is the finding. **"Deliver to the active window" is a solved problem when the OS does the
delivery, and an unsolved one when a port does**, because a port must first be told what is focused,
and nothing tells it (§4).

---

## 4. Is it a port?

| Part | Status | Evidence |
|---|---|---|
| Own the mic and transcribe | **A port today.** No addition needed. | `audio.capture` / `audio.stopCapture`, gated `.microphone`, events to the calling port (`BridgeMethods.swift:683-691`; `AudioBridge.swift:46-182`) |
| The global hotkey | **Cannot be a port.** | No registry method exposes keyboard events: 78 `BridgeMethod` declarations across `Sources/Port42Lib/Services/*.swift`, none in a `keyboard`/`hotkey`/`input` namespace (`grep -ho "BridgeMethod(permission: [^,)]*"`). A port's JS sees `keydown` only inside its own focused web view; a hidden port has no window and sees nothing. A shell-global chord requires Command (`ShellState.swift:730`) and lives in an enum in the shell (`:717-723`), not in the registry |
| Know what is focused | **Reflexively yes, globally no.** Needs a named addition. | A port can learn that **it** is focused: `presentation` returns `{state, visible, w, h}` and `State` includes `focused` (`BridgeMethods.swift:403-414`; `PortPresentation.swift:19-20`), pushed as an event on every change. Nothing reports **which other** port is focused: `ports.list` reports presentation as status, never focus (`BridgeMethods.swift:1350`, `:1408`), and no method reads `shell.zoom` or `selectedTileId` |
| Deliver text into the focused unit | **A port today for a named target. Not for "the focused one".** | `port.push` (`BridgeMethods.swift:183`), `chat.post` (`PortChat.swift:292`). Both take an explicit id; the focus read above is the missing input. And a push is attributed as `programmatic`, not as the human (§1) |

**Direct answer.** Voice input is not a port. It is a shell mode, one of whose stages can be a port.

The mic and the transcriber are already port-shaped and should stay that way: a port that turns speech
into text, publishing on its own topic, is a clean unit and composes with everything in Phase 3's
pipe. The trigger and the routing are shell concerns, because both require knowledge the port model
deliberately does not hand out (what key was pressed outside me, what is focused besides me). Adding
either to the registry would hand every port a keylogger and a focus tracker, on a bridge with no
object-level authorization (§5).

**On "in the hidden state" specifically: hidden is the part to refuse.** Everything the hidden state
contributes here is invisibility, and invisibility is the one property this feature must not have.

---

## 5. The sharp edge

### When is the mic actually hot

From `audio.capture` returning `{ok: true}` until one of: `audio.stopCapture`, the owning port being
closed or stopped, or the app exiting. `releaseIfOwned(byPortId:)` (`AudioBridge.swift:211-223`) is
called from the close path and the stop path (`PortWindowManager.swift:545`, `:680`).

**Hiding a port does not release its mic.** `minimize` suspends AI billing and disables the unseen
timer clamp; it does not touch audio (`PortWindowManager.swift:656-663`). So a capturing port that is
then hidden keeps the microphone open, at full timer rate, on no desktop, in no rail, in no dock and
in no exposé. That is the exact construction the proposal asked about, and it is available today.

Also hot: the network. With `requiresOnDeviceRecognition = false` (`AudioBridge.swift:103`), audio
leaves the machine for Apple's recognition service whenever on-device recognition is not in use
(`SFSpeechRecognizer.h:159`).

### What tells the user

**Inside Port42: nothing.** There is no read of `AudioBridge.isCapturing` anywhere under
`Sources/Port42Lib/Views/` (grep for `capturing|isCapturing|mic` returns only comments and the
permission-overlay narration). There is no `NSStatusItem`, `NSStatusBar` or `MenuBarExtra` anywhere in
`Sources/`. A port's chrome shows a driver chip for writes (`PortActivity.swift:132`), not a mic
state. `AudioBridge` already holds `ownerPortId` (`AudioBridge.swift:25`), so the information needed
to draw an indicator exists and nothing draws it.

**Outside Port42: the macOS privacy indicator, with a gap.** Apple documents an orange dot beside
Control Center while the mic is in use, and Control Center naming the apps using it. It also
documents that **only one indicator dot is shown at a time**, so a camera in use shows green and the
mic dot is not drawn. Port42 can hold both, and `screen.record` with mic audio asks for camera-class
and mic-class access in the same call (`BridgeMethods.swift:745`). The OS indicator is real coverage
and it is not complete coverage.
([Use Control Center on Mac](https://support.apple.com/en-gb/guide/mac-help/mchl50f94f8f/mac))

### What stops another port doing the same thing invisibly

Less than it looks like.

- `audio.capture` **is** gated, and that is the good news: it is one of the 31 gated declarations, not
  one of the 47 ungated ones (measured on this tree: 78 `BridgeMethod` declarations, 47 with
  `permission: nil`, which updates the audit spec's 41-of-69 to 47-of-78).
- **The grant is machine-wide per grantee, not per port.** `ensurePermission` reads and writes grants
  keyed `(grantee: principal.id, on: .machine, zone: principal.spaceId)`
  (`BridgeDispatcher.swift:115-123`). There is no per-port mic grant, and `PortObject.port` exists
  unfilled (`docs/security-audit-nautilus-spec.md:161-172`).
- **A port inherits its creator's grants at construction.** `PortBridge.init` unions in everything the
  creating principal holds on port 0 in that zone (`PortBridge.swift:70-79`) and passes it as
  `pregrant` (`:429`), which skips the card. Grant one companion the mic once, and **every port that
  companion writes afterwards, in that space, holds the mic with no prompt**.
- **`port.exec` is ungated and runs under the victim's principal** (`BridgeMethods.swift:288`). A port
  holding nothing can execute JS inside a port that holds the mic grant. Code path, not executed;
  T6 in the audit spec settles it.
- **Declared capabilities are a label.** `port.setCapabilities` is ungated and self-asserted
  (`BridgeMethods.swift:1662`). A port that lists no microphone capability can hold one.
- **The card cannot render while the shell is locked.** `ShellPermissionOverlay` renders inside
  `ShellView` (`ShellView.swift:231-235`) and `TransitionRoot` swaps `LockScreenView` in place of
  `ShellView` (`TransitionRoot.swift:81`), so an ask raised while locked has no render site and the
  gateway answers `timed_out` at 30 seconds (`gateway/gateway.go:419-423`).

### The position

**This should never be invisible. Say it plainly, in the product.**

An invisible port holding a microphone grant and listening for a hotkey is the worst construction this
codebase can express, and today it composes out of shipped parts: `presentation: "hidden"`, an
inherited `.microphone` grant that raises no card, no in-app indicator, and an OS dot that another
capability can mask.

If voice input is built, four things go with it, and they are the design, not hardening added later:

1. **The shell owns the mic indicator, not the port.** Drawn whenever `AudioBridge.isCapturing`,
   naming `ownerPortId`, in the chrome, unconditionally. A port cannot suppress it, because a port
   does not draw it.
2. **Hide releases the mic, or hide is refused while capturing.** Today hide is the one transition
   that keeps a capture alive while removing every way to see it. Whichever way this is resolved, it
   must not stay as it is.
3. **A voice mode is a shell faculty with one owner.** One mic, one place to see it, one place to
   revoke it. `AudioBridge` is already a single shared instance with single-capture semantics
   (`AudioBridge.swift:47-49`), so the model is already singular; the ownership should be too.
4. **Do not add a keyboard capability to the registry**, and do not build the `CGEventTap`. On a
   bridge with no object-level authorization and grant inheritance at construction, a keyboard read is
   a keylogger every port inherits.

---

## 6. Latency

End to end, per utterance. Bounded-by column says what sets the number.

| Stage | Cost | Bounded by |
|---|---|---|
| Key down to the shell | Under one frame, local monitor, in process | AppKit dispatch |
| Start capture | **Unmeasured.** Two TCC round trips (`AVCaptureDevice.requestAccess`, `SFSpeechRecognizer.requestAuthorization`) on **every** call (`AudioBridge.swift:56`, `:64`), then `engine.prepare()` + `engine.start()` (`:162-163`) | AVFoundation and the TCC daemon. **This is the number that decides the design** |
| First audio buffer | One tap buffer of 1024 frames (`AudioBridge.swift:140`): 21.3 ms at 48 kHz, 23.2 ms at 44.1 kHz, 64 ms at 16 kHz. Rate is the device's (`inputNode.outputFormat`, `:78`) | AVAudioEngine buffer size, tunable |
| Transcribe to first partial | **Unmeasured, network-bounded.** Partials on (`:101`), on-device off (`:103`) | Speech.framework plus the network |
| Deliver to a port | **1 ms to 2 ms median**, measured on Dev4, producer to subscriber, and unchanged when either end is off screen (`docs/plan-nautilus-phase3.md:134-142`) | The in-process bridge |
| Deliver into a terminal | Awaited to completion, so the caller knows the keystrokes landed (`GhosttyTerminalController.swift:479-481`) | Ghostty plus the pty |

**The bridge round trip does not kill it.** One to two milliseconds against a network transcription
stage is noise, two orders of magnitude below the stage that actually costs. A port-based transcription
stage meets any budget the framework allows.

**Two real costs, and one is architectural.**

- **Engine start on key down.** If the engine starts when the key goes down, the first syllable is
  lost by however long `engine.start()` takes plus two TCC round trips. This is unmeasured and it
  decides the design: either the engine is pre-warmed, which means the mic is open before the person
  presses anything (the security problem, worse), or the first word is clipped, or the design is
  toggle rather than hold so the start cost is paid visibly and once.
- **The whole app counts as unseen when its window is covered.** Measured: one run read 1 event/s and
  0 frames for "both visible" with the Dev4 window behind other windows
  (`docs/plan-nautilus-phase3.md:149-150`). For system-wide push-to-talk, Port42's window is behind
  the app being typed into by definition. **Event delivery is unaffected at full rate** (`:143-145`),
  so an event-driven port is fine and a port that polls a timer runs at 1 Hz. If a voice port needs a
  loop, it has to be hidden, which is the state that opts out of the clamp
  (`PortWindowManager.swift:658-659`), and which is the state §5 says to refuse. Event-driven is the
  only design that is both fast and visible.

**Do not use `rawAudio` for this.** It is unnecessary, since transcription is built in, and it is
expensive: at 48 kHz it pushes about 47 events per second, each a 5,464-character base64 string
(1024 frames x 4 bytes = 4,096 bytes), each going through `evaluateJavaScript`
(`PortBridge.swift:537`) and a NotifyBus publish (`:555`).

---

## What could not be determined

1. **`AVAudioEngine.start()` latency after TCC is already granted**, and the cost of the two
   authorization round trips on a warm call. This is the number the whole hold-versus-toggle decision
   rests on. Needs a live run on a dev instance.
2. **`SFSpeechRecognizer` first-partial latency** on GM's network, and therefore whether the network
   path is usable interactively.
3. **Whether `supportsOnDeviceRecognition` is true for en-US on GM's machine**, which decides whether
   audio leaves the machine at all. The code sets `requiresOnDeviceRecognition = false` regardless.
4. **Whether macOS dictation still reaches a web port and a terminal port on this branch.** Measured
   2026-07-27 in I2 C6 (`docs/architecture-invariants.md:64-70`), code-confirmed here
   (`GhosttyTerminalView.swift:379-399`), not re-run.
5. **Whether the mic dot is masked in practice** when Port42 holds camera-class and mic-class access
   together. Apple documents one dot at a time; not observed.
6. **Whether a `CGEventTap` works in a notarized, hardened-runtime Port42** with Accessibility
   granted. No such code exists in the tree, so there was nothing to measure. Not worth measuring
   until §5's recommendation against it is overruled.
7. **The cross-port `port.exec` escalation into `audio.capture`.** Same status as the audit spec's T6:
   the code path says it works, it was not executed.

## The trigger: hold space, insert and retract (GM, 2026-09-26)

**Correction to this note.** It recorded that "hold space does not survive the key path" and listed
three reasons: `shouldYieldKey` yields every key when an editor is focused, `shellGlobalChord`
requires Command by construction, and no `.keyUp` monitor exists. All three are accurate descriptions
of Port42's current code and none is a platform constraint. macOS delivers key-up, and a local
monitor discards an event by returning nil. GM has already built this trigger on Windows.

**The mechanism is duration.** Space at typing speed is roughly 80 to 120 ms down. Held past a
threshold near 200 ms it is intent, not a character.

Three ways to handle the first 200 ms, decided:

- **Delay delivery.** Withhold the space until the threshold resolves. Correct, and it puts 200 ms of
  lag on every space typed. Rejected.
- **Insert and retract.** Chosen. Insert the space normally so typing is untouched; if the key is
  still down at the threshold, send a backspace and begin capture. One character appears and vanishes.
- **Key repeat.** Free, but the repeat delay is a user preference and can exceed a second, by which
  point several spaces have been typed.

**Scope.** Inside Port42 a local monitor sees key-down and key-up and can discard the event, so this
needs no new permission. Reaching other apps needs the Accessibility tap, for the reason already
recorded: a global monitor observes a key and cannot prevent its delivery.

**To verify before building.** Whether the retract is invisible in a Ghostty surface or flickers. A
terminal is where a stray character costs most, and it is also the surface most likely to be
dictated into.
