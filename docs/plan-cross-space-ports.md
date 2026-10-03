# Plan: ports across spaces, with the same rights as sharing

Status: decided (Gordon, 2026-09-30); built on `lens/238` (#238), not yet in `main`. Aimed at 1.0.7. A feature for the squad to build; the dev lead
reviews the permission design.

## The call (Gordon)

A port can reach a port in another space on the same machine, by a grant, with the rights sharing a port
to the web or to another machine already uses: "it would work across any right". Today a page asking
about a port in another space gets `not_found` (APP-10, so a port cannot probe what other spaces hold).
That stays the default for anything not granted.

## The model

- **A grant**: (reading port) x (target: one port, or optionally every port in a space) x (a set of
  rights). The rights are the existing `RemoteRight`s: **see** (source, page, console, state, events:
  `state.get`, `port.getDom`, `port.console`), **use** (input and chat: `chat.read`, `chat.post`,
  `port.push`), **edit** (update, patch, rename), plus **wake_agents** and **fork**.
- **The first call asks, once.** A card names both sides: "Launch desk, small (port42-app) wants to
  use Launch desk in port42-growth". It offers the rights, **see** on by default and nothing stronger
  without the person ticking it. An optional box, off by default: "also allow every port in port42-app to
  do this to ports in port42-growth".
- **Shown and revocable** in Settings, Access, by port and space, like the secret and site grants.
- **Never asked about the person's own reads**, and a grant does not follow a fork or a share.
- **Ungranted stays `not_found`**, and a right not granted is refused as `permission_denied` naming the
  right, so a caller can ask for more.
- **Reuse the share path**: the grant is the same thing an invite carries, between two ports on one
  machine, so it goes through `RemoteAccess` and its table, not a second permission system.

## Not in this

- Granting across machines (already sharing).
- A space-wide grant for edit (the space box is see and use only; edit is per port).

## How it is checked

Calibrated tests for: default `not_found`; a card on the first call; a see grant allows `state.get` and
refuses `port.push` with `permission_denied`; each right allows exactly its methods; revoking in Access
takes effect at once; a fork or a share carries no grant; the space box grants see and use for every port
in the space and never edit. ImagineTeamScenarioTests and BridgeTargetScopeTests stay green. Live on Dev3
with the Launch desk and its small view across port42-growth and port42-app.

## As built (#238)

- The gate is `authorizeCrossSpace` (`Sources/Port42Lib/Services/CrossSpacePorts.swift`), after the remote
  gate. It acts only when a port's page names, by id, a web port in a space it cannot read. A title never
  resolves across spaces, a terminal is never reached, and a method outside the table is not admitted
  (`port.exec` stays `not_found` with every right).
- The grant: grantee `port:<reading port's key>`, object the target's key or `space:<id>`, zone "", in
  `grants`. The `port:` prefix keeps these rows out of everything that lists another machine's rights.
- Reach: the invite table (`RemoteAccess`), plus `port.fork` by `fork`. `chat.read` is `see`, as in the
  table (this plan's list put it under use). Not gated, because they already answer across spaces with no
  grant: `port.subscribe` and `presence.list` (the subscriptions spike, #246).
- `wake_agents`: a post into the other space's port wakes its companions only with it, as for a guest.
- `edit` runs APP-07's rule unchanged, and a cross-space write marks the code as changed by that port
  (NAU-02), so the target stops running with its creator's grants.
- The space box covers the reading port, not every port in its space: the grantee is always one port.
- More rights later: unticked in Settings, Access, not by a second card, so a page cannot ask again and
  again.
