# Research notes, September 2026

Written while nautilus Phase 0 and Phase 1 were landing. Each is measured against the tree at the
commit it names. None is an approved decision.

| Note | Question | Where it landed |
|---|---|---|
| [kernel-boundary.md](kernel-boundary.md) | Should the kernel move out of Swift? | **Recommends moving the kernel to Go, after nautilus**, with three mechanical seam moves first (`PortPanel` into Models, geometry constants off `ShellState`, `GatewayProcess` behind a protocol). The one to hand to whoever does the work. |
| [windows-port.md](windows-port.md) | What would a Windows version take? | 30 files and 3,869 lines of kernel already compile on Windows and Linux; the rest is blocked by the seam list, not the platform. The Go side ports with one ten-line change. GRDB does not build on Windows. |
| [libghostty-windows.md](libghostty-windows.md) | Can libghostty back a Windows terminal? | **No.** The cross-platform libghostty is a different library, there is no Windows renderer, and `PlatformTag` is macOS and iOS only. Use ConPTY plus a JS terminal. Also found that Port42 runs on a Ghostty fork, not upstream. |
| [iphone.md](iphone.md) | Can Port42 run on an iPhone? | It can render and drive ports; it cannot host agents, because iOS has no processes and an agent is a process. Web ports and GRDB port cleanly; `gomobile bind` makes the Go door linkable. App Store 4.2.7 is the constraint, not 2.5.2. |
| [host-mesh.md](host-mesh.md) | What is "my virtual network of hosts"? | A primitive the model lacks: membership ("this host is me") rather than a per-port grant. Also audits the invite mechanism, whose door survived Phase 1 and whose payload did not. |
| [invite-over-libp2p.md](invite-over-libp2p.md) | How does the invite change under libp2p? | It stops being a credential and becomes an enrolment coupon that binds a peer id. One payload type, since a space is a port. Replication is the open work, and it is three problems, not one. |

**The running gag across all six:** every question that looked like a platform question turned out to
be the same structural one. The kernel and the shell share an object graph, and Windows, Linux and
iOS are each just a different way of noticing.

## The spike that produced the numbers

`spikes/windows-kernel/carve.sh` generates a kernel-only package from the tree's own sources, builds
it, and prints every file it had to drop. The dropped list is the seam list.
`.github/workflows/windows-kernel-spike.yml` runs it on Linux and Windows and cross-compiles the Go
side. Both are on this branch.
