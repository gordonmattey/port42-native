# Architecture and code quality review

Status: report, 2026-10-01. Requested by Gordon ("a full architecture review of the code, to ensure we
have good design principles in place and good code quality"). Branch reviewed: `lead/for-1.0.7`.
Board: `dash:item:dev-arch-review`.

Scope: about 45k lines of Swift (Sources), 7.8k lines of Go and JS (gateway, relay, guest), 32k lines of
tests, and the build and release scripts. Five read-only reviews, one per area, each checked against the
conventions in `CLAUDE.md`. The dev lead then verified the security findings and the largest structural
claims by reading the code; each finding below is marked **verified** (read and confirmed) or
**reported** (from the area review, not independently re-read).

Security findings are not in this document. They are in a private appendix kept outside the public
repo (the agreed rule for open security findings). Count: 23, of which 8 are verified.

## Verdict

The foundations are sound. Persistence is disciplined (all SQL in `DatabaseService`, append-only
migrations, GRDB records), the registry-first API is real and its generated surfaces are enforced by
tests, the relay is designed for backpressure, and pure logic is pulled out where it can be tested
headlessly. The code has drifted from the architecture `CLAUDE.md` describes in four places:
authorization has no single seam, state ownership is split across objects with different lifetimes,
sequencing relies on timers and main-thread blocking I/O, and the release and test pipeline depends on
one machine and leaves the Go side ungated. None of these needs a rewrite. Most fixes are small or
medium and can land ticket by ticket.

## What to keep

- One home for SQL, append-only migrations, GRDB structs (verified: no `sql:` outside `DatabaseService`).
- The registry: one declaration per method carries permission, write target, schema; undeclared
  arguments are refused before any card; `RemoteAccess` denies by default and is tested complete.
- Generated references (`llms.txt`, tool golden, skills references, guest method table) with freshness
  tests and `PORT42_REGEN_*` switches.
- Pure, headless policy seams: `VoiceTrigger`, `CompanionPostGate`, `WakeQueue`, `ChatRouting`,
  `ShellPlacement`, `ChatTranscript.build`, `Space.reorder`.
- Relay design: a write queue per guest, so one stalled guest never blocks a host.
- Build hygiene: pinned actions and images, a byte-identical guest bundle with SRI, surgical process
  kills in `build.sh`.

## The six themes, in priority order

### 1. Authorization has no single seam (API layer)

Write scope is checked in the dispatcher, read scope inside method bodies, and the target port is
resolved more than once per call by different rules. Five separate "may this caller act on this port"
predicates exist (`requireCodeAuthority`, `maySetState`, `mayManage(invite)`, `mayManage(sharingOf:)`,
the inline check in `port.delete`), each with its own rule, and read scope depends on each body. The
authorization matrix is tested as a table of prose strings, and the scope tests call the method body
directly, bypassing the dispatcher where write scope lives.

- **Resolve once** (verified): the dispatcher resolves the target, and several bodies resolve it again
  with a different matcher. Fix: the dispatcher resolves once and hands the resolved port to the body;
  write paths never match titles by substring. Medium.
- **Read scope at the seam** (reported): declare a target for reads too and run `canRead` in the
  dispatcher for every targeted method. Medium.
- **One authority type** (reported): a single `PortAuthority` with named relations and a per-verb
  policy table, replacing the five predicates. Medium.
- **Pipeline order** (verified): the dispatcher's steps should run cheapest refusal first, in one fixed
  order: resolve, local scope, remote gate, forward, permission, CAS. Small.
- **A behavioral matrix test** (reported): principal kind × method × same or other space, run through
  `runBridgeMethod`. Medium.

### 2. State ownership is split across objects with different lifetimes (state and views)

- **`AppState` is a god object** (verified size): 2,652 lines plus 24 extensions in 19 files (about 6.8k
  lines in all), owning auth, grants, terminals, setup, voice, relays and boot. Extract
  `TerminalCompanionService`, `GrantStore`, `SpaceStore` and `BootCoordinator`; AppState composes them.
  Large, and best done one service at a time.
- **`ShellState` is owned by a view** (verified): `ShellView` creates it as a `@StateObject`; AppState holds
  only a weak reference. While locked, the shell does not exist, so presentation answers, attention
  peeks and invite links are lost, and peeks, layout undo and backgrounds reset on unlock. With #189
  (a window per display) there is now one `ShellState` per window, which is why the per-space
  backgrounds broke when merged against it. Fix: app-level shell state owned by AppState; per-window
  state (zoom, hover) stays per window. Medium, and it should precede the #189 merge.
- **Domain state outside SQLite** (verified for backgrounds): per-space backgrounds, space recency, the
  last space and secret metadata live in UserDefaults; the background presentation lives on the
  port_panels row; deleting a space leaves its map entry. Fix: space columns via a new migration;
  UserDefaults only for device preferences. Medium.
- **Observation is partial** (reported): `companions` is reloaded by hand at 15 sites with no observation;
  `currentSpace` is a copied value patched by hand; the spaces query is duplicated with a comment
  requiring the copies to match. Fix: store `currentSpaceId`, observe agents, share one request. Medium.
- **Invalidation fan-out** (reported): `ShellState` has 51 `@Published` properties including the mouse
  position, set on every mouse move and observed by 12 view types; AppState forwards every
  `PortWindowManager` change; a retired inline-height pipeline still publishes. Fix: give the mouse its
  own object, delete the dead pipeline, move to `@Observable` (macOS 14) when touching these. Small first
  steps; this is a likely contributor to the scroll jitter measured earlier.
- **Logic in views** (reported): a voice controller and four event monitors in `ShellView` `@State`;
  secrets create and delete written twice in views; `saveUser` called from `SetupView`; default space
  naming duplicated. Fix: move each behind an AppState or service method with tests. Medium.

### 3. Sequencing by timers and blocking I/O on the main actor (state, services, views)

- Every `DatabaseService` call is synchronous on `@MainActor`, including hot paths: the mirror lookup
  reads two tables on every bridge call (`RemoteTile.swift:66-69`, verified), chat routing reads members
  and 200 entries per post. The codebase has already measured main-thread commits causing gateway
  timeouts. Fix: cache with `ValueObservation`; `DatabasePool` with async access on hot paths. Medium to
  large.
- Boot, background adoption, terminal delivery and dismissals are ordered by `asyncAfter` delays,
  `usleep` and polls: 50 `asyncAfter` calls in Views alone, and terminal delivery tuned by about ten
  timing constants with a `cli == "claude"` special case. This is the source of the "message sat
  unsent" class of bugs. Fix: an event-driven boot state machine, one `DeliveryPolicy` per CLI producer,
  animation completion handlers. Medium.
- Lifecycle gaps (reported): the gateway pipe handler is never cleared; `stop()` blocks main for up to
  2 s; terminal teardown leaves polling Tasks running; the hooks receiver uses a blocking accept loop
  with no timeouts. Small each.

### 4. Concurrency is unchecked (state, services)

`Package.swift` is tools 5.9 with no strict-concurrency setting (verified). Reported races: a double
continuation resume in `ScreenRecorder.stop` (a crash when it happens), `VoiceGlobalTrigger` touched from
two threads, a non-Sendable `DatabaseService` captured in detached tasks. Fix: strict concurrency as
warnings per target, then fix what it finds. Medium to large; best paired with theme 3.

### 5. Release and test pipeline (gateway, build, tests)

- **Go is ungated** (verified): `build.sh` runs `go test` for the CLI only; the relay deploy workflow has
  no test step. The door and the relay can ship red. Small fix.
- **Release depends on one Mac and has no guard** (verified: no branch or clean-tree check in
  `build.sh`): the build number is a gitignored local counter that Sparkle compares; a missing
  `generate_appcast` is only a warning; the appcast commit lands on whatever branch is checked out and
  takes anything staged. Fix: refuse unless on a clean `main` at `origin/main`; derive the build number
  from git; fail on a missing appcast tool. Small.
- **The Go suite needs Node and Chrome** (reported): 61 of 73 seconds is the guest browser suite, and it
  fails rather than skips on a fresh clone. Small.
- **Tests that pin source text** (reported): 49 of 264 test files assert on source strings, including
  security guards. Replace the security pins with behavioral tests. Medium.
- **Flaky and unsafe tests** (reported): sleeps then assert-nothing, random ports, and a reclaim test that
  could kill another process's listener. Inject clocks, bind port 0. Medium.
- **Fixtures** (reported): 33 private world builders; `makeParityWorld` sets state by hand instead of
  running the restore and observation path, so regressions there are invisible. Medium.
- **Repo weight** (reported): 147 files of the signed `dist/Port42.app` in plain git history. Publish the
  DMG through Releases only. Small.
- **Shared build directory** (reported): dev instances share one `.build` and `.build-number`, the known
  SwiftPM lock wedge. Small.

### 6. Error handling and dead code (all areas)

- Three error shapes reach callers: `BridgeError`, `["error":…]` dictionaries patched at the boundary,
  and uncoded strings; the streaming path drops `code`. Device services return dictionaries whose code
  is replaced by a generic one. Fix: services throw `BridgeError`, one renderer per adapter. Medium.
- Swallowed errors: 35 `try?` in AppState, 22 `try? db.<write>` across services, 14 `print` beside
  `p42log` (print is lost in a release build). Small to medium.
- Dead code (reported): `ToolExecutor` never instantiated, unused draft stores, the inline-height
  pipeline, the unused Ghostty representable path, swim and engine leftovers, two notification names
  with no sender or no receiver, `wired` never false. Small.
- Comments as history: many functions carry more dated incident history than code. Keep the invariant
  and the reason; history belongs in commits. Small, ongoing.
- Identity by display name in chat routing, watches and the remote actor mapping; key on ids. Medium.

## Recommended order

1. The private security appendix, first: each item becomes a squad ticket (issues are the squad's).
2. Before the 1.0.7 merge: `ShellState` ownership (theme 2) and the backgrounds moved to AppState, since
   #189 makes both necessary anyway.
3. Small, high-leverage fixes as one batch: Go tests gated in `build.sh` and the relay workflow; the
   release guard; delete the inline-height pipeline and the mouse publish; clear the gateway pipe
   handler; `p42log` in place of `print`.
4. Authorization seam (theme 1), as a feature with a plan: resolve once, read scope at the seam, one
   authority type, a behavioral matrix test.
5. Then, as features: AppState extraction, observation and the space columns, the delivery policy and
   boot state machine, strict concurrency.

Effort classes are the reviewers' (small, medium, large); scope and timing are Gordon's call.
