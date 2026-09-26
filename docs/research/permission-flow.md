# One guided permission flow

Research spike for Future roadmap item 3 in `docs/plan-shell-only.md` ("One guided permission flow in
place of a series of dialogs"). Measured against the tree at `f63c223` (research, which contains
nautilus), 2026-09-26. Live grant and client counts read from the Dev3 and production databases on
the same day. Not an approved decision.

Companions: `host-mesh.md` (consent for your own devices), `invite-over-libp2p.md` (consent for a
guest).

## Recommendation

**The item's premise does not hold for the local case, and holds strongly for the remote one.**

There is no series of dialogs to replace. Measured: Dev3 holds **2 grants across 25 enrolled
grantees**; production holds **4 grants across 25**, and three of the four belong to `local-http`, an
identity deleted from the code. A first session that opens a terminal, captures the screen and
captures audio raises **4 Port42 cards and 3 macOS dialogs**, and a session that touches none of those
raises **zero**. The count is low because 41 of 69 registry methods are ungated, not because consent
is well designed.

What is actually wrong is three different things, and bundling the asks fixes none of them:

1. **The grantee fragments.** A spawned terminal's client id keys on the port's session id
   (`ClientRegistry.swift:240`), so every fresh terminal is a new grant bucket. Dev3 minted **25
   grantees in 12 hours**, six of them named `harness-s1-claude`, all for the same act. Any capability
   those sessions needed would be asked for once per session, forever.
2. **The existing gates are skippable.** `port.push` writes raw keystrokes into a live terminal with
   `permission: nil` (`BridgeMethods.swift:180`), and `port.subscribe` streams a terminal's full output
   with `permission: nil` (`BridgeMethods.swift:46-47`). Both reach the thing `.terminal` protects
   without touching `.terminal`. This is the same defect `port.create`'s gate was added to close
   ("the gate is on the first command, not the second", `BridgeMethods.swift:120-137`), at two
   different doors.
3. **The card has no context and no render site outside the shell.** The message is written by Port42
   per permission, not by the asker (`PortPermission.swift:44-102`), so it never says what for. The
   overlay exists only inside `ShellView` (`ShellView.swift:205-210`), and a returning launch starts on
   the lock screen (`AppState.swift:175`, `TransitionRoot.swift:21`) with the gateway already up
   (`AppState.swift:724`).

**Order of work: (1) a stable grantee for a spawned session, (2) close the ungated write and read
paths, (3) then just-in-time with context plus a per-port manifest.** Do not build the up-front bundle
(option A) and do not build a trust level (option D); both re-create the blanket pre-grant that D12
deleted for cause, and `PortObjectGrantTests.swift:342` pins that no blanket pre-grant survives
anywhere in the tree.

## 1 · The current flow, mapped

### The permission enum, and what each case gates

`PortPermission` (`PortPermission.swift:6-17`), eleven cases. The registry is the only
method-to-permission table (`PortPermission.swift:19-24`); the parallel switch was deleted in Phase 3.

| Permission | Methods that declare it | Count |
|---|---|---|
| `terminal` | `terminal.exec` (`BridgeMethods.swift:415`), plus `port.create type:"terminal"` in-body (`:141-152`) | 1 + 1 |
| `screen` | `screen.capture` (`:455`), `screen.windows` (`:469`), `screen.stream` (`:700`), `screen.record.start` (`:766`), `screen.record` (`:801`) | 5 |
| `browser` | `browser.open` (`:575`), `.navigate` (`:590`), `.capture` (`:597`), `.text` (`:616`), `.html` (`:632`), `.execute` (`:649`), `.close` (`:656`), plus `port.create type:"browser"` in-body (`:141-152`) | 7 + 1 |
| `filesystem` | `fs.pick` (`:1003`), `fs.read` (`:1013`), `fs.write` (`:1037`), `fs.list` (`:1065`), `fs.mkdir` (`:1083`) | 5 |
| `camera` | `camera.capture` (`:475`), `camera.stream` (`:690`) | 2 |
| `microphone` | `audio.capture` (`:680`), `audio.stopCapture` (`:685`), plus `screen.record`'s in-body ask (`:737-745`) | 2 + 1 |
| `automation` | `automation.runAppleScript` (`:501`), `automation.runJXA` (`:515`) | 2 |
| `clipboard` | `clipboard.read` (`:917`), `clipboard.write` (`:923`) | 2 |
| `rest` | `rest.call` (`:825`) | 1 |
| `notification` | `notify.send` (`:483`) | 1 |
| `ai` | **none** | 0 |

`.ai` is dead. Its comment still names `ai.complete`, `ai.cancel` and `companions.invoke`
(`PortPermission.swift:7`), all removed with the engine in Phase 1. The only streaming method left is
`port.subscribe`, ungated (`BridgeMethods.swift:46-47`). The case survives because two tests assert its
description is non-empty and that it does not grant terminal (`PortPermissionTests.swift:152`, `:136`).
Production still holds an `ai` grant row for `local-http`, which can never fire.

Three further tests in that suite name methods the registry does not have (`terminal.send`,
`terminal.resize`, `terminal.kill`, `PortPermissionTests.swift:40-53`) and pass because an unknown
method returns nil (`:55`). They assert nothing.

Coverage: **28 of 69 registry entries are gated, 41 are not** (`grep -c 'permission: \.'` and
`'permission: nil'` over `BridgeMethods.swift`).

### Where the prompt is raised

One gate, one queue, one render site.

- **Gate.** `AppState.ensurePermission` (`BridgeDispatcher.swift:110-119`). Reads the grantee's grants
  on port 0 in the caller's zone, unions any same-call `pregrant`, and prompts only on a miss. It
  persists on grant (`:117`) and does not persist a denial.
- **Called from two places.** The dispatcher, before the body (`BridgeDispatcher.swift:50-54`, and the
  streaming twin `:531`), and two method bodies that escalate on an argument: `port.create` on `type`
  (`BridgeMethods.swift:148-152`) and `screen.record` on `audio` (`:742`). Both go through
  `ensurePermission` rather than `permissions.request`, deliberately, because the request path prompts
  and only the gate remembers (`BridgeMethods.swift:138-140`).
- **Queue.** `PermissionCoordinator` (`PermissionCoordinator.swift:81-156`). One `current`, a FIFO
  `queued`, coalescing on `(principal.id, permission)` (`:99-118`). `resolveCurrent` advances
  (`:121-126`); `denyAll` (`:130-135`) and `cancelRequests(from:)` (`:139-150`) resolve `false`.
- **Render site.** `ShellPermissionOverlay`, mounted once at `ShellView.swift:205-210`, `zIndex(230)`.
  The scrim does not dismiss; Esc denies (`ShellPermissionOverlay.swift:11-12`, `:86`).

### What the user sees

One card, one permission (`ShellPermissionOverlay.swift:27-107`), in this order: the asker's display
name (`:29`), an SF Symbol (`:34`, from `PortPermission.iconName`), a title and a message
(`:38-46`, from `PortPermission.permissionDescription`), an optional narration of the macOS dialogs
that follow (`:50-65`, from `PermissionRequest.systemFollowUp`, `PermissionCoordinator.swift:61-74`),
what Allow does and how to undo it (`:69`, from `Principal.scopeDescription`,
`Principal.swift:199-204`), Deny and Allow, and `"1 of N waiting"` when the queue is deeper than one
(`:102-106`).

A port needing three capabilities therefore produces three sequential blocking cards, each about one
permission, with a counter.

### What is persisted

Table `grants`, migration `v43-grants` (`DatabaseService.swift:656-689`), created 2026-07 when the
store moved out of `UserDefaults`. **One row per permission**, primary key
`(grantee, object, zone, permission)` (`:673-685`), index `grants_lookup` on
`(grantee, object, zone)` (`:686-687`). Columns: `grantedAt`, and `lastUsedAt`, written through a
throttle (`AppState.swift:620-624`, `DatabaseService.swift:1003-1010`) as the only honest basis for a
later reap.

Read path: `AppState.grants(grantee:on:zone:)` (`AppState.swift:487-497`) over an in-memory
`grantCache` (`:473`), because the check runs on every gated dispatch. Write path:
`AppState.saveGrants` (`:500-505`), whose **only production caller is the gate**
(`BridgeDispatcher.swift:117`). Nothing else writes a grant.

Zone is `NOT NULL` with `""` for unzoned, because SQLite treats NULLs as distinct and a nullable
column in a primary key would not enforce uniqueness (`DatabaseService.swift:666-669`).

**A second, narrower store exists and is not persisted.** `AppState.pickedFilePaths`
(`AppState.swift:309-321`) holds per-principal absolute paths granted by `fs.pick`
(`BridgeMethods.swift:1000-1011`) or a file drop (`PortBridge.swift:188`). `fs.read`/`fs.write` honour
exactly those paths for exactly that principal and refuse everything else with `access_denied`
(`BridgeMethods.swift:983-998`). It is a plain `var` on `AppState`, so it dies at quit while the broad
`.filesystem` grant persists.

### Where revocation lives

Settings → Access, the `grants` tab of `SignOutSheet` (`SignOutSheet.swift:384-492`), the first surface
in the product's life that can read the grant store (`:184-191`). Grouped by grantee (`:206-302`), one
sub-row per (object, zone) with `objectLabel` and `zoneLabel` from `PortGrantDisplay`
(`PortObject.swift:92-116`), a `lastUsedAt` age (`:318-324`), and one revocable chip per capability
(`FlowChips`, `:158-182`). Three verbs: revoke one capability (`:476-480` → `AppState.swift:609-613`),
revoke all for a grantee (`:448-451` → `:615-618`), revoke a client (`:418-421` →
`:602-604`). The tab also lists enrolled clients (`:401-432`) and mints one by hand (`:326-381`).

`zoneLabel` marks a grant whose space is gone as dead (`PortObject.swift:111-116`). That is the
manager's real job: 135 of the 144 grants in the old store named a deleted space and could never fire
(`:105-108`).

**Revoking a client does not revoke its grants** (`AppState.swift:598-604`), stated as deliberate. But
`upsertClient` clears `revokedAt` on re-registration (`DatabaseService.swift:831-844`), and a spawned
terminal re-registers unconditionally every time its surface is built, including on the restore path
(`AppState.swift:1436-1444`, called from `buildTerminalSurface` at `:1389`, whose doc names the restore
path at `:1385`). So "revoke client" on a `child` is undone by the next app launch, with its grants
intact. *Derived from code paths; not verified live.*

### How a grant is keyed

`PortGrantKey.key(grantee:object:zone:)` (`PortObject.swift:137-140`) is the only place a key is
built, pinned by a source scan (`PortObjectGrantTests.swift:379`). Three parts:

- **Grantee** = `Principal.id` (`Principal.swift:34`). Four kinds (`:16-30`): `port` (the port id, or
  its creator's id), `companion`, `peer` (a gateway caller's client id), `human`. Identity policy lives
  in named factories (`:60-66`, `:136-151`, `:164-169`).
- **Object** = a `PortObject` (`PortObject.swift:36-86`): peer-qualified by construction,
  `PortObject.machine` is port 0 (`:58`), `PortObject.port(key)` names a tile (`:61-63`),
  `remotePort` names one on a peer (`:71-73`). **Every production grant is on port 0**: the gate hard-codes
  `.machine` (`BridgeDispatcher.swift:112`, `:117`, and the comment at `:107-109`). The slot was built
  ahead of a caller that can fill it (`PortObject.swift:24-29`), and tests exercise a non-zero object
  because production cannot (`PortObjectGrantTests.swift:71-110`).
- **Zone** = the caller's space, or `"global"` (`PortObject.swift:132`, `PortGrantKey.key` `:138`).

**Zone is inconsistent across surfaces, and it splits buckets.** A port's JS carries its space
(`Principal.forPortBridge`, `Principal.swift:136-151`; the pregrant read at `PortBridge.swift:71` uses
`zone: spaceId`). A gateway caller carries nil, so `"global"` (`Principal.peer`, `Principal.swift:87-89`;
constructed with no space at `ToolExecutor.swift:171`, `:202`). The space instead appears inside the
child client's *id* (`ClientRegistry.swift:218-219`). So one companion asks twice for the same
capability: once as the CLI in the terminal (zone `global`) and once through a port it created (zone
= the space).

**A port inherits its creator's grants.** `port.create` records `createdBy: p.id`
(`BridgeMethods.swift:158`); `Principal.forPortBridge` authorizes a port as that creator
(`Principal.swift:138-141`); `PortBridge.init` unions the creator's port 0 grants into the port's
same-call pregrant (`PortBridge.swift:67-75`). So a `.screen` grant given to an agent reaches every
port that agent ever writes, including ports written after the grant.

## 2 · The prompt burden, counted

Assumptions, stated because the count depends on them: one Mac, a fresh data directory, Claude Code
already installed, the person asks for a chart, then a terminal, then a screen capture, then audio
transcription. Derived from the code paths named, not from a live run.

| Step | Port42 cards | Why |
|---|---|---|
| Setup: name, CLI detection, Echo spawned | **0** | `completeSetup` calls `spawnNativeTerminalPort` directly (`AppState.swift:1148-1152`), never `port.create`, so no gate runs |
| Echo greets; the person asks for a chart; Echo writes a web port | **0** | `port.create type:"web"` is ungated by construction (`BridgeMethods.swift:141-147`) |
| The person opens a terminal from the dock | **0** | Same direct spawn path |
| An agent opens a terminal | **1** (`.terminal`) | `BridgeMethods.swift:148-152` |
| A port captures the screen | **1** (`.screen`) | The port's zone is its space, the agent's earlier grant was `global`, so the buckets differ |
| A port captures audio | **1** (`.microphone`) | `BridgeMethods.swift:680` |

Four Port42 cards. Then the macOS layer, which follows ours and is separate:

| macOS dialog | Raised at |
|---|---|
| Screen Recording | `SCShareableContent` (`ScreenBridge.swift:33`, `:75`, `:204`). The card warns it "may need Port42 restarted once" (`PermissionCoordinator.swift:68`) |
| Microphone | `AVCaptureDevice.requestAccess(for: .audio)` (`AudioBridge.swift:56`) |
| Speech Recognition | `SFSpeechRecognizer.requestAuthorization` (`AudioBridge.swift:64-68`), because `transcribe` defaults to true (`:51`) |

Three, plus a Notifications dialog if anything calls `notify.send`
(`NotificationBridge.swift:25-33`), and a per-app Apple Events dialog each time automation touches a
new app (`AutomationBridge.swift:32`, narrated at `PermissionCoordinator.swift:69-70`).

Third layer, uncounted: the CLI agent's own approvals. Claude Code and Codex ask per tool and per
command under their own policy. The number is set by the CLI's configuration, not by this tree, so it
is **unknown** here. It is named because the person experiences all three layers as one flow and only
one of them is Port42's.

**Total attributable to Port42 in a first session that touches terminal, screen and audio: 7 dialogs
(4 ours, 3 the OS's). In a first session that touches none of them: 0.**

### Measured against that

Read from the live databases, 2026-09-26:

```
Dev3  (nautilus, two days of scenario runs)   2 grants,  25 clients (23 child, 1 installed, 1 manual)
        nautilus-harness  · port 0 · global   · terminal   · used today
        terminal-432d…    · port 0 · C4AEE…   · microphone · used today
Production (older build)                       4 grants,  25 clients (23 child, 1 installed)
        local-http  · port 0 · D2ED… · terminal, ai, filesystem   (identity deleted from the code)
        port42-cli  · port 0 · global · terminal                  (never used)
```

Two facts follow. **The store is nearly empty**, so there is no accumulating dialog burden to
compress. And **the grantee set is not**: Dev3 minted 25 client rows between `2026-09-25 17:39` and
`2026-09-26 04:57`, nine on one day and sixteen on the next, six of them sharing the name
`harness-s1-claude`. Production holds 14 `terminal-*` rows accumulated since 2026-07-31. That is the
rate at which grant buckets fragment: a capability any of those sessions needed would be asked for
sixteen times in a day.

The harness sidesteps this by doing its terminal spawning as `nautilus-harness`, a hand-added client
that holds the one `terminal` grant (`scripts/scenarios/run.py:10`, `:52`), so the child terminals it
opens never need one.

## 3 · What is wrong beyond the count

### The card cannot say who is asking, or why

**Why.** The message is a constant per permission, written by Port42
(`PortPermission.swift:44-102`). `.terminal` says "This port wants to run terminal commands on your
computer" whether the caller is Echo running `git status` or a cron script running anything. The card
has no access to the method name, the arguments, or a purpose from the asker. TCC requires the
*requesting* app to supply a reason string (`Info.plist:29-36`); Port42's asker supplies nothing.

**Who.** `displayName` is fixed at mint (`ClientRegistry.swift:29-30`) and is honest for a CLI and a
companion. It is weakest exactly where it matters: a port whose creator is not an author authorizes as
itself and the card shows its title or `"a port"` (`Principal.swift:143-145`), and a port whose creator
*is* an author shows the creator's name for a grant that will then apply to every other port that
creator writes.

`.rest`'s message says "This companion wants to…" while every other case says "This port wants to…"
(`PortPermission.swift:99`), which is the same field guessing at a caller kind it is not given.

### Nothing can be pre-granted

`saveGrants` has exactly one production caller, the gate (`BridgeDispatcher.swift:117`). Settings →
Access can revoke and can mint a client, and has no way to grant (`SignOutSheet.swift:384-492`). The
consequence is that the only way to authorize a caller that has no human present at call time is to
let it fail once with a person watching. `addByHandRow` exists precisely for callers with no human at
call time (`SignOutSheet.swift:326-335`) and gives them a credential with no capabilities.

This is a deliberate consequence of D12, which deleted three blanket "allow without prompting"
toggles that were all on in production (`ToolExecutor.swift:153-164`, `SignOutSheet.swift:154-159`). The
deletion was right about blanket authority and left no narrow replacement.

### Scopes that could be narrower

- **`.filesystem` is read plus write plus list plus mkdir, everywhere.** And the gesture that *is* the
  consent, `fs.pick`, is itself behind the broad grant (`BridgeMethods.swift:1003`), so the person
  approves general file access in order to point at one file. The narrow half already works and is not
  persisted (`AppState.swift:309-321`). Inverting the two is the single largest available narrowing:
  make the picker ungated, make `fs.read`/`fs.write` on an absolute path need only a picked path, and
  keep `.filesystem` for the data-directory sandbox.
- **`.microphone` is microphone plus speech recognition.** `transcribe` defaults to true
  (`AudioBridge.swift:51`), so one Port42 grant becomes two TCC grants and there is no way to ask for
  raw audio alone.
- **`.screen` is a screenshot, a window list, a live stream and a recording** (five methods). Listing
  windows is a different act from recording the display.
- **`.browser` is seven methods including `browser.execute`**, arbitrary JS in the embedded browser,
  under the same grant as opening a URL.
- **`.terminal` is bypassable, not merely broad.** `port.push` types raw keystrokes into a live
  terminal with `permission: nil` (`BridgeMethods.swift:180-183`; the description says so: "end with a
  newline to run the command"). `port.subscribe` streams that terminal's output with `permission: nil`
  (`BridgeMethods.swift:46-47`; terminal output is published to the port topic at
  `AppState.swift:1503-1506`). `ports.list` enumerates every port in every space with `permission: nil`
  (`BridgeMethods.swift:1342`). So an enrolled client with no grants at all can find every terminal on
  the machine, read everything it prints, and type into it. The plan already names the read half as a
  known local gap that becomes serious remotely (`plan-shell-only.md`, Phase 4, "Reads must be scoped
  before anything is remote").
- **Grants never expire.** Stated as a closed decision (`DatabaseService.swift:711-720`).
  `lastUsedAt` exists as the basis for a later reap and nothing reads it except the display.

### Where a denial is indistinguishable from an error

Four places, in descending severity.

1. **A pending ask with no render site becomes a timeout.** The overlay lives only in `ShellView`
   (`ShellView.swift:205-210`). A returning launch sets `showDreamscape = true`
   (`AppState.swift:175`), `RootScreen.decide` returns `.lock` (`TransitionRoot.swift:21`), and
   `rootContent` renders `LockScreenView` with no `ShellView` in the hierarchy
   (`TransitionRoot.swift:79-93`). The gateway is already running, started from `loadInitialState`
   (`AppState.swift:724` → `configureSyncIfNeeded` → `gp.start()` at `:823`). So a
   gated call from an enrolled client while the app is locked enqueues a card nobody can see, and the
   gateway answers `timed_out` after 30 seconds (`gateway/gateway.go:419-423`). This is the exact class
   of defect `PermissionCoordinator`'s own header records as fixed
   (`PermissionCoordinator.swift:8-24`); the fix made the render site singular, not unconditional.
   *Derived from code paths; not verified live.*
2. **Teardown denies.** `cancelRequests(from:)` resolves `false` when a port dies with a card queued
   (`PermissionCoordinator.swift:139-150`, called from `PortBridge.deinit` at `PortBridge.swift:86-89`),
   and `denyAll` resolves `false` on shell teardown (`:130-135`). The caller receives
   `permission_denied`, which is what it would receive if the person had clicked Deny. The deinit
   comment already notes the coalescing case: a sibling port riding the same card is denied too
   (`PortBridge.swift:83-85`).
3. **The Port42 layer and the macOS layer share one code.** `permission_denied` is returned both by
   the gate (`BridgeDispatcher.swift`/`BridgeError.permissionDenied`) and by a TCC refusal
   (`AudioBridge.swift:59`, `:71`, `ScreenBridge.swift:326`, `NotificationBridge.swift:43`,
   `CameraBridge.swift:49`). The repairs are different in kind: ask again in Port42, versus open
   System Settings. `BridgeErrorCode` already makes exactly this distinction elsewhere, un-merging
   `access_denied` from `permission_denied` because "the caller's repair is different in kind"
   (`BridgeErrorCode.swift:59-70`, `:149`), and the macOS layer was not given the same treatment.
4. **An Apple Events refusal carries no code at all.** `runAppleScript` returns
   `["error": msg]` with no `code` for any script failure (`AutomationBridge.swift:35-37`), so a TCC
   denial reads as a syntax error. And the screen path detects a TCC denial by string-matching
   `localizedDescription` for "permission" or "denied" (`ScreenBridge.swift:322-327`), which is
   localization-dependent.

A denial is also never remembered (`PortCreateGateTests.swift:118`, "a denial is not persisted, so the
caller can be asked again"), so a caller that was refused asks again on its next call. That is
deliberate and it is the opposite of the browser's behavior, where a denial sticks to the origin.

## 4 · Design options

### What transfers, and what does not

**macOS TCC.** Transfers: per-capability, ask on first use, one revocable place. Port42 already has
that shape. The one piece worth taking across is the **usage description supplied by the asker**
(`Info.plist:29-36` is Port42's own, per capability, to the OS); Port42's card has no equivalent field
for the port or agent that wants the capability. Does not transfer: TCC's subject is a code-signed
bundle, stable across launches, so one row per (bundle, service) is durable. Port42's subject is minted
per terminal session (`ClientRegistry.swift:240`) and per space (`:218-219`), so there is no stable
subject for a durable grant to attach to. TCC also owns a settings pane it can send you to and a reset
verb; Port42 can reach neither the pane nor the state underneath it, which is why the screen card has
to say the app "may need restarting once" (`PermissionCoordinator.swift:68`). And TCC's prompts are
modal to the app by the OS; Port42's are modal to one view (`ShellView.swift:205`).

**Browser permissions.** Transfers: the three-state model (granted / denied / prompt) with a
**remembered denial**, which Port42 lacks. Transfers: powerful features gated on a user gesture rather
than on a standing grant, which Port42 already does once and correctly in `fs.pick`
(`BridgeMethods.swift:1000-1011`). Does not transfer: the origin. A browser identifies the *code*; the
origin is the boundary and the code cannot change without the origin changing. In Port42 a port's code
is written by an agent at runtime, replaced in place by `port.update` (`BridgeMethods.swift:1461`), and
the port authorizes as its creator (`Principal.swift:138-141`), so two ports with unrelated code share
one bucket and one port's code changes under a grant already given. This is the gap that makes
roadmap item 4 ("share a port's code") the harder one.

**Mobile runtime permissions.** Transfers: a declared manifest paired with a runtime ask, which is
Android's model and is half-built here already, with the wrong semantics. `port.setCapabilities`
(`BridgeMethods.swift:1654-1663`) is an ungated, self-asserted, free-text string list used only as a
`ports.list` filter (`:1342`). It is the natural declared half of a manifest and currently authorizes
nothing. Transfers: one-time and while-in-use scopes, which Port42 has none of. Does not transfer: a
mobile manifest is fixed and signed at install. A Port42 port is generated and then updated in place,
so a manifest "approved once" is approved for code that has since changed. Any manifest design has to
answer what `port.update` does to it, and nothing today does.

### The options

| | What it is | What it costs | What it gets wrong |
|---|---|---|---|
| **A · Up-front bundle at enrolment** | Ask once, when a client enrols, for everything it may want | Needs a declared list at enrolment. Children have none: they enrol at spawn with a name and a kind (`AppState.swift:1441-1444`). Needs a new grant-writing path beside the gate | Re-creates the blanket pre-grant D12 deleted (`ToolExecutor.swift:153-164`, `PortObject.swift:154-157`), which `PortObjectGrantTests.swift:342` pins out of the tree. Wrong on timing: nobody can judge at enrolment what an agent will want. Wrong on frequency: enrolment happens by machine, 25 times in 12 hours on Dev3, so the bundle question appears sixteen times a day |
| **B · Just-in-time with context** | Keep the gate. Give the card the method name, a purpose string from the asker, short arguments, and the macOS follow-up it already has | A `purpose` on the ask, threaded from the call. The card's structure already supports it (`ShellPermissionOverlay.swift:27-73`); `systemFollowUp` is the precedent (`PermissionCoordinator.swift:61-74`) | Changes no count and does not touch the fragmenting bucket. The purpose string is written by an LLM, so it is persuasion, not evidence: it must be rendered as a claim beside the method name, which is the fact |
| **C · Declared manifest, approved once** | A port declares its capability set at `port.create`; one card lists the set; the grant lands on the port object | The object slot exists and needs no migration (`PortObject.swift:26-29`, `:61-63`); tests already exercise a non-zero object (`PortObjectGrantTests.swift:71-90`). Needs a manifest argument on create, a card that renders a set, and a rule for `port.update` | Does not cover an agent in a terminal, which declares nothing and is the principal caller. Invites over-declaration, as mobile manifests did. And it removes the inheritance that currently makes a companion's ports cheap (`PortBridge.swift:67-75`), which is a behavior change, not only an addition |
| **D · Trust level per caller** | A grantee gets a level; the gate consults the level instead of a permission set | One column and a policy table | The top level is the blanket pre-grant with a nicer name. It keys on the client id, and the client id is what fragments, so the level would be re-assigned per session. Also do not reuse the word: `PortInput.Trust` already means the provenance of an input event (`PortInput.swift:70-76`) |

**Recommended sequence.** Two prerequisites, then B and C together.

1. **A stable grantee for a spawned session.** An ad-hoc terminal keys on its port id
   (`ClientRegistry.swift:240`), which is stable across restarts for one port and different for every
   new one. A companion keys on `child-<companionId>-<spaceId>` (`:218-219`), which is stable. The
   question to settle is what the durable subject of a grant is for a tool the person thinks of as
   "Claude Code in a terminal": the companion, the tool, or the session. Until that is answered, any
   flow built on top asks the same question repeatedly.
2. **Close the ungated paths** (`port.push` to a terminal, `port.subscribe`, `ports.list`), because a
   guided flow that carefully asks for `.terminal` while a sibling verb reaches the same terminal for
   free is ceremony rather than consent.
3. **B plus C.** The card gets context and the purpose is the asker's claim; a port declares its set
   once and the grant lands on the port object rather than on port 0. Neither A nor D.

Also worth doing regardless, all small and independently verifiable: delete `.ai` and the two tests
that keep it; delete the three vacuous tests naming methods that do not exist; give the automation
path a code (`AutomationBridge.swift:35-37`); split the OS layer's refusal from ours with a distinct
code; mount the permission overlay outside `ShellView` or refuse a gated call while locked with a
coded error naming the reason.

## 5 · What this must not ignore

### The invite: a guest arriving with a grant

D10 is one invite per port, granting that port only, and port 0 is never invitable
(`plan-shell-only.md`, D10 and Phase 4). `invite-over-libp2p.md` turns the payload into an enrolment
coupon that binds a peer id and carries no access.

What that requires of this work:

- **The grant must land on a port object, not on port 0.** The slot exists (`PortObject.port`,
  `PortObject.swift:61-63`) and the gate hard-codes `.machine` (`BridgeDispatcher.swift:112`, `:117`).
  Option C is therefore not only the port-manifest design, it is the same change the invite needs.
- **Reads must be scoped first.** Today the guest page takes a full client token in a query string
  (`gateway/guestpage.go:50`, `:174-175`) and is thereafter that client, and `ports.list` and
  `port.subscribe` are ungated. A guest with a per-port coupon and those two verbs has the whole
  desktop.
- **The cascade question is a consent question.** `invite-over-libp2p.md` asks whether a grant on a
  container reaches its contents, including future ones. That is the same question as C's
  `port.update` rule one level up: a standing grant on something whose contents change later.
- **A guest is a grantee with no prompt available.** There is no human at the guest's end and the
  host's human may be at the lock screen. A flow that assumes an interactive card cannot serve an
  invite; the coupon has to carry the capability set and the redemption has to be the consent.

### The host mesh: your own devices

`host-mesh.md` states the missing primitive: membership ("this host is me") rather than a per-port
grant, and revocation by device rather than by grant. Against this work:

- **`Principal.Kind` has no case for it** (`Principal.swift:16-30`): `port`, `companion`, `peer`,
  `human`. A device that is you is not a `peer` in the sense that word carries here, and modeling it
  as one means every capability is asked for per device.
- **A mesh makes the grantee question unavoidable.** If a grant made on the laptop should hold on the
  desk, authorization state replicates, and it cannot replicate while the grantee is a per-session
  slug minted by the machine it was minted on.
- **`PortObject` is already peer-qualified** (`PortObject.swift:41`, `:66-73`), and
  `PortObjectGrantTests.swift:92` pins that a grant on a peer's port 0 does not reach this machine's.
  So the object half is ready for the mesh and the grantee half is not.

### Terminal spawning, gated in Phase 0

`plan-nautilus-phase0.md:118-122` records step 0.5 as already true: a client without the grant that
opens a terminal running `claude` raises a card, and approving it records `terminal` on port 0 for
that client. The gate is `port.create`'s in-body escalation on `type`
(`BridgeMethods.swift:141-152`), and its own comment explains why it had to be there: `terminal.exec`
and `browser.open` were gated and creating the port was not, so both gates could be skipped by making
a port instead of calling the verb (`:120-137`).

Two things follow for this work.

- **The same reasoning is unfinished.** `port.push` reaches a live terminal's shell with no permission
  (`BridgeMethods.swift:180`) and `port.subscribe` reads it (`:46-47`). Phase 3 will make this worse
  deliberately: "the same headless terminal port then carries `terminal.exec`", so every shell action
  gets a port (`plan-shell-only.md`, Phase 3). More terminal ports and more ungated port verbs is the
  wrong direction unless the write and read verbs are gated on the target's kind, the way `port.create`
  is gated on `type`.
- **The grant that consent bought is inherited.** Approving a terminal for a client records
  `.terminal` on port 0 for that client, and `PortBridge` unions the creator's port 0 grants into every
  port it makes (`PortBridge.swift:67-75`). The person consented to that client opening a terminal, and
  what was recorded also covers every port that client ever writes.

## What could not be determined

- **Whether a gated call while the app is locked actually hangs to the gateway's 30-second timeout.**
  Derived from `ShellView.swift:205`, `TransitionRoot.swift:21`, `AppState.swift:175`, `:724` and
  `gateway/gateway.go:419`. Settled by locking Dev3 and timing a `clipboard.read` from an enrolled
  client that holds no clipboard grant.
- **Whether revoking a `child` client is undone by the next launch.** Derived from
  `AppState.swift:1441` plus `DatabaseService.swift:838-841` plus the restore path named at
  `AppState.swift:1385`. Settled by revoking a companion client in Settings → Access, restarting Dev3,
  and re-reading `clients.revokedAt`.
- **Whether the Screen Recording grant still needs a relaunch.** The card claims it may
  (`PermissionCoordinator.swift:68`). Settled by resetting the TCC entry for the Dev3 bundle and
  calling `screen.capture`.
- **How many approvals the CLI layer adds.** Set by Claude Code's and Codex's own configuration, not
  by this tree. Settled by running the first-run script once per CLI with a default configuration and
  counting.
- **Whether any of the 25 Dev3 grantees is nameable by the person.** Six share the name
  `harness-s1-claude` and fourteen production rows are `terminal-<uuid>-<uuid>`. Whether a person
  looking at Settings → Access can place a row is a question about the list, and it was not tested.
- **Whether `.microphone` can be split without breaking a shipped port.** `audio.capture`'s
  `transcribe` defaults to true (`AudioBridge.swift:51`), so any port that relies on the default would
  need the second grant. How many such ports exist in the wild is unknown.
