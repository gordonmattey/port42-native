# Plan: chat window UI (onboarding + input) — 2026-07-24

Step-by-step, ordered by "contained + high value" first. Each step is independently shippable.

## 1. Multi-line, auto-expanding text entry (InputView)

**Now.** The chat input is effectively single-line; long text runs off the edge instead of wrapping.

**Want.** As you type and the text reaches the edge (e.g. a narrower window), it wraps to the next line
and the input box **grows vertically** to fit the rows. It keeps growing up to **10 rows**, then caps and
provides a **scrollbar** (scroll within the fixed 10-row height).

**Approach.** macOS 14+: `TextField(text:, axis: .vertical)` with `.lineLimit(1...10)` auto-grows from 1
to 10 rows then scrolls — simplest path. (Fallback: a `TextEditor` with a measured height clamped to 10
rows.) Preserve the send model: **Enter sends, Shift+Enter inserts a newline** — make sure a plain Enter
does not just add a line in the multiline field.

**File.** `Sources/Port42Lib/Views/InputView.swift`.

## 2. Pop ports to the right of the response (responsive MessageRow)

**Now.** Port segments stack vertically **below** the message text — `MessageRow` renders
`entry.messageSegments` in a `VStack` (`ConversationContent.swift` ~852–894).

**Want.** When there's enough horizontal room, the port sits to the **right** of the response
(side-by-side); inline-below when narrow. Reflow on resize. The first swim is full-screen (wide gutters),
so Echo's text sits left and the shader port sits right, both visible at once.

**Approach.** Split the message body so text-segments and port-segments go into a left column + right
column above a width threshold, and stack (current behavior) below it — `GeometryReader`/`ViewThatFits`
or a width-conditional `HStack`/`VStack` around the segment loop.

**File.** `ConversationContent.swift` (`MessageRow` body ~830–905).

**Open.** Multiple ports (stack on the right / grid); which side (right for LTR); does the port scroll
with the message or pin while reading.

## 3. Terminal ports get an inline card that opens in open water

**Now.** A terminal port produces **no** message segment (it opens as a desktop tile), so it leaves no
trace in the chat. Web ports get the compact non-play block (`PortCompactBlock`, ~870) that expands
inline on run.

**Want.** A created terminal shows the same **inline card** (title, type, status) — and **opening it
navigates into open water and surfaces the terminal there**, rather than rendering a live terminal inline.
The card is the handle; "open" is the gesture that takes you to the surface you drive it from.

**Approach.** (a) Make a created terminal emit an inline card/segment referencing the terminal id, so it
appears in the conversation at all. (b) A terminal variant of `PortCompactBlock` whose run/open action
calls the open-water navigation + focuses the terminal port, instead of `activatedPortIndices.insert`
(the web inline-expand path). Web ports keep expanding inline; terminals (and other not-inline-renderable
ports) route to open water.

**Files.** `ConversationContent.swift` (`PortCompactBlock`, segment rendering), the terminal-create path
(to attach a card), and the open-water navigation entry (the shell zoom / open-water button).

**Note.** Biggest of the three — plus the navigation. Do 1 and 2 first.

## Findings (2026-07-24 session — attempted step 1, reverted)

- **`ConversationContent.body` is at SwiftUI's type-check ceiling.** Adding `axis: .vertical` +
  `.lineLimit(1...10)` + an Enter/Shift-Enter `onKeyPress` to the input `TextField` tipped it into
  "the compiler is unable to type-check this expression in reasonable time" (at line ~279, the whole
  body). Splitting off the field's visual modifiers into a computed property was not enough. **Step 1's
  real prerequisite: extract the entire input bar (the `HStack` with the field + all its key/change
  handlers + send button) into its own `View` struct.** Then the multiline field fits. Reverted the
  attempt to keep the tree green (2.3 fix is committed).
- **Terminal/web port cards already exist.** `ChatEntry.terminalPortInfo` parses `[terminal:<id>:<title>]`
  and `webPortInfo` parses `[port:<id>:<title>]` (`ChatEntry.portCard(id:title:)` builds the web one). So
  step 3's "terminal gets an inline card" is partly there — a terminal already has a card format. The
  remaining work is: ensure a created terminal emits the card, render it as a `PortCompactBlock`-style
  block, and make its open action route to **open water + focus the terminal** rather than expand inline.
