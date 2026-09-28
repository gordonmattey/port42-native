# Share once, fork from what you were shared

Against `nautilus` at `0369388`, 2026-09-26. A design note, not an approved plan. Companion to
`docs/research/invite-over-libp2p.md`, which covers granting ACCESS to a port. This covers what the
recipient does with what they were given.

## The frame (GM, 2026-09-26)

**Share is one act, and audience is a parameter.** One person's Port42, several, or anyone on the
web. "Publish a port as a website" is not a second feature; it is share with audience "anyone", and
the guest page is the renderer for a recipient with no Port42. There is no separate act of sharing
code.

**Fork is the recipient's act.** Having been shared a port, you may fork it. The fork is yours: new
port id, your space, your data, no grants inherited, the original untouched.

**Scope for the first cut (GM):** Port42 to Port42. The web audience is a known second phase.

That frame collapses most of the question. What remains is fork, and fork is four decisions:
what travels, whose identity the copy has, whether the share conveyed the right to copy at all, and
whether the copy remembers where it came from.

## 1 · What travels, and what is this instance's

`invite-taxonomy.md` already named the axis this rests on: **access** reaches something of mine,
**recipe** builds something of yours. A fork is a recipe. Nothing of the author's machine is
exposed, there is nothing to revoke, and the author can go offline forever with no effect.

The port row carries 25 fields (`PersistedPortPanel`, `DatabaseService.swift:1802-1837`). They split cleanly.

| Field | Source | Travels? |
|---|---|---|
| `html` | `port_panels.html` | **Yes.** The artifact. |
| `userTitle` | v20 | **Yes**, as a default the forker may override. The fallback title is parsed out of the HTML anyway (`PortWindowManager.swift:87-95`). |
| `portType` | v34 | **Yes.** `web` / `terminal` / `browser` / `chat`. |
| `capabilities` | v20 | **Yes**, but see §4. It is a label, not a contract. |
| `id`, `udid` | UUID at birth (`PortWindowManager.swift:399`) | **No.** A fork mints its own. Collision is impossible by construction. |
| `spaceId` | creation | **No.** The fork's home is the forker's space. |
| `createdBy` | `p.id` of the creating principal (`BridgeMethods.swift:157`) | **No.** It is a local principal id, meaningless on another machine, and it is also the authorization identity (§5). |
| `messageId`, `anchorMessageId` | chat anchoring | **No.** Names a message in the author's transcript. |
| `positions`, `posX`/`posY`, `z`, `width`/`height` | v13, v36, v46 | **No.** Per-desktop geometry on a screen the forker does not have. The fork is placed by the forker's own `place()`. |
| `presentation`, `isBackground`, `isAlwaysOnTop`, `dockOrder`, `adoptedSpaceIds` | v12, v34, v36, v38 | **No.** All describe where the author keeps it. |
| `isChatPort` | v34 | **No.** One chat port per space, minted by `ensureChatPort` (`AppState.swift:1263-1265`). Not forkable. |
| `grantedPermissions` | v14 | **No, and this is load-bearing.** See §5. |

Two things the brief listed as candidates are not port state at all.

**Storage contents cannot travel, because a port has none.** `port_storage` is keyed
`(portKey, channelId, creatorId)` in the schema (`DatabaseService.swift:191-200`), but the service
resolves those from the CALLER, not from a port: scope is the principal's space or `__global__`, and
creator is the principal's id or `__shared__` (`BridgeServiceStorage.swift:58-70`). So the namespace
belongs to whoever wrote, not to the port that wrote. Two ports made by the same companion in the
same space share one namespace, which `PortBridge.swift:142-145` records as a known consequence.
**There is no query that enumerates one port's keys**, so "ship the port's data" is not merely
unimplemented, it is currently inexpressible.

**The chat transcript is per space, not per port.** There are no `chat.*` methods in the registry;
chat is still `messages.recent` / `messages.send` over the `messages` table, scoped by space id
(`BridgeMethods.swift:1268-1286`). D1's transcript-as-a-file is not built. A port has no transcript
to carry.

**Expected permissions do not exist as data.** There is no declared-permission field anywhere. The
capability list is self-asserted at runtime and nothing reads it as a gate (§4).

## 2 · What `port_versions` actually stores

Every version's HTML is kept forever. The table is seven columns
(`DatabaseService.swift:303-311` plus `metaVersion` at `:424-426`):

```
id · portUdid · version · html · createdBy · createdAt · metaVersion
```

`metaVersion` is the author's own `<meta name="version">`, scraped out of the HTML and backfilled by
v28 (`DatabaseService.swift:431-443`). `port.history` returns `version`, `createdBy`, `createdAt` and
nothing else (`BridgeMethods.swift:1501-1521`); `port.getHtml` returns one version's HTML
(`:1478-1499`); `port.restore` writes a snapshot back as a new version (`:1570-1590`).

**What is not stored:** the title, the capability list, the type, the size, the position, any
signature, any content hash, and any origin. Every one of those lives on `port_panels`, which keeps
only the current row. So the history is a history of the HTML alone.

**Could a port be rebuilt on another machine from the database as it stands?** For a `web` port,
yes, and only just: `port.getHtml` plus `port.history` is enough to reconstruct the HTML and its
lineage of edits, and `ports.list` supplies the title and capability list for the current version
(`:1438-1462`). **For a `terminal` port, no.** The `html` column holds a JSON `TerminalPortConfig`
rather than HTML (`PortWindowManager.swift:79-84`), which carries a command, args, a cwd and an env
that describe the author's machine. Forking one would hand someone a command line to run, which is
a materially different act from handing them a document, and it is the same escalation
`port.create` already gates (`BridgeMethods.swift:137-147`). **For a `browser` port, trivially**,
it is a URL.

Two integrity notes. The version series is deduplicated only against the immediately preceding row
(`DatabaseService.dedupePortVersionsSQL`, `:1176-1185`), so a series can still contain A-B-A. And
`version` is `MAX(version)+1` per port (`:1656`), which is a local counter and not comparable across
machines.

## 3 · Does sharing convey the right to fork?

**Different rights, and the flag is a capability boundary rather than a switch on one method.**

For a Port42-to-Port42 share the flag is enforceable, because a grant already names a set of
permissions and the recipient's grant can simply exclude the source-revealing set. Verified against
the registry:

| Method | Reveals source? | Line |
|---|---|---|
| `port.getHtml` | **Yes.** The stored HTML, any version. | `BridgeMethods.swift:1478` |
| `port.getDom` | **Yes.** `document.documentElement.outerHTML` of the live surface. | `:316`, `:353` |
| `port.exec` | **Yes.** Arbitrary JS whose return value comes back to the caller, so `outerHTML` is one call. | `:284`, `:308-309` |
| `port.history` | Indirectly. No HTML, but it enumerates the version numbers `getHtml` needs. | `:1501` |
| `port.console` | Incidentally. Whatever the port logged, not the source by construction. | `:1677` |
| `port.info` | **No. GM's list is wrong here.** It returns the CALLER's own principal id, display name, space and activity token, takes no `id` argument, and says nothing about any other port. | `:1659-1668` |
| `port.restore` | **No.** It is a write, not a read. It belongs out of a no-fork grant for a different reason: it mutates the author's port and rewrites their version series. | `:1570` |

So the no-inspect set is five reads (`getHtml`, `getDom`, `exec`, `history`, `console`), and
excluding `getHtml` alone achieves nothing. The flag means **use, do not inspect**: render, events
and input stay; source reads and arbitrary JS go.

**Where it lives.** Grants key on `(grantee, object, zone, permission)`
(`DatabaseService.swift:673-687`), and `PortObject` is already peer-qualified with a port slot
(`PortObject.swift:36-73`). The slot is built and empty: *"No production path can name an object
other than port 0 today, because every `PortPermission` case is a machine capability"*
(`PortObject.swift:24-29`), and the dispatcher hardcodes `on: .machine` at both read and write
(`BridgeDispatcher.swift:112`, `:117`). So the flag needs a `PortPermission` case that is about a
port rather than the machine, and the dispatcher's object argument to become a parameter.

**Cost now versus retrofit.** Adding it now is one enum case and turning two hardcoded arguments
into one parameter. Retrofitting it means every share issued before the flag existed was issued
under "inspect allowed", since absence of a restriction is permission. That is not a migration, it
is a re-consent: the author has to be asked again about every live share. The slot was built early
for exactly this reason, and the argument holds a second time.

**The web audience is where it stops being enforceable.** `gateway/guestpage.go:116` calls
`port.getHtml` and `:119` assigns `surface.srcdoc = SHIM + html`. A browser guest renders the port
by receiving its source; view-source in their tab shows it. **The UI must not imply a lock that does
not exist.** For a Port42 recipient say "cannot copy"; for a web recipient say nothing stronger than
"please don't", or say nothing. The only way to change that is §7.

## 4 · Capabilities are a label, not a contract

`port.setCapabilities` writes a string array onto the panel and the bridge
(`BridgeMethods.swift:1716-1725`), it is persisted as JSON (`DatabaseService.swift:1862-1866`) and
restored (`PortWindowManager.swift:250-257`). Every read of it is display or filtering:
`ports.list`'s `capabilities` filter (`BridgeMethods.swift:1441`, `:1465`) and `allPorts()`'s merge
of the implicit `terminal` tag (`PortWindowManager.swift:964`). **Nothing gates on it.**

So a forked port's capability list tells the forker what the author claimed, and constrains nothing.
It is useful on an install card as a declaration of intent, and it must not be described as what the
port can do.

## 5 · A fork with zero grants: refuted as a free property, confirmed as the right target

Zero grants is the right answer. It is not what happens today, and there are **two independent
inheritance paths**, both of which have to be cut.

**Path one, the creator's bucket.** A port authorizes as its creator when the creator is a real
author (`Principal.forPortBridge`, `Principal.swift:136-151`), and `PortBridge.init` unions in
everything that creator holds on port 0 in this zone at construction time
(`PortBridge.swift:70-75`). The result is passed to the dispatcher as `pregrant`
(`PortBridge.swift:414`), which skips the prompt. **So a fork created by a companion arrives holding
every capability that companion already has in that space.** If your companion holds `.terminal`
there, the stranger's code runs with terminal access and no card is shown. A fork created by the
human keys on `messageId` instead (rung 2) and does start empty.

**This is the single most important measurement in the note.** "Fork" cannot be implemented as a
plain `port.create`, because `port.create` sets `createdBy: p.id` (`BridgeMethods.swift:157`) and an
agent doing the fork on the user's behalf is the natural path.

**Path two, the row.** `grantedPermissions` is persisted on the port row from the bridge's live set
(`DatabaseService.swift:1859-1860`) and restored into the bridge at launch
(`PortWindowManager.swift:233-235`). A fork implemented by copying the row inherits the author's
grants directly.

Cutting both is small and must be explicit: fork mints a principal for the new port rather than
inheriting one, and drops `grantedPermissions`. Both are assertions worth a test, because both
current behaviors are deliberate features being suppressed for one path only.

## 6 · The trust problem, concretely

**A port's `window.port42` is not a subset of the bridge. It is all of it.** The JS surface is a
generic `Proxy` over the registry: any `port42.a.b(...)` posts `call('a.b', args)`
(`PortBridge.swift:614-617`). The registry has flags for `wired` and `toolExposed`
(`BridgeRegistry.swift:27`, `:32`) and **no flag for port-JS exposure**. Whatever is in the
registry, a port can call.

What a hostile forked port can attempt today, once a grant exists:

- **`terminal.exec`**, an arbitrary command (`BridgeMethods.swift:418`, `.terminal`).
- **`fs.read` / `fs.write` / `fs.list` / `fs.mkdir`**, the filesystem (`:1016`, `:1040`, `:1068`,
  `:1086`, `.filesystem`).
- **`automation.runAppleScript` / `runJXA`**, which drive any app on the machine (`:504`, `:518`,
  `.automation`).
- **`rest.call`**, arbitrary outbound HTTP, which is the exfiltration path for everything above
  (`:828`, `.rest`).
- **`clipboard.read`**, whatever is on the clipboard (`:920`, `.clipboard`).
- **`screen.capture` / `camera.capture` / `audio.capture`**, the devices (`:458`, `:478`, `:683`).

And what it can do **with no grant at all**, because every `port.*`, `ports.*`, `space.*`,
`messages.*`, `bus.*` and `storage.*` method declares `permission: nil`:

- **Enumerate every port in every space.** `ports.list` iterates `allPorts()`, which is all panels
  regardless of space, and filters by space only if the caller asked
  (`BridgeMethods.swift:1424`, `:1465`; `PortWindowManager.swift:960-969`).
- **Read any other port's source.** `port.getHtml` resolves through `resolvePortRef`, which searches
  every panel and falls back to a DB lookup by udid with no caller scoping
  (`AppState.swift:1945-1957`).
- **Run arbitrary JS inside any other port.** `port.exec` (`:284`). The victim port's own bridge
  calls then run under the victim's principal, so a port with no grants borrows the grants of a port
  that has them. **This is a privilege-escalation path that exists today, independently of sharing.**
- **Overwrite or delete another port.** `port.update`, `port.patch`, `port.restore`, `port.manage`
  with `close` (`:1523`, `:1542`, `:1570`, `:364`).
- **Read any space's chat.** `messages.recent` takes `space_id` through `targetSpace`
  (`:1268-1286`, `:1117-1119`), and `space.list` returns every space (`:1177-1181`).
- **Read and write shared storage.** `scope: "global"` plus `shared: true` resolves to
  `(__global__, __shared__)`, a namespace every port on the machine can read and write
  (`BridgeServiceStorage.swift:61-70`).
- **Post as the user.** `messages.send` (`:1329`), `bus.publish` (`:1310`).

**The conclusion is structural, not a list of holes.** There is no object-level authorization
anywhere. A grant says a caller may use the MACHINE's terminal, and nothing says which ports a
caller may touch, because the dispatcher's object is a constant. Today that is tolerable because
every port on the machine is one the user or their own companion made. **Forking is what makes it
intolerable**, because it is the first path by which code the user did not author, and did not have
an agent generate under their eye, gets a bridge.

**What would have to be true before forking a stranger's port is safe:**

1. **Grants name an object.** `PortObject` becomes the dispatcher's parameter, so "this port may use
   the terminal" is expressible and "any port may use the terminal" is not.
2. **A port may not act on another port.** `port.exec`, `port.update` and friends refuse a target the
   caller does not own, or ask. Without this, per-object grants are decorative.
3. **A fork starts at zero and stays there until asked** (§5, both paths).
4. **The permission card names the port and its provenance**, not a capability in the abstract.
   `plan-web-port-sharing.md` already argues this for guests: *"Ada's Pricing Calculator wants
   filesystem access"*.
5. **Only then does signing matter.** A signature says who wrote the code; it says nothing about
   what the code does. Signing a port that can call `automation.runJXA` with no object scoping buys
   attribution after the fact and no containment. Order matters: 1-3 without signing is a real
   improvement; signing without 1-3 is theater.

## 7 · Lineage: yes, one field, not backfillable

**Decided (GM):** a fork records its origin, set at fork time.

**One field, holding a structure.** A new nullable `origin` column on `port_panels`, a JSON object:

```
{ "peer": "<source peer id>", "port": "<source udid>", "version": <source version>, "at": "<iso8601>" }
```

Four values because three of them are individually insufficient. A peer id alone cannot name which
port. A port id alone is a UUID from another machine with nothing to resolve it against. A version
alone is a local counter (`DatabaseService.swift:1656`), so it means nothing without the pair that
scopes it. It is a JSON blob rather than four columns for the same reason `positions` is
(v46): one nullable column that is absent for every port that was not forked, rather than four that
are null on almost every row.

**Not backfillable, which is the argument for deciding it now.** The origin of a copy is known only
at the moment of copying. Nothing in the fork's own state records where its HTML came from: there is
no content hash on `port_versions`, and identical HTML on two machines is indistinguishable from
coincidence. Once a fork exists without an origin, the fact is gone.

**What it buys, without committing to anything.** A recorded origin makes "the author shipped a new
version" answerable later: compare the fork's `origin.version` against the source's current one and
offer a diff. That is the whole of the subscription question deferred rather than decided. Note what
it does not buy: a merge. The fork's HTML has diverged, `port.patch` is a literal string replace
(`BridgeMethods.swift:1542-1568`), and there is no three-way merge anywhere in the tree. "The author
shipped v4" can honestly offer "read it" and "replace yours with it", and must not promise more.

One consequence to accept deliberately: `origin.peer` is a record of who you took code from, and it
persists. That is desirable for provenance and it is a disclosure. It should be visible to the
forker in the port's own chrome, not only in the database.

## 8 · What survives of `plan-web-port-sharing.md`

| Item | Status against `0369388` |
|---|---|
| G1, a `state` event kind on every replacing write | **Landed.** `PortEventKind.swift:58`, and `replacesState` is declared per method (`BridgeRegistry.swift:57`). |
| G2, iframe plus a forwarding shim | **Built.** `gateway/guestpage.go:84-112`, sandboxed `allow-scripts`, token held by the parent. |
| G3, token threading with a `token_required` retry | **Built**, including the `current` carry (`guestpage.go:70-77`, `:159-174`). |
| Phase 0, the whole loop with no app changes | **Built**, as `/port` on the gateway (`gateway/main.go:53-57`). |
| Phase 1, `clients.kind` gains `guest` | **Not built.** The four kinds are `paired`, `child`, `manual`, `installed` (`ClientRegistry.swift:36-54`). |
| Phase 2, a `port42://port?` invite | **Not built, and the ground moved.** Every `*Invite.swift` is gone from the tree, and `invite-over-libp2p.md` replaces the credential-carrying link with an enrolment coupon. |
| The transport (ngrok, a public gateway URL) | **Retired by D5.** `TunnelService` is gone; only `ngrok-skip-browser-warning` headers remain (`gateway/main.go:45`, `:55`, `:64`, `:180`). The gateway binds `:4242` (`main.go:22`). **So the guest page has no path from outside the machine today.** |
| The boundary, "the page shows ONE shared port and nothing else" | **Survives and gets stronger.** It is now the definition of the web audience rather than a restraint. |
| Open question 3, "does the shim expose every bridge method or a subset?" | **Still open, and §6 is the answer to it.** The shim is a `Proxy`, the local surface is a `Proxy`, and neither has a subset. |

## 9 · The smallest useful version

**Fork a port you were shared, from a known Port42 peer, into your space, starting at zero grants.**

1. **`port.fork { id }`.** Reads `getHtml` plus `ports.list`, mints a new udid, sets `html`,
   `userTitle`, `portType` and `capabilities`, sets `origin`, and drops everything in the "No"
   column of §1.
2. **The fork's principal is the new port, never the caller.** Not `createdBy: p.id`. Both
   inheritance paths in §5 cut, with a test on each.
3. **`web` only in the first cut.** `terminal` forking hands over a command line and needs the
   `.terminal` escalation `port.create` already applies (`BridgeMethods.swift:137-147`). `browser` is
   a URL and is harmless. `chat` is not forkable.
4. **An install card that names the source peer, the title, and the declared capabilities as a
   claim** rather than as a fact (§4).
5. **A fork of your own port needs none of this** and is worth shipping first: it is the same verb
   with `origin.peer` = self, it exercises the id and grant machinery under no trust pressure at
   all, and "duplicate this port so I can change it without breaking the one that works" is wanted
   on its own.

**What this deliberately does not solve:** §6. A forked port that asks for `.terminal` and is
granted it can do anything. The honest mitigation in the smallest version is that the card names a
peer the user chose to accept a share from, and that a fresh fork holds nothing until the user says
yes to a card that names it. That is a real reduction and it is not containment. **Containment is
§6.1 and §6.2, and it should be sequenced before the audience widens past known peers.**

## 10 · Which parts serve publishing too

**Shared, because share is one mechanism:** the artifact definition in §1 (what is the thing versus
what is this instance of it), the fact that geometry and adoption are never part of the thing, the
capability list being a claim (§4), and every structural finding in §6, since a published port is
still a port running on the author's machine with the author's grants.

**Fork-specific:** identity minting, the two grant-inheritance cuts (§5), lineage (§7), and the
install card. A published port is never installed anywhere, so it needs none of them.

**Publish-specific and not addressed here:** a transport that reaches outside the machine, which
D5 retired and Phase 4 has not yet replaced, and the RPC question below.

## 11 · Forward pointer: rendering without shipping code

Noted as connected, not scoped. Today a viewer renders a port by receiving its source
(`guestpage.go:116`, `:119`). If a viewer instead received rendered output and sent back input, three
separate problems close at once:

- **The fork flag becomes enforceable on the web**, because there is no source in the viewer's tab
  to read (§3).
- **A port's code and its data never leave the machine**, which is a different and stronger promise
  than "the recipient agreed not to copy".
- **It works for ports whose live state cannot be replicated at all.**
  `invite-over-libp2p.md` measured that a web port's DOM and JS heap *"does not replicate"* and can
  only be re-derived by replaying inputs.

That is the RPC / Mirror / Converge fork from `invite-over-libp2p.md` arriving through a different
door: sharing a port and meshing your own machines turn out to need the same decision about where a
port's state lives. It is also what would let a phone be a viewer, which
`docs/research/iphone.md` reaches by a third route (it can render and drive ports; it cannot host
agents). Three notes now point at one mechanism, which is the argument for scoping it deliberately
rather than discovering it inside whichever feature needs it first.

## What could not be determined

- **Whether any fork consumer exists.** No `fork`, `clone`, `install` or `duplicate` verb is in the
  registry or the views. Settled by: a decision, not a measurement.
- **What the origin peer id will be.** `PortObject.peerID` and `PortAddress.peerID` are both
  `String?` with no minting path in this tree, and libp2p is Phase 4. `origin.peer` is therefore
  typed as a string with no format pinned. Settled by: Phase 4's identity landing.
- **Whether a forked port should be allowed to declare `capabilities` at all**, given they are
  self-asserted and ungated (§4). Settled by: whether the install card is a consent surface or a
  description.
- **Whether `port.exec` cross-port escalation (§6) is reachable from a web guest today.** The shim
  forwards any method name (`guestpage.go:95-99`) and the guest's credential is a hand-made client
  token, so on the code path it should be. Not executed live: it would need a running Dev3 and a
  minted client, and running it against the daily driver is out of bounds. Settled by: a scenario
  run on Dev3 that calls `port.exec` on a port the guest was not shared.
- **What a `terminal` port's fork should mean.** `TerminalPortConfig` carries a cwd and an env from
  the author's machine (`PortWindowManager.swift:79-84`), and a path that exists there may not exist
  on the forker's. Settled by: deciding whether the fork rewrites those or refuses.
