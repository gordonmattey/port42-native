# Recommendation: make the kernel boundary real

**For:** whoever picks up the seam work. **From:** the Windows research spike, 2026-09-25.
**Status:** a recommendation, not a decision. GM has not approved it.

Everything here is measured on `research-windows-port`, which branches from `nautilus` and carries
`spikes/windows-kernel/carve.sh` plus a CI workflow that runs it. Full background in
`docs/research-windows-port.md`.

## The finding this rests on

Port42's own documents describe a kernel (ports, the registry, addresses, permissions, the bus) and a
shell (the desktop, the chrome, the window manager). That boundary is asserted, not enforced: kernel
and shell are one SwiftPM target, so nothing stops a kernel service reaching into the shell, and
several do.

Carving the candidate kernel into its own package and building it shows where. On Linux and Windows
the same 30 files, 3,869 lines, compile. Everything else was dropped for naming something on the
shell's side of the line, never for anything about the platform.

The blocked work, grouped by what it reaches for, counting code references only:

| Reaches for | Files | Lines blocked |
|---|---|---|
| `ShellState` | 3 | 2,528 |
| `PortPanel` | 2 | 2,305 |
| `AppUser` | 1 | 2,133 |
| `AppState` | 6 | 1,491 |
| `GatewayProcess` | 4 | 870 |
| `Port42AuthStore` | 2 | 436 |
| `TerminalPortConfig` | 1 | 386 |

## Recommendation

**Do these three. They are defects on the project's own terms and each is mechanical.**

### 1. Move `PortPanel` into `Models/`

It is the port's data model and it is defined inside `Views/PortWindowManager.swift`, so
`DatabaseService` (persistence) depends on a view file. Nothing about that is correct today,
independently of any platform. Blocks 2,305 lines.

The move is the definition plus its `Codable`/`Identifiable` conformances. `PortWindowManager` keeps
everything that manages panels; it stops owning what a panel *is*.

### 2. Move the geometry constants off `ShellState`

`PortPlacement` and `PortPresentation` are the pure geometry layer and they reach up into shell state
for `parkWidth`, `minTileSize` and `Zoom`. The constants belong beside the geometry that uses them,
not on the object that happens to have declared them first. Blocks 2,528 lines, and it is the
cheapest of the three.

Note for whoever does it: `parkWidth` and `minTileSize` are already `nonisolated static let` on
`ShellState`, so this is a move plus a rename of the references, not a redesign. `Zoom` is an enum
that describes the zoom ladder, which is genuinely shell state; the fix there is for
`PortPresentation` to take what it needs as a parameter rather than to import the ladder.

### 3. Put `GatewayProcess` behind a protocol

Four files (`GatewayDoor`, `CLIInstallService`, `InstructionService`, `BridgeReference`) want a port
number and a lifecycle, and reach an AppKit-importing class to get them. A two-method protocol, with
the AppKit class as its only implementation today, cuts 870 lines loose and changes no behavior.

### Then wire the gate

`spikes/windows-kernel/carve.sh` already does the carving. Run it in CI and the boundary stops being
a claim: a kernel service that reaches into the shell fails a build, the same way a re-grid on spawn
now fails a test. Without the gate, these three moves will be undone by the next person who needs
something from `AppState` and has no reason to know there is a line.

## Do NOT do these now

**Splitting `AppState`.** It is 4,015 lines, it sits in the registry's dispatch path, and six kernel
files reach it. It is the right eventual move and it is a project, not a chore. Doing it inside
nautilus Phase 1 would put five passing scenarios at risk for a benefit nobody can cash yet.

**Moving the kernel to Go.** Only pays off once a second client is actually being built. Deciding it
now means deciding it with no user and no deadline.

**Anything for Windows specifically.** No part of this recommendation is a Windows change. If Windows
never happens, all three moves are still right.

## One correction worth carrying forward

An earlier draft of the research claimed nautilus was "the largest single reduction in the cost of a
Windows port". Re-measuring after Phase 0 finished and Phase 1 steps 1 to 4 landed showed that was
wrong: the tree shrank by about 3,965 lines and the portable kernel did not grow at all, 30 files
before and 30 after. Deleting Apple-coupled features shrinks the SHELL's porting surface. Only moving
types moves the KERNEL boundary. They are different problems that share a direction.

## How to verify the work

Not by reading the diff. Run the carve:

```
./spikes/windows-kernel/carve.sh --prune
```

It prints every file it had to drop. Each of the three moves above should remove specific names from
that list, and the survivor count should rise from 30. If a move does not change the list, it did not
do what it claimed.

The CI workflow (`.github/workflows/windows-kernel-spike.yml`) runs the same carve on Linux and
Windows, and cross-compiles the Go side. It is scoped to its own branch, so it gates nothing until
someone decides it should.
