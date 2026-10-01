# Request: Web Browser Public Key Credential entitlement (passkeys in browser ports)

For Gordon to submit as Account Holder, on Apple's dedicated request form for
`com.apple.developer.web-browser.public-key-credential` (linked from the entitlement's documentation
page; the general entitlement request flow does not offer it). Status: SUBMITTED 2026-09-30 by Gordon, request ID 6K9522T3Z8. Waiting on Apple. (The form also asked: is it a browser (yes), does it support WebAuthn (yes), will it integrate with iCloud Keychain passkeys (yes), and a link plus evaluation notes for the browser.)

## Why

A Port42 browser port is a WKWebView. A passkey sign-in in it fails ("failed to find Bluetooth
device", seen on Google, 2026-09-29) because WebKit gives an app's web views passkeys only with this
entitlement. Browser use (`docs/plan-browser-use.md`) needs people signed in to their own sites.

## App details

- App: Port42 (macOS 14 and later), distributed outside the Mac App Store with Developer ID and
  notarized.
- Bundle ID: `com.port42.app`
- Team ID: `5R5X43WDXE` (Gordon Mattey)
- Download: https://github.com/gordonmattey/port42-native/releases/latest

## Text for the form

**What the app does.** Port42 is a desktop for working with AI agents. Its browser ports are a
general-purpose web browser: the person types any address or search, follows links to any site, and
signs in to the sites they use, with the browser's own address bar, back and forward, and pop-up
windows for sign-in flows. Pages are not restricted to a set of domains and are not our service.

**Why passkeys are needed.** People sign in to their own accounts (Google, GitHub, their bank, work
tools) inside these browser ports. Many of those accounts are set up with passkeys, and today the
sign-in fails in our web view, so the person has to fall back to a password or cannot sign in at all.
We want passkey sign-in to work exactly as it does in Safari, for any site the person visits.

**How the credential is handled.** WebKit performs the WebAuthn ceremony; the app never sees or
stores private keys or passkey material. Sites are shown with their real address in the address bar
and in any sign-in pop-up, so the person always sees which relying party they are signing in to.

**Web browser status.** Port42 can be set as the default web browser (System Settings, Desktop & Dock,
Default web browser, or Port42's own Settings). A link opened from any other app then opens in a Port42
browser port. (Built 2026-09-30, `docs/plan-default-browser.md`. Submit this request only once a public
release has it, since Apple may download the current release to check.)

## After it is granted

- Add the entitlement to `Port42.release.entitlements` and `Port42.dev.entitlements`.
- A managed entitlement needs a provisioning profile embedded in the app: create a Developer ID
  provisioning profile for `com.port42.app` with the entitlement, embed it at
  `Contents/embedded.provisionprofile`, and have `build.sh` copy it in before signing. A Development
  profile for the dev instances.
- Check live: a passkey sign-in to Google in a Dev instance's browser port.
