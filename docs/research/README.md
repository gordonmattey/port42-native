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
| 4 | Share, and fork what you were shared | scoping | **Merged, GM 2026-09-26.** Was three items (share a port, publish as a website, share a port's code). See below. |
| 5 | Share a whole space | **moved up by GM** | Was 12. A space is a port, so this is the cascade question in `invite-over-libp2p.md`, not a separate mechanism. |
| 7 | Multi-display | | Interacts with per-desktop positions (v46) and `port-shape.md`. |
| 8 | A live media plane | GM: "would be cool" | Additive, and depends on Phase 4's transport existing. |
| 9 | The membrane interprets | | Five docs already in `docs/membrane/`. |
| 10 | Add Antigravity as a first-run path | GM, 2026-09-26: "add antigravity should be the thing, later" | Setup detects which CLI agent is installed and runs Echo on it (Claude Code and Codex today). The item is Antigravity specifically, not agents in general, and it stays late. |
| 11 | Expand the CLI | **replaces "MCP as a port capability"** | GM, 2026-09-26: "i really dont like it, i think we could expand the cli instead." MCP moves down and the framing changes: the CLI is the surface to grow, not a second protocol to adopt. |
| 12 | Computer use | GM: "kinda a bad smell" | Has `plan-computer-use.md`. Demote rather than delete. |
| 13 | Windows and Linux | **scoped** | `windows-port.md`, `kernel-boundary.md`, `libghostty-windows.md`. |

## Share and fork, one mechanism and one verb (GM, 2026-09-26)

Three roadmap items collapse into one mechanism plus one verb.

**Share is the only act, and audience is a parameter.** One person's Port42, several people, or anyone
on the web. "Publish a port as a website" is not a separate feature: it is share with audience
"anyone", and the guest page is the renderer for a recipient who has no Port42.

**Fork is the recipient's act.** Nobody shares code. You share a port; whoever holds it may fork it.
The fork is theirs: new port id, their space, their data, no grants inherited, the original
untouched.

**Both decisions settled, GM 2026-09-26.**

**Lineage: yes.** A fork records its origin. One field, set at fork, not backfillable, and it is what
makes "the author shipped a new version" possible later without committing to subscription semantics
now.

**The fork flag exists and is a capability boundary, not a switch on one method.** Measured:

- `gateway/guestpage.go:116` calls `port.getHtml`, and `:119` assigns `surface.srcdoc = SHIM + html`.
  A web guest renders a port by receiving its source, so for a browser audience "no fork" is
  unenforceable by construction. Changing that means the guest receives rendered output instead of
  code, which is the RPC versus replication fork in `invite-over-libp2p.md`, not a flag.
- Seven methods reveal source or permit extraction: `port.getHtml`, `getDom`, `exec`, `history`,
  `restore`, `console`, `info`. Gating `getHtml` alone achieves nothing, because a guest holding
  `port.exec` reads `document.documentElement.outerHTML`.

So the flag means **use, do not inspect**: no-fork excludes the source-revealing set from the grant
and leaves render, events and input. It is enforceable for a Port42-to-Port42 share and is a request
for a web one. The UI should say so rather than imply a lock that does not exist.

**Scope, GM 2026-09-26: Port42 to Port42 is the first cut.** Rendering to the web over RPC, where the
guest receives output rather than code, is a later problem. Worth keeping in view because it pays
three ways at once: the flag becomes enforceable on the web, the port's code and data never leave the
machine, and it works for ports whose live state cannot be replicated at all. It is the third mode in
`invite-over-libp2p.md` arriving through a different door, and it is also what would make a phone a
viewer rather than a peer.
