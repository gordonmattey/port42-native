# Release: Port42 1.0.2

Started 2026-09-28, after 1.0.1 shipped. The squad's batch is on `squad/for-1.0.2`, built on `main`.

## Checks when the batch comes in

In addition to the team test and the full suites for every ticket:

- **APP-15 binds a companion's terminal to its space** (GM, 2026-09-28). Today a companion calling
  through its terminal arrives as a `.peer` with no space (`AppState.swift`, the gateway caller built
  by `RemoteToolExecutor(senderId:)`), though `whoami` finds the space through `terminalClientPanels`.
  So `storage.set` with `shared: true` from a companion's terminal fails "storage requires space
  context", and space-scoped reads cannot scope it. When APP-15 lands, check:
  - a test: a companion terminal's `storage.set key=x shared:=true` succeeds and lands in its
    space's shared bucket, and a companion in another space cannot read it;
  - live, on Dev5: the same call from a companion's terminal succeeds;
  - `whoami` and the principal agree on the space;
  - `PortReadScope` then scopes these callers (its "not scoped here" note for `.peer` can go).
- **The operator dash's items** stay on the machine-wide board (`dash:item:*`), by choice: growth's
  working-space companions write there too. Nothing to move.
