# Plan: browser use (a companion drives a browser port you can see)

Status: Phases 1 and 2 done, 2026-09-30 (16c29b4; 73a992b, 9320592, 6e8d1b1 and the Gmail test fixes). Live: Gordon signed in to Google in a browser port, and a companion sorted his Gmail inbox into an Attention port with look and act on the daily driver. Phase 3 (Keychain logins) waits until a task needs a companion to sign in on its own. Card #177 (computer use), browser first. Gordon: "we can just
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
- A paused port is refused. A port on screen is acted on where the person sees it; one that is running
  with no tile, or a tile on another space, is acted on out of sight in a window off every display, and
  put back after (Gordon, 2026-09-30). Its card says what the companion is doing either way.

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

## Phase 3: remembered logins (future work, low priority; decided 2026-09-30)

**How it works today (why this is needed).** A browser port keeps cookies and site storage, which is
what keeps the person signed in across restarts. It stores no passwords: password saving and autofill
are Safari's, built on WebKit, not WebKit's. The person's saved passwords live in iCloud Keychain (the
Passwords app), and Apple lets only Safari, the Passwords app, an app signing in to its own associated
website, and password-manager extensions fill from it. A browser like Port42 cannot read them. (Chrome and
Firefox reach them only through Apple's iCloud Passwords browser extension, which talks to the Passwords
app through a helper Apple installs; there is no public equivalent for Port42.) To be confirmed with a
spike before building: that no API gives a third-party browser iCloud Keychain passwords.

What it does (Gordon: 1 yes, 2 yes, 3 yes, 4 the one-time import):

1. **Save.** A script in Port42's own world watches a browser port's forms; when one with a password field
   is submitted, Port42 offers "Save this login to Port42?" with the site and the username. Yes stores it
   in the Keychain as Port42's own internet password for that host (server, account, password). Never
   offered for a site the person said "never" to (remembered per site).
2. **Fill for the person.** When a page shows a login form for a site Port42 has a login for, a small
   offer by the field fills it on a click, as Safari does. Several accounts for one site: a choice.
3. **Fill for a companion.** `port.act` gains `login`: Port42 finds the form and fills the username and
   password itself, then submits. First a card, per companion, site and account: "calm-moth wants to sign
   in to github.com as gordon@...". The password never passes through the companion, the model or a
   page's instructions. A page that asks for a password it has no form for gets nothing.
4. **One-time import.** Settings, Secrets: import the CSV the Passwords app exports (File, Export All
   Passwords). Each row becomes a Port42 Keychain login; the screen then asks the person to delete the
   exported file, since it holds every password in plain text. Nothing is kept of the file.

5. **Passkeys** (Gordon: in Phase 3, 2026-09-30). **Blocked on Apple** granting the web browser passkey
   entitlement; the request is drafted in `docs/apple-passkey-entitlement-request.md` for Gordon to submit
   as Account Holder. Once granted: add it to the release and dev entitlements, embed the Developer ID and
   Development provisioning profiles that carry it (`build.sh` copies them in before signing), and a
   passkey sign-in in a browser port then works as in Safari, from the person's iCloud Keychain (the Mac's
   own passkeys, and a phone's by QR). A companion cannot complete one alone: a passkey needs the person's
   Touch ID or phone, so a companion that reaches one stops and asks the person, and its card says so.

Also: Settings, Secrets lists Port42's saved logins (site, username), with delete; the Keychain items are
readable only by Port42.

Not in it: reading a password manager (1Password and others) beyond the CSV import; syncing logins to
another Mac.

How it is checked (passkeys: live only, after the grant, a Google passkey sign-in on a dev instance): tests for the form watcher (a password form submit offers once; a "never" site is not
offered), the Keychain store (save, read back, delete, per host and account, in a test keychain), the
companion fill (a card per site and account; the password is typed into the page by Port42 and never in
any reply), and the CSV import (Apple's column layout, bad rows skipped and reported). Live on Dev6: save a
login, sign out, fill it; a companion signs in after the card; import a small exported file.

## Not in this

- Tabs (#173, after this).
- Always asking before buying, sending or deleting on an allowed site (add it if wanted).
- The headless `browser.*` session getting look and act (it can follow once the port has them).
