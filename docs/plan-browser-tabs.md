# Plan: tabs in a browser port (Arc's left-hand list)

Status: DROPPED, 2026-09-30 (Gordon: "we aren't doing tabs, tabs are an antipattern"). A link from elsewhere opens as a new browser port on the current space instead (docs/plan-default-browser.md). Card: "Tabs in a browser port, like Arc's left-hand list"
(dash `dev-browser-tabs`). Gordon: "the only reason I like Arc is the left-hand nav for managing tabs";
"we can just build browser use into Port42 natively". Research: the architect's spike #197,
`docs/research/browser-tabs.md` on `spike/browser-tabs` (09ad3ed).

## The problem

A browser port shows one page. Every link that opens a new window does nothing (there is no UI
delegate), a second page means a second port, and a browser port forgets where it was on restart (its
start URL is all it keeps). So Port42 cannot be where someone browses, and a companion cannot see what
they browse.

## Decided

- **The tab list lives inside the browser port** (the spike's option C, and the card's words: "vertical
  tabs in one browser port"). The rail stays the list of ports.
- **One web view per tab, with sleeping tabs** (option C). The spike measured about 10 MB (a bare page)
  to 45 MB (an app-sized page) per live tab, one WebContent process each, and 99 MB for 19 sleeping
  tabs plus one live against 938 MB all live. A switch between live tabs is about 10 ms; waking a
  sleeping one is about 175 to 300 ms.

## Phase 1: tabs a person uses

What it does:

- **A tab list down the left of the browser port**, Arc-style: pinned tabs at the top, a divider, then
  the open tabs, newest last, and "+ New tab" under them. Each row: the site's initial, the page title,
  a close button on hover. The selected tab is highlighted. The address bar stays over the page.
- **Folds at compact size.** Below 520 points wide the list folds to a column of initials; the
  address bar and the page keep the rest. At card size the port shows its card, as now.
- **New tabs**: "+ New tab", ⌘T while the browser has the keyboard, and any link or script that opens a
  new window (target=_blank, window.open), which today does nothing. A new tab opens in front.
- **Close**: the hover button, or ⌘W while the browser has the keyboard. Closing the selected tab
  selects the one below it, else the one above. Closing the last tab leaves one empty tab (the port
  itself closes as it does today, from its title bar).
- **Pin and reorder**: right-click a tab to pin or unpin it. Drag rows to reorder, within pinned or
  within open.
- **Sleeping tabs**: at most 6 live tabs per browser port. Past that, the least recently used unpinned
  tab sleeps: its web view is released, its URL, title and back-forward state are kept, and selecting
  it wakes it. The selected tab never sleeps. A sleeping row is dimmed.
- **It remembers**: tabs, their order, pins and the selected tab survive a restart. On launch only the
  selected tab loads; the others wake when chosen. The selected tab's URL is also written back to the
  port, so a browser port no longer restarts at its first page.
- **Everything else follows the selected tab**: the port's card (page, site, loading bar), the stale-
  write token, `port.getDom` and `port.exec`, the title in ⌘K. Nothing outside the browser port changes.

How it is built, in steps, each with its tests:

1. **The tab model**, pure: a tab (id, url, title, pinned, last active, asleep) and a tab set with
   open, close (and what gets selected), select, pin, move, and which tab sleeps next. Tests on each
   rule.
2. **Persistence**: a new `browserTab` table (a new migration, keyed by the port's udid, with position
   and selected). Round-trip tests, and a port's tabs are deleted with the port.
3. **Many web views per browser port** in `PortWindowManager`: a web view per live tab, built the way a
   browser port's is today. `webViews[id]` is always the selected tab's, so every existing reader keeps
   working; switching rebinds the facts, URL and navigation observers. A UI delegate turns new-window
   requests into tabs. Tests on a headless world: the selected tab is the port's view; a new tab from a
   link; sleep past the budget releases a view and waking rebuilds it at its URL; restart restores the
   list with only the selected tab loaded.
4. **The tab list view** in `ShellBrowserTile`, with the fold at compact width, pin, close, drag to
   reorder, and ⌘T / ⌘W while a browser holds the keyboard.
5. **Live on Dev6**: several tabs, a link that opens a new window, pin and reorder, sleep past six and
   wake, restart and find it all back, the card following the selected tab. Screenshots.

Not in Phase 1: tab groups and folding groups, favicons from the site (initials instead), a snapshot
of a sleeping tab, tabs in the API.

## Phase 2: companions see the tabs (planned in full before it starts)

- The API: list, open, select and close tabs; `port.getDom` and `port.exec` take a tab; a text read
  (the page's text and links, not its HTML) for a model turn.
- Tab events on the port's topic (opened, navigated, title changed, closed, slept), so a companion can
  watch a browser port. Today a browser port publishes nothing a watch can wake on.
- **A decision for Gordon before this ships**: browser ports share the default data store, so a tab
  may be a page he is signed in to. Which tabs a companion may read (all, pinned only, only ones it
  opened, or on his say per site) is his call.

## How it is checked

Swift Testing on the model, persistence and the manager (steps 1 to 3), calibrated by breaking each
rule. The full suite and ImagineTeamScenarioTests green. Live on Dev6 with screenshots, and what was
not checked said plainly.
