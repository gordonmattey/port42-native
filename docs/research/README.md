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

**Two notes are not roadmap items.** `security-bridge-authorization.md` consolidates what two
spikes found independently about the bridge authorizing callers against capabilities but never
against objects. `defects-found.md` lists the concrete bugs found while scoping, none of which was
the thing being scoped.

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
| 1 | ~~The program as the credential~~ | **dropped**, [program-as-credential.md](program-as-credential.md) | Does not work on this door. The app never holds the caller's socket, and the program on the other end is `curl`. **Replaced by: move the local door to a unix socket.** The sequencing worry that ranked it first does not apply, so Phase 4 is unblocked. |
| 2 | The chrome is ports too | **scoped**, [chrome-as-ports.md](chrome-as-ports.md) | The largest structural bet. Decides what the shell is, and carries the layout and shell-on-other-platforms questions with it. |
| 3 | One guided permission flow | **scoped**, [permission-flow.md](permission-flow.md) | Every capability shipped adds another dialog to retrofit. Overlaps the invite and mesh consent models. |
| 4 | Share, and fork what you were shared | **scoped**, [share-a-ports-code.md](share-a-ports-code.md) | **Merged, GM 2026-09-26.** Was three items (share a port, publish as a website, share a port's code). See below. |
| 5 | Share a whole space | **moved up by GM** | Was 12. A space is a port, so this is the cascade question in `invite-over-libp2p.md`, not a separate mechanism. |
| 7 | Multi-display | | Interacts with per-desktop positions (v46) and `port-shape.md`. |
| 8 | RPC-rendered ports | **scoped**, [rpc-rendered-ports.md](rpc-rendered-ports.md) | Viable for a read-only markup-and-CSS port only. Markup is 7% of a real port; a canvas has no readable DOM. |
| 8 | A live media plane | GM: "would be cool" | Additive, and depends on Phase 4's transport existing. |
| 9 | The membrane interprets | | Five docs already in `docs/membrane/`. |
| 10 | Add Antigravity as a first-run path | GM, 2026-09-26: "add antigravity should be the thing, later" | Setup detects which CLI agent is installed and runs Echo on it (Claude Code and Codex today). The item is Antigravity specifically, not agents in general, and it stays late. |
| 11a | Headless CLI `ai.complete` | **scoped, recommendation is do not build it**, [headless-cli-ai.md](headless-cli-ai.md) | A port already has a model: `chat.post` wakes a companion and the reply returns as a chat event. A subprocess call costs 264 MB and 2.3 to 7.7 seconds, and default flags cost 45x the tokens of the same answer. |
| 11 | Expand the CLI, and MCP without the cruft | **both live**, [mcp-without-the-cruft.md](mcp-without-the-cruft.md) | GM first rejected MCP ("i really dont like it, i think we could expand the cli instead"), then, 2026-09-26: "MCP without the cruft is my vision." Not a contradiction: what was rejected was the 11,380-token manifest, not the protocol. D9 does not close MCP, it closes Port42 calling a provider. Two surfaces, not yet chosen between. |
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

## Found while scoping fork: the bridge has no object-level authorization

Not a fork gap. A property of the product as it stands, surfaced because fork is what would point it
at code the user did not author.

Every `port.*`, `ports.*`, `space.*`, `messages.*`, `bus.*` and `storage.*` method declares
`permission: nil`, and `BridgeDispatcher` hardcodes `on: .machine` at both the read and the write
site (`BridgeDispatcher.swift:112`, `:117`). With no grant at all, a port can:

- enumerate every port in every space (`BridgeMethods.swift:1424`, `:1465`; `resolvePortRef` applies
  no caller scoping, `AppState.swift:1945-1957`),
- read any other port's source,
- run arbitrary JS inside another port with `port.exec`, where it executes under the victim's
  principal, so a port with no grants borrows the grants of one that has them,
- overwrite or close another port,
- read any space's chat (`messages.recent` takes `space_id`, `:1117-1119`).

The `PortObject` slot for object-scoped grants is built and empty. Closing this is a re-consent
rather than a migration, because absence of a restriction is currently permission.

**Independently corroborated by the permission-flow spike**, which found the same hole at two more
doors: `port.push` types raw keystrokes into a live terminal with `permission: nil`
(`BridgeMethods.swift:180`), `port.subscribe` streams that terminal's output ungated (`:46-47`), and
`ports.list` enumerates every port in every space (`:1342`). An enrolled client holding zero grants
can therefore find every terminal, read everything it prints, and type into it. That is the same
defect `port.create`'s own gate was added to close, at two other doors.

Measured consent state, 2026-09-26: Dev3 holds 2 grants across 25 enrolled grantees, production holds
4 across 25, and three of those four belong to `local-http`, an identity deleted from the code. The
prompt count is low because **41 of 69 registry methods are ungated**, not because consent is well
designed.

Two more, both derived from code paths rather than executed: revoking a `child` client is undone by
the next launch, because `upsertClient` clears `revokedAt` and a spawned terminal re-registers
unconditionally on restore; and a gated call while the shell is locked enqueues a card with no render
site, so the gateway answers `timed_out` after 30 seconds.

Unverified: the cross-port `port.exec` escalation from a web guest. It should work on the code path
(`guestpage.go:95-99` forwards any method name) but was not executed. Testing it needs a dev instance
and a minted client.

## Token efficiency (2026-09-26)

[token-efficiency.md](token-efficiency.md). Measured with Claude's own `count_tokens` against
`claude-opus-5`, not an approximation.

**86% of what a companion spends before doing any work is the ports manual.** Across ten turns a
Claude companion pays 189,304 input tokens, of which 162,954 is `help topic:"ports"`, which Port42's
own instruction block calls REQUIRED READING. Inside the manual's 18,106 tokens, 13,995 is the
registry describing itself for the third and fourth time. The lever is the `PublishedDocs` rule that
already exists in the tree, applied to the manual.

**Tools cost nothing here, so tool selectors save nothing.** 54 generated schemas would cost 11,380
and have no consumer, because the CLI was chosen over MCP and the in-app model was deleted. Recorded
so the lever is not reopened.
