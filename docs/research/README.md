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
| [port-shape.md](port-shape.md) | Why does every port get the same tile? | Ports should declare a shape intent (`columns`, `aspect`, `reading`, `dense`, `free`) the way they declare capabilities. An OS window manager arranges rectangles because rectangles are all it has; Port42 can arrange meaning. |
| [invite-over-libp2p.md](invite-over-libp2p.md) | How does the invite change under libp2p? | It stops being a credential and becomes an enrolment coupon that binds a peer id. One payload type, since a space is a port. Replication is the open work, and it is three problems, not one. |

**The running gag across all six:** every question that looked like a platform question turned out to
be the same structural one. The kernel and the shell share an object graph, and Windows, Linux and
iOS are each just a different way of noticing.

## The spike that produced the numbers

`spikes/windows-kernel/carve.sh` generates a kernel-only package from the tree's own sources, builds
it, and prints every file it had to drop. The dropped list is the seam list.
`.github/workflows/windows-kernel-spike.yml` runs it on Linux and Windows and cross-compiles the Go
side. Both are on this branch.

## Research order (GM, 2026-09-26)

The thirteen Future roadmap items in `plan-shell-only.md`, ordered for scoping. Ranked by how
expensive the decision is to get wrong late, not by how much anyone wants the feature.

| # | Item | Status | Note |
|---|---|---|---|
| 1 | The program as the credential | scoping | Phase 4 is about to key grants on a peer id. If identity changes afterwards, authorization is redone. |
| 2 | The chrome is ports too | scoping | The largest structural bet. Decides what the shell is, and carries the layout and shell-on-other-platforms questions with it. |
| 3 | One guided permission flow | scoping | Every capability shipped adds another dialog to retrofit. Overlaps the invite and mesh consent models. |
| 4 | Share a port's code | scoping | Distribution. Installing a port means running someone's JS against your grants, which is the part most likely to be underestimated. |
| 5 | Publish a port as a website | **moved up by GM** | Was 11. |
| 6 | Share a whole space | **moved up by GM** | Was 12. The cascade question in `invite-over-libp2p.md` is the open part. |
| 7 | Multi-display | | Interacts with per-desktop positions (v46) and `port-shape.md`. |
| 8 | A live media plane | GM: "would be cool" | Additive, and depends on Phase 4's transport existing. |
| 9 | The membrane interprets | | Five docs already in `docs/membrane/`. |
| 10 | More agents as first-run paths | GM queried the item | Setup detects which CLI agent is installed and runs Echo on it. Today Claude Code and Codex; the item is adding Gemini and Antigravity to that detection. Not about agents in general. |
| 11 | Expand the CLI | **replaces "MCP as a port capability"** | GM, 2026-09-26: "i really dont like it, i think we could expand the cli instead." MCP moves down and the framing changes: the CLI is the surface to grow, not a second protocol to adopt. |
| 12 | Computer use | GM: "kinda a bad smell" | Has `plan-computer-use.md`. Demote rather than delete. |
| 13 | Windows and Linux | **scoped** | `windows-port.md`, `kernel-boundary.md`, `libghostty-windows.md`. |
