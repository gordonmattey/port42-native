# Review: port42.ai/architecture.html against the nautilus model

Deferred (GM, 2026-09-24): the page is rewritten after the nautilus phases land. Recommendation 5 now reads against per-port invites (plan D10).

Date 2026-09-24. Page read live on this date. Each claim is checked against the code on
`slice-02-wire` and against `plan-shell-only.md`. Status labels: **Built** (in the code and
exercised), **Partial**, **Planned** (a nautilus phase), **Roadmap** (not in the plan), **Cut** (the
plan removes it), **Not built**.

This is a product and engineering review of what the page says. Whether any of it differentiates in
the market is a go-to-market question and is not assessed here; none of the claims below has been
validated with users.

## Claim by claim

| Section | Claim | Status | Under the new model |
|---|---|---|---|
| Hero | A human and an agent reach the same surface through one bridge, same methods, same permissions | **Built** | Unchanged. The registry and one dispatch path. |
| The AI has no surface | Computer use, headless APIs and bolted-in assistants all fragment the work | Positioning | Unchanged. |
| A port is an actor | Query it, write to it, it streams updates back, for terminal, HTML and browser | **Built** | Unchanged. |
| A port is an actor | Local, on another machine, or a peer | Local **Built**; remote **Planned** (Phase 4) | Same call over libp2p. |
| One bridge, every caller | UI, agent as tools, CLI, REST API | **Built** | "Agent as tools" now means a CLI agent calling the registry with its own token. There is no in-app agent. |
| One bridge, every caller | Another Port42 gateway over the wire | **Planned** (Phase 4) | A peer over libp2p, authenticated by peer id. |
| One bridge, every caller | No separate "AI mode" | **Built**, and truer after Phase 1 | The in-app engine goes, so there is no AI mode anywhere. |
| One bridge, every caller | Right-of-way decides who acts; take the pen from an agent mid-task and hand it back | **Partial** | What is built: a stale write is refused and told the current state, and the driver is shown. Taking and handing back the pen is not built; per-element right-of-way is roadmap. |
| Your space stays | The space is the one invariant layer where every port lives | Built, reframed | The invariant is the port. A space is a port that holds ports, and the desktop is port 0. |
| Your space stays | Agents plug in from below | **Built** | Any CLI agent in a terminal port. Claude Code and Codex are first-class. |
| Your space stays | Memory plugs in from below | **Cut** as built | Keeper, the in-app memory service, goes with the engine. An agent brings its own memory; a port keeps its state in storage. |
| Your space stays | Knowledge (vaults, docs, RAG) plugs in from below | **Not built** | Roadmap: MCP as a port capability is the likely shape. |
| Your space stays | Your domain tunes it from above, as packs | **Not built** | Roadmap. Nothing called a pack exists. |
| Your space stays | Port42 never learns a domain, an agent or a body of knowledge | **Built**, and stronger after D9 | Port42 also never calls a model provider or holds a model credential. |
| No trampling | Watcher watches every agent | **Partial** | Driver presence, the console, subscriptions, needs-attention peeks. No single "Watcher". |
| No trampling | Gatekeeper decides what reaches you | **Not built** | "The membrane interprets" is roadmap. |
| No trampling | Controller grants and limits access | **Built** | Grants on port objects, named clients, Settings → Access, revoke. |
| No trampling | Coordinator hands off, no clash | **Partial** | Stale writes are refused with the current token. Handoff is not built. |
| No trampling | Guard: undo and guardrails | **Partial** | Version history with `port.history` and `port.restore`; permission prompts. No general undo. |
| No trampling | "These come built into Port42" | Overstated | Two of five are built, three are partial or not built. |
| Reach any port | `port42://[type]/[id]/[path]` | **Partial** | Built grammar is `port42://space/<spaceId>/<portId>`. The plan's remote form is `port42://<peerID>/space/<id>/<portId>`. Under the new model a space is a port, so the grammar can reduce to peer plus port. Reconcile before the page states a grammar. |
| Reach any port | Addresses name agents, spaces and relations | **Partial** | Agents are terminal ports and spaces are ports, so both get port addresses. Relations are not built. |
| Reach any port | "Today, agent and space invites already travel this way" | **Cut** | Agent invites were LLM-companion recipes and went with LLM mode. Space invites ride the ngrok hub, which the plan removes. They are replaced by the peer invite and the guest link (Phase 4). |
| Reach any port | Same call, any distance; remote is never a special case | **Planned** (Phase 4) | The design goal of the transport seam. |
| Reach any port | A port "as of T" is a first-class address | **Not built** | Version history exists, but no address resolves a time. Roadmap. |
| Reach any port | Local-first and end-to-end encrypted | Local-first **Built**; E2E **Cut** as built | Today's E2E is app-level AES on hub messages, which goes. After Phase 4, traffic between peers is encrypted by the libp2p handshake and the browser guest by WebRTC or WebTransport. The claim holds again at the transport layer. |
| Reach any port | A port serializes completely and arrives running in another space | **Partial** | A web port's HTML travels. Its storage and its references to instance-local ids do not, and a terminal's running process cannot. |
| Reach any port | libp2p with Circuit-Relay and DCUtR, no server in the middle | **Planned** (Phase 4) | A relayed connection does pass through a relay, which forwards encrypted bytes it cannot read. "No server that can read your data" is the accurate form. |
| Tailor | AI, memory and knowledge behind stable, versioned interfaces | AI **Built** (as processes); memory and knowledge **Not built** | The AI interface is a process with a token, not a plug-in API. `ServiceManifest` is the plug-in shape for the rest and has no external tenant yet. |
| Tailor | Build ports, tune with packs, arrange the space your way | Ports **Built**; packs **Not built**; arrange **Built** with the layout branch | |

## What the page does not say that the new model does

- **Everything is a port, including where you talk.** The desktop, a space and a port can each carry
  a chat. There is no messaging system; collaboration is two subscribers on one port.
- **Composition.** One port feeds another with no glue, which is the Unix pipe claim and scenario 3.
  The page never mentions it, and it is the most concrete thing the product demonstrates.
- **Port42 holds no model.** It never calls a provider and never reads a model credential (D9). The
  agent a person already uses is the agent Port42 runs.
- **Sharing is a link.** A browser with nothing installed can see and drive a port (the guest).

## Recommendations for the rewrite

1. Lead with the port as the only primitive, and show the three scopes it applies to.
2. Add a composition section with the produce, transform, render example from the baseline.
3. Mark each claim built or planned on the page itself. The addressing section already does this
   ("protocol spec in progress"); the five capabilities and the swappable layers do not.
4. Replace the five named capabilities with what is built: grants and Access, stale-write refusal
   with the driver shown, version history and restore, needs-attention peeks. Name the rest as
   direction.
5. Remove "agent and space invites already travel this way" and the space-level E2E claim until
   Phase 4 ships the peer invite and transport encryption.
6. Settle the address grammar in the plan before the page shows one.
