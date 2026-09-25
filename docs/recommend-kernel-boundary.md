# Recommendation: make the kernel boundary real, and move the kernel to Go

**For:** whoever picks up the seam work. **Status:** recommendation, not an approved decision.

Measured on `research-windows-port`, which branches from `nautilus` and carries
`spikes/windows-kernel/carve.sh` plus a CI workflow that runs it. Evidence in
`docs/research-windows-port.md`.

## The finding

Port42's architecture describes a kernel (ports, the registry, addresses, permissions, the bus) and a
shell (the desktop, the chrome, the window manager). The boundary is asserted, not enforced: kernel
and shell are one SwiftPM target, so a kernel service can reach into the shell, and several do.

Carving the candidate kernel into its own package and building it locates every breach. On Linux and
Windows the same 30 files, 3,869 lines, compile. Everything else was dropped for naming something on
the shell's side of the line, never for anything about the platform.

Blocked work, grouped by what it reaches for, counting code references only:

| Reaches for | Files | Lines blocked |
|---|---|---|
| `ShellState` | 3 | 2,528 |
| `PortPanel` | 2 | 2,305 |
| `AppUser` | 1 | 2,133 |
| `AppState` | 6 | 1,491 |
| `GatewayProcess` | 4 | 870 |
| `Port42AuthStore` | 2 | 436 |
| `TerminalPortConfig` | 1 | 386 |

## The direction: the kernel moves to Go

The gateway is already Go, already the door, and already cross-platform: `gateway` and `shim`
cross-compile to windows/amd64 untouched, and `cli` needs one ten-line change. The registry is the
API, the transport is a seam, and the shell is a client of both. A Go kernel makes that structure the
program rather than a description of it.

What it buys:

- **A second client becomes a UI, not a port.** Windows and Linux shells talk to the same kernel over
  the same door the guest page already uses.
- **Persistence stops being a platform question.** `modernc.org/sqlite` is pure Go, no cgo, and builds
  for Windows. The Swift path does not: GRDB claims Apple platforms only, calls Linux "provided by
  contributors, not automatically tested, not officially maintained", and does not mention Windows.
- **The `AppState` problem is dissolved rather than refactored.** Its 4,015 lines are a Swift object
  in the registry's dispatch path. Under a Go kernel the dispatch path is Go and the Swift side keeps
  only what a shell needs, so the untangling is not a 4,015-line Swift refactor anyone has to survive.
- **One terminal story.** ConPTY on Windows and a pty on Unix both live in the kernel, where the
  hooks and the output pipeline already are.

Sequencing: **after nautilus lands.** Nautilus is deleting and rewriting large parts of exactly this
code, and the five scenarios pass today. Starting the move mid-phase trades a passing product for an
unfinished one. The three moves below are the preparation, and they are worth doing on their own
terms.

## The three moves to make first

Each is mechanical, each is a defect on the project's own terms, and each holds whether or not the Go
move happens.

### 1. `PortPanel` into `Models/`

The port's data model is defined inside `Views/PortWindowManager.swift`, so `DatabaseService`
depends on a view file. Blocks 2,305 lines. The move is the type and its conformances;
`PortWindowManager` keeps everything that manages panels and stops owning what a panel is.

### 2. Geometry constants off `ShellState`

`PortPlacement` and `PortPresentation` are the pure geometry layer and reach up into shell state for
`parkWidth`, `minTileSize` and `Zoom`. Blocks 2,528 lines, and it is the cheapest of the three:
`parkWidth` and `minTileSize` are already `nonisolated static let`, so it is a move plus renamed
references. `Zoom` is genuinely shell state, so `PortPresentation` takes what it needs as a parameter
instead of importing the ladder.

### 3. `GatewayProcess` behind a protocol

`GatewayDoor`, `CLIInstallService`, `InstructionService` and `BridgeReference` want a port number and
a lifecycle and reach an AppKit-importing class to get them. A two-method protocol, with the AppKit
class as its only implementation, frees 870 lines and changes no behavior.

### Then wire the gate

`spikes/windows-kernel/carve.sh` does the carving. Run it in CI and the boundary is enforced: a
kernel service that reaches into the shell fails a build. Without it, the three moves are undone by
the next person who needs something from `AppState` and has no reason to know there is a line.

## Not part of this

A Swift-side `AppState` split as its own project. Under the Go direction the dispatch path leaves
Swift, so splitting a 4,015-line Swift object first is work the move discards.

## Verification

Not by reading the diff. Run the carve:

```
./spikes/windows-kernel/carve.sh --prune
```

It prints every file it had to drop. Each move removes specific names from that list and raises the
survivor count above 30. A move that does not change the list did not do what it claimed.

`.github/workflows/windows-kernel-spike.yml` runs the same carve on Linux and Windows and
cross-compiles the Go side. It is scoped to its own branch and gates nothing until someone decides it
should.
