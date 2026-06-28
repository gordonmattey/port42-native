# Swim → Space — Phase 2 detailed plan (kill `swim-<id>` strings, lands WITH the v35 migration)

Parent: `docs/plan-swim-is-space.md`. Predecessor: `docs/plan-swim-is-space-phase1.md` (1a shipped:
`findDirectSpace` / `getOrCreateDirectSpace` + tests, commit `620004d`).

**This commit = Phase 1b (the v35 data migration) + Phase 2 (every `swim-<id>` string site re-pointed
to membership resolution), landed together.** They MUST ship in one commit: v35 deletes every
`swim-<id>` row, so any site still *constructing* `"swim-\(id)"` after v35 either reads a dead id
(empty memory) or *recreates* an orphan `swim-` space. So all construction/parse sites move in the
same commit that runs v35.

This is still **behaviour-preserving** (modulo ids): relationship memory stays "one inner state on
the companion's DM", swims still open/restore, the sidebar is unchanged. UI/state teardown
(`activeSwimCompanion`, `startSwim`/`exitSwim`, `SwimView`) is **Phase 3**, NOT here.

---

## Decisions (Phase 2)

- **D-P2-A — DO D4 (memory is space-scoped).** (gordon chose this 2026-06-27.) Relationship memory
  keys to the **current space** (the space the turn/tool-call happens in), not a hardcoded DM. The
  **companionId comes from `createdBy`** (the calling companion) or an explicit arg — NOT parsed from
  a `swim-` id. Fallback to the companion's **direct space** only when there is **no current-space
  context** (e.g. an HTTP/headless tool call with `spaceId == nil`). Consequences:
  - A companion in #project accrues #project memory; in a DM it accrues DM memory. One mechanism.
  - **Existing data is unaffected for DM use:** v35 moves all historical memory onto the migrated DM
    (a `direct` space). Opening that DM ⇒ current space == that DM ⇒ all history shows. Team-space
    conversations start with fresh (empty) memory — that is the intended scoping, not data loss.
  - This **dissolves most of the reverse-parse category** (C): tools no longer derive companionId
    from the space id; they use `createdBy` + the current space id directly.
- **D-P2-B — keep DMs out of the main space list.** `getOrCreateDirectSpace` creates `isSwim:false`
  `type:"direct"` spaces. `getRegularSpaces` currently filters `isSwim==false` → those would leak
  into the main space list. Change the filter to **exclude `type == "direct"`** (not `isSwim`) so
  DMs stay presented as companion rows until Phase 3 decides sidebar grouping. (Equivalent to today
  for legacy data; correct for migrated data.)
- **D-P2-C — `Space.swim` factory stays for now.** Don't delete it in Phase 2 (smaller diff, less
  risk). It becomes dead once `startSwim` stops calling it; delete in Phase 3/4. The only *live* use
  after this commit is... none (startSwim moves off it) — but leave the symbol to keep the diff
  focused. (Grep-gate its removal in Phase 4.)

---

## New DB helpers (add in this commit, alongside 1a's two)

```swift
/// Single-agent fetch (write-path tools have only a companionId, need the AgentConfig).
public func getAgent(id: String) throws -> AgentConfig?

/// READ-path id resolver: the companion's direct-space id, or nil if no DM exists yet.
/// (Thin wrapper over findDirectSpace so call sites read cleanly.)
public func directSpaceId(companionId: String) throws -> String? {
    try findDirectSpace(companionId: companionId)?.id
}

/// WRITE-path id resolver: ensure the companion's DM exists, return its id. nil if agent is gone.
public func getOrCreateDirectSpaceId(companionId: String) throws -> String? {
    guard let agent = try getAgent(id: companionId) else { return nil }
    return try getOrCreateDirectSpace(companion: agent).id
}

/// REVERSE resolver (spaceId → companionId): the sole agent member of a direct space, else nil.
/// Replaces every `dropFirst("swim-".count)` parse.
public func companionId(ofDirectSpaceId spaceId: String) throws -> String?
// SQL: SELECT agentId FROM agentSpaces WHERE spaceId = ? — but only if spaces.type='direct'
//      AND exactly one agentSpaces row for that spaceId; else nil.
```

(`directSpaceId`/`getOrCreateDirectSpaceId`/`companionId(ofDirectSpaceId:)` are the three verbs the
~24 sites reduce to. Adding them keeps the call sites one-liners and the logic testable in one place.)

---

## The v35 migration (Phase 1b — see phase1 doc for the real-DB findings driving the pre-pass)

Append `repointSpaceId` static helper + `v35-swim-to-direct` migration per the phase1 doc, **with the
pre-pass the live-DB audit proved necessary**:

1. For each `isSwim=1` space: if it has **0 `agentSpaces` rows AND `substr(id,6)` is not in `agents`**
   → **DELETE** it (cascades messages); `log` the id + message count. (13 such dead swims in the
   live DB — unreachable test cruft.)
2. Else if it has 0 `agentSpaces` rows but the embedded agent **does** exist → backfill the
   `agentSpaces` row from `substr(id,6)` before repointing (defensive; none in the live DB).
3. Repoint the rest to a fresh UUID via `repointSpaceId` (insert new parent `isSwim=0` → move 9 child
   tables → delete old parent).
4. **Post-pass dup guard:** after all repoints, find any companion that is now the sole agent member
   of >1 `direct` space (the `testeng`→`forge` case) and `log` it. Don't auto-merge; flag for manual
   cleanup. `findDirectSpace`'s oldest-wins keeps resolution deterministic meanwhile.

Tests: `SwimMigrationTests` per the phase1 doc (repoint full / FK-cascade-intact / post-repoint
resolution / no-children / idempotent), PLUS: **dead-swim dropped** (0-member + agent-gone → deleted,
not orphaned), **backfill** (0-member + agent-exists → membership added then repointed).

---

## Site-by-site re-point (D4 semantics: memory space = current space; companion = `createdBy`/arg)

Helper used per direction: **`memSpaceId`** = the space memory attaches to for this turn =
`currentSpaceId ?? (try? db.directSpaceId(companionId:))` (current space, fallback to DM when headless),
and for **writes** the fallback is `getOrCreateDirectSpaceId(companionId:)`.

### A. Context/initiative reads — use the CURRENT space, not the DM

| Site | Now | After (D4) |
|---|---|---|
| `AppState.swift:448` `buildRelationshipPreamble` (in `SpaceAgentHandler`, has `self.spaceId`) | `"swim-\(companionId)"` | use **`self.spaceId`** (the turn's space) for fold/position/creases/engravings. No DM fallback needed — a handler always has a real space. |
| `AppState.swift:1478` initiative watching | `swim-\(agent.id)` | use **`spaceId`** (the function already receives the current `spaceId`) |
| `AppState.swift:2206` bus initiative | `swim-\(agent.id)` | use **`spaceId`** (function receives it) |

Net: initiative/preamble become genuinely space-scoped — a companion watches/remembers per the space
the turn is in. (This is the heart of D4.)

### B. Relationship TOOLS — `createdBy` + current space (read), getOrCreate fallback (write)

All currently force `spaceId = "swim-\(companionId)"` and ignore the turn's space. D4: companionId =
`createdBy` (or explicit `companionId` arg for HTTP), spaceId = the executor/bridge's current
`spaceId`; only when that's nil fall back to the DM (`directSpaceId` for reads,
`getOrCreateDirectSpaceId` for writes).

- `ToolExecutor.swift`: `crease_read:142`, `crease_write:164`, `engrave_read:194`, `engrave_write:215`,
  `fold_read:245-246`, `fold_update:264`, `position_read:281`, `position_set:301`. (Note `fold_read`
  already has `cid = spaceId ?? swimId` — that pattern IS D4; generalise it to every tool and make the
  fallback `directSpaceId` instead of the `swim-` string.)
- `PortBridge.swift`: `fold.update:846`, `position.set:866` (writes): `spaceId ?? getOrCreate…`.

### C. Reverse parse — mostly DISSOLVES under D4 (companion = `createdBy`, space = current)

- `PortBridge.swift` reads `creases.read:1131`, `engravings.read:1152`, `fold.read:1204`,
  `position.read:1220`: **drop** the `cid.hasPrefix("swim-")` guard + `dropFirst` parse. Use
  `guard let companionId = createdBy else { return <existing error> }` and `spaceId = cid` (the
  current space). These now work in any space (read this companion's memory for the current space) —
  the intended D4 generalisation.
- `AppState.swift:1222-1224` routing `implicitCompanion` — this is **NOT memory**; it answers "is this
  space a 1:1 DM, and if so which companion is implicit (so an un-@mentioned message still routes)?"
  This genuinely needs membership: `let implicit = (try? db.companionId(ofDirectSpaceId: spaceId)).flatMap { cid in companions.first { $0.id == cid } }`. This is the ONE surviving use of
  `companionId(ofDirectSpaceId:)`.

### D. Sidebar / activity id (last-activity lookup — id must match what gets written)

| Site | Now | After |
|---|---|---|
| `AppState.swift:2778` lastActivityTimes | `swim-\(companion.id)` | `directSpaceId(companionId:)`; key under that id |
| `SidebarView.swift:54`, `:316` | `swim-\(companion.id)` | `directSpaceId(companionId:)` (nil ⇒ fall back to `companion.createdAt`, as today) |
| `DatabaseService.swift:1179` `getLastSwimTime` | `getLastMessageTime("swim-\(id)")` | `getLastMessageTime(spaceId: directSpaceId(companionId:) ?? "")` |

(These are activity-ordering lookups, not memory — they point at the DM regardless of D4.)

### D. Sidebar / activity id (Phase 2 portion only)

- `SidebarView.swift:54` and `:316` build `swim-\(companion.id)` to look up `lastActivityTimes`.
  Both must use the **same** id AppState:2778 writes under → `directSpaceId(companionId:)` (nil ⇒
  fall back to `companion.createdAt`, as today). Keep the companion-row UI itself (Phase 3 unifies it).

### E. Create/open path (the one bit of Phase 3 we MUST pull forward)

- `AppState.swift:2611` `startSwim` → replace `Space.swim(companion:)` + `upsertSpace` +
  `assignAgentToSpace` with `let space = try db.getOrCreateDirectSpace(companion: companion)` then
  `selectSpace(space)`. Keep setting `activeSwimCompanion` + UserDefaults for now (Phase 3 removes
  them). This is what stops v35 from being re-populated with fresh `swim-` rows.
- `getRegularSpaces` (`DatabaseService.swift:597`) → filter `type != "direct"` (D-P2-B).

### Leave alone (Phase 3/4)

`activeSwimCompanion` field + all its reads (`PortBridge:346,1367`, `ContentView:313`,
`SetupView:768`, `SidebarView:203,333,368`, `TransitionRoot:190`), `exitSwim`, `Space.swim` factory,
`isSwim` column. `DatabaseService.swift:263-268` (v6 legacy channel→isSwim migration) — never touch.

---

## Tests (Phase 2)

- **Reverse lookup** `companionId(ofDirectSpaceId:)`: direct+sole-member → id; team space → nil;
  2-agent direct → nil; non-existent → nil.
- **getAgent** hit/miss.
- **D4 — memory follows the current space**: ToolExecutor with `spaceId = <team space>`,
  `createdBy = companion`; `crease_write` then `crease_read` → crease stored under the **team
  space id** (assert `crease.spaceId == teamSpace.id`), and a read with `spaceId = <other space>`
  does NOT see it. (Proves memory is space-scoped, not DM-pinned.)
- **D4 — headless fallback to DM**: ToolExecutor with `spaceId = nil`, `createdBy = companion`;
  `crease_write` → stored under the companion's direct space (created via `getOrCreateDirectSpace`),
  `crease_read` (also nil spaceId) reads it back. (Proves the no-current-space fallback.)
- **startSwim opens the direct space** (update existing `SwimUnificationTests`): after `startSwim`,
  `currentSpace.type == "direct"`, `isSwim == false`, exactly one direct space exists, calling twice
  doesn't duplicate. (The existing `SwimSpaceInfraTests` assert `swim-<id>` ids — those EXPECTATIONS
  must be updated to UUID/membership, since the behaviour they pinned is exactly what's changing.)
- **getRegularSpaces excludes direct** (D-P2-B).
- Migration tests per Phase 1b above.

## Build/verify gate

- `swift build` green; `swift test` — the 7 pre-existing failures (recorded in this session) stay,
  no NEW failures; new Phase 2 tests pass.
- Manual (the real proof, on a backed-up real DB): open a companion → DM opens; existing creases/fold
  load (migrated); send a message; reload → restores the same DM; a team space is unaffected; no new
  `swim-` rows appear (`SELECT id FROM spaces WHERE id LIKE 'swim-%'` → 0).

## Gated-run results (verified on a COPY of the real DB, 2026-06-27)

Opened a copy of the live `port42.sqlite` (v34) through `DatabaseService` so v35 ran, then inspected.
Outcome after fixing the issue below:

- `swim-` ids remaining: **0**; `isSwim=1` rows: **0**; direct spaces: **16**, each with exactly one
  agent member (every DM resolves via `findDirectSpace`).
- creases preserved (64), folds preserved (7); messages 1404 → **1374** (exactly the 30 messages on
  the 13 dead swims, cleanly removed); **0 newly-orphaned** rows; **0** synced direct spaces.
- `testeng`/`forge` dup detected and logged by the post-pass; oldest-wins keeps resolution
  deterministic. (`testeng` is test cruft — manual delete recommended on the real run.)

**Bug the gated run caught (would have shipped otherwise): GRDB disables FK enforcement during
migrations**, so `ON DELETE CASCADE` does NOT fire inside v35. The dead-swim `DELETE FROM spaces`
orphaned its 30 child messages instead of cascading them. Unit tests missed it because in-memory
test writes run with FK **on**. Fix: `deleteSpaceAndChildren` deletes the 9 child tables explicitly
before the space row (used for dead swims); `repointSpaceId` already moved children explicitly so it
was unaffected. Pre-existing note: 43 orphan creases already existed at v34 (old data-hygiene issue,
unrelated to v35 — left as-is, not increased).

## Sequencing

1. Add the 4 helpers + change `getRegularSpaces` filter.
2. Add `repointSpaceId` + `v35` (with pre/post-pass) + migration tests.
3. Re-point sites A→E.
4. Update `SwimUnificationTests` expectations (swim-id → direct/UUID).
5. Build + test + manual-verify on a backed-up real DB. Commit 1b+2 together.
6. Then Phase 3 (UI teardown), Phase 4 (drop `isSwim` + `Space.swim`).
