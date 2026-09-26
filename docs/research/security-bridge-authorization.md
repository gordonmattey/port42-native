# Security: the bridge has no object-level authorization

Consolidated 2026-09-26 from two spikes that reached the same conclusion independently while scoping
unrelated features: `share-a-ports-code.md` (fork) and `permission-flow.md` (consent). Measured
against `nautilus` at `0369388`. Nothing here was exploited; items marked unverified are read from
code paths and say what would settle them.

## The finding

Port42 authenticates callers and does not authorize them against objects. A caller is checked for
*which machine capability* it may use (`terminal`, `screen`, `camera`) and never for *which port* it
may act on. So the port model's own boundary, one port cannot touch another, is not enforced
anywhere.

Two facts produce it:

- Every `port.*`, `ports.*`, `space.*`, `messages.*`, `bus.*` and `storage.*` method declares
  `permission: nil`. **41 of 69 registry methods are ungated.**
- `BridgeDispatcher` hardcodes the object as `.machine` at both the read and the write site
  (`BridgeDispatcher.swift:112`, `:117`), so every grant in production is a port 0 grant.
  `PortObject.port` exists and nothing local fills it (`PortObject.swift:24-29`, `:61-63`).

## What an enrolled client holding zero grants can do today

Each of these needs no permission card, because the method is ungated:

| Action | Method | Evidence |
|---|---|---|
| Enumerate every port in every space | `ports.list` | `BridgeMethods.swift:1342`, `:1424`, `:1465`; `resolvePortRef` applies no caller scoping, `AppState.swift:1945-1957` |
| Read any port's source | `port.getHtml`, `port.history` | ungated |
| Read the rendered DOM of any port | `port.getDom` | ungated |
| Run arbitrary JS inside any port | `port.exec` | ungated |
| Type raw keystrokes into a live terminal | `port.push` | `BridgeMethods.swift:180` |
| Stream a live terminal's output | `port.subscribe` | `BridgeMethods.swift:46-47`; output published at `AppState.swift:1503-1506` |
| Overwrite or close another port | `port.update`, `port.close` | ungated |
| Read any space's chat | `messages.recent` takes `space_id` | `BridgeMethods.swift:1117-1119` |

The terminal row is the sharpest: **find every terminal on the machine, read everything it prints,
and type into it**, with no grant at all. Terminals are where the CLI agents live, so that is also
read and write access to every agent session.

## Two privilege escalations

**1. `port.exec` runs under the victim's principal.** A caller with no grants executes JS inside a
port that does have grants, and the calls that JS makes are attributed to the host port. Grants are
borrowed rather than checked. Unverified end to end: the code path says it works, it was not run.

**2. A port inherits its creator's machine grants at construction.** `PortBridge.init` unions in
everything the creating principal holds on port 0 in that zone (`PortBridge.swift:67-75`) and passes
it to the dispatcher as `pregrant` (`:414`), which skips the card. A grant given once to an agent
therefore reaches every port that agent ever writes, **including ports written afterwards**. The same
values are persisted on the port row (`DatabaseService.swift:1859-1860`) and restored into the bridge
at launch (`PortWindowManager.swift:233-235`).

## Consent integrity

- **Revoking a `child` client is undone by the next launch.** `upsertClient` clears `revokedAt`
  (`DatabaseService.swift:838-841`) and a spawned terminal re-registers unconditionally on the
  restore path (`AppState.swift:1441`). *Unverified: revoke, restart, re-read `clients.revokedAt`.*
- **The grantee fragments, so revocation and grants both scatter.** A spawned terminal's client id
  keys on the port's session id (`ClientRegistry.swift:240`). Dev3 minted 25 grantees in 12 hours,
  six under the single name `harness-s1-claude`.
- **A card raised while the shell is locked has no render site.** The overlay exists only in
  `ShellView` (`ShellView.swift:205-210`), a returning launch starts locked (`AppState.swift:175`)
  with the gateway already up, so the call waits and the gateway answers `timed_out` at 30 seconds
  (`gateway/gateway.go:419-423`). *Unverified: lock Dev3, time a `clipboard.read` from an ungranted
  client.*
- **A denial is not distinguishable from a failure.** Teardown resolves `false`, so `cancelRequests`
  and `denyAll` look identical to a click on Deny (`PermissionCoordinator.swift:130-150`). The Port42
  layer and the macOS TCC layer share one `permission_denied` code although the repairs differ. An
  Apple Events refusal carries no code at all (`AutomationBridge.swift:35-37`), and the screen path
  detects TCC denial by string-matching `localizedDescription` (`ScreenBridge.swift:322-327`).
- **Declared capabilities are a label, not a control.** `port.setCapabilities` is ungated and
  self-asserted (`BridgeMethods.swift:1654-1663`), and every read of it is display or filtering.
- **Zone is inconsistent across surfaces.** A port's JS carries its space (`Principal.swift:136-151`),
  a gateway caller carries `"global"` (`:87-89`), and a child's space sits inside its client id
  (`ClientRegistry.swift:218-219`). One companion therefore asks twice for the same capability, once
  as the CLI and once through a port it made.
- **The narrow grant is the one that does not persist.** `fs.pick`, the gesture that *is* the
  consent, sits behind the broad `.filesystem` grant (`BridgeMethods.swift:1003`), while the per-path
  store it fills is session-only (`AppState.swift:309-321`).

## Exposure

**Local today.** The gateway binds loopback (`GatewayProcess.swift:90` passes
`-addr 127.0.0.1:<port>`) and the tunnel was deleted in Phase 1, so nothing outside the machine can
reach the bridge. An attacker must already be a process on this machine, an enrolled client, or a
port the user opened. That bounds severity now and does not reduce the defect: the model's promise is
containment *between* ports and clients, and that promise is not kept.

**It stops being local at Phase 4.** A remote caller reaching the same ungated verbs would enumerate
and read the user's whole desktop. The plan already says reads must be scoped before anything is
remote; this note is the specific list of what that means.

**The guest page hands out a full client token.** It arrives in a query string
(`gateway/guestpage.go:50`, `:174-175`), so a shared link carries a general-purpose credential rather
than a capability for one port. The enrolment coupon in `invite-over-libp2p.md` replaces this.

## What to do, in order

1. **A stable grantee for a spawned session.** Without it, every grant and every revocation is
   scattered across identities that multiply, and nothing else in this list can be reasoned about.
2. **Gate the port verbs on the target object.** Turn the dispatcher's two hardcoded `.machine`
   arguments into a parameter and fill `PortObject.port`. The slot is already built and empty.
   `port.push` and `port.subscribe` should additionally gate on the target's kind, the way
   `port.create` already gates on `type`.
3. **Cut the pregrant.** A port should not inherit its creator's machine grants by construction, and
   certainly not for ports created later.
4. **Then consent UX.** Just-in-time with the asker's reason, plus a per-port declared manifest.
   Not an up-front bundle and not a trust level: both re-create the blanket pre-grant that
   `PortObjectGrantTests.swift:342` pins out of the tree.

Closing this is a re-consent rather than a migration. Absence of a restriction is currently
permission, so adding the restriction changes what existing grantees may do.

## Unverified, each with the test that settles it

| Claim | Test |
|---|---|
| `port.exec` cross-port escalation works from a web guest | Dev instance, minted client, exec into a port that holds a grant |
| Revoking a `child` client is undone on restart | Revoke, restart, re-read `clients.revokedAt` |
| A gated call while locked hangs to 30s | Lock the instance, time a `clipboard.read` from an ungranted client |
| Screen Recording still needs a relaunch | The card claims it may (`PermissionCoordinator.swift:68`) |
