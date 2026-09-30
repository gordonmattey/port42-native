# Plan: Port42 as the default web browser

Status: built, 2026-09-30; checked on Dev6 (a URL opened from outside became a browser port on the current space). Gordon: "it could be default browser in future, we should support that, why
not"; build it before the passkey entitlement request, so the request can say it truthfully. Decided: a
link opens as a new browser port on the space the person is in. Tabs are not coming (Gordon: "tabs are an
antipattern"; #173 dropped).

## What it does

- **Port42 can be chosen as the default web browser.** The release app declares the http and https
  schemes, so it is listed in System Settings, Desktop & Dock, Default web browser. Dev instances do not
  declare them, so the list does not fill with Port42 Dev, Dev2, and so on.
- **A link opened anywhere else** (Mail, Slack, a terminal, `open https://...`) opens as a new browser port
  on the current space, brought to the front, with Port42 brought forward. A link that arrives before the
  person is through setup waits and opens once they are.
- **Settings has a "Make Port42 your default browser" button** that shows macOS's own prompt, and says
  which browser is the default now.

## Not in this

- Opening .html files from Finder (a document type, and file access): later if wanted.
- Tabs.

## How it is checked

- Tests: an http or https link is recognized and a port42:// one is not; a link makes a browser port on
  the current space with that address, in front; a link held before setup opens after it.
- Live on Dev6: `open -a` with a URL opens it as a browser port on the current space. The release
  bundle's Info.plist lists http and https; a dev bundle's does not.
