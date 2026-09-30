# Plan: browser use (a companion drives a browser port you can see)

Status: Phase 1 done (16c29b4; Gordon signed in to Google in a Dev6 browser port, by email, 2026-09-29). Phase 2 building. Card #177 (computer use), browser first. Gordon: "we can just
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

Found in Phase 1: a passkey sign-in fails in a browser port ("failed to find Bluetooth device").
WebKit gives passkeys to an app's web views only with Apple's browser entitlement
(`com.apple.developer.web-browser.public-key-credential`), which the Account Holder requests on
Apple's form. Until then, "Try another way" signs in by password. A draft of the request is to be
written for Gordon.

## Phase 2: look and act

Two methods on a browser port, used by any companion through the `port42` command, in a loop.

**`port.look(id)`** returns:
- `image`: the path of a PNG of the port's page as it is on screen (the view's own snapshot, so no
  screen permission), with each actionable element outlined and numbered on it (set-of-marks). A file,
  not base64, so a companion reads it with its image tool and the reply stays small.
- `elements`: the numbered list, each `{n, role, label, box}` in the page's coordinates; a field also
  gives its type and value, except a password field, whose value is never returned.
- `text`: the visible page's text, capped, and `url`, `title`, `token`.
The element scan runs in an isolated script world, so the page can neither see it nor tamper with
the numbering.

**`port.act(id, action, token)`**, one step per call:
- `click` an element `n` (its center) or a point `x,y`; `type` text (into element `n` after clicking
  it, else where the focus is); `key` (Enter, Tab, Escape, arrows, with modifiers); `scroll` by an
  amount, optionally over element `n`; `navigate` to a URL; `back`; `forward`.
- Delivered as real mouse and key events to the port's view, so the page sees trusted input and a
  click may open a popup, as a person's would. Returns what changed: url, title, and whether the page
  navigated. The companion looks again before its next step.
- A write, with the port's token: if the person has touched the port since the companion looked, the
  act is refused with `stale_write` and the companion looks again (right of way). The events Port42
  delivers for a companion do not count as the person driving.
- The port must be on the desktop (tiled or focused), since events need a window; a hidden port
  answers with an error that says to show it.

**Permission, per companion and per site.** Both methods ask, the first time a companion uses a site,
with a card: "calm-moth wants to use github.com in your browser (you may be signed in there)". The
answer is remembered for that companion and site (the grant object `site:<host>`, beside the
`secret:<name>` grants) and shows in Settings, Access, where it can be revoked. The person themselves,
and a port's own page, are not asked. A navigation to a new site asks again for that site before the
next look or act.

**Seen as it happens.** A brief ring where each click lands and a caret where it types, drawn over the
port; the companion's presence says what it is doing ("clicking Sign in"), so its card and the rail
show it.

How it is checked:
1. The element scan and the marks, on a local page: numbering, labels, boxes, a password never
   returned, the isolated world. Tests.
2. The action mapping: a click on `n` lands on its center in view coordinates, typing reaches a
   focused field, keys and scroll, a hidden port refused. Tests on a headless browser port in a
   window.
3. The permission: first use asks, a yes is remembered per companion and site, another site asks
   again, a no refuses, the person is not asked. Tests with the card answered by the test.
4. Right of way: a person's input between look and act makes the act stale; a companion's own events
   do not. Tests.
5. Live on Dev6, the test app (Gordon, 2026-09-30: "helping me sort my email, a port that is a
   transformation of what I need to pay attention to"). Gmail in a browser port, signed in. A companion
   reads the inbox's first page with look, opens only the threads it needs to classify, and builds an
   Attention port: needs a reply, needs you to do something, worth knowing, noise, each with a line on
   why; a click on one takes the Gmail port to that thread. Archive, label and "draft a reply" are
   buttons on the Attention port, and the companion acts in Gmail only when one is pressed. It asks
   once for mail.google.com. What it reads goes to the model it runs on, so the first version keeps to
   the inbox's first page. Screenshots.

## Phase 3: Keychain logins (planned in full before it starts)

- Logins stored as Keychain internet passwords per site, added in Settings, Secrets, or offered for
  saving when the person signs in by hand.
- `port.act login`: Port42 finds the form and fills it; the credential never leaves Port42. Its own
  permission card, naming the account.

## Not in this

- Tabs (#173, after this).
- Always asking before buying, sending or deleting on an allowed site (add it if wanted).
- The headless `browser.*` session getting look and act (it can follow once the port has them).
