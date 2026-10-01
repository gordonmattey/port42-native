# Plan: everything the app does, the API does

Status: Phase A done (a786df9, fea03b1, d2cda25; checked live on Dev6 with Gordon clicking the cards). Phase B building, 2026-09-30. Gordon: "API parity" (picked from the top five). Source: the gap review,
`docs/api-gap-review.md` (#132). Found again when echo was recreated with an unfilled `{{USER}}` in his prompt
and the API could not fix it. Branch `lead/for-1.0.7`.

## The rule

Anything a person can change in the app, an agent can change through the API, under the same checks the
app applies, and with a permission when it acts on something the agent does not own. Secrets stay
human-only. Each method is declared once in the registry; the references, tool schemas and guest table
regenerate from it, and tests fail when they are stale.

## What exists, and what does not

Already there: `port.move` takes `space_id` (#126), `companions.remove`, `companions.create`,
`companions.watch*`, `port.manage` (focus, close, hide, pause, show, pin, pinEverywhere, unpin),
`space.create/delete/list/current/setWorkingDirectory/switchTo`, `invite.create/list/revoke/accept`.

## Phases

**A. Companions.** `companions.update` (name, prompt, model, runs, command, args, working directory,
trigger; not secrets) and `companions.delete`. The app already has `updateCompanion` (a rename refuses a
name another companion holds) and `deleteCompanion`. Authorization: a companion updates itself freely; editing another
companion, or deleting any, asks the person every time with a card naming it, and a yes is never kept; the
person may do any; secrets never. Tests: each field, the rename clash, the permission, delete closing what it should.

**B. Ports across spaces.** `port.manage showIn` and `hideFrom` (the adoption the "Spaces…" row uses, #128),
and `ports.list` reporting where a port is also shown. Under the write scope (APP-11).

**C. Spaces.** `space.update` (name, accent), `space.rest`, `space.wake`, `space.reorder`; `space.list`
reports resting and accent.

**D. Port tiles.** `port.manage reload`, `port.move` with width and height, `port.fork`.

**E. Sharing after the invite.** `invite.shared` (who, with which rights), `invite.setRights`, `invite.stop`,
`remote.leave`, `remote.setWake`.

**F. Cleanup.** `port.manage background` and `unbackground` and the `move` right in the descriptions; the
dead menu items (New Space, Help), wired or removed.

## Not in this

Secrets from the API, ever. The cross-space grants (`docs/plan-cross-space-ports.md`) and the shared permission
card (`docs/plan-permission-card.md`) are their own cards; this plan's new methods use the card when it exists.

## How each phase is checked

Swift Testing, calibrated (break the check, see it fail, restore); the generated references regenerated;
`ImagineTeamScenarioTests`, `BridgeTargetScopeTests` and `BridgeSchemaParityTests` green; every new method
classified in `RemoteAccess` and the target-scope table. Live on a dev instance, as an agent would call it.

## Decisions for Gordon

None to start Phase A. Decided with Gordon's echo case: a companion may edit another, but each edit asks the person.
