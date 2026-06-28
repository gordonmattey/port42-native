# Swim → Space — Phase 1 detailed plan (DB: membership lookup + data migration)

Parent: `docs/plan-swim-is-space.md` (full collapse, north-star). This is the **detailed plan for
Phase 1 only** — write it, build green, commit, before touching Phases 2–4. Phase 1 adds the DB
layer and migrates existing data **without any behaviour change** (the app still drives swims the
old way until Phase 2/3 re-point the call sites).

## Goal of Phase 1

1. Membership-based DM resolution: `findDirectSpace(companionId:)` + `getOrCreateDirectSpace(...)`.
2. A GRDB migration (`v35`) that rewrites every existing `swim-<companionId>` space — and all its
   child rows across 9 FK-linked tables — to a fresh UUID id, dropping the `swim-` prefix.
3. Heavy unit tests on both (this is the riskiest step in the whole collapse).

**Out of Phase 1:** no call-site changes (the ~20 `swim-<id>` sites still run — they'll just be
operating on migrated data via the *new* ids... see "Compatibility during Phase 1" below), no UI
changes, `isSwim` column stays (set to 0 on migrated rows; dropped in Phase 4).

## Compatibility during Phase 1 (important)

After `v35`, the magic id `swim-<X>` no longer exists in the DB, but Phase-1 code still *constructs*
`"swim-\(companionId)"` at ~20 sites (e.g. `startSwim` upserts `Space.swim`). To keep the app
working between Phase 1 and Phase 2 **without regressions**, Phase 1 must NOT break those sites.
Two options:

- **(chosen) Make `startSwim`/`Space.swim` resolve through the new path immediately** — i.e. do a
  *minimal* slice of Phase 2 for the create/open path only: `startSwim` calls
  `getOrCreateDirectSpace` instead of `Space.swim`. Existing reads (`buildRelationshipPreamble`,
  tools) still use `"swim-\(id)"` — which post-migration points at *nothing*, so they'd read empty
  memory. **Not acceptable.**
- **(safer, actually chosen) Keep Phase 1 read-compatible:** the migration **also leaves a stable
  alias** so old `"swim-\(id)"` lookups still resolve until Phase 2 removes them. Simplest alias:
  do NOT change the id in Phase 1 at all — instead Phase 1 only *adds* `findDirectSpace`/
  `getOrCreateDirectSpace` (which work on the existing `swim-<id>` spaces too, since they're
  `type:"direct"` with one agent member) and the migration is **deferred into Phase 2** where the
  call sites move in the same commit.

**Decision:** split the original Phase 1 — do the **lookup helpers in Phase 1a (zero risk, no data
change)**, and the **id-rewrite migration in Phase 1b, landed together with the Phase 2 call-site
swap** so reads never point at a dead id. This avoids a window where memory reads break. The doc
below specifies both 1a and 1b; ship 1a first.

---

## Phase 1a — lookup helpers (no data change)

### `findDirectSpace(companionId:)`

A DM is the `type:"direct"` space whose **only** agent member is `companionId`. (The human isn't in
`agentSpaces` — human membership is implicit — so "one agent member" == a 1:1 DM.)

```swift
/// The direct (1:1) space for this companion: type "direct" with exactly one agent member = it.
/// Deterministic on dups (oldest wins). nil if none.
public func findDirectSpace(companionId: String) throws -> Space? {
    try dbQueue.read { db in
        try Space.fetchOne(db, sql: """
            SELECT s.* FROM spaces s
            WHERE s.type = 'direct'
              AND EXISTS (SELECT 1 FROM agentSpaces a WHERE a.spaceId = s.id AND a.agentId = ?)
              AND (SELECT COUNT(*) FROM agentSpaces a2 WHERE a2.spaceId = s.id) = 1
            ORDER BY s.createdAt ASC
            LIMIT 1
            """, arguments: [companionId])
    }
}
```

### `getOrCreateDirectSpace(companion:)`

```swift
/// Find the companion's direct space, or create a fresh UUID one (type "direct", unsynced) and
/// add the companion as its agent member.
public func getOrCreateDirectSpace(companion: AgentConfig) throws -> Space {
    if let existing = try findDirectSpace(companionId: companion.id) { return existing }
    let space = Space(id: UUID().uuidString, name: companion.displayName, type: "direct",
                      createdAt: Date(), encryptionKey: nil, syncEnabled: false, isSwim: false)
    try dbQueue.write { db in
        try space.insert(db)
        try db.execute(sql: "INSERT OR IGNORE INTO agentSpaces (agentId, spaceId) VALUES (?, ?)",
                       arguments: [companion.id, space.id])
    }
    return space
}
```

(Note: `isSwim:false` — new DMs are never swims. The `isSwim` param stays only until Phase 4 drops
the column.)

### Phase 1a tests (`DirectSpaceLookupTests`, `DatabaseService(inMemory:true)`)

- **DM hit:** seed a `direct` space + `agentSpaces(companion, space)` → `findDirectSpace` returns it.
- **Team space ignored:** seed a `team` space with the companion as a member → not returned.
- **Two-agent direct ignored:** a `direct` space with 2 agent members → not returned (not a 1:1).
- **None → nil.**
- **Dup DMs → oldest:** two direct spaces for the same companion, different `createdAt` → returns the
  older.
- **getOrCreate creates once:** call twice → same space id both times; exactly one `direct` space +
  one `agentSpaces` row exist.

---

## Phase 1b — the `v35` data migration (lands with Phase 2 call-site swap)

### What it does

For every legacy swim space (`id LIKE 'swim-%'` AND `isSwim = 1`): mint a UUID, repoint all child
rows, swap the `spaces` row, drop the `swim-` id. FK-safe (insert new parent → move children →
delete old parent, so no row is ever orphaned even with `foreign_keys = ON`).

### Child tables to repoint (all `spaceId` → new id)

`messages`, `agentSpaces`, `port_panels`, `port_storage`, `input_history`,
`companion_positions`, `companion_folds`, `companion_creases`, `companion_engravings`.
(Confirmed: all have a `spaceId` column FK→`spaces(id) ON DELETE CASCADE`.)

### Factored helper (so it's unit-testable without running the migrator)

```swift
/// Repoint a space and all its child rows from oldId to newId. FK-safe ordering:
/// new parent first, children next, old parent last. Caller runs inside a write txn.
static func repointSpaceId(_ db: Database, from oldId: String, to newId: String) throws {
    // 1. new parent (copy the row, force isSwim=0)
    try db.execute(sql: """
        INSERT INTO spaces (id, name, type, createdAt, encryptionKey, syncEnabled, isSwim,
                            heartbeatInterval, heartbeatPrompt)
        SELECT ?, name, type, createdAt, encryptionKey, syncEnabled, 0, heartbeatInterval, heartbeatPrompt
        FROM spaces WHERE id = ?
        """, arguments: [newId, oldId])
    // 2. children
    for table in ["messages", "agentSpaces", "port_panels", "port_storage", "input_history",
                  "companion_positions", "companion_folds", "companion_creases", "companion_engravings"] {
        try db.execute(sql: "UPDATE \(table) SET spaceId = ? WHERE spaceId = ?",
                       arguments: [newId, oldId])
    }
    // 3. old parent (now childless)
    try db.execute(sql: "DELETE FROM spaces WHERE id = ?", arguments: [oldId])
}
```

(`agentSpaces` PK is `(agentId, spaceId)` — the UPDATE is safe as long as the companion isn't
already a member of `newId`; it isn't, `newId` is brand new. Table names are interpolated from a
hardcoded allowlist, not user input — safe.)

### Real-DB findings (sanity check on a copy of gordon's live DB, 2026-06-27)

Ran a read-only audit on a copy of the live `port42.sqlite` (at `v34`, v35 not yet run). Of **29**
`isSwim=1` spaces:

- **15 healthy** — exactly one `agentSpaces` member, member id == the id embedded in `swim-<id>`,
  the agent still exists. These migrate cleanly and `findDirectSpace` resolves them.
- **13 with ZERO `agentSpaces` rows, and the embedded companion is GONE from `agents`** — dead
  swims (mostly test cruft: `test`, `enginer`, `dsadsa`, stray `Claude Code`/`Gemini CLI`). Naive
  repoint mints a UUID `direct` space with **no membership** → permanently invisible to
  `findDirectSpace` (orphan). A few carry messages (`test`=16, `enginer`=6) but no live agent can
  ever reopen them.
- **1 mismatch (`testeng`)** — its sole `agentSpaces` member is **`forge`**, a *different* live
  companion that ALSO owns its own `forge` swim. So `forge` is a member of **2** swim spaces →
  post-migration `findDirectSpace(forge)` sees a **dup** (oldest-wins resolves it deterministically,
  but the other becomes shadowed/unreachable).

**Implication — the naive `SELECT id FROM spaces WHERE isSwim=1` repoint-all would create 13 orphan
spaces and 1 dup.** v35 needs a pre-pass:

1. **Skip/drop dead swims** — for an `isSwim=1` space with no `agentSpaces` row whose embedded
   `substr(id,6)` is not in `agents`, **delete** it (cascades its messages) rather than migrate it
   to an unreachable orphan. (These are unrecoverable test cruft; nothing can open a swim whose
   companion is gone.) Log each deletion + its message count.
2. **Dup guard** — after repointing, if any companion ends up the sole member of >1 `direct` space,
   log it (the `testeng`/`forge` case). Decide per-case: drop the cruft swim (`testeng`) or merge.
   Don't silently shadow.
3. Optionally **backfill membership** for any `isSwim=1` space that has zero `agentSpaces` rows but
   whose embedded companion *does* still exist (none in this DB, but defensive) — insert the
   `agentSpaces` row from `substr(id,6)` before repointing so it stays resolvable.

### The migration

```swift
migrator.registerMigration("v35-swim-to-direct") { db in
    let swimIds = try String.fetchAll(db, sql: "SELECT id FROM spaces WHERE isSwim = 1")
    for oldId in swimIds {
        // PRE-PASS (see "Real-DB findings"): drop dead swims (no member + agent gone),
        // backfill membership where the embedded agent still exists, before repointing.
        let newId = UUID().uuidString
        try Self.repointSpaceId(db, from: oldId, to: newId)
    }
    // POST-PASS: assert/log any companion that is now sole member of >1 direct space (dup guard).
}
```

Runs once (GRDB tracks applied migrations). `UUID()` is fine in app code (this is not a Workflow
script). If GRDB's default immediate FK checks ever complain, the ordering already prevents
violations; only as a last resort wrap with GRDB deferred-FK-check registration.

### Phase 1b tests (`SwimMigrationTests`)

Test `repointSpaceId` directly (don't try to half-run the migrator): on `DatabaseService(inMemory:
true)` (schema already built), insert a fake legacy swim space + children, call `repointSpaceId`,
assert.

- **Full repoint:** seed `spaces(id:"swim-T", isSwim:1, type:"direct")` + `messages`, `agentSpaces`,
  `companion_creases`, `companion_folds`, `port_panels` rows on `"swim-T"`. Call
  `repointSpaceId(from:"swim-T", to:"NEW")`. Assert: no space `"swim-T"`; space `"NEW"` exists with
  `isSwim==0`; every child row now has `spaceId=="NEW"`; row counts preserved (nothing dropped).
- **FK intact:** after repoint, deleting `"NEW"` cascades the children (proves FK wiring survived).
- **findDirectSpace post-repoint:** the companion resolves to `"NEW"`.
- **No-children space:** a swim space with zero messages/creases repoints cleanly.
- **Idempotent-ish guard:** running the migration body twice over the same `isSwim=1` set is a
  no-op the second time (no `isSwim=1` rows remain) — assert second run changes nothing.

### Migration safety checklist (must do before shipping 1b on a real DB)

- Back up `~/Library/Application Support/Port42/port42.sqlite`.
- Run on a **copy of a real DB** with several swims + accrued creases/folds; verify history +
  relationship memory survive under the new ids and the app reads them.
- Confirm migrated direct spaces keep `syncEnabled = 0` (don't start syncing private DMs).
- Dedup check: if `findDirectSpace` sees >1 direct space per companion post-migration, log it
  (shouldn't happen — one swim per companion historically — but assert/observe).

---

## Sequencing recap

1. **1a** (lookup helpers + tests) — zero data risk, ship first.
2. **1b** (the `v35` migration + repoint tests) — land **together with Phase 2** (call-site swap to
   `findDirectSpace`/current-space) so no read ever points at a dead `swim-<id>`.
3. Then Phase 3 (UI unify) and Phase 4 (drop `isSwim`) per the parent plan.
