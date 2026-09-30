# Plan: browser use (a companion drives a browser port you can see)

Status: Phase 1 building, 2026-09-29. Card #177 (computer use), browser first. Gordon: "we can just
build browser use into Port42 natively"; "I want it to act on those pages ... but it needs permission
somehow ... I want to keep OAuths too ... use Keychain". Tabs (#173, `docs/plan-browser-tabs.md`) wait
behind this: "we won't need tabs for a start".

## The problem

A companion can read a browser port (`port.getDom`) and run script in it (`port.exec`), and it has an
invisible browser of its own (`browser.*`). It cannot see the page you see, click or type the way a
person does (a script click is not a trusted event, and sites ignore it), or work on a site you are
signed in to with your say-so. And a login that opens a popup ("Sign in with Google") does nothing in a
browser port today, because nothing handles a new window.

## What it does

The loop: **look** (a screenshot of the port's page and a numbered list of what can be acted on),
**decide** (the model picks one step), **act** (Port42 performs it as real input), look again.

- **Sign-ins stay.** Browser ports keep one persistent store, so a site stays signed in across
  restarts, OAuth included, and popups work (Phase 1).
- **Per companion, per site permission.** The first time a companion looks at or acts on a site in a
  browser port, a card asks: "calm-moth wants to use github.com in your browser (you're signed in
  there)", with Allow once, Always for this site, Deny. Grants show in Settings, Access, revocable per
  companion and site.
- **Passwords in the Keychain, never in the model.** Port42 keeps site logins as Keychain internet
  passwords. A companion can only ask to "log in"; Port42 fills the form itself, so the password never
  passes through the companion, the model or a page's instructions. Filling is its own permission.
- **Visible, and yours to take over.** A highlight on what it acts on, its card and presence say
  "clicking Sign in", and touching the port takes it back (right of way, as today).

## Phase 1: popups and OAuth in browser ports

- A browser port gets a UI delegate. A page that opens a window with a size (an OAuth or payment
  popup) gets a popup drawn over the port, with its address and a close button; the popup keeps its
  link to the page that opened it, so the sign-in result comes back, and it closes itself when the site
  closes it. A plain new-window link (target=_blank, no size) opens in the port itself, since there are
  no tabs yet.
- A page's alert, confirm and prompt show as sheets instead of being silently dismissed, and a file
  input opens the file picker.
- Checked: tests on a headless browser port (a sized window.open makes a popup tied to its port and
  window.close removes it; a plain target=_blank navigates the port; confirm answers). Live on Dev6:
  sign in to a site through a Google popup, restart, still signed in.

## Phase 2: look and act (planned in full before it starts)

- `port.look(id)`: the port's page as an image (its own view, so no screen permission) and the
  numbered actionable elements (role, label, box), plus the page's text.
- `port.act(id, action)`: click (an element number or a point), type, press a key, scroll, go to a
  URL, go back. Delivered as real mouse and key events to the port's view.
- The per-site permission card and grants, the highlight, the presence line, right of way.

## Phase 3: Keychain logins (planned in full before it starts)

- Logins stored as Keychain internet passwords per site, added in Settings, Secrets, or offered for
  saving when the person signs in by hand.
- `port.act login`: Port42 finds the form and fills it; the credential never leaves Port42. Its own
  permission card, naming the account.

## Not in this

- Tabs (#173, after this).
- Always asking before buying, sending or deleting on an allowed site (add it if wanted).
- The headless `browser.*` session getting look and act (it can follow once the port has them).
