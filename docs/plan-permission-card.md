# Plan: one permission card, one rights vocabulary

Status: decided, not built (Gordon, 2026-09-30: "does it make sense that it's the same card across
everything", then yes). For 1.0.7 or later. A design card for the dev lead; the cross-space card
(`docs/plan-cross-space-ports.md`) is its first user.

## The problem

Each permission asks in its own words and its own look: a capability (terminal, screen, camera...), a
named secret, a site a companion may use in a browser port, a share, a port reaching another space. A
person has to learn each, and nothing says which asks are small and which are large.

## What it does

- **One card layout.** Who ("calm-moth", "Launch desk, small") wants to do what (see, use, edit,
  control) to what (a site, a port in another space, a secret, the screen). Allow once, Always, Deny.
  Built once, in `ShellPermissionOverlay`, and every ask uses it.
- **One vocabulary.** The rights are the ones sharing already uses: see, use, edit, wake_agents, fork.
  A capability that is not about a port maps onto a named verb in the same table (screen: see the screen;
  terminal: control a shell).
- **Weight shows.** A stronger right (edit, control, anything that reaches outside Port42, anything that
  cannot be taken back) looks stronger and cannot be granted by "Always" alone: it needs an extra tick. A
  read of a status line does not look like the keys to a shell.
- **One table**, in `docs/interaction-model.md`: every permission, who asks, what it names, which rights,
  and its weight.

## Not in this

- Changing what any permission guards, or what the person has already granted: existing grants stay.

## Order

1. The table of every permission today and its weight (a doc and a test that fails when a permission has no
   row).
2. The card template, with the cross-space card built on it first.
3. The existing cards, one at a time, onto it.

## How it is checked

A test that every `PortPermission` and every grant object kind has a row in the table; the card for each
shows its who, what, rights and weight; a strong right cannot be granted by "Always" alone. Live on a dev
instance: raise each card and look at them together.
