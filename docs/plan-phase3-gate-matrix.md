# Phase 3 gate matrix: the real principal, the remainder

*2026-07-19, branch shell-s1. Status: SIGNED OFF (GM, 2026-07-19: decision 1 confirmed no
migration, breaking changes acceptable; decision 2 = Option 1, space-scoped). Items A, B, C
implemented and green (289 tests / 43 suites); D (live two-caller proof) and E (docs) remain.
Companion to `plan-phase3-principal.md` (the design) and `plan-api-unification.md` Phase 3 (stale,
superseded). Discipline: an item is not touched until its gate test exists and is recorded
failing. Test in Port42Dev only (:4243). Exact suite names in test filters, never substrings.*

**Progress log (2026-07-19):**
- **A DONE.** Negative gates pinned in `BridgePrincipalTests` (`remote-\(` constructor scan,
  `remote-http` consumer allowlist). Acid-tested: a planted constructor line named Principal.swift.
- **B DONE.** `PermissionRequester` deleted; `PermissionCoordinator.request` takes a `Principal`;
  `PermissionRequest.principal` + public `awaiterCount`; `scopeDescription` lives on Principal;
  `ShellPermissionOverlay`, `BridgeDispatcher`, and the fs.drop path all use the Principal
  directly. Collapse gate recorded failing first, then green. Found and fixed en route: the
  `coalescesAndResumesAll` test raced its own registration (settled on `current != nil`, already
  true from the first ask, so `resolveCurrent` could answer before asks two and three joined; they
  then rode a card nobody answers and the run hung). It now settles on `awaiterCount == 3`.
- **C DONE.** `portPrincipal` is the ONE PortBridge identity (id = `createdBy ?? messageId`,
  space-scoped); both `handleMethod` inline principals replaced; deinit cancels by principal id.
  Gates recorded failing first: creator resolution, single-construction scan, companion/port
  shared storage namespace. The storage gate proves todo #6's companion-port sharing.
- **D DONE (live, Port42Dev :4243, 2026-07-19).** Gated method: `clipboard.read` (no pregrant
  toggle, no macOS TCC layer). (1) Local curl prompted as "Local (gateway)", GM allowed, grant
  landed in `portPerms.local-http.global`; the WS second caller (`scratchpad peer_b.py`,
  identify `peer-test-B`, no `is_host`, empty `channel_id`) prompted AGAIN and its grant landed in
  `portPerms.peer-test-B.global` — distinct callers, distinct decisions, distinct buckets.
  (2) Relaunched Port42Dev; local curl returned with no prompt (persistence under the principal
  id). (3) Regression: `user.get`/`ports.list`/`help` over the gateway unchanged; a fresh port's
  JS round-tripped `user.get` + the `creases.read` alias via `port.exec`. Note for future rigs:
  `port.exec` wraps a bare single-line script as `return (expr)` (PortExecJS.wrapBody), so
  multi-statement probes need newlines or an explicit `return` — malformed probes surface as
  "Script error." lines inside the port, which is the port's error hook working, not a bug.
- **E DONE.** This log; `plan-api-unification.md` Phase 3 section replaced with a pointer;
  `plan-phase3-principal.md` status header corrected; handoff updated; the coordinator-test race
  recorded in `summer2026-todo.md` and the storage-sharing item (#6) updated for the
  companion-port half.

---

## Ground truth: Phase 3 is partially shipped, not unstarted

The handoff line "Phase 3 designed but UNSTARTED" is wrong. Commit **157439c** (2026-07-17,
"feat(principal): Phase 3 — stable local gateway principal") is on shell-s1 and shipped:

- **Gateway stable id.** `HandleHTTPCall` sets `SenderID: "local-http"` (gateway.go:863,870), with
  Go gates in `gateway_httpcall_test.go` (stable id + concurrent callID routing, including the
  latent UnixNano collision fix).
- **Swift keying.** `onCallReceived` keeps `senderId` as the identity and derives display via
  `Principal.gatewayDisplayName` (AppState.swift:1195-1198). `RemoteToolExecutor` builds
  `Principal(id: senderId, kind: .peer)` for both registries (ToolExecutor.swift:126,142); the
  close-out later deleted its old-path executor entirely, so no label-keyed fallback exists.
- **Grant keying + persistence.** `runBridgeMethod`/`runBridgeStream` key grants on `principal.id`
  and persist via `saveCompanionPermissions(createdBy: principal.id)` into
  `portPerms.<principalId>.<spaceId|global>` (BridgeDispatcher.swift:35-42, AppState.swift:1014).
- **Display consumer.** `ShellDesktop.who()` maps `local-http` to "Local (gateway)"
  (ShellDesktop.swift:1321-1326).
- **Tests.** `BridgePrincipalTests` (id/display split, per-id grant isolation, global bucket).
- **Waiting seam.** The picked-file grant store (`AppState.pickedFilePaths`) is principal-keyed
  (tail item 7).
- **No label constructors remain.** `remote-\(` appears nowhere in Sources; `remote-http` survives
  only as the documented legacy mapping in `who()`.

What the plan (`plan-phase3-principal.md`) lists as Steps 2, 3, and the substance of 4 is done.
The remainder is items A through E below plus two decisions.

## Decisions needed from GM (the blocker)

1. **Migration: confirm the locked no-migration stands.** The handoff prompt says "existing Always
   Allow grants stored under label keys need a migration". `plan-phase3-principal.md` §0 records
   the opposite as locked (GM, 2026-07-17): no migration, old label-keyed grants drop, a caller
   re-grants once; the `remoteAllow*` UserDefaults toggles are untouched and still work
   (ToolExecutor.swift:116-119). 157439c shipped on that basis two days ago, so label buckets are
   already orphaned. Recommendation: the locked decision stands (it also matches the no-compat
   hard rule); item D's live matrix includes the re-grant-once check. Confirm.

2. **Port principal resolution (the real fork).** Two keying behaviors coexist for ports today:
   - Registry path: a port's principal id is its `messageId`, so grants persist per-port
     (PortBridge.swift:290-293 + the dispatcher). The creating companion's grants flow in one-way
     as `pregrant`.
   - The fs.drop gesture path (the one surviving old-style check): `recordGrant` persists to the
     creating companion's bucket, the P-260 "future ports by the same companion auto-grant"
     semantics (PortBridge.swift:108-119).
   Separately, `summer2026-todo.md` #6 (storage sharing) is explicitly parked on this: "resolve a
   port's principal to (companionId, spaceId) in Phase 3 so a companion, its ports, and its
   gateway session share one namespace."
   **Option 1 (recommended): resolve to creator.** A companion-created port's principal id is the
   companion id (kind stays .port, port id survives for coalescing/cancel); a human-created port
   keys on its own id. One bucket per author closes P-260 both ways and unblocks todo #6 storage
   sharing with no second mechanism. Cost: a port and its companion become one permission subject,
   which is the stated intent of P-260.
   **Option 2: stay per-port.** Keep one-way pregrant, align fs.drop to per-port keying, solve
   storage sharing later by another means. Cheaper now, leaves todo #6 parked.

## The matrix

| # | Item | Gate test (exists + recorded failing before code) | Depends on |
|---|---|---|---|
| A | Pin the negative gate: the label can never be a key again | `BridgePrincipalTests`: source-scan asserts (1) no `remote-\(` identity constructor in Sources/Port42Lib, (2) every `remote-http` occurrence is on the documented consumer allowlist (`who()` legacy mapping). Scan is green-by-nature at birth, so acid-test it Spike-B style: reintroduce a constructor locally, watch it name the file, revert. | nothing |
| B | Collapse `PermissionRequester` into `Principal` | New scan case, recorded failing while the type exists: no `struct PermissionRequester` in Sources. Plus `PermissionCoordinatorTests` re-typed to `Principal` (coalescing on principal.id, cancelRequests(from:) drops a closed port's asks, double-answer no-op) staying green, and a kind-aware `scopeDescription` case per Principal.Kind. Delete `Principal.permissionRequester`; `request(_:from:)` takes `Principal`; `ShellPermissionOverlay` reads principal displayName + scope; the fs.drop check builds a Principal. | A |
| C | Port principal resolution per decision 2 | If Option 1: `BridgePrincipalTests` case, recorded failing: grant via a companion-created port principal, assert the same companion's next port (different port id) resolves the grant, and a different companion's port does not; storage case: the port principal and its companion principal read the same `storage.set` value. If Option 2: case pinning fs.drop grants under the port id (recorded failing while `recordGrant` writes the companion bucket). | B, decision 2 |
| D | The live two-caller proof (plan Step 5, never run) | Live acceptance matrix in Port42Dev :4243, run after A-C: (1) local curl grants a gated method (`screen.capture`); a WS client identifying as `peer-test-B` (identify without `is_host`, call with empty `channel_id`) calling the same method still prompts; (2) relaunch Port42Dev, local curl does not re-prompt (persisted under `portPerms.local-http.global`); (3) re-grant-once: a pre-157439c label bucket seeded in defaults does not resolve, one grant fixes it (decision 1's check); (4) no regression: ports.list / port.getHtml / a port's JS / an in-app companion unchanged. `sample Port42Dev <pid>` before killing anything hung. | A-C built |
| E | Docs close-out | No test (docs). `plan-api-unification.md` Phase 3 section replaced with a pointer + shipped result; `plan-phase3-principal.md` status header corrected (steps 2-4 shipped in 157439c, remainder here); handoff updated; the two deliberate behavior changes recorded (shared local-http bucket, remoteExecutors cache collapse) plus decision 2's outcome. The permission-prompt-lost bug note carries over: no path may persist a denial. | A-D |

Droppable if GM wants the arc lean: a WS peer's display name currently renders as its raw id
(`gatewayDisplayName` has no peer-name resolution; `onCallReceived` does not receive
`sender_name`). Display-only, no keying impact; can ride with C or drop.

## Sequencing

A (pin, cheap) -> B (collapse) -> C (resolution, needs decision 2) -> D (live gate) -> E (docs).
Each item lands individually: gate recorded failing, implement, green, commit when asked. Suites:
`BridgePrincipalTests`, `PermissionCoordinatorTests` (exact names in filters). Full bridge
regression check per item: `swift test --filter Bridge` equivalents by exact suite list, then the
214-test baseline.

## Risk

Low. The identity edits with behavioral risk (gateway id, keying, persistence) shipped in 157439c
and are gated. B is a type collapse over one coordinator + one overlay + one bridge site. C is the
only behavior change and it is decision-gated with its own recorded-failing tests. The
migration-drop risk named in the handoff is retired by decision 1 plus D(3).
