# The Membrane

The interface between the human loop and the agent loops — watching and steering many running agents
with one person. Four documents, which trace to each other and are the single source of truth:

- [`membrane-requirements.md`](membrane-requirements.md) — **the jobs**, as multi-party job stories
  (architecture-free): what any solution must serve. Jobs `J1–J21`, constraints `C1–C6`.
- [`membrane-spec.md`](membrane-spec.md) — **what the membrane does**: its faculties, each named for the
  role that carries it and traced to the jobs it serves. A coverage matrix proves every job is served.
- [`membrane-architecture.md`](membrane-architecture.md) — **how it's built**: the roles that realize the
  faculties, grouped **by role** into the **Face** (Sensor · Synchronizer · Presenter), the **Crew**
  (Watcher · Gatekeeper · Controller · Coordinator · Guard · Librarian), and the **Substrate** (Runner ·
  Keeper). Continues the trace: role → job. *(Build order is a separate plan, not encoded here.)*
- [`make-or-break.md`](make-or-break.md) — **where it lives or dies**: every anxiety ranked by
  adoption-impact, derived (not asserted). Answer: trust-with-real-stakes — **recovery (Guard) and
  control (Controller)** — not attention, and not privacy (privacy is an operator setting).

Traceability runs the whole chain: **job → faculty → role**. Change a job and the spec must answer it;
add a faculty and it must earn its place against a job; add a role and it must realize a faculty. Each
role keeps a stable **ID** (F1–F4, S1–S3, R1–R3) as its anchor, so a rename never breaks the chain.

## Role interfaces

The four docs above are the source of truth. Each role earns a deeper spec of its own when we build it —
a **versioned interface contract** (a level-2 invariant), traced back up the chain.

- **The Keeper — Person-Model Interface (F3)** — *parked; to be re-specced.* A v0.1 was drafted then set
  aside to revisit. Foundational (the Gatekeeper's personalized triage needs it — J12; powers J4/J9), but
  not on the path for Slice 01.

## Build — vertical slices

A slice runs end-to-end through several roles, building only the sliver of each that the slice needs —
so a real implementation meets the contracts and tells us whether they're right.

- [`slice-01-trust-core.md`](slice-01-trust-core.md) — **Slice 01 · The Trust Core**: one bounded,
  reversible coding task — run, watched, recovered. Cuts through Runner · Controller · Guard (+ thin
  Watcher · Gatekeeper · Presenter); serves J1, J3, J5, J10, J15. Pierces the make-or-break (Guard +
  Controller); standalone (no Port42).
