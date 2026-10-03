# Plan: two instances, an agent on each side, working on one shared port

Status: test run 2026-10-02 (all eight steps), fix scoped, decisions made (below), not built. Gordon: "the most valuable thing to get
working is port sharing between two instances where my agent is talking with the other agent on a shared
port." Branch to come: `lead/two-agents`.

## The test (run, and kept as the acceptance test)

Dev6 hosts, with companion `alba` in space `studio`; Dev11 is the guest, with `bram` in `visit`. The port is
"Shared board", a small card board whose cards live in the port's storage.

| # | Step | Result 2026-10-02 |
|---|---|---|
| 1 | The host's agent shares the port with see, use, edit, wake_agents | Passed: `alba` made the invite and explained it |
| 2 | The guest accepts | Passed (through the API; the accept box was not exercised) |
| 3 | The guest's person brings their agent onto the tile | **Broke:** the person posted in `bram`'s own chat; no way to bring an agent to a tile |
| 4 | The two agents talk in the port's chat | **Broke, then passed:** `bram` answered `@alba` in its own chat (never crossed); once told, a real exchange |
| 5 | The guest's agent changes the code | Passed: the change landed live on both sides |
| 6 | Both edit at once | Passed, but every guest write was refused once first (finding 1) |
| 7 | The host takes `edit` away | Passed: `bram` refused `not_granted` and said so |
| 8 | The host stops sharing | Passed, with the wrong error on the guest (finding 5) |

`bram` filed a draft bug report through Claude Code during step 6; it is finding 1, word for word.

## Findings

1. **A tile's reads return the guest's token, its writes are checked against the host's.** `ports.list` and
   `port.getDom` on a tile give `522656b0:N` (the guest's counter for the tile); `port.patch` is forwarded and
   checked against `87cfc2cc:N` (the host's). Every first write from the guest is refused `stale_write`.
2. **A version records the port's creator, not who changed it.** `savePortVersion(createdBy: panel.createdBy)`
   (`PortWindowManager.swift:463, 1003`). On the host every version says the client that made the port; on the
   guest's tile, "you". With two agents editing, nobody can tell who did what.
3. **The guest's tile keeps its own history**, saved each time the mirrored page changes, and it lags the
   host's (5 against 6 during the run). The tile's history picker reads it.
4. **A woken agent answers where it was asked, not in the shared port's chat**, and does not know it is on a
   tile, who is on the other side, how to address them (`@alba` on the host, `@alba (label)` on the guest),
   or what its rights are. No skill covers a shared tile.
5. **After the host stops sharing, the guest gets `host_offline: that instance is not connected to its
   relay`.** True (a host with nothing shared leaves the relays, GW-16) but misleading: the guest should be
   told the port is no longer shared with it.
6. **Only the person, the port itself or the invite's maker manages a port's sharing.** The port's creator
   cannot (`mayManage(sharingOf:)`), so the client that made the board could not revoke a share its agent made.
7. **The token moves on activity that is not a code change** (storage writes from the page, chat), so an
   agent's patch races ordinary use of the port. To confirm and decide: CAS on code writes only against the
   code, or keep it as is and make the retry cheap (finding 1 makes it one retry, not a guess).
8. **No way to bring your agent onto a tile, and nothing marks the shared chat** (the person posted in the wrong
   one). The accept box offers remote wake only.
9. **Permissions** (decisions, see the order): a mention adds an agent to the whole space, and any of the
   guest's agents can act on a tile. Further hardening of the path between instances is tracked privately.

## Decisions (Gordon, 2026-10-02)

1. **A mention gives that agent the one port**, as a port-level grant; it does not join the space.
2. **On the guest, only agents the person brought onto a tile act on it**; others are refused and told how to be
   added.
3. **A card the first time another instance's agent wakes one of yours**, once per (that agent, your agent, that
   port), remembered. On both sides: the share's `wake_agents` (host) and remote wake (guest) say the other
   side may ask; the card is the yes for that pair. To confirm with Gordon: keep the card, or fold it into the
   share card's wording.
4. **A code edit conflicts only with another code edit**: a code token for code writes; storage, chat and other
   activity no longer move it.
5. **Remote wake on by default**, and an agent making an invite includes `wake_agents` unless told otherwise.
6. **Bring a companion** on the accept box (one or more), and add or remove later from the tile's menu.
7. **One history, the host's**, shown on both sides with the author named (`bram (gordon11)`); the guest keeps
   no copy of a mirrored page's versions.

## The fix, in order

**Phase 1. Hardening (do first).** The path between instances, tracked in a private appendix until fixed; a
mention from another instance never adds an agent to a space. Each with a calibrated test.

**Phase 2. Correctness.**
- **The host's token on a tile (1).** The tile keeps the host's last token: every forwarded response carries
  it, the mirror's event stream updates it, and `ports.list`, `port.getDom` and the other window reads on a tile
  return it. A write composed from a read lands first time.
- **Who made each version (2).** `savePortVersion` takes the writer: the principal for a local write, the
  forwarded actor (`bram (gordon11)`) for a remote one. `port.history` and the history picker show it. A new
  migration if the column needs widening; none for the value.
- **One history (3).** A tile's history picker and `port.history` on a tile read the host's (forwarded); the
  guest stops saving its own versions of a mirrored page.
- **The token and activity (7).** Measure what moves it during the test; then decide (Gordon) between a code
  token for code writes and leaving it.
- **The right error (5).** A guest whose host left the relays after a stop gets "no longer shared with you"
  when its last call or the host's departure says so, and `host_offline` only when the host was sharing.
- **The creator manages sharing (6).** `mayManage(sharingOf:)` includes the port's creator.

**Phase 3. Permissions (Gordon's decisions, recommendation in each).**
- **A mention gives that agent this port, not the space.** A port-scoped grant, the shape of #238; on the host
  and on the guest. Recommend yes.
- **On the guest, only agents the person brought onto a tile can act on it.** The tile has members; a companion
  not among them is refused on the tile, with a message saying how to be added. Recommend yes.
- **A card the first time another instance's agent wakes one of yours** ("bram on gordon11 wants alba on Shared
  board"), once per guest per port. Recommend yes.

**Phase 4. UX.**
- **Bring a companion.** The accept box picks one or more of your companions; they join the tile (Phase 3's
  members) and are told what it is. The same from the tile's menu later.
- **The shared chat is obvious.** The tile's chat says it is shared, with whom, and who is in it from each side
  (the presence strip, `dev-guest-presence`).
- **Agents know where they are.** The wake line on a tile names the host and the other side's agents; the
  `port42-team` skill gets a "Shared ports" section: reply in the port's chat, address the other side by the
  name shown there, your rights, and what `not_granted` means.

**Phase 5. The acceptance test, automated.** `scripts/test-two-instances.sh`: two dev instances, the board, both
companions, the invite and the accept (through the accept box path once it exists), then each step above as
a chat post with a check on both sides. Run after each phase; all eight steps and the new ones (bring a
companion, a mention stays on the port, an outsider agent on the guest is refused) pass before release.

**Phase 6. Addressing and machine names** (Gordon, 2026-10-02: yes to all four, the readable form). Found in the
realistic run: the same agent had a different name on each machine (plain on its own, `name (label)` on the
other), so `bram` addressed `alba` with his own machine's label and woke nobody; the label was a person's
display name reused as a machine's, alongside `knownAs` and the peer label; a mention that matched nobody did
nothing.
- **6.1 One name per machine.** `machineName`: the one set in Settings, else this Mac's name (with the dev
  profile on a dev instance, "Gordon's MacBook Pro dev6"). It is what this machine joins as (the host's label
  for it), what an invite says the host is, and the label beside its people and agents in a shared chat.
  Wording reads "on Gordon's MacBook Pro", not "on Gordon's machine". A name the host already uses gains four
  characters of the peer id, as before.
- **6.2 One name in a shared chat, the same on both machines.** While a port is shared, the host serves every
  author with its machine: its own people and agents as `alba (Gordon's MacBook Pro)` in `chat.read`, chat
  events, `chat.post`'s answer, presence that leaves the Mac, and its own transcript. Another machine's were
  already labelled. Storage is unchanged; the label is applied on the way out.
- **6.3 Mentions by the plain name.** In a shared chat `@alba` reaches the one alba; `@alba` with any label
  after it reaches her too unless the label is another machine's in this chat. The host matches its own
  companions; the guest wakes the companions it brought onto the tile (members). `whoami`'s `elsewhere` gives
  the plain mention; the intro and `port42-team` say to address by the name before the brackets.
- **6.4 A wrong mention is said.** An agent's post in a shared chat naming someone who is not there gets a
  Port42 line in that chat: "nobody here is called X; in this chat: ...". The composer's hint knows the chat's
  authors, so a person sees the same before sending.

**Phase 7. From the first hand-run** (Gordon typing both people, 2026-10-03).
- **Freezes:** calls to the host took 18 to 30 s during setup and about 190 times overnight, with the gateway and,
  in most samples, the app's main thread idle. Every call slower than 2 s now logs where it spent the time, on
  both sides under one call id: handed to the app, waiting for the main thread, or in its method.
- **A machine is "<name>'s Port42"** until its person names it in Settings (the only place it is edited). A
  tile tells its host this machine's name when it connects, and the host's label follows it; what was said
  before keeps the old name. People read as "Gordon (Gordon's Port42)", never "(remote)".
- **The joined line** says in words what they can do. **The wrong-mention line** fires only for a near miss of
  an agent's name, and names the one meant; a person in the story ("@sam") is left alone.
- **The guest's @ picker** offers the host's agents on the port from the moment it joins: `chat.read` names
  them on a shared port.

## Not in this

Ports across spaces on one machine (#238, #249); sharing a whole space; the relay rate cap (#122).
